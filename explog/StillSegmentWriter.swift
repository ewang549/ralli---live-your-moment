import AVFoundation
import UIKit
import os

private let stillLog = Logger(subsystem: "com.ej.explog", category: "reel")

/// Renders a still into a real, fixed-duration video segment.
///
/// The recap reel is one continuous video, and a photo has no video track to
/// insert — which is exactly why `VlogComposer.makeComposition` drops every
/// still and `DailyVlogView` has to count them in a footnote instead ("N photos
/// not in the reel yet"). Turning the still into actual frames is what closes
/// that gap.
///
/// `OverlayBurnIn.burnPhoto` is the closest thing that already existed, but it
/// composites into a JPEG. There is no way to get from a JPEG to something
/// `AVMutableComposition.insertTimeRange` will accept, so this writes frames
/// through `AVAssetWriter` instead — the one piece of this feature with no
/// precedent anywhere in the app.
enum StillSegmentWriter {

    /// Frames per second written for a still.
    ///
    /// A static image needs exactly one distinct frame, but a track holding a
    /// single sample plays back unpredictably (and scrubs worse), so the same
    /// buffer is appended at a normal rate. H.264 compresses the identical
    /// frames to almost nothing, so the file cost of this is negligible.
    static let frameRate: Int32 = 30

    enum WriteError: LocalizedError {
        case writerUnavailable
        case bufferUnavailable
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .writerUnavailable: "This photo couldn't be added to the reel."
            case .bufferUnavailable: "This photo couldn't be prepared for the reel."
            case .writeFailed(let message): message
            }
        }
    }

    /// Writes `image` to `url` as a `duration`-long video of `size`.
    ///
    /// `size` is the reel's render size, and the still is aspect-*fitted* into
    /// it over black rather than stretched or cropped — a photo that isn't the
    /// reel's shape keeps the framing it was taken with, matching how every
    /// playback surface in the app already treats a log.
    static func write(_ image: UIImage,
                      size: CGSize,
                      duration: CMTime,
                      to url: URL) async throws {
        try? FileManager.default.removeItem(at: url)

        // H.264 wants even dimensions; an odd one silently fails to encode.
        let width = Int(size.width.rounded()) & ~1
        let height = Int(size.height.rounded()) & ~1
        guard width > 0, height > 0 else { throw WriteError.writerUnavailable }
        let pixelSize = CGSize(width: width, height: height)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw WriteError.writeFailed(error.localizedDescription)
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.canAdd(input) else { throw WriteError.writerUnavailable }
        writer.add(input)
        guard writer.startWriting() else {
            throw WriteError.writeFailed(writer.error?.localizedDescription ?? "The reel couldn't start writing.")
        }
        writer.startSession(atSourceTime: .zero)

        guard let buffer = pixelBuffer(for: image, size: pixelSize, pool: adaptor.pixelBufferPool) else {
            writer.cancelWriting()
            throw WriteError.bufferUnavailable
        }

        let frameDuration = CMTime(value: 1, timescale: frameRate)
        let total = max(1, Int((duration.seconds * Double(frameRate)).rounded()))

        // `requestMediaDataWhenReady` rather than a spin loop: the writer
        // decides when it can take more, and appending regardless is how you
        // get a truncated track on a slow device. The block is re-invoked
        // whenever the input drains, so it has to pick up where it left off —
        // hence the counter living outside it.
        let queue = DispatchQueue(label: "com.ej.explog.still-segment")
        let progress = WriteProgress()
        await withCheckedContinuation { continuation in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    guard progress.frame < total else {
                        progress.finish(input, continuation)
                        return
                    }
                    let time = CMTimeMultiply(frameDuration, multiplier: Int32(progress.frame))
                    guard adaptor.append(buffer, withPresentationTime: time) else {
                        stillLog.error("still segment append failed at frame \(progress.frame)")
                        progress.finish(input, continuation)
                        return
                    }
                    progress.frame += 1
                }
                // Input is full for now; this block runs again once it drains.
            }
        }

        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(total)))
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw WriteError.writeFailed(writer.error?.localizedDescription ?? "The photo segment didn't finish writing.")
        }
    }

    /// How far the append loop has got, and the guarantee it resumes exactly once.
    ///
    /// `requestMediaDataWhenReady`'s block is `@Sendable` and re-entered on the
    /// writer's own queue, so the counter can't just be a captured `var`. Every
    /// access happens on the one serial queue the block is scheduled on, which
    /// is what makes the unchecked conformance true rather than merely quiet.
    private final class WriteProgress: @unchecked Sendable {
        var frame = 0
        private var resumed = false

        func finish(_ input: AVAssetWriterInput, _ continuation: CheckedContinuation<Void, Never>) {
            input.markAsFinished()
            guard !resumed else { return }
            resumed = true
            continuation.resume()
        }
    }

    /// The still, flattened onto black at `size` and copied into a pixel buffer.
    private static func pixelBuffer(for image: UIImage,
                                    size: CGSize,
                                    pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        // Flatten first, through UIKit, so the image's `orientation` is applied
        // — `UIImage.cgImage` is the raw bitmap and ignores it, which is how a
        // photo taken in one rotation ends up sideways in the reel.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let flattened = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: OverlayBurnIn.fittedRect(mediaSize: image.size, in: size))
        }
        guard let cgImage = flattened.cgImage else { return nil }

        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height),
                                kCVPixelFormatType_32ARGB,
                                [kCVPixelBufferCGImageCompatibilityKey: true,
                                 kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
                                &buffer)
        }
        guard let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                                      width: CVPixelBufferGetWidth(buffer),
                                      height: CVPixelBufferGetHeight(buffer),
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }

        // No vertical flip, which is the surprise here — the same one
        // `OverlayBurnIn.fit(_:into:)` documents for its own coordinate space.
        // A pixel buffer's first row is the top of the frame while `CGContext`
        // counts up from the bottom, so a flip looks obviously necessary; adding
        // one puts the photo in the reel upside down. Drawing straight in is
        // already right way up.
        //
        // A flipped still is a perfectly valid, perfectly playable file and
        // completely wrong, which is exactly why
        // `stillSegmentIsNotVerticallyFlipped` decodes a frame and reads the
        // pixels back instead of trusting either this comment or the reasoning
        // behind it.
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))

        return buffer
    }
}
