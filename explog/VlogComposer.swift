import AVFoundation

/// Stitches a day's individual clips into one continuous "mini vlog" track.
///
/// Only real captures (video files on disk) can be concatenated — seeded "vibe"
/// clips and photos have no video track, so callers fall back to the story-style
/// sequential player when this returns `nil`.
enum VlogComposer {

    /// Builds a single playable item from `urls`, in the order given.
    /// Returns `nil` when nothing usable could be stitched.
    ///
    /// Main-actor bound because `AVPlayerItem` is; the expensive work (track and
    /// duration loading) still happens off the main thread inside each `await`.
    @MainActor
    static func makePlayerItem(from urls: [URL]) async -> AVPlayerItem? {
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
        return AVPlayerItem(asset: composition)
    }
}
