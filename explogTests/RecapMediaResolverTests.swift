import Testing
import Foundation
@testable import explog

/// Covers which clips can become reel segments, and that resolving them keeps
/// the day in order.
///
/// The ordering test is the one that matters most and is the easiest to lose:
/// resolution runs concurrently, so returning results as they arrive would
/// silently shuffle the day into completion order — a reel that plays 9 AM after
/// 3 PM is still a perfectly valid video.
///
/// Deliberately no network here. The download branch needs a real Storage URL
/// and a live connection, neither of which belongs in a unit test; what's
/// covered is every branch that decides *whether* to download and what order the
/// results come back in.
@MainActor
struct RecapMediaResolverTests {

    private func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "resolver-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A real file on disk, standing in for a capture made on this device.
    private func localFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "local-\(UUID().uuidString).mov")
        try Data("not really a movie".utf8).write(to: url)
        return url
    }

    private func info(kind: ClipKind,
                      local: URL? = nil,
                      remote: URL? = nil,
                      capturedAt: Date = .now) -> RecapClipInfo {
        RecapClipInfo(id: UUID(), kind: kind, capturedAt: capturedAt,
                      caption: "", localURL: local, remoteURL: remote)
    }

    // MARK: - What can become a segment

    /// A vibe clip is generated art with no media behind it — there are no
    /// pixels to put in a video file, so it can never be a segment.
    @Test func vibeClipsAreNotStitchable() {
        #expect(!info(kind: .vibe).isStitchable)
        // Not even if something has left a stray URL on it.
        #expect(!info(kind: .vibe, remote: URL(string: "https://example.com/x.mov")).isStitchable)
    }

    /// A clip whose file is on this device is stitchable without any fetching.
    @Test func localCapturesAreStitchable() throws {
        #expect(info(kind: .video, local: try localFile()).isStitchable)
    }

    /// The case this whole fetch path exists for: a clip that only lives in
    /// Storage. On any device that didn't film it — a reinstall, a second phone
    /// — this is the entire day, and calling it unstitchable would leave the
    /// recap showing clips it then refused to stitch.
    @Test func clipsThatOnlyExistInStorageAreStillStitchable() {
        #expect(info(kind: .video, remote: URL(string: "https://example.com/x.mov")).isStitchable)
        #expect(info(kind: .photo, remote: URL(string: "https://example.com/x.jpg")).isStitchable)
    }

    /// A local filename pointing at a file that isn't there any more doesn't
    /// count — this is exactly the state a reinstall leaves behind.
    @Test func aMissingLocalFileWithNoRemoteCopyIsNotStitchable() {
        let gone = FileManager.default.temporaryDirectory.appending(path: "gone-\(UUID().uuidString).mov")
        #expect(!info(kind: .video, local: gone).isStitchable)
    }

    // MARK: - Resolving

    /// Local files resolve to themselves — no copy, no fetch.
    @Test func localFilesResolveInPlace() async throws {
        let file = try localFile()
        let clip = info(kind: .video, local: file)
        let resolved = await RecapMediaResolver.resolve([clip], into: scratch())

        #expect(resolved.count == 1)
        #expect(resolved.first?.url == file)
    }

    /// Unstitchable clips are dropped rather than resolved to nothing, which is
    /// what lets the caller report the difference as "N had no media".
    @Test func unstitchableClipsAreDropped() async throws {
        let file = try localFile()
        let resolved = await RecapMediaResolver.resolve([
            info(kind: .vibe),
            info(kind: .video, local: file),
            info(kind: .vibe),
        ], into: scratch())

        #expect(resolved.count == 1)
        #expect(resolved.first?.url == file)
    }

    /// The day comes back in the order it went in, not in the order the
    /// concurrent fetches happened to finish.
    @Test func resolutionPreservesTheDaysOrder() async throws {
        let files = try (0..<6).map { _ in try localFile() }
        let clips = files.map { info(kind: .video, local: $0) }

        let resolved = await RecapMediaResolver.resolve(clips, into: scratch())

        #expect(resolved.count == 6)
        #expect(resolved.map(\.url) == files)
        // And each result is still paired with the clip it came from.
        #expect(resolved.map(\.info.id) == clips.map(\.id))
    }

    @Test func nothingResolvableYieldsNothing() async throws {
        let resolved = await RecapMediaResolver.resolve([info(kind: .vibe)], into: scratch())
        #expect(resolved.isEmpty)
    }
}
