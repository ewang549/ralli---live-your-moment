import SwiftUI
import UIKit

/// Decoded images, held in memory across view teardowns.
///
/// Two separate flashes trace back to not having this. A paging feed destroys a
/// pane the instant it scrolls away and rebuilds it coming back, and `AsyncImage`
/// starts from nothing every time it is rebuilt — so a friend's profile photo
/// dropped back to the emoji orb on each appearance, and a full-resolution
/// capture re-decoded on the main thread on each swipe. Keeping the decoded
/// image means anything seen once comes back on the very first frame.
///
/// `NSCache` rather than a dictionary so entries are evicted under memory
/// pressure instead of growing without bound over a long session.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.countLimit = 120 }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// An image resolved from disk first, then from the network, and cached both
/// ways — the shape `AsyncImage` has, without its habit of forgetting.
///
/// The local tier matters for your own content: a photo picked on this device
/// renders straight from the file rather than waiting on a round trip. Decoding
/// happens off the main thread in both tiers, which is the other half of the
/// fix — `UIImage(contentsOfFile:)` called from `body` stalled the frame it was
/// drawn in, and for a full-size capture that stall was visible as a blank pane.
struct CachedImage<Content: View, Placeholder: View>: View {
    /// On-device file, when this row was captured or picked here.
    var localURL: URL?
    /// Uploaded copy, consulted only when there's no local file.
    var remoteURL: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    /// Seeded synchronously from the cache so a revisited view never shows the
    /// placeholder — this is what actually removes the flash, rather than just
    /// making it shorter.
    @State private var image: UIImage?

    init(localURL: URL?,
         remoteURL: URL?,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.localURL = localURL
        self.remoteURL = remoteURL
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: Self.cacheKey(localURL: localURL, remoteURL: remoteURL)
            .flatMap { ImageCache.shared.image(for: $0) })
    }

    /// Identifies the image independently of which tier serves it, so the
    /// `.task` restarts when the view is reused for somebody else's row.
    private static func cacheKey(localURL: URL?, remoteURL: URL?) -> String? {
        if let localURL { return localURL.path }
        if let remoteURL { return remoteURL.absoluteString }
        return nil
    }

    private var cacheKey: String? {
        Self.cacheKey(localURL: localURL, remoteURL: remoteURL)
    }

    var body: some View {
        Group {
            if let image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: cacheKey) {
            guard image == nil, let key = cacheKey else { return }
            let local = localURL
            let remote = remoteURL
            let loaded = await Task.detached(priority: .userInitiated) {
                await Self.load(localURL: local, remoteURL: remote)
            }.value
            // The view may have been recycled onto a different row while this
            // was in flight; that row's own task owns it now.
            guard let loaded, cacheKey == key else { return }
            ImageCache.shared.store(loaded, for: key)
            image = loaded
        }
    }

    private static func load(localURL: URL?, remoteURL: URL?) async -> UIImage? {
        if let localURL, FileManager.default.fileExists(atPath: localURL.path),
           let decoded = UIImage(contentsOfFile: localURL.path) {
            return decoded
        }
        guard let remoteURL else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: remoteURL) else {
            return nil
        }
        return UIImage(data: data)
    }
}

extension CachedImage where Placeholder == EmptyView {
    init(localURL: URL?,
         remoteURL: URL?,
         @ViewBuilder content: @escaping (Image) -> Content) {
        self.init(localURL: localURL, remoteURL: remoteURL, content: content) { EmptyView() }
    }
}
