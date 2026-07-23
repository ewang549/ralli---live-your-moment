import SwiftUI
import AVFoundation
import AVKit

/// Renders any clip full-bleed: looping video, photo, or stylized "vibe" placeholder
/// (used for seeded demo content and simulator captures).
struct ClipView: View {
    let clip: Clip
    var isActive: Bool = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch clip.kind {
                case .video:
                    if let url = clip.assetURL, FileManager.default.fileExists(atPath: url.path) {
                        LoopingVideoView(url: url, isPlaying: isActive)
                    } else {
                        vibeBody
                    }
                case .photo:
                    if let url = clip.assetURL, let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
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
        VibeClipView(emoji: clip.emoji, label: clip.label, hueA: clip.hueA, hueB: clip.hueB, animate: isActive)
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

/// AVPlayerLayer-backed looping player (no system chrome, aspect-fill).
struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    var isPlaying: Bool

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(url: url)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.setPlaying(isPlaying)
    }

    final class PlayerContainerView: UIView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?

        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        func configure(url: URL) {
            let item = AVPlayerItem(url: url)
            let player = AVQueuePlayer()
            player.isMuted = false
            looper = AVPlayerLooper(player: player, templateItem: item)
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            self.player = player
        }

        func setPlaying(_ playing: Bool) {
            playing ? player?.play() : player?.pause()
        }
    }
}

/// Small circular avatar used across lists and overlays.
struct AvatarView: View {
    let friend: Friend
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Theme.avatarGradient(hue: friend.hue))
            Text(friend.emoji).font(.system(size: size * 0.5))
        }
        .frame(width: size, height: size)
    }
}
