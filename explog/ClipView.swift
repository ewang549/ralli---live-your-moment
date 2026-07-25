import SwiftUI
import AVFoundation
import AVKit
import UIKit

/// Renders any clip full-bleed: looping video, photo, or stylized "vibe" placeholder
/// (used for seeded demo content and simulator captures).
struct ClipView: View {
    let clip: Clip
    var isActive: Bool = true
    /// How the media fills its container. `.fill` is the feed look — full-bleed,
    /// cropped to whatever shape the pane is — and stays the default so every
    /// existing call site is unchanged. `.fit` letterboxes instead, which is
    /// what the post-capture review needs: capture is landscape-only, so filling
    /// a portrait screen crops the shot into something the user never framed.
    var contentMode: ContentMode = .fill

    var body: some View {
        ClipMediaView(kind: clip.kind,
                      localURL: clip.assetURL,
                      remoteURL: clip.remoteURL,
                      emoji: clip.emoji,
                      label: clip.label,
                      hueA: clip.hueA,
                      hueB: clip.hueB,
                      isActive: isActive,
                      contentMode: contentMode)
    }
}

/// The media-resolution ladder, expressed over plain values rather than a model:
/// on-device file first, then the uploaded copy, then the stylized vibe
/// placeholder.
///
/// `Clip` and `SpotClip` are separate models that both back media rows — Pulse
/// and chat read the first, the Places feed reads the second — and only `Clip`
/// ever had this logic. Places rendered the placeholder unconditionally as a
/// result, real upload or not. Keeping one implementation here is what stops the
/// two surfaces drifting apart again.
struct ClipMediaView: View {
    let kind: ClipKind
    /// On-device media, when this row was captured here.
    var localURL: URL?
    /// Uploaded copy, when it has reached Storage.
    var remoteURL: URL?
    let emoji: String
    let label: String
    let hueA: Double
    let hueB: Double
    var isActive: Bool = true
    var contentMode: ContentMode = .fill

    /// What a player should load: the local file when it's really on disk,
    /// otherwise the uploaded copy. Local first means your own just-captured log
    /// plays instantly instead of round-tripping through Storage.
    private var videoURL: URL? {
        if let localURL, FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }
        return remoteURL
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch kind {
                case .video:
                    if let url = videoURL {
                        LoopingVideoView(url: url, isPlaying: isActive, contentMode: contentMode)
                    } else {
                        vibeBody
                    }
                case .photo:
                    if let url = localURL, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } else if let remote = remoteURL {
                        // Downloaded photo. The vibe body stands in while it
                        // loads and if it fails, so a row is never empty.
                        AsyncImage(url: remote) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: contentMode)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                                .clipped()
                        } placeholder: {
                            vibeBody
                        }
                    } else {
                        vibeBody
                    }
                case .vibe:
                    vibeBody
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private var vibeBody: some View {
        VibeClipView(emoji: emoji, label: label, hueA: hueA, hueB: hueB, animate: isActive)
    }
}

extension ClipMediaView {
    /// A place clip. Same ladder, different model.
    init(spotClip: SpotClip, isActive: Bool = true, contentMode: ContentMode = .fill) {
        self.init(kind: spotClip.kind,
                  localURL: spotClip.assetURL,
                  remoteURL: spotClip.remoteURL,
                  emoji: spotClip.emoji,
                  label: spotClip.label,
                  hueA: spotClip.hueA,
                  hueB: spotClip.hueB,
                  isActive: isActive,
                  contentMode: contentMode)
    }
}

/// The stylized ambient placeholder: gradient wash + drifting emoji.
struct VibeClipView: View {
    let emoji: String
    let label: String
    let hueA: Double
    let hueB: Double
    var animate: Bool = true

    @State private var drift = false

    var body: some View {
        ZStack {
            Theme.clipGradient(hueA: hueA, hueB: hueB)
            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 260, height: 260)
                .blur(radius: 40)
                .offset(y: drift ? -60 : 40)
            Text(emoji)
                .font(.system(size: 88))
                .scaleEffect(drift ? 1.06 : 0.96)
                .offset(y: drift ? -10 : 10)
        }
        .clipped()
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                drift = true
            }
        }
    }
}

/// AVPlayerLayer-backed looping player (no system chrome, aspect-fill by default).
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var isPlaying: Bool
    /// `.fill` crops to the container (the feed look); `.fit` letterboxes, so a
    /// landscape capture keeps its framing on a portrait screen.
    var contentMode: ContentMode = .fill

    private var videoGravity: AVLayerVideoGravity {
        contentMode == .fill ? .resizeAspectFill : .resizeAspect
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(url: url, videoGravity: videoGravity)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // Reconfigure when the view is reused for a different clip. SwiftUI only
        // rebuilds this on an identity change, so without the check a recycled
        // pane keeps playing whatever it loaded first — a previous clip's video
        // frozen under a new caption and author.
        if uiView.currentURL != url {
            uiView.configure(url: url, videoGravity: videoGravity)
        } else {
            uiView.setVideoGravity(videoGravity)
        }
        uiView.setPlaying(isPlaying)
    }

    final class PlayerContainerView: UIView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        /// What's actually loaded, so `updateUIView` can tell a reuse from a
        /// plain play/pause toggle.
        private(set) var currentURL: URL?

        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func configure(url: URL, videoGravity: AVLayerVideoGravity = .resizeAspectFill) {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = false
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer.player = player
            playerLayer.videoGravity = videoGravity
            self.player = player
            self.currentURL = url
        }

        func setVideoGravity(_ gravity: AVLayerVideoGravity) {
            guard playerLayer.videoGravity != gravity else { return }
            playerLayer.videoGravity = gravity
        }

        func setPlaying(_ playing: Bool) {
            playing ? player?.play() : player?.pause()
        }
    }
}

/// Small circular avatar used across lists and overlays.
///
/// Three tiers, same shape as `ClipView`'s photo branch: the photo picked on
/// this device, then the friend's synced `avatarURL`, then the emoji orb. The
/// middle tier is what makes a friend's real photo show up in Pulse and chat
/// rows — only `avatarPhotoFileName` used to be consulted, and that is never
/// set for someone else's account.
struct AvatarView: View {
    let friend: Friend
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            if let url = friend.avatarPhotoURL, let uiImage = UIImage(contentsOfFile: url.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if !friend.avatarURL.isEmpty, let remote = URL(string: friend.avatarURL) {
                AsyncImage(url: remote) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    placeholderOrb
                }
            } else {
                placeholderOrb
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholderOrb: some View {
        ZStack {
            Circle().fill(Theme.avatarGradient(hue: friend.hue))
            Text(friend.emoji).font(.system(size: size * 0.5))
        }
    }
}

/// Avatar for an account with no local `Friend` row — a public beacon's host,
/// say, or anyone else the viewer has no relationship with.
///
/// Same ladder as `AvatarView` minus its first tier: a locally-picked photo file
/// only ever exists for accounts this device has a row for, so there are two
/// rungs here rather than three.
struct RemoteHostOrb: View {
    let emoji: String
    var avatarURL: String = ""
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            if !avatarURL.isEmpty, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    orb
                }
            } else {
                orb
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var orb: some View {
        ZStack {
            Circle().fill(Theme.accentWash)
            Text(emoji.isEmpty ? "🙂" : emoji).font(.system(size: size * 0.5))
        }
    }
}
