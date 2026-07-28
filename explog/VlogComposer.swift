import AVFoundation

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
}
