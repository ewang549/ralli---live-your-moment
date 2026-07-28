import Foundation
import AVFoundation
import CryptoKit
import os

private let videoCacheLog = Logger(subsystem: "com.explog.app", category: "videocache")

/// Remote clip files, kept on disk so a clip seen once plays from local storage
/// on every later appearance.
///
/// Photos already had this (`ImageCache`); video had nothing. A feed pane builds
/// `AVURLAsset(url:)` straight from the Storage URL, so scrolling away from a
/// friend's clip and back re-streamed the whole file from the network every
/// time — and logs are mostly video, which made it the dominant cost of a feed
/// that "doesn't load fast enough".
///
/// The cache deliberately does *not* sit in front of first playback. A cold clip
/// streams immediately, exactly as before, while a copy downloads in the
/// background; only the second appearance is served from disk. Downloading
/// first would trade a visible stall on first view for a faster second view,
/// which is the wrong way round.
///
/// Files live in Caches, so the system may purge them under storage pressure —
/// correct for content that can always be re-fetched. `trim()` keeps the
/// directory under `budgetBytes` so a long session can't grow it without bound.
final class VideoCache {
    static let shared = VideoCache()

    /// Roughly 60-100 short clips. Small enough to be a good citizen on a full
    /// device, large enough that scrolling a feed back and forth stays local.
    private let budgetBytes: UInt64 = 256 * 1024 * 1024

    private let directory: URL
    private let lock = NSLock()
    /// Cache keys known to be on disk. Consulted instead of hitting the file
    /// system, because the lookup happens on the main thread while a pane is
    /// being configured and a `stat` per pane is exactly the kind of small
    /// synchronous IO that shows up as scroll stutter.
    private var present: Set<String> = []
    /// Keys with a download already in flight, so a clip that appears in two
    /// panes (or is scrolled past twice) is fetched once.
    private var inFlight: Set<String> = []

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("RalliVideoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Indexing touches the disk, so it happens off the main thread. Until it
        // lands every lookup simply misses and streams, which is the old
        // behaviour rather than a failure.
        Task.detached(priority: .utility) { [weak self] in
            self?.indexExistingFiles()
            self?.trim()
        }
    }

    // MARK: Lookup

    /// A stable filename for `url`, ignoring the query string.
    ///
    /// Firebase Storage download URLs carry an access token in the query that
    /// can be reissued for the same underlying object; keying on the full URL
    /// would then miss on a file already cached. The path alone identifies the
    /// object.
    private func key(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        let identity = components?.url?.absoluteString ?? url.absoluteString
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("mov")
    }

    /// The on-disk copy of `url`, when there is one.
    func cachedFile(for url: URL) -> URL? {
        let key = key(for: url)
        return lock.withLock { present.contains(key) } ? fileURL(for: key) : nil
    }

    /// Starts caching `url` in the background unless it's already cached or
    /// being fetched. Safe to call on every pane configure.
    func warm(_ url: URL) {
        // A file:// url is already local; caching it would just duplicate it.
        guard !url.isFileURL else { return }
        let key = key(for: url)

        let shouldFetch = lock.withLock {
            guard !present.contains(key), !inFlight.contains(key) else { return false }
            inFlight.insert(key)
            return true
        }
        guard shouldFetch else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.lock.withLock { _ = self.inFlight.remove(key) } }
            await self.download(url, key: key)
        }
    }

    private func download(_ url: URL, key: String) async {
        guard let (temp, response) = try? await URLSession.shared.download(from: url) else { return }
        // Don't cache an error page as if it were a clip.
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: temp)
            return
        }

        let destination = fileURL(for: key)
        do {
            // The downloaded temp file is deleted as soon as this returns, so
            // it has to be moved rather than referenced.
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            videoCacheLog.error("cache write failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: temp)
            return
        }

        lock.withLock { _ = present.insert(key) }
        trim()
    }

    // MARK: Housekeeping

    private func indexExistingFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let keys = names.map { ($0 as NSString).deletingPathExtension }
        lock.withLock { present.formUnion(keys) }
    }

    /// Deletes least-recently-modified files until the directory is under
    /// budget. Cheap no-op in the common case.
    private func trim() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: .skipsHiddenFiles
        ) else { return }

        var entries: [(url: URL, size: UInt64, modified: Date)] = []
        var total: UInt64 = 0
        for file in files {
            guard let values = try? file.resourceValues(forKeys: Set(keys)) else { continue }
            let size = UInt64(values.fileSize ?? 0)
            entries.append((file, size, values.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > budgetBytes else { return }

        for entry in entries.sorted(by: { $0.modified < $1.modified }) {
            guard total > budgetBytes else { break }
            guard (try? FileManager.default.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.size
            let key = entry.url.deletingPathExtension().lastPathComponent
            lock.withLock { _ = present.remove(key) }
        }
    }

    /// Drops everything. Used by account deletion and sign-out, where leaving a
    /// previous user's media on disk would be wrong.
    func clear() {
        lock.withLock { present.removeAll() }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
