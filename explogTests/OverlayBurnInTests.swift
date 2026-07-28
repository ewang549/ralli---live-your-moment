import Testing
import Foundation
import AVFoundation
import UIKit
@testable import explog

/// Proves the creative layer actually lands on the pixels where it was dragged.
///
/// The interesting failures here are silent ones — an overlay that burns in
/// upside down, mirrored, or offset by the letterbox bars still produces a
/// perfectly valid file, and nothing short of looking at the pixels catches it.
/// So these tests build media with known content, run the real burn-in, and
/// read specific pixels back out.
@MainActor
struct OverlayBurnInTests {

    // MARK: - Fixtures

    /// A transparent screen-sized overlay with one opaque red square, drawn at
    /// `markerRect` in screen points.
    private func overlay(screen: CGSize, markerRect: CGRect) -> OverlayBurnIn.OverlayRender {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: screen, format: format).image { context in
            UIColor.red.setFill()
            context.fill(markerRect)
        }
        return OverlayBurnIn.OverlayRender(image: image, screenSize: screen)
    }

    /// A solid-colour still written to Documents, as a capture would be.
    private func writePhoto(size: CGSize, color: UIColor) throws -> CapturedMedia {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let fileName = "test-photo-\(UUID().uuidString).jpg"
        try #require(image.jpegData(compressionQuality: 1))
            .write(to: URL.documentsDirectory.appending(path: fileName))
        return CapturedMedia(kind: .photo, assetFileName: fileName)
    }

    /// The colour at a normalised position (0…1 from the top-left) of `image`.
    private func colorAt(_ point: CGPoint, in image: UIImage) throws -> (r: Int, g: Int, b: Int) {
        let cgImage = try #require(image.cgImage)
        let x = min(max(Int(point.x * CGFloat(cgImage.width)), 0), cgImage.width - 1)
        let y = min(max(Int(point.y * CGFloat(cgImage.height)), 0), cgImage.height - 1)

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try #require(CGContext(data: &pixel,
                                             width: 1, height: 1,
                                             bitsPerComponent: 8, bytesPerRow: 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // `CGContext` counts from the bottom-left and `point` is given from the
        // top-left, so the row being sampled has to be mirrored before it can
        // be offset into the one-pixel window.
        let flippedY = cgImage.height - 1 - y
        context.draw(cgImage, in: CGRect(x: -x, y: -flippedY,
                                         width: cgImage.width, height: cgImage.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
    }

    private func isReddish(_ color: (r: Int, g: Int, b: Int)) -> Bool {
        color.r > 150 && color.g < 100 && color.b < 100
    }

    // MARK: - Geometry

    /// Landscape media on a portrait screen letterboxes into a centred band —
    /// this is the rect every overlay coordinate is measured against.
    @Test func fittedRectCentresLandscapeMediaOnAPortraitScreen() {
        let rect = OverlayBurnIn.fittedRect(mediaSize: CGSize(width: 1920, height: 1080),
                                            in: CGSize(width: 400, height: 800))
        #expect(rect.width == 400)
        #expect(abs(rect.height - 225) < 0.01)
        #expect(rect.origin.x == 0)
        // Vertically centred: (800 - 225) / 2.
        #expect(abs(rect.origin.y - 287.5) < 0.01)
    }

    @Test func fittedRectSurvivesDegenerateInput() {
        let container = CGSize(width: 400, height: 800)
        let rect = OverlayBurnIn.fittedRect(mediaSize: .zero, in: container)
        // Falls back to the whole container rather than dividing by zero.
        #expect(rect.size == container)
    }

    /// The crop has to drop the letterbox bars, so an overlay sitting at the
    /// top of the *media* ends up at the top of the cropped image — not a third
    /// of the way down it.
    @Test func cropDiscardsTheLetterboxBars() throws {
        let screen = CGSize(width: 400, height: 800)
        let mediaSize = CGSize(width: 1920, height: 1080)
        // Media band is y = 287.5...512.5. Put the marker across the top of it.
        let render = overlay(screen: screen,
                             markerRect: CGRect(x: 0, y: 288, width: 400, height: 40))

        let cropped = try #require(OverlayBurnIn.cropToMedia(render, mediaSize: mediaSize))
        #expect(abs(cropped.size.width - 400) < 2)
        #expect(abs(cropped.size.height - 225) < 2)

        // Red near the top of the crop, clear near the bottom.
        #expect(isReddish(try colorAt(CGPoint(x: 0.5, y: 0.05), in: cropped)))
        #expect(!isReddish(try colorAt(CGPoint(x: 0.5, y: 0.9), in: cropped)))
    }

    // MARK: - Photos

    /// The whole point: text dragged to the top-left of the shot is at the
    /// top-left of the file that gets sent.
    @Test func photoBurnInKeepsTheOverlayWhereItWasDragged() async throws {
        let screen = CGSize(width: 400, height: 800)
        let media = try writePhoto(size: CGSize(width: 1920, height: 1080), color: .blue)

        // Media band is y = 287.5...512.5. A marker in its top-left quarter.
        let render = overlay(screen: screen,
                             markerRect: CGRect(x: 20, y: 300, width: 100, height: 40))

        let burned = await OverlayBurnIn.burn(render, into: media)
        let fileName = try #require(burned.assetFileName)
        #expect(fileName != media.assetFileName, "the original capture must not be overwritten")

        let url = URL.documentsDirectory.appending(path: fileName)
        defer {
            try? FileManager.default.removeItem(at: url)
            media.assetFileName.map { try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: $0)) }
        }
        let result = try #require(UIImage(contentsOfFile: url.path))

        // Same shape as what was filmed — no bars baked in.
        #expect(abs(result.size.width / result.size.height - 1920.0 / 1080.0) < 0.01)

        // Marker centre sits at x ≈ 70/400, y ≈ (320 - 287.5)/225 of the media.
        #expect(isReddish(try colorAt(CGPoint(x: 70.0 / 400.0, y: 32.5 / 225.0), in: result)))
        // ...and nowhere near the opposite corner, which is where a vertical
        // or horizontal flip would have put it.
        #expect(!isReddish(try colorAt(CGPoint(x: 70.0 / 400.0, y: 1 - 32.5 / 225.0), in: result)))
        #expect(!isReddish(try colorAt(CGPoint(x: 1 - 70.0 / 400.0, y: 32.5 / 225.0), in: result)))
    }

    @Test func captureWithNothingDrawnOnItIsHandedThroughUntouched() async throws {
        let media = try writePhoto(size: CGSize(width: 640, height: 480), color: .green)
        defer {
            media.assetFileName.map { try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: $0)) }
        }
        // A fully transparent overlay still composites, but a *missing* file
        // is the case that must not lose the capture.
        let missing = CapturedMedia(kind: .photo, assetFileName: "does-not-exist.jpg")
        let render = overlay(screen: CGSize(width: 400, height: 800), markerRect: .zero)
        let result = await OverlayBurnIn.burn(render, into: missing)
        #expect(result.assetFileName == "does-not-exist.jpg")
    }

    // MARK: - Video

    /// The one that can't be reasoned about from the API docs: Core Animation
    /// renders into a video frame bottom-left first, so an overlay composited
    /// without accounting for that comes out vertically mirrored.
    @Test func videoBurnInIsNotVerticallyFlipped() async throws {
        let videoSize = CGSize(width: 640, height: 360)
        let media = try await writeVideo(size: videoSize, color: .blue)
        let screen = CGSize(width: 360, height: 720)

        // Media band on this screen: height = 360 * (360/640) = 202.5,
        // y = 258.75...461.25. Marker across the top of the media.
        let render = overlay(screen: screen,
                             markerRect: CGRect(x: 0, y: 260, width: 360, height: 30))

        let burned = await OverlayBurnIn.burn(render, into: media)
        let fileName = try #require(burned.assetFileName)
        #expect(fileName != media.assetFileName, "the original capture must not be overwritten")

        let url = URL.documentsDirectory.appending(path: fileName)
        defer {
            try? FileManager.default.removeItem(at: url)
            media.assetFileName.map { try? FileManager.default.removeItem(at: URL.documentsDirectory.appending(path: $0)) }
        }

        let frame = try await firstFrame(of: url)
        // Top of the frame is red, bottom is not. Reversed means the layer
        // tree needs flipping; both red means the crop is wrong.
        #expect(isReddish(try colorAt(CGPoint(x: 0.5, y: 0.03), in: frame)))
        #expect(!isReddish(try colorAt(CGPoint(x: 0.5, y: 0.95), in: frame)))
    }

    /// A one-second solid-colour clip, written as a real file.
    private func writeVideo(size: CGSize, color: UIColor) async throws -> CapturedMedia {
        let fileName = "test-clip-\(UUID().uuidString).mov"
        let url = URL.documentsDirectory.appending(path: fileName)
        try? FileManager.default.removeItem(at: url)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let pool = try #require(adaptor.pixelBufferPool)
        for frame in 0..<15 {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixelBuffer = try #require(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            let context = try #require(CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ))
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: size))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 15))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return CapturedMedia(kind: .video, assetFileName: fileName)
    }

    private func firstFrame(of url: URL) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let (cgImage, _) = try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600))
        return UIImage(cgImage: cgImage)
    }
}
