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
    /// Portrait, matching the aspect every clip container in the app is
    /// normalised to (`VideoCard.aspectRatio`), so the sticker is framed the
    /// same way the log itself is.
    private static let renderSize = CGSize(width: 540, height: 960)

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

        let content = ZStack {
            Color.black
            if let frame {
                Image(uiImage: frame)
                    .resizable()
                    // `.fill` for the same reason the feeds use it: a landscape
                    // capture in a portrait card is cropped, not letterboxed
                    // into two black bars.
                    .aspectRatio(contentMode: .fill)
                    .frame(width: renderSize.width, height: renderSize.height)
                    .clipped()
            } else {
                // A vibe log has no media anywhere — its "picture" is the
                // generated gradient the friend actually sees.
                VibeClipView(emoji: clip.emoji, label: clip.label,
                             hueA: clip.hueA, hueB: clip.hueB, animate: false)
            }

            // The emoji sits bottom-left on a dark disc, which is where a
            // reaction badge lands on the clip container itself.
            VStack {
                Spacer()
                HStack {
                    Text(emoji)
                        .font(.system(size: 108))
                        .padding(26)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 3))
                    Spacer()
                }
            }
            .padding(28)
        }
        .frame(width: renderSize.width, height: renderSize.height)

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
