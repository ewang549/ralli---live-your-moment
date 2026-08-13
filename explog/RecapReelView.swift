import SwiftUI
import AVKit

/// The day as one continuous video.
///
/// Deliberately a *third* surface rather than a replacement for either thing the
/// recap already does. `DayRecapPage` steps clip by clip, which is what makes the
/// edge taps mean "one hour" (see its doc comment on why stitching broke that),
/// and the download button exports a file to Photos. Neither of those is
/// "press play and watch your day", which is the one thing you'd actually show
/// someone — so it gets its own screen instead of overloading theirs.
///
/// What plays here is a real stitched timeline with each clip's own hour and
/// caption burned into its own segment, photos included. See
/// `VlogComposer.makeReel(from:stillDuration:renderSize:)`.
struct RecapReelView: View {
    let day: Date
    /// The day's clips, chronological. Bucketed by hour here so the reel's
    /// running order is the same one the recap's edge taps walk.
    let clips: [Clip]

    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .preparing
    @State private var player: AVPlayer?
    @State private var reel: VlogComposer.Reel?
    /// Clips that couldn't become segments — a vibe clip, which is generated art
    /// with no file behind it, or one whose media wouldn't come down.
    @State private var leftOut = 0
    /// Where clips fetched from Storage land, released with the reel.
    @State private var downloads = FileManager.default.temporaryDirectory
        .appending(path: "recap-fetch-\(UUID().uuidString)", directoryHint: .isDirectory)

    private enum Phase: Equatable {
        case preparing
        case playing
        case nothingToPlay
        case failed(String)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                content
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .task(id: day) { await build(screen: proxy.size) }
            }
            .ignoresSafeArea()

            header
        }
        .preferredColorScheme(.dark)
        .onDisappear(perform: tearDown)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .preparing:
            status {
                ProgressView().tint(.white)
                Text("Stitching your day…")
                    .foregroundStyle(Theme.textSecondary)
                // Encoding a still into frames is the slow part, so say so
                // rather than leaving a spinner with no explanation.
                Text("photos take a moment to render")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }

        case .playing:
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            }

        case .nothingToPlay:
            status {
                Text("🎬").font(.system(size: 56))
                Text("Nothing to stitch for this day")
                    .foregroundStyle(Theme.textSecondary)
            }

        case .failed(let message):
            status {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.textSecondary)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
    }

    private func status<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack {
                CloseButton(overMedia: true) { dismiss() }
                Spacer()
                VStack(spacing: 1) {
                    Text("Your day, stitched")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(day.dayLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
                // Balances the close button.
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 16)

            // The same honesty the recap's footer already practises about what
            // isn't in the reel — now a much shorter list, since photos are in.
            if leftOut > 0, phase == .playing {
                Text("\(leftOut) log\(leftOut == 1 ? "" : "s") had no media to stitch")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.45)))
            }
        }
        .padding(.top, 6)
    }

    // MARK: Building

    /// Renders each clip's stamp, stitches the day, and starts playing.
    private func build(screen: CGSize) async {
        guard player == nil else { return } // Already built for this day.

        // Everything the reel needs, read off the models here on the main actor
        // and in hourly order — the recap's own axis, not a fresh sort. Past this
        // line nothing touches SwiftData. See `RecapClipInfo`.
        let ordered = clips.hourGroups.flatMap { $0 }.map(RecapClipInfo.init)

        guard ordered.contains(where: \.isStitchable) else {
            phase = .nothingToPlay
            return
        }

        // Clips that only exist in Storage are fetched rather than skipped: on
        // any device that didn't film them — a reinstall, a second phone — that
        // is the entire day, and a recap that shows you clips it then refuses to
        // stitch is worse than one that takes a moment to pull them down.
        let resolved = await RecapMediaResolver.resolve(ordered, into: downloads)
        leftOut = ordered.count - resolved.count

        guard !resolved.isEmpty else {
            phase = .failed("This day's clips couldn't be loaded to stitch.")
            return
        }

        // The reel's frame has to be known before the stamps are drawn — they
        // are scaled to cover it, so they have to be laid out in its shape.
        let videoURLs = resolved.compactMap { $0.info.kind == .video ? $0.url : nil }
        let renderSize = await VlogComposer.reelRenderSize(forVideosAt: videoURLs)
        let canvas = RecapStamp.canvas(mediaSize: renderSize, screen: screen)

        let sources = resolved.map { item in
            VlogComposer.ReelSource(
                url: item.url,
                kind: item.info.kind,
                // Stickers and drawings are already in the pixels — burned in at
                // capture by `OverlayBurnIn` — so the only thing left to draw is
                // the stamp, exactly as the live surfaces draw it.
                overlay: RecapStamp.image(date: item.info.capturedAt,
                                          caption: item.info.caption,
                                          canvas: canvas))
        }

        guard let built = await VlogComposer.makeReel(from: sources, renderSize: renderSize) else {
            phase = .failed("This day's clips couldn't be stitched into one video.")
            return
        }

        reel = built
        let item = VlogComposer.makePlayerItem(for: built)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        phase = .playing
        newPlayer.play()
    }

    /// Stops playback, then releases the photo segments the reel rendered.
    ///
    /// Order matters: the composition reads those files lazily, so dropping them
    /// while the player still holds the item blanks the photos.
    private func tearDown() {
        player?.pause()
        player = nil
        reel?.discardScratch()
        reel = nil
        try? FileManager.default.removeItem(at: downloads)
    }
}
