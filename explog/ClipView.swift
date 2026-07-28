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
    /// Feed sync cycle, forwarded to the video player. Left at 0 by every
    /// surface that plays a clip on its own rather than in a synced stack.
    var restartToken: Int = 0

    /// Optional so this view still works where the sync layer isn't in scope —
    /// the capture and review flow renders clips before `MainTabView`'s
    /// environment is in play, and a preview has no environment at all.
    @Environment(EngagementSync.self) private var engagementSync: EngagementSync?

    var body: some View {
        ClipMediaView(kind: clip.kind,
                      localURL: clip.assetURL,
                      remoteURL: clip.remoteURL,
                      emoji: clip.emoji,
                      label: clip.label,
                      hueA: clip.hueA,
                      hueB: clip.hueB,
                      isActive: isActive,
                      contentMode: contentMode,
                      isMuted: clip.isMuted,
                      restartToken: restartToken)
            // Counted here rather than at each of the dozen call sites, because
            // this is the one place that already knows both *which* clip and
            // whether it's the one actually being watched. A pane built ahead
            // of the visible one to make paging smooth is inactive, so it
            // doesn't count; the author's own views are dropped server-side.
            .task(id: viewToken) {
                guard isActive, !clip.remoteID.isEmpty else { return }
                engagementSync?.markViewed(logID: clip.remoteID)
            }
    }

    /// Re-runs the count when either the clip or its active state changes — a
    /// recycled pane swapped onto a different clip is a different view.
    private var viewToken: String { "\(clip.remoteID)-\(isActive)" }
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
    /// Silences the video on playback. Carried from `Clip.isMuted`; ignored by
    /// the photo and vibe branches, which have no audio to begin with.
    var isMuted: Bool = false
    /// See `LoopingVideoView.restartToken`. Only a synced stack sets this.
    var restartToken: Int = 0

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
                        LoopingVideoView(url: url,
                                         isPlaying: isActive,
                                         contentMode: contentMode,
                                         isMuted: isMuted,
                                         restartToken: restartToken)
                    } else {
                        vibeBody
                    }
                case .photo:
                    // Decoded off the main thread and cached, so a pane rebuilt
                    // by a page swipe redraws from memory instead of blanking
                    // while a full-size capture decodes. The vibe body is only
                    // reached on a genuinely cold load or a failure.
                    CachedImage(localURL: localURL, remoteURL: remoteURL) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: contentMode)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .clipped()
                    } placeholder: {
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
    /// Silences this player. A playback flag, not an edit — the file keeps its
    /// audio track, so toggling this back restores the sound with no re-encode.
    var isMuted: Bool = false
    /// Bumped by the feed's `ClipSyncClock` to restart every pane in lockstep.
    ///
    /// The stack used to synchronize by putting the clock's cycle in the view's
    /// `.id()`, which made SwiftUI destroy and rebuild the whole player every
    /// cycle. Rebuilding tears the player off the layer and only reattaches one
    /// after an async asset load — so every cycle boundary showed a black frame,
    /// which is the flash this replaces. Passing the cycle as a value instead
    /// keeps one player alive for the clip's whole life and just seeks it back
    /// to zero, which is both seamless and far cheaper.
    var restartToken: Int = 0

    private var videoGravity: AVLayerVideoGravity {
        contentMode == .fill ? .resizeAspectFill : .resizeAspect
    }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.configure(url: url, videoGravity: videoGravity, restartToken: restartToken)
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        // Reconfigure when the view is reused for a different clip. SwiftUI only
        // rebuilds this on an identity change, so without the check a recycled
        // pane keeps playing whatever it loaded first — a previous clip's video
        // frozen under a new caption and author.
        if uiView.currentURL != url {
            uiView.configure(url: url, videoGravity: videoGravity,
                             isMuted: isMuted, restartToken: restartToken)
        } else {
            uiView.setVideoGravity(videoGravity)
            uiView.restartIfNeeded(token: restartToken)
        }
        // Outside the reuse branch on purpose: the review screen toggles mute
        // on a player that is already loaded and playing, so applying it only
        // on configure would leave the toggle silent until the next clip.
        uiView.setMuted(isMuted)
        uiView.setPlaying(isPlaying)
    }

    final class PlayerContainerView: UIView {
        private var player: AVQueuePlayer?
        private var looper: AVPlayerLooper?
        /// What's actually loaded, so `updateUIView` can tell a reuse from a
        /// plain play/pause toggle. Set the moment `configure` is called, not
        /// when the player finally arrives, so a scroll that recycles this view
        /// twice in quick succession still resolves to the last url asked for.
        private(set) var currentURL: URL?
        /// Whether the feed wants this pane playing. `configure` finishes
        /// asynchronously now, so `setPlaying` can land before there's a player
        /// to tell — this is what the new player reads when it appears.
        private var wantsPlaying = false
        /// Whether the caller wants this silenced. Held here for the same
        /// reason as `wantsPlaying`: `configure` finishes asynchronously, so
        /// the flag has to outlive the gap and be read by the player that
        /// eventually arrives.
        private var wantsMuted = false
        /// The last sync-clock cycle this view restarted on, so a repeated
        /// `updateUIView` for the same cycle doesn't keep seeking to zero.
        private var restartToken = 0

        override static var layerClass: AnyClass { AVPlayerLayer.self }
        private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

        /// Loads `url` and starts looping it.
        ///
        /// The asset's duration and tracks are loaded *before* an
        /// `AVPlayerItem` is built from it. Handing `AVPlayerItem(url:)` a cold
        /// url makes the player itself do that work, and it does it while
        /// playing — so at the loop seam, when `AVPlayerLooper` resets to the
        /// start, there can be nothing decoded and ready to show and a black
        /// frame lands on screen.
        func configure(url: URL,
                       videoGravity: AVLayerVideoGravity = .resizeAspectFill,
                       isMuted: Bool = false,
                       restartToken: Int = 0) {
            playerLayer.videoGravity = videoGravity
            currentURL = url
            wantsMuted = isMuted
            // A fresh load starts at zero by definition, so adopt the caller's
            // cycle rather than seeking on the next update for a restart that
            // has effectively already happened.
            self.restartToken = restartToken

            // Drop the previous clip immediately — this view gets recycled, and
            // leaving the old player attached shows the wrong video underneath
            // the new caption until the new one loads.
            looper = nil
            player?.pause()
            player = nil
            playerLayer.player = nil

            // A clip already pulled down once plays from disk; anything else
            // streams exactly as before while a copy is fetched in the
            // background for next time. Caching never delays first playback.
            let playbackURL = VideoCache.shared.cachedFile(for: url) ?? url
            if playbackURL == url { VideoCache.shared.warm(url) }

            let asset = AVURLAsset(url: playbackURL)
            Task { @MainActor [weak self] in
                _ = try? await asset.load(.duration, .tracks)
                // The pane may have been recycled onto a different clip while
                // this was loading; that clip's own configure owns it now.
                guard let self, self.currentURL == url else { return }
                self.install(asset: asset, videoGravity: videoGravity)
            }
        }

        private func install(asset: AVURLAsset, videoGravity: AVLayerVideoGravity) {
            let player = AVQueuePlayer()
            player.isMuted = wantsMuted
            // These are short local clips that loop continuously: waiting to
            // build a buffer is exactly the stall that shows as a black frame
            // at the seam. Play what's there.
            player.automaticallyWaitsToMinimizeStalling = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
            playerLayer.player = player
            playerLayer.videoGravity = videoGravity
            self.player = player
            if wantsPlaying { player.play() }
        }

        func setVideoGravity(_ gravity: AVLayerVideoGravity) {
            guard playerLayer.videoGravity != gravity else { return }
            playerLayer.videoGravity = gravity
        }

        /// Jumps back to the first frame when the feed's clock starts a new
        /// cycle, keeping every visible pane in step.
        ///
        /// Seeking an already-playing player is what makes this seamless: the
        /// layer keeps its current frame up until the new one decodes, so
        /// nothing blanks. `toleranceBefore/After: .zero` matters — an inexact
        /// seek lands on the nearest keyframe, which for these short clips can
        /// be visibly late and drifts panes out of sync with each other.
        func restartIfNeeded(token: Int) {
            guard token != restartToken else { return }
            restartToken = token
            guard let player else { return }
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            if wantsPlaying { player.play() }
        }

        func setMuted(_ muted: Bool) {
            wantsMuted = muted
            player?.isMuted = muted
        }

        func setPlaying(_ playing: Bool) {
            wantsPlaying = playing
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

    /// The uploaded copy, when this friend has one.
    private var remoteURL: URL? {
        friend.avatarURL.isEmpty ? nil : URL(string: friend.avatarURL)
    }

    var body: some View {
        ZStack {
            if friend.avatarPhotoURL != nil || remoteURL != nil {
                // See `GlassOrbAvatar`: someone with a real photo never shows
                // the emoji, not even while the photo loads.
                CachedImage(localURL: friend.avatarPhotoURL, remoteURL: remoteURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Circle().fill(Theme.avatarGradient(hue: friend.hue))
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
