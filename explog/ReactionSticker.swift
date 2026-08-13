import SwiftUI
import AVFoundation
import UIKit
import os

private let stickerLog = Logger(subsystem: "com.ej.explog", category: "reaction")

/// Builds the picture a reaction is actually sent as.
///
/// Reacting to a friend's log used to post the string "🔥 reacted to your log",
/// which tells the friend nothing about *which* log — a thread full of those is
/// unreadable. Stream has no server-side sticker or overlay feature, so the
/// image has to exist as a file before it is sent: a still of the log with the
/// emoji stamped on it, uploaded as an ordinary image attachment.
///
/// The compositing technique is the one `PostCaptureReview.saveComposite()`
/// already uses — `ImageRenderer` flattening a SwiftUI `ZStack` into a
/// `UIImage`. Only pulling the still is new, and only for video.
enum ReactionSticker {
    /// Long edge of the sticker in points; the short edge follows from the log's
    /// own aspect ratio. Large enough to stay sharp at full thread width, small
    /// enough that the upload is quick.
    private static let longEdge: CGFloat = 960

    /// The canvas, shaped like the log rather than the log squeezed into the
    /// canvas.
    ///
    /// This used to be a fixed 540×960 portrait card that a landscape capture
    /// was `.fill`-cropped into — the one surface left in the app still cropping
    /// a log, after every clip container moved to `.fit`. The reaction a friend
    /// receives is supposed to say *which* log it is, and a strip out of the
    /// middle of a 16:9 shot frequently doesn't.
    private static func renderSize(aspectRatio: Double) -> CGSize {
        let ratio = aspectRatio > 0 ? aspectRatio : Clip.defaultAspectRatio
        return ratio >= 1
            ? CGSize(width: longEdge, height: (longEdge / ratio).rounded())
            : CGSize(width: (longEdge * ratio).rounded(), height: longEdge)
    }

    /// A still of `clip` with `emoji` on it, written to a temp file ready to
    /// upload. Nil when there is no frame to be had — the caller then falls
    /// back to sending text, rather than sending an empty message.
    @MainActor
    static func makeImageFile(for clip: Clip, emoji: String) async -> URL? {
        guard let composited = await composite(clip: clip, emoji: emoji) else { return nil }
        guard let data = composited.jpegData(compressionQuality: 0.85) else { return nil }

        // A distinct name per send: Stream keys uploads off the file, and two
        // reactions to the same log are two different messages.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reaction-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            stickerLog.error("reaction sticker write failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Compositing

    @MainActor
    private static func composite(clip: Clip, emoji: String) async -> UIImage? {
        let frame = await still(for: clip)
        // The still's own dimensions are the truth about the log's shape; the
        // clip's recorded ratio only has to cover a vibe log, which has no
        // media to measure.
        let ratio: Double = if let frame, frame.size.height > 0 {
            frame.size.width / frame.size.height
        } else {
            clip.displayAspectRatio
        }
        let size = renderSize(aspectRatio: ratio)
        // Everything on top of the frame is proportional to the short edge, so
        // the badge reads the same on a wide log as a tall one now that the
        // canvas is no longer one fixed shape.
        let unit = min(size.width, size.height)

        let content = ZStack {
            Color.black
            if let frame {
                Image(uiImage: frame)
                    .resizable()
                    // `.fit`, matching every clip container in the app. The
                    // canvas above is already the frame's shape, so this is a
                    // whole-frame fit with no bars to show rather than a
                    // letterbox — the `.fill` this replaced cropped the log.
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
            } else {
                // A vibe log has no media anywhere — its "picture" is the
                // generated gradient the friend actually sees.
                VibeClipView(emoji: clip.emoji, label: clip.label,
                             hueA: clip.hueA, hueB: clip.hueB, animate: false)
            }

            // The emoji sits bottom-left on a soft disc, which is where a
            // reaction badge lands on the clip container itself.
            //
            // Small, and pushed right out to the corner: padded inward it read
            // as a watermark stamped *onto* the log rather than a tapback
            // sitting *on* the bubble. The disc is sized so its lower-left
            // sweep just meets the curve of the bubble the SDK draws this
            // attachment in — poking into the corner, not clipped by it.
            VStack {
                Spacer()
                HStack {
                    Text(emoji)
                        .font(.system(size: unit * 0.15))
                        .padding(unit * 0.045)
                        // Deliberately a translucent fill rather than one of the
                        // app's `.ultraThinMaterial` surfaces: `ImageRenderer`
                        // doesn't rasterize blur, so a material here flattens to
                        // something that looks nothing like the glass it does on
                        // screen. A softer disc with a shadow is the honest
                        // version of that treatment for a flattened image.
                        .background(Circle().fill(.black.opacity(0.42)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.28), lineWidth: unit * 0.004))
                        // Tighter than it was: at the old size the shadow was a
                        // second dark halo around an already-dark disc, which is
                        // most of what made the badge look busy.
                        .shadow(color: .black.opacity(0.3), radius: unit * 0.018, y: unit * 0.006)
                    Spacer()
                }
            }
            .padding(unit * 0.02)
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        return renderer.uiImage
    }

    // MARK: Stills

    /// One frame of the log, whatever kind it is and wherever it lives.
    @MainActor
    private static func still(for clip: Clip) async -> UIImage? {
        switch clip.kind {
        case .photo: await photo(for: clip)
        case .video: await videoFrame(for: clip)
        case .vibe: nil
        }
    }

    private static func photo(for clip: Clip) async -> UIImage? {
        // Same resolution ladder `ClipMediaView` renders from — the file on
        // this device first, then the uploaded copy. Reacting is nearly always
        // to somebody else's log, so the remote tier is the usual one.
        if let localURL = clip.assetURL,
           FileManager.default.fileExists(atPath: localURL.path),
           let decoded = UIImage(contentsOfFile: localURL.path) {
            return decoded
        }
        guard let remoteURL = clip.remoteURL else { return nil }
        // Already decoded for the pane being reacted to, in the common case.
        if let cached = ImageCache.shared.image(for: remoteURL.absoluteString) {
            return cached
        }
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL),
              let image = UIImage(data: data) else { return nil }
        return image
    }

    private static func videoFrame(for clip: Clip) async -> UIImage? {
        guard let url = videoURL(for: clip) else { return nil }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        // Without this a clip filmed in landscape comes out rotated — the
        // transform lives on the track, not in the pixel buffer.
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1080, height: 1080)
        // Exact time zero is often a black or half-decoded frame, so take one
        // just after the start and let the generator snap to the nearest.
        let time = CMTime(seconds: 0.15, preferredTimescale: 600)
        do {
            let (cgImage, _) = try await generator.image(at: time)
            return UIImage(cgImage: cgImage)
        } catch {
            stickerLog.error("frame extraction failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Local file, then the on-disk cache, then the network. The cache tier is
    /// what usually saves this from re-downloading a clip already on screen.
    private static func videoURL(for clip: Clip) -> URL? {
        if let localURL = clip.assetURL, FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        guard let remoteURL = clip.remoteURL else { return nil }
        return VideoCache.shared.cachedFile(for: remoteURL) ?? remoteURL
    }
}
