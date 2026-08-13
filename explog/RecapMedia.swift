import Foundation
import os

private let recapMediaLog = Logger(subsystem: "com.ej.explog", category: "reel")

/// One clip's reel-relevant facts, lifted off the SwiftData model.
///
/// The reel is built off the main actor — downloading, encoding stills, and
/// compositing all happen away from the UI — and a `@Model` is not safe to carry
/// across that boundary. Reading everything the reel needs into plain values
/// once, on the main actor, is what keeps the rest of the pipeline free of
/// SwiftData entirely (and is why `VlogComposer` takes URLs rather than clips).
struct RecapClipInfo: Sendable {
    let id: UUID
    let kind: ClipKind
    let capturedAt: Date
    let caption: String
    /// The capture on this device, when there is one.
    let localURL: URL?
    /// The uploaded copy in Storage, when it has reached it.
    let remoteURL: URL?

    init(id: UUID, kind: ClipKind, capturedAt: Date,
         caption: String, localURL: URL?, remoteURL: URL?) {
        self.id = id
        self.kind = kind
        self.capturedAt = capturedAt
        self.caption = caption
        self.localURL = localURL
        self.remoteURL = remoteURL
    }

    init(_ clip: Clip) {
        id = clip.id
        kind = clip.kind
        capturedAt = clip.capturedAt
        caption = clip.label
        localURL = clip.assetURL
        remoteURL = clip.remoteURL
    }

    /// Whether this clip could become a segment at all.
    ///
    /// Vibe clips are generated art with no media behind them; everything else
    /// needs a file here or a copy in Storage to fetch.
    var isStitchable: Bool {
        guard kind != .vibe else { return false }
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) { return true }
        return remoteURL != nil
    }
}

/// Gets every clip in a day down to a real file on disk, so the reel can stitch it.
///
/// The composer works from local files by design — `AVMutableComposition` reading
/// a dozen Storage URLs over the network mid-stitch is how you get a reel that
/// hangs rather than one that plays. But a clip is only guaranteed to have a
/// local file on the device that filmed it: reinstall the app, or sign in on a
/// second phone, and your own day comes back from Storage with `assetFileName`
/// pointing at nothing. Without this the recap would show you a day it then
/// refused to stitch, which is a worse answer than waiting a moment for it.
enum RecapMediaResolver {

    struct Resolved: Sendable {
        let info: RecapClipInfo
        /// A real file, either the original capture or a freshly fetched copy.
        let url: URL
    }

    /// Resolves `clips` to local files, downloading whatever isn't already down.
    ///
    /// Order is preserved: the caller hands these to the composer as the reel's
    /// running order, so returning them in completion order would shuffle the
    /// day. Anything that can't be resolved is dropped and reported by its
    /// absence — the caller counts the difference.
    static func resolve(_ clips: [RecapClipInfo],
                        into directory: URL,
                        timeout: TimeInterval = 25) async -> [Resolved] {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        // Fetched concurrently — a day is a couple of dozen short files, and
        // doing them one at a time is the difference between a reel that starts
        // in a moment and one that takes most of a minute.
        var byID: [UUID: Resolved] = [:]
        await withTaskGroup(of: Resolved?.self) { group in
            for info in clips where info.isStitchable {
                group.addTask {
                    await resolveOne(info, into: directory, session: session)
                }
            }
            for await resolved in group {
                guard let resolved else { continue }
                byID[resolved.info.id] = resolved
            }
        }

        return clips.compactMap { byID[$0.id] }
    }

    private static func resolveOne(_ info: RecapClipInfo,
                                   into directory: URL,
                                   session: URLSession) async -> Resolved? {
        // The original capture, when this is the phone that filmed it.
        if let local = info.localURL, FileManager.default.fileExists(atPath: local.path) {
            return Resolved(info: info, url: local)
        }
        guard let remote = info.remoteURL else { return nil }

        // A copy the feed already pulled down while scrolling — free, and the
        // common case for a clip you've looked at recently.
        if info.kind == .video, let cached = VideoCache.shared.cachedFile(for: remote),
           FileManager.default.fileExists(atPath: cached.path) {
            return Resolved(info: info, url: cached)
        }

        let destination = directory.appending(path: "\(info.id.uuidString).\(info.kind == .photo ? "jpg" : "mov")")
        do {
            let (temporary, response) = try await session.download(from: remote)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                recapMediaLog.error("reel: fetch for \(info.id, privacy: .public) returned \(http.statusCode)")
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            return Resolved(info: info, url: destination)
        } catch {
            recapMediaLog.error("reel: fetch failed for \(info.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
