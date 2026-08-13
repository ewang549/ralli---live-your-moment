import Testing
import Foundation
import AVFoundation
import CoreMedia
import UIKit
@testable import explog

/// Proves the day actually stitches into one video with the *right* overlay on
/// each segment.
///
/// Every failure this feature can have is a silent one. A reel whose segments
/// are in the wrong order, whose photos are upside down, or which paints clip
/// one's caption over clip two is a perfectly valid, perfectly playable file —
/// nothing short of decoding frames and reading pixels catches any of it. So
/// these build reels out of flat colours with known markers burned into known
/// corners, then decode frames back out and look at them.
///
/// The same approach, and the `colorAt` helper, as `OverlayBurnInTests`.
///
/// Serialized: every test here drives a real H.264 encode and a real decode, and
/// running a dozen of those at once starves the simulator's media services badly
/// enough to fail writes that are perfectly correct. There is nothing to gain
/// from parallelism in a suite this small anyway.
@MainActor
@Suite(.serialized)
struct RecapReelTests {

    // MARK: - Fixtures

    private static let reelSize = CGSize(width: 640, height: 360)

    /// A solid-colour still.
    private func solid(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A still split red over blue, for catching a vertical flip.
    private func splitImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
    }

    /// A real video file of one flat colour, written through the still writer.
    private func video(_ color: UIColor,
                       size: CGSize = RecapReelTests.reelSize,
                       seconds: Double = 1) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "reel-test-\(UUID().uuidString).mov")
        try await StillSegmentWriter.write(solid(color, size: size),
                                           size: size,
                                           duration: CMTime(seconds: seconds, preferredTimescale: 600),
                                           to: url)
        return url
    }

    /// A photo file on disk, as a capture would leave one.
    private func photo(_ color: UIColor, size: CGSize) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "reel-test-\(UUID().uuidString).jpg")
        try #require(solid(color, size: size).jpegData(compressionQuality: 1)).write(to: url)
        return url
    }

    /// A transparent overlay with one opaque red square at `rect`, in top-left
    /// coordinates — standing in for the real `ClipStamp` bitmap.
    private func marker(at rect: CGRect, canvas: CGSize) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            UIColor.red.setFill()
            context.fill(rect)
        }
        return try #require(image.cgImage)
    }

    /// One decoded frame of the reel, overlays and all.
    ///
    /// Reads through `AVAssetImageGenerator` with the reel's own video
    /// composition attached, which runs the exact compositor playback and export
    /// would — no separate code path to be wrong.
    private func frame(of reel: VlogComposer.Reel, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: reel.composition)
        generator.videoComposition = reel.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }

    /// One decoded frame of a plain file, no compositor.
    private func frame(ofFileAt url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }

    /// The colour at a normalised position (0…1 from the top-left).
    private func colorAt(_ point: CGPoint, in cgImage: CGImage) throws -> (r: Int, g: Int, b: Int) {
        let x = min(max(Int(point.x * CGFloat(cgImage.width)), 0), cgImage.width - 1)
        let y = min(max(Int(point.y * CGFloat(cgImage.height)), 0), cgImage.height - 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel,
                                             width: 1, height: 1,
                                             bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // `CGContext` counts from the bottom-left and `point` is given from the
        // top-left, so the sampled row has to be mirrored before it's offset
        // into the one-pixel window.
        let flippedY = cgImage.height - 1 - y
        context.draw(cgImage, in: CGRect(x: -x, y: -flippedY,
                                         width: cgImage.width, height: cgImage.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    // Generous thresholds: these survive a round trip through H.264, which does
    // not preserve exact values.
    private func isReddish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.r > 130 && c.g < 110 && c.b < 110 }
    private func isGreenish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.g > 100 && c.r < 120 && c.b < 120 }
    private func isBluish(_ c: (r: Int, g: Int, b: Int)) -> Bool { c.b > 110 && c.r < 120 && c.g < 120 }

    // MARK: - The still → video step

    /// A photo has to survive becoming frames the same way up it went in. This
    /// is the single easiest thing in the feature to get silently wrong: the
    /// pixel buffer's first row is the top of the frame while `CGContext` counts
    /// up from the bottom.
    @Test func stillSegmentIsNotVerticallyFlipped() async throws {
        let size = Self.reelSize
        let url = FileManager.default.temporaryDirectory
            .appending(path: "still-flip-\(UUID().uuidString).mov")
        try await StillSegmentWriter.write(splitImage(size: size),
                                           size: size,
                                           duration: CMTime(seconds: 1, preferredTimescale: 600),
                                           to: url)

        let decoded = try await frame(ofFileAt: url, at: 0.5)
        #expect(isReddish(try colorAt(CGPoint(x: 0.5, y: 0.15), in: decoded)))
        #expect(isBluish(try colorAt(CGPoint(x: 0.5, y: 0.85), in: decoded)))
    }

    @Test func stillSegmentRunsForTheRequestedDuration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "still-duration-\(UUID().uuidString).mov")
        try await StillSegmentWriter.write(solid(.green, size: Self.reelSize),
                                           size: Self.reelSize,
                                           duration: CMTime(seconds: 2, preferredTimescale: 600),
                                           to: url)

        let duration = try await AVURLAsset(url: url).load(.duration)
        #expect(abs(duration.seconds - 2) < 0.15)
    }

    // MARK: - Stitching

    /// Nothing usable in, nothing out — the caller falls back to clip-by-clip.
    @Test func reelIsNilWhenThereIsNothingToStitch() async throws {
        let missing = VlogComposer.ReelSource(
            url: FileManager.default.temporaryDirectory.appending(path: "does-not-exist.mov"),
            kind: .video, overlay: nil)
        #expect(await VlogComposer.makeReel(from: [missing]) == nil)
    }

    /// A vibe clip is generated art with no file behind it; it can't be a segment.
    @Test func vibeClipsAreLeftOutOfTheReel() async throws {
        let real = try await video(.green)
        let vibe = VlogComposer.ReelSource(url: real, kind: .vibe, overlay: nil)
        let reel = try #require(await VlogComposer.makeReel(from: [
            VlogComposer.ReelSource(url: real, kind: .video, overlay: nil), vibe,
        ]))
        #expect(reel.segments.count == 1)
    }

    /// Segments run head to tail in the order given, with no gaps — this is what
    /// makes "plays the day in hourly order" true rather than hopeful.
    @Test func segmentsRunHeadToTailInTheOrderGiven() async throws {
        let first = try await video(.green, seconds: 1)
        let second = try await video(.blue, seconds: 1)
        let reel = try #require(await VlogComposer.makeReel(from: [
            VlogComposer.ReelSource(url: first, kind: .video, overlay: nil),
            VlogComposer.ReelSource(url: second, kind: .video, overlay: nil),
        ]))

        #expect(reel.segments.count == 2)
        #expect(reel.segments[0].range.start == .zero)
        // No gap: segment two starts exactly where segment one ended.
        let firstEnd = reel.segments[0].range.end
        #expect(abs(reel.segments[1].range.start.seconds - firstEnd.seconds) < 0.001)
        #expect(abs(reel.duration.seconds - 2) < 0.2)

        // And the order is really the order: green frames first, blue after.
        #expect(isGreenish(try colorAt(CGPoint(x: 0.5, y: 0.5), in: try await frame(of: reel, at: 0.5))))
        #expect(isBluish(try colorAt(CGPoint(x: 0.5, y: 0.5), in: try await frame(of: reel, at: 1.5))))
    }

    /// A photo becomes a real segment of the reel rather than being counted in a
    /// footnote — the gap `VlogComposer`'s own doc comment used to describe.
    @Test func photosBecomeSegmentsOfTheReel() async throws {
        let clip = try await video(.green, seconds: 1)
        let still = try photo(.blue, size: Self.reelSize)

        let reel = try #require(await VlogComposer.makeReel(
            from: [
                VlogComposer.ReelSource(url: clip, kind: .video, overlay: nil),
                VlogComposer.ReelSource(url: still, kind: .photo, overlay: nil),
            ],
            stillDuration: CMTime(seconds: 2, preferredTimescale: 600)))

        #expect(reel.segments.count == 2)
        // The still holds the screen for the duration it was given.
        #expect(abs(reel.segments[1].range.duration.seconds - 2) < 0.15)
        // And it is really the photo playing there.
        #expect(isBluish(try colorAt(CGPoint(x: 0.5, y: 0.5), in: try await frame(of: reel, at: 2))))
    }

    // MARK: - Per-segment overlays

    /// The heart of the feature: one continuous file where *each* segment
    /// carries its own overlay.
    ///
    /// One overlay over the whole asset — which is all `OverlayBurnIn.burnVideo`
    /// could do — would put both markers on both segments, or one marker on
    /// both. Marking opposite corners is what tells those apart.
    @Test func eachSegmentCarriesItsOwnOverlay() async throws {
        let canvas = CGSize(width: 320, height: 180)
        let topLeft = try marker(at: CGRect(x: 0, y: 0, width: 120, height: 60), canvas: canvas)
        let bottomRight = try marker(at: CGRect(x: 200, y: 120, width: 120, height: 60), canvas: canvas)

        let first = try await video(.green, seconds: 1)
        let second = try await video(.blue, seconds: 1)
        let reel = try #require(await VlogComposer.makeReel(from: [
            VlogComposer.ReelSource(url: first, kind: .video, overlay: topLeft),
            VlogComposer.ReelSource(url: second, kind: .video, overlay: bottomRight),
        ]))

        let early = try await frame(of: reel, at: 0.5)
        #expect(isReddish(try colorAt(CGPoint(x: 0.1, y: 0.1), in: early)))
        #expect(!isReddish(try colorAt(CGPoint(x: 0.9, y: 0.9), in: early)))

        let late = try await frame(of: reel, at: 1.5)
        #expect(isReddish(try colorAt(CGPoint(x: 0.9, y: 0.9), in: late)))
        #expect(!isReddish(try colorAt(CGPoint(x: 0.1, y: 0.1), in: late)))
    }

    /// The overlay has to land the way up it was drawn. `OverlayBurnIn.fit`
    /// deliberately does not flip vertically, and this is the reel's copy of the
    /// check that keeps that true: a flip here would still export a valid file
    /// with the caption at the wrong end of the frame.
    @Test func reelOverlayIsNotVerticallyFlipped() async throws {
        let canvas = CGSize(width: 320, height: 180)
        let top = try marker(at: CGRect(x: 0, y: 0, width: 320, height: 40), canvas: canvas)
        let clip = try await video(.green, seconds: 1)

        let reel = try #require(await VlogComposer.makeReel(from: [
            VlogComposer.ReelSource(url: clip, kind: .video, overlay: top),
        ]))

        let decoded = try await frame(of: reel, at: 0.5)
        #expect(isReddish(try colorAt(CGPoint(x: 0.5, y: 0.05), in: decoded)))
        #expect(!isReddish(try colorAt(CGPoint(x: 0.5, y: 0.95), in: decoded)))
    }

    /// A photo segment gets its stamp too — the overlay path has to be the same
    /// one for both kinds, or captions would appear on clips and not on stills.
    @Test func photoSegmentsCarryTheirOverlayToo() async throws {
        let canvas = CGSize(width: 320, height: 180)
        let top = try marker(at: CGRect(x: 0, y: 0, width: 320, height: 40), canvas: canvas)
        let still = try photo(.blue, size: Self.reelSize)

        let reel = try #require(await VlogComposer.makeReel(
            from: [VlogComposer.ReelSource(url: still, kind: .photo, overlay: top)],
            stillDuration: CMTime(seconds: 1, preferredTimescale: 600),
            renderSize: Self.reelSize))

        let decoded = try await frame(of: reel, at: 0.5)
        #expect(isReddish(try colorAt(CGPoint(x: 0.5, y: 0.05), in: decoded)))
        #expect(isBluish(try colorAt(CGPoint(x: 0.5, y: 0.6), in: decoded)))
    }

    // MARK: - Geometry

    /// A clip that isn't the reel's shape letterboxes into it rather than being
    /// cropped — the same rule every playback surface in the app follows.
    @Test func offShapeSegmentsAreFittedNotCropped() {
        let transform = VlogComposer.transformFitting(
            natural: CGSize(width: 1080, height: 1080),
            preferred: .identity,
            into: CGRect(x: 0, y: 0, width: 640, height: 360))

        // A square fitted into 640×360 becomes 360×360, centred horizontally.
        let mapped = CGRect(origin: .zero, size: CGSize(width: 1080, height: 1080)).applying(transform)
        #expect(abs(mapped.width - 360) < 0.5)
        #expect(abs(mapped.height - 360) < 0.5)
        #expect(abs(mapped.minX - 140) < 0.5)
        #expect(abs(mapped.minY) < 0.5)
    }

    /// A rotated clip is stood upright before it is fitted, so a mixed-orientation
    /// day doesn't play half sideways.
    @Test func rotatedSegmentsAreStoodUprightBeforeFitting() {
        let quarterTurn = CGAffineTransform(rotationAngle: .pi / 2)
        let transform = VlogComposer.transformFitting(
            natural: CGSize(width: 1920, height: 1080), // stored landscape…
            preferred: quarterTurn,                     // …displayed portrait
            into: CGRect(x: 0, y: 0, width: 640, height: 360))

        let mapped = CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)).applying(transform)
        // Displayed shape is 1080×1920, which fits 360-tall into the reel.
        #expect(abs(mapped.height - 360) < 0.5)
        #expect(abs(mapped.width - 202.5) < 1)
        // Landed inside the frame, not off its edge.
        #expect(mapped.minX >= -0.5)
        #expect(mapped.minY >= -0.5)
    }

    /// The stamp is laid out against the media as it appears *on screen*, not
    /// against the video's pixel size — otherwise a 34pt hour banner renders as
    /// a speck in the corner of a 1920-wide frame.
    @Test func stampCanvasMatchesTheMediaAsItAppearsOnScreen() {
        let canvas = RecapStamp.canvas(mediaSize: CGSize(width: 1920, height: 1080),
                                       screen: CGSize(width: 390, height: 844))
        #expect(abs(canvas.width - 390) < 0.5)
        #expect(abs(canvas.height - 219.375) < 0.5)
    }

    /// The real stamp renders something — the reel's overlays come from here,
    /// and a silently-nil bitmap would mean a reel with no captions at all.
    @Test func stampRendersABitmap() throws {
        let image = try #require(RecapStamp.image(date: .now, caption: "hello",
                                                  canvas: CGSize(width: 390, height: 220)))
        #expect(image.width == 390)
        #expect(image.height == 220)
    }
}
