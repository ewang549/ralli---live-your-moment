import SwiftUI
import SwiftData
import AVKit

/// Swipe-right destination from the Pulse feed: your own day, stitched end to end.
///
/// Days are laid out oldest → newest left to right, so the paging gesture that
/// brought you here (a right swipe) keeps walking backwards through your history.
struct DailyVlogView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allClips: [Clip]
    @Query private var friends: [Friend]

    /// How far back the recap archive goes.
    private static let dayCount = 30

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)

    private var me: Friend? { friends.first { $0.isMe } }

    /// Oldest first, today last — matches the left-to-right paging order.
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: .now)
        return (0..<Self.dayCount)
            .compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: today) }
            .reversed()
    }

    private func clips(on day: Date) -> [Clip] {
        guard let me else { return [] }
        let calendar = Calendar.current
        return allClips
            .filter { $0.author?.id == me.id && calendar.isDate($0.capturedAt, inSameDayAs: day) }
            .sorted { $0.capturedAt < $1.capturedAt } // chronological, like a vlog
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            // Horizontal paging = day scrubbing. Each page owns its own player.
            TabView(selection: $selectedDay) {
                ForEach(days, id: \.self) { day in
                    DayRecapPage(day: day, clips: clips(on: day))
                        .tag(day)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            header
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                CloseButton(overMedia: true) { dismiss() }

                Spacer()

                VStack(spacing: 1) {
                    Text("Daily recap")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(dayTitle(selectedDay))
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }

                Spacer()

                // Balances the leading button so the title stays centered.
                Color.clear.frame(width: 36, height: 36)
            }
            .padding(.horizontal, 16)

            Text("swipe → for earlier days")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 6)
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInYesterday(day) { return "yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

// MARK: - One day's mini vlog

/// Plays a single day: real captures are concatenated into one continuous video,
/// anything else falls back to a timed sequence of the day's clips.
private struct DayRecapPage: View {
    let day: Date
    let clips: [Clip]

    @State private var stitched: AVPlayer?
    @State private var isStitching = true
    @State private var fallbackIndex = 0

    /// Only on-disk video files can be fed to `AVMutableComposition`.
    private var videoURLs: [URL] {
        clips.compactMap { clip in
            guard clip.kind == .video, let url = clip.assetURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    var body: some View {
        ZStack {
            Color.black

            if clips.isEmpty {
                emptyState
            } else if let stitched {
                // The real "mini vlog": every clip of the day as one video.
                VideoPlayer(player: stitched)
                    .ignoresSafeArea()
                    .onAppear { stitched.play() }
                    .onDisappear { stitched.pause() }
            } else if isStitching {
                ProgressView().tint(.white)
            } else {
                fallbackReel
            }

            if !clips.isEmpty {
                footer
            }
        }
        .task(id: day) {
            isStitching = true
            stitched = nil
            fallbackIndex = 0
            // Composition is off the main thread inside VlogComposer's awaits.
            if let item = await VlogComposer.makePlayerItem(from: videoURLs) {
                let player = AVQueuePlayer(playerItem: item)
                player.actionAtItemEnd = .pause
                stitched = player
            }
            isStitching = false
        }
    }

    /// Story-style sequence used when the day has no stitchable video
    /// (seeded "vibe" clips, photos, or simulator captures).
    private var fallbackReel: some View {
        let clip = clips[min(fallbackIndex, clips.count - 1)]
        return ZStack {
            ClipView(clip: clip, isActive: true)
                .id(clip.id)
                .ignoresSafeArea()

            VStack {
                HStack(spacing: 4) {
                    ForEach(clips.indices, id: \.self) { index in
                        Capsule()
                            .fill(index <= fallbackIndex ? Theme.gold : .white.opacity(0.3))
                            .frame(height: 3)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 92)
                Spacer()
            }
        }
        .task(id: fallbackIndex) {
            guard clips.count > 1 else { return }
            try? await Task.sleep(for: .seconds(clipDuration))
            withAnimation(.easeInOut(duration: 0.25)) {
                fallbackIndex = (fallbackIndex + 1) % clips.count
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🎬").font(.system(size: 56))
            Text("No logs on this day")
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var footer: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .foregroundStyle(Theme.gold)
                Text("\(clips.count) clip\(clips.count == 1 ? "" : "s") · \(totalSecondsLabel)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.5)))
            .padding(.bottom, 40)
        }
    }

    private var totalSecondsLabel: String {
        // Each pulse clip is capped at 2s, so the reel length is predictable.
        let seconds = Double(clips.count) * CaptureContext.pulse.maxClipDuration
        return "\(Int(seconds))s vlog"
    }
}
