import SwiftUI
import AVFoundation
import UIKit
import os

private let burnLog = Logger(subsystem: "com.ej.explog", category: "overlay")

/// Bakes the post-capture creative layer into the media that actually gets sent.
///
/// The text, stickers and doodles added on `PostCaptureReview` are positioned,
/// scaled and rotated freely, and none of that had anywhere to go: the send
/// path collapsed every text item into one joined string, that string became
/// `Clip.label`, and playback drew `label` as a fixed caption pinned to the
/// bottom-left. So a caption dragged to the top-right of the shot arrived at
/// the bottom-left as plain text, and stickers and drawings arrived nowhere at
/// all. `saveComposite()` did honour position — but only for the "Save to
/// Photos" button, and only for photos.
///
/// This burns the overlay into the pixels instead, which needs no new schema on
/// `Clip` and no change to any playback surface: the text *is* the media.
///
/// # Coordinate spaces
///
/// Overlay positions are recorded in **screen points**, because that is where
/// the gestures happen. The media underneath is drawn `.fit` into the same
/// screen, so it occupies a smaller rect with letterbox bars around it (capture
/// is landscape, the review screen is portrait). Burning in therefore means:
/// render the overlays over the whole screen, crop to the rect the media
/// actually occupies, and scale that into the media's own pixel dimensions.
///
/// Cropping to the media rect rather than keeping the full screen is deliberate
/// — it keeps the log's aspect ratio exactly what was filmed. Baking the
/// letterbox bars into the file would put permanent black bands inside every
/// feed pane. The cost is that an overlay dragged off the shot and onto the
/// bars is clipped, which is the right trade: the bars are not part of the
/// picture.
enum OverlayBurnIn {

    // MARK: - Entry point

    /// Returns media with `overlay` burned in, or the original when there is
    /// nothing to burn or the composite fails.
    ///
    /// Failure deliberately yields the untouched capture rather than nothing:
    /// losing the overlay is bad, losing the log the user just filmed is worse.
    static func burn(_ overlay: OverlayRender, into media: CapturedMedia) async -> CapturedMedia {
        guard let fileName = media.assetFileName else { return media }
        let source = URL.documentsDirectory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return media }

        switch media.kind {
        case .photo:
            guard let burned = burnPhoto(at: source, overlay: overlay) else { return media }
            return CapturedMedia(kind: .photo, assetFileName: burned)
        case .video:
            guard let burned = await burnVideo(at: source, overlay: overlay) else { return media }
            return CapturedMedia(kind: .video, assetFileName: burned)
        case .vibe:
            // No media to burn into — a vibe log is generated art.
            return media
        }
    }

    /// The rendered overlay plus the screen it was laid out on.
    ///
    /// Kept together because neither is meaningful without the other: the image
    /// only says *what* was drawn, `screenSize` says what those coordinates
    /// were relative to.
    struct OverlayRender {
        /// Transparent everywhere the user drew nothing, sized to the screen.
        let image: UIImage
        /// The bounds the overlays were positioned in.
        let screenSize: CGSize
    }

    // MARK: - Geometry

    /// Where media of `mediaSize` lands when aspect-*fitted* into `container` —
    /// the same fit `ClipView(contentMode: .fit)` performs on the review screen.
    static func fittedRect(mediaSize: CGSize, in container: CGSize) -> CGRect {
        guard mediaSize.width > 0, mediaSize.height > 0,
              container.width > 0, container.height > 0 else {
            burnLog.notice("fittedRect: degenerate input, mediaSize=\(String(describing: mediaSize)) container=\(String(describing: container)) -> returning full container")
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / mediaSize.width, container.height / mediaSize.height)
        let size = CGSize(width: mediaSize.width * scale, height: mediaSize.height * scale)
        let rect = CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width,
                      height: size.height)
        burnLog.notice("fittedRect: mediaSize=\(String(describing: mediaSize)) container=\(String(describing: container)) -> rect=\(String(describing: rect))")
        return rect
    }

    /// The part of the screen-sized overlay that sits over the media itself.
    ///
    /// Returned at whatever resolution it was rendered at; the caller scales it
    /// to the media's pixel size when drawing, so nothing is resampled twice.
    static func cropToMedia(_ overlay: OverlayRender, mediaSize: CGSize) -> UIImage? {
        guard let cgImage = overlay.image.cgImage else { return nil }
        let rect = fittedRect(mediaSize: mediaSize, in: overlay.screenSize)

        // `overlay.image` is rendered at screen *scale*, so its pixel grid is
        // that many times denser than the point rect being cropped.
        let scale = overlay.image.scale
        let pixelRect = CGRect(x: rect.origin.x * scale,
                               y: rect.origin.y * scale,
                               width: rect.width * scale,
                               height: rect.height * scale).integral
        burnLog.notice("cropToMedia: overlay.screenSize=\(String(describing: overlay.screenSize)) overlay.image.size=\(String(describing: overlay.image.size)) overlay.image.scale=\(scale) cgImage.pixels=\(cgImage.width)x\(cgImage.height) pixelRect=\(String(describing: pixelRect))")

        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        guard let cropped = cgImage.cropping(to: pixelRect.intersection(bounds)) else {
            burnLog.error("cropToMedia: cropping failed, pixelRect \(String(describing: pixelRect)) did not intersect bounds \(String(describing: bounds))")
            return nil
        }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    /// Scales the overlay to cover `frame`.
    ///
    /// No vertical flip, which is the surprise here. Core Image's coordinate
    /// space counts from the bottom-left while the overlay was laid out from
    /// the top-left, so a flip looks obviously necessary — but
    /// `CIImage(cgImage:)` already presents the bitmap the same way up as the
    /// video frames it is composited over, and flipping puts text composed at
    /// the top of a shot at the bottom of the export. That is a perfectly
    /// valid file and completely wrong, which is exactly why
    /// `videoBurnInIsNotVerticallyFlipped` reads the pixels back rather than
    /// trusting the reasoning.
    static func fit(_ overlay: CIImage, into frame: CGRect) -> CIImage {
        let extent = overlay.extent
        guard extent.width > 0, extent.height > 0 else { return overlay }

        let scaled = overlay.transformed(by: CGAffineTransform(scaleX: frame.width / extent.width,
                                                              y: frame.height / extent.height))
        return scaled.transformed(by: CGAffineTransform(translationX: frame.origin.x,
                                                        y: frame.origin.y))
    }

    /// The media's own dimensions, in the orientation it is displayed in.
    static func naturalSize(of media: CapturedMedia) async -> CGSize? {
        guard let fileName = media.assetFileName else { return nil }
        let url = URL.documentsDirectory.appending(path: fileName)

        switch media.kind {
        case .photo:
            // `UIImage.size` is already orientation-applied, which is what the
            // review screen laid out against.
            return UIImage(contentsOfFile: url.path)?.size
        case .video:
            guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform) else { return nil }
            // A clip filmed in landscape can be stored portrait with a rotation
            // on the track; the displayed size is the transformed one.
            let displayed = natural.applying(transform)
            return CGSize(width: abs(displayed.width), height: abs(displayed.height))
        case .vibe:
            return nil
        }
    }

    // MARK: - Photos

    /// Draws the overlay onto the still and writes a new file beside it.
    ///
    /// The original is left alone: it is the only copy of what the camera
    /// actually saw, and a burn-in is not undoable.
    private static func burnPhoto(at source: URL, overlay: OverlayRender) -> String? {
        guard let image = UIImage(contentsOfFile: source.path),
              let cropped = cropToMedia(overlay, mediaSize: image.size) else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let bounds = CGRect(origin: .zero, size: image.size)
        let composited = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            // `draw(in:)` applies the image's orientation, so what lands here
            // is upright — the same thing the review screen was showing.
            image.draw(in: bounds)
            cropped.draw(in: bounds)
        }

        guard let data = composited.jpegData(compressionQuality: 0.92) else { return nil }
        let fileName = "photo-\(UUID().uuidString).jpg"
        do {
            try data.write(to: URL.documentsDirectory.appending(path: fileName), options: .atomic)
            return fileName
        } catch {
            burnLog.error("photo burn-in write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: - Video

    /// Re-encodes the clip with the overlay composited into every frame.
    ///
    /// There was no video compositing anywhere in the app before this.
    ///
    /// The textbook approach is `AVVideoCompositionCoreAnimationTool` with a
    /// Core Animation layer tree. It is not used here: that tool renders
    /// through `CARenderer`, which needs to create an `IOSurface`, and that
    /// call traps outright in an XPC-restricted process — the unit-test host
    /// among them. So the one part of this worth testing (does the overlay come
    /// out the right way up?) could not be tested at all.
    ///
    /// Core Image does the same job with no such restriction, and needs no
    /// layer tree because the overlay is a single static image rather than an
    /// animation. `sourceImage` arrives already rotated by the track's
    /// preferred transform, so a clip filmed in any orientation composites the
    /// same way.
    ///
    /// It runs once, here, at send time — producing the file that is then
    /// uploaded — rather than at playback, so every surface that plays a clip
    /// keeps rendering a plain video and needs no changes at all.
    private static func burnVideo(at source: URL, overlay: OverlayRender) async -> String? {
        let asset = AVURLAsset(url: source)

        // The overlay has to be cropped against the *displayed* size, which is
        // the transformed one — the same size the review screen laid out over.
        guard let displaySize = await naturalSize(of: CapturedMedia(kind: .video,
                                                                    assetFileName: source.lastPathComponent)),
              let cropped = cropToMedia(overlay, mediaSize: displaySize),
              let overlayCG = cropped.cgImage else { return nil }
        burnLog.notice("burnVideo: displaySize=\(String(describing: displaySize)) cropped.size=\(String(describing: cropped.size)) cropped.scale=\(cropped.scale)")

        let overlayImage = CIImage(cgImage: overlayCG)
        var loggedFirstFrame = false
        let videoComposition: AVMutableVideoComposition
        do {
            videoComposition = try await AVMutableVideoComposition.videoComposition(with: asset) { request in
                let frame = request.sourceImage.extent
                if !loggedFirstFrame {
                    loggedFirstFrame = true
                    burnLog.notice("burnVideo: first composition request, sourceImage.extent=\(String(describing: frame)) (compare width/height ratio against displaySize \(String(describing: displaySize)) above -- a swapped aspect here means the frame is still in pre-transform orientation)")
                }
                let overlaid = fit(overlayImage, into: frame).composited(over: request.sourceImage)
                request.finish(with: overlaid, context: nil)
            }
            burnLog.notice("burnVideo: videoComposition.renderSize=\(String(describing: videoComposition.renderSize))")
        } catch {
            burnLog.error("video composition build failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        guard let export = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetHighestQuality) else {
            burnLog.error("no export session for burn-in")
            return nil
        }
        export.videoComposition = videoComposition

        let fileName = "clip-\(UUID().uuidString)-text.mov"
        let destination = URL.documentsDirectory.appending(path: fileName)
        do {
            try await export.export(to: destination, as: .mov)
            return fileName
        } catch {
            burnLog.error("video burn-in export failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: destination)
            return nil
        }
    }
}
