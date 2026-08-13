import AVFoundation
import CoreImage
import UIKit
import os

private let reelLog = Logger(subsystem: "com.ej.explog", category: "reel")

/// Stitches a day's individual clips into one continuous "mini vlog" track.
///
/// Only real captures (video files on disk) can be concatenated — seeded "vibe"
/// clips and photos have no video track, so callers fall back to the story-style
/// sequential player when this returns `nil`.
///
/// Photos are a known gap rather than an oversight. Turning a still into a
/// segment means rendering it to frames through an `AVVideoComposition`, which
/// is a materially bigger piece of work than the concatenation here; until that
/// exists, a day's photos are counted and reported by the recap screen instead
/// of being dropped without explanation. See `DailyVlogView.stillsLeftOut`.
enum VlogComposer {

    /// Concatenates `urls` head to tail into one composition, in the order
    /// given. Returns `nil` when nothing usable could be stitched.
    ///
    /// The shared half of playback and export: both need the exact same
    /// timeline, and building it twice is how the thing you watch and the file
    /// you save quietly drift apart.
    static func makeComposition(from urls: [URL]) async -> AVMutableComposition? {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        // Audio is optional: a silent clip shouldn't abort the whole vlog.
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        var cursor = CMTime.zero
        var appliedTransform = false

        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let asset = AVURLAsset(url: url)

            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  duration.isValid, duration > .zero
            else { continue }

            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
            } catch {
                continue // Skip an unreadable clip rather than losing the vlog.
            }

            // Orientation comes from the first clip that lands; without this the
            // whole reel plays sideways for portrait captures.
            if !appliedTransform, let transform = try? await sourceVideo.load(.preferredTransform) {
                videoTrack.preferredTransform = transform
                appliedTransform = true
            }

            if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                // A missing/short audio track is fine — video timing already advanced.
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            cursor = cursor + duration
        }

        guard cursor > .zero else { return nil }
        return composition
    }

    /// Builds a single playable item from `urls`, in the order given.
    /// Returns `nil` when nothing usable could be stitched.
    ///
    /// Main-actor bound because `AVPlayerItem` is; the expensive work (track and
    /// duration loading) still happens off the main thread inside each `await`.
    @MainActor
    static func makePlayerItem(from urls: [URL]) async -> AVPlayerItem? {
        guard let composition = await makeComposition(from: urls) else { return nil }
        return AVPlayerItem(asset: composition)
    }

    enum ExportError: LocalizedError {
        case nothingToExport
        case sessionUnavailable

        var errorDescription: String? {
            switch self {
            case .nothingToExport: "There are no videos in this day to save."
            case .sessionUnavailable: "This day's recap couldn't be prepared for saving."
            }
        }
    }

    /// Writes the stitched day out as a real `.mp4` in the temporary directory
    /// and hands back its URL.
    ///
    /// A file on disk is what the photo library needs — it imports by URL, not
    /// from a composition — so saving has to go through a full export rather
    /// than reusing the player's in-memory timeline.
    static func export(_ urls: [URL], named name: String) async throws -> URL {
        guard let composition = await makeComposition(from: urls) else {
            throw ExportError.nothingToExport
        }
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPresetHighestQuality) else {
            throw ExportError.sessionUnavailable
        }

        let output = FileManager.default.temporaryDirectory
            .appending(path: "\(name).mp4")
        // Exports refuse to overwrite, and the same day re-saved has to land on
        // the same predictable name rather than littering unique ones.
        try? FileManager.default.removeItem(at: output)

        try await session.export(to: output, as: .mp4)
        return output
    }

    // MARK: - The overlaid reel
    //
    // Everything above concatenates raw video tracks and nothing else: no
    // photos, no overlays. What follows is the "watch the day as one video"
    // timeline, which needs both — and needs a *different* overlay on each
    // segment of one continuous file, which is the part nothing in the app did
    // before. `OverlayBurnIn.burnVideo` composites one overlay over one whole
    // asset; this is that technique parameterized per segment.

    /// One item going into the reel, with its overlay already rendered.
    ///
    /// Overlays arrive as finished bitmaps rather than being drawn in here, and
    /// that seam is deliberate: it keeps this type off the main actor and out of
    /// SwiftUI, and it is what lets the tests feed in known marker images and
    /// read them back out of the composited frames. Production passes
    /// `RecapStamp.image(date:caption:canvas:)`.
    struct ReelSource {
        let url: URL
        let kind: ClipKind
        /// Transparent except where the stamp is drawn. Laid out at any size —
        /// it is scaled to cover the reel frame. Nil leaves the segment bare.
        let overlay: CGImage?

        init(url: URL, kind: ClipKind, overlay: CGImage?) {
            self.url = url
            self.kind = kind
            self.overlay = overlay
        }
    }

    /// A stitched day: the timeline, plus the recipe that paints each segment.
    ///
    /// The two travel together because neither is the reel on its own — playing
    /// the composition without the video composition gives you the day with
    /// every overlay missing, which is exactly the file `export(_:named:)`
    /// already produces.
    struct Reel {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        /// The pixel frame every segment is fitted into.
        let renderSize: CGSize
        /// One entry per source that actually made it in, in timeline order.
        let segments: [Segment]
        /// This reel's own temporary directory, holding its photo segments.
        let scratchDirectory: URL

        var duration: CMTime { composition.duration }

        struct Segment {
            let range: CMTimeRange
            let overlay: CGImage?
        }

        /// Releases the photo segments this reel rendered.
        ///
        /// Call when the reel is finished with and *not* before — the
        /// composition reads these files lazily, so discarding them while the
        /// player is alive blanks every photo in the reel.
        func discardScratch() {
            try? FileManager.default.removeItem(at: scratchDirectory)
        }
    }

    /// Where photo segments are written.
    ///
    /// Each reel gets its own subdirectory of this, never a shared one. An
    /// `AVComposition` reads its media lazily, so these files have to outlive
    /// the build and stay put for as long as the reel is on screen — which
    /// makes "clear the scratch space before building" quietly destructive the
    /// moment two reels exist at once. Per-reel directories mean a build can
    /// only ever delete its own files.
    static var stillScratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appending(path: "recap-stills", directoryHint: .isDirectory)
    }

    /// How long a reel's scratch directory survives before a later build
    /// collects it, for the case where `discardScratch()` never ran (a crash, a
    /// kill). Comfortably longer than any reel stays on screen.
    private static let scratchLifetime: TimeInterval = 60 * 60

    /// Deletes scratch directories left behind by earlier runs.
    ///
    /// Age-based rather than "everything but mine", so a reel someone is
    /// currently watching is never collected out from under its player.
    private static func purgeStaleScratch() {
        let root = stillScratchRoot
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let cutoff = Date.now.addingTimeInterval(-scratchLifetime)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Stitches `sources` into one continuous timeline, each segment carrying
    /// its own overlay. Returns `nil` when nothing usable could be stitched.
    ///
    /// Order is the caller's: `DailyVlogView` passes the day in hourly order and
    /// this preserves it exactly.
    static func makeReel(from sources: [ReelSource],
                         stillDuration: CMTime = CMTime(seconds: clipDuration, preferredTimescale: 600),
                         renderSize requestedSize: CGSize? = nil) async -> Reel? {
        let renderSize = evenSize(await resolveRenderSize(requestedSize, in: sources))
        let renderRect = CGRect(origin: .zero, size: renderSize)

        purgeStaleScratch()
        let scratch = stillScratchRoot.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        // Audio is optional: a silent clip shouldn't abort the whole reel.
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        )

        // The track's `preferredTransform` is deliberately left identity, unlike
        // `makeComposition` above, which stamps the *first* clip's rotation onto
        // the whole reel and plays every differently-oriented clip after it
        // sideways. Here each segment carries its own rotation in
        // `sourceTransform` instead, so a mixed-orientation day comes out right.
        var prepared: [Prepared] = []
        var cursor = CMTime.zero

        for source in sources {
            guard let segment = await prepareSegment(source,
                                                     renderSize: renderSize,
                                                     stillDuration: stillDuration,
                                                     scratch: scratch)
            else { continue }

            let asset = AVURLAsset(url: segment.url)
            guard let sourceVideo = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  duration.isValid, duration > .zero
            else { continue }

            let sourceRange = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(sourceRange, of: sourceVideo, at: cursor)
            } catch {
                reelLog.error("reel: skipped unreadable segment: \(error.localizedDescription, privacy: .public)")
                continue // Skip one clip rather than losing the reel.
            }

            if let audioTrack, let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                // A missing/short audio track is fine — video timing already advanced.
                try? audioTrack.insertTimeRange(sourceRange, of: sourceAudio, at: cursor)
            }

            prepared.append(Prepared(
                range: CMTimeRange(start: cursor, duration: duration),
                sourceTransform: transformFitting(natural: segment.natural,
                                                  preferred: segment.transform,
                                                  into: renderRect),
                overlay: source.overlay.map { fit(CIImage(cgImage: $0), into: renderRect) },
                sourceOverlay: source.overlay
            ))
            cursor = cursor + duration
        }

        guard cursor > .zero else {
            try? FileManager.default.removeItem(at: scratch)
            return nil
        }

        // Black backing, so a segment whose shape isn't the reel's letterboxes
        // into it rather than leaving whatever the compositor had there before.
        let backing = CIImage(color: .black).cropped(to: renderRect)
        let segments = prepared
        let videoComposition: AVMutableVideoComposition
        do {
            videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
                guard let segment = Self.segment(at: request.compositionTime, in: segments) else {
                    request.finish(with: request.sourceImage, context: nil)
                    return
                }
                // All geometry was resolved per segment when the reel was built
                // — nothing here is computed per frame, which matters at 30fps
                // across a whole day.
                var image = request.sourceImage.transformed(by: segment.sourceTransform)
                if let overlay = segment.overlay {
                    image = overlay.composited(over: image)
                }
                request.finish(with: image.composited(over: backing), context: nil)
            }
        } catch {
            reelLog.error("reel composition build failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        videoComposition.renderSize = renderSize

        return Reel(composition: composition,
                    videoComposition: videoComposition,
                    renderSize: renderSize,
                    segments: prepared.map { Reel.Segment(range: $0.range, overlay: $0.sourceOverlay) },
                    scratchDirectory: scratch)
    }

    /// A playable item for `reel`, with the overlays attached.
    ///
    /// The `videoComposition` is the whole difference between this and
    /// `makePlayerItem(from:)` — without it the item plays the same timeline
    /// with every stamp missing.
    @MainActor
    static func makePlayerItem(for reel: Reel) -> AVPlayerItem {
        let item = AVPlayerItem(asset: reel.composition)
        item.videoComposition = reel.videoComposition
        return item
    }

    // MARK: Reel internals

    /// A segment with its geometry and overlay resolved, ready for the compositor.
    private struct Prepared {
        let range: CMTimeRange
        /// Maps this segment's raw frames into the reel frame, rotation included.
        let sourceTransform: CGAffineTransform
        /// Already scaled and positioned over the reel frame.
        let overlay: CIImage?
        /// The unpositioned bitmap, kept only so `Reel.Segment` can report it.
        let sourceOverlay: CGImage?
    }

    /// Which segment `time` falls in.
    private static func segment(at time: CMTime, in segments: [Prepared]) -> Prepared? {
        if let hit = segments.first(where: { $0.range.containsTime(time) }) { return hit }
        // Exactly on the closing boundary, or a rounding hair past it. The
        // segment that just ended is the honest answer; returning nothing would
        // drop the overlay for the reel's final frame.
        return segments.last { $0.range.start <= time } ?? segments.first
    }

    /// The file to insert for `source`, plus the geometry its frames arrive in.
    ///
    /// Photos become a real video segment here — see `StillSegmentWriter`.
    private static func prepareSegment(_ source: ReelSource,
                                       renderSize: CGSize,
                                       stillDuration: CMTime,
                                       scratch: URL) async
    -> (url: URL, natural: CGSize, transform: CGAffineTransform)? {
        switch source.kind {
        case .video:
            guard FileManager.default.fileExists(atPath: source.url.path),
                  let geometry = await videoGeometry(at: source.url) else { return nil }
            return (source.url, geometry.natural, geometry.transform)

        case .photo:
            guard FileManager.default.fileExists(atPath: source.url.path),
                  let image = UIImage(contentsOfFile: source.url.path) else { return nil }
            let stillURL = scratch.appending(path: "still-\(UUID().uuidString).mov")
            do {
                try await StillSegmentWriter.write(image, size: renderSize,
                                                   duration: stillDuration, to: stillURL)
            } catch {
                reelLog.error("reel: still segment failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            // Written at the reel's own size, so it needs no rotation or fit.
            return (stillURL, renderSize, .identity)

        case .vibe:
            // Generated art with no media file — nothing to insert.
            return nil
        }
    }

    /// The reel's pixel frame: the first real video's shape, or 720p when the
    /// day is photos only.
    ///
    /// Exposed because a caller has to know this *before* it can draw overlays.
    /// Every segment's overlay is scaled to cover the whole reel frame, so an
    /// overlay laid out at some other aspect ratio arrives stretched — the stamp
    /// has to be rendered on a canvas shaped like the reel. See
    /// `RecapStamp.canvas(mediaSize:screen:)`.
    static func reelRenderSize(forVideosAt urls: [URL]) async -> CGSize {
        for url in urls {
            guard let geometry = await videoGeometry(at: url) else { continue }
            let oriented = CGRect(origin: .zero, size: geometry.natural).applying(geometry.transform)
            let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            if size.width > 0, size.height > 0 { return evenSize(size) }
        }
        return CGSize(width: 1280, height: 720)
    }

    private static func resolveRenderSize(_ requested: CGSize?, in sources: [ReelSource]) async -> CGSize {
        if let requested { return requested }
        return await reelRenderSize(forVideosAt: sources.filter { $0.kind == .video }.map(\.url))
    }

    private static func videoGeometry(at url: URL) async -> (natural: CGSize, transform: CGAffineTransform)? {
        guard let track = try? await AVURLAsset(url: url).loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        return (natural, transform)
    }

    /// H.264 refuses odd dimensions; an odd one here fails the encode silently.
    private static func evenSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(2, CGFloat(Int(size.width.rounded()) & ~1)),
               height: max(2, CGFloat(Int(size.height.rounded()) & ~1)))
    }

    /// Maps a segment's raw frames into `rect`: rotated upright, then fitted.
    ///
    /// Aspect-*fit* rather than fill, for the reason the recap screen letterboxes
    /// too — cropping a clip to the reel's shape shows framing the user never
    /// chose. The vertical centring is also what makes this safe across Core
    /// Image's bottom-left origin and UIKit's top-left one: a centred fit has the
    /// same offset measured from either end.
    static func transformFitting(natural: CGSize,
                                 preferred: CGAffineTransform,
                                 into rect: CGRect) -> CGAffineTransform {
        let oriented = CGRect(origin: .zero, size: natural).applying(preferred)
        guard oriented.width > 0, oriented.height > 0,
              rect.width > 0, rect.height > 0 else { return preferred }

        let target = OverlayBurnIn.fittedRect(mediaSize: oriented.size, in: rect.size)
        let scale = target.width / oriented.width
        return preferred
            .concatenating(CGAffineTransform(translationX: -oriented.minX, y: -oriented.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: target.minX + rect.minX,
                                             y: target.minY + rect.minY))
    }

    /// Scales `overlay` to cover `frame`. See `OverlayBurnIn.fit(_:into:)` —
    /// same job, same deliberate absence of a vertical flip.
    static func fit(_ overlay: CIImage, into frame: CGRect) -> CIImage {
        OverlayBurnIn.fit(overlay, into: frame)
    }
}
