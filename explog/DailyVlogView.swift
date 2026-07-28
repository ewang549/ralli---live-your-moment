import SwiftUI
import SwiftData
import Photos

/// Your own day, clip by clip.
///
/// The horizontal axis walks the whole timeline: tap the leading edge to go
/// back, the trailing edge to go forward — the same quarter-width edge zones the
/// hour feeds use, so one gesture means "step along the time axis" everywhere.
/// A step moves between the *clips* of the day on screen and only rolls over to
/// the next or previous day once you run off the end of one. Forward stops at
/// today (there is no tomorrow to recap) and back stops at the edge of the
/// archive.
struct DailyVlogView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allClips: [Clip]
    @Query private var friends: [Friend]

    /// How far back the recap archive goes.
    private static let dayCount = 30

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var saveState: SaveState = .idle

    /// Where a "save to Photos" has got to. Kept on this screen rather than
    /// inside the player so it survives a re-stitch.
    private enum SaveState: Equatable {
        case idle
        case working
        case saved
        case failed(String)
    }

    private var me: Friend? { friends.first { $0.isMe } }

    private var today: Date { Calendar.current.startOfDay(for: .now) }

    /// The oldest day the archive reaches back to.
    private var earliestDay: Date {
        Calendar.current.date(byAdding: .day, value: -(Self.dayCount - 1), to: today) ?? today
    }

    private var canStepBack: Bool { selectedDay > earliestDay }
    private var canStepForward: Bool { selectedDay < today }

    /// Walks the day axis, clamped to the archive at one end and today at the
    /// other so the recap can never land on a day that cannot have content.
    private func stepDay(_ delta: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: delta, to: selectedDay) else { return }
        let clamped = min(max(next, earliestDay), today)
        guard clamped != selectedDay else { return }
        selectedDay = clamped
        saveState = .idle // The exported file belonged to the day we just left.
    }

    private var clips: [Clip] {
        guard let me else { return [] }
        let calendar = Calendar.current
        return allClips
            .filter { $0.author?.id == me.id && calendar.isDate($0.capturedAt, inSameDayAs: selectedDay) }
            .sorted { $0.capturedAt < $1.capturedAt } // chronological, like a vlog
    }

    /// The clips that can actually be concatenated: real video files on disk.
    private var videoURLs: [URL] {
        clips.compactMap { clip in
            guard clip.kind == .video, let url = clip.assetURL,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// Photos and vibe clips from this day that the stitched reel leaves out.
    ///
    /// Surfaced rather than swallowed: a still has no video track to insert, so
    /// including one means rendering it to frames — real work that this first
    /// version doesn't do. Saying so is the difference between a known gap and
    /// a recap that quietly loses half your day.
    private var stillsLeftOut: Int { clips.count - videoURLs.count }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            DayRecapPage(day: selectedDay,
                         clips: clips,
                         videoURLs: videoURLs,
                         canStepBack: canStepBack,
                         canStepForward: canStepForward,
                         onStepDay: stepDay,
                         stillsLeftOut: stillsLeftOut)
                .ignoresSafeArea()

            header
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Chrome

    private var header: some View {
        VStack(spacing: 8) {
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
                        .contentTransition(.numericText())
                }

                Spacer()

                downloadButton
            }
            .padding(.horizontal, 16)

            if let note = saveNote {
                Text(note)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.55)))
                    .transition(.opacity)
            }

            Text("tap the edges to step through your day")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: saveState)
    }

    private var downloadButton: some View {
        Button { save() } label: {
            Group {
                switch saveState {
                case .working: ProgressView().tint(.white).scaleEffect(0.8)
                case .saved: Image(systemName: "checkmark")
                default: Image(systemName: "arrow.down.to.line")
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(saveState == .saved ? Theme.mint : .white)
            .frame(width: 36, height: 36)
            .background {
                Circle().fill(.black.opacity(0.45))
                    .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
            }
        }
        .buttonStyle(.plain)
        // Nothing stitchable means nothing to hand the photo library.
        .disabled(videoURLs.isEmpty || saveState == .working)
        .opacity(videoURLs.isEmpty ? 0.35 : 1)
        .accessibilityLabel("Save this day to Photos")
    }

    private var saveNote: String? {
        switch saveState {
        case .idle: nil
        case .working: "Saving to Photos…"
        case .saved: "Saved to Photos"
        case .failed(let message): message
        }
    }

    // MARK: Save to Photos

    /// Exports the stitched day and hands the file to the photo library.
    ///
    /// Add-only authorization: this writes one video and never reads the
    /// library, so asking for full access would be asking for more than the
    /// feature needs.
    private func save() {
        guard !videoURLs.isEmpty, saveState != .working else { return }
        saveState = .working
        let urls = videoURLs
        let name = "ralli-recap-\(selectedDay.formatted(.iso8601.year().month().day()))"

        Task { @MainActor in
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                saveState = .failed("Allow photo access in Settings to save your recap.")
                return
            }
            do {
                let file = try await VlogComposer.export(urls, named: name)
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
                }
                saveState = .saved
            } catch {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "today" }
        if calendar.isDateInYesterday(day) { return "yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

// MARK: - One day's mini vlog

/// Plays a single day one clip at a time, advanced by tapping the edges.
///
/// Viewing is deliberately *not* the stitched reel. Concatenating the day into
/// one continuous video gave the edge taps nothing to step through, so they had
/// to move whole days and a single clip inside a day was unreachable. Playing
/// `clips[clipIndex]` on its own makes "back" and "forward" mean the same thing
/// here as everywhere else in the app. The export is untouched by this and still
/// stitches the whole day — what you save is the day, what you watch is a clip.
///
/// There is no auto-advance: each clip loops until you ask for the next one.
private struct DayRecapPage: View {
    let day: Date
    let clips: [Clip]
    /// The stitchable subset, resolved by the parent so the footer's readout and
    /// the export can never disagree about what's in the saved reel.
    let videoURLs: [URL]
    let canStepBack: Bool
    let canStepForward: Bool
    let onStepDay: (Int) -> Void
    let stillsLeftOut: Int

    /// Which clip of `day` is on screen.
    ///
    /// May briefly hold `.max` as a sentinel meaning "whichever clip is last" —
    /// see `step(_:)`. Always read through `safeIndex`, never directly.
    @State private var clipIndex = 0

    /// `clipIndex` brought inside the day's real bounds, including the `.max`
    /// sentinel and the window between a day change and the task that resolves
    /// it.
    private var safeIndex: Int {
        guard !clips.isEmpty else { return 0 }
        return min(max(clipIndex, 0), clips.count - 1)
    }

    /// The edge zones stay live if there's another clip *or* another day beyond
    /// it, so stepping only goes inert at the true ends of the archive.
    private var canGoBack: Bool { safeIndex > 0 || canStepBack }
    private var canGoForward: Bool { safeIndex + 1 < clips.count || canStepForward }

    var body: some View {
        ZStack {
            Color.black

            if clips.isEmpty {
                emptyState
            } else {
                let clip = clips[safeIndex]
                // Letterboxed, not filled: capture is landscape-only, so
                // filling this portrait screen crops the shot down to a strip
                // of its middle — framing the user never chose. The `Color`
                // base above is the letterbox backing.
                ClipView(clip: clip, isActive: true, contentMode: .fit)
                    .id(clip.id)
                    .ignoresSafeArea()
            }

            // Scrubbing, over the media and under the footer readout.
            EdgeStepZones(onBack: { step(-1) },
                          onForward: { step(1) },
                          canStepForward: canGoForward,
                          canStepBack: canGoBack)

            if !clips.isEmpty {
                progressBars
                footer
            }
        }
        .task(id: day) {
            // The new day's `clips` are already in hand here, which is the whole
            // reason the "last clip" landing is resolved on arrival rather than
            // at the moment of the tap.
            clipIndex = clipIndex == .max ? max(clips.count - 1, 0) : 0
        }
    }

    /// Walks the timeline: within the day while there are clips left, rolling
    /// over to the neighbouring day at either end.
    ///
    /// Stepping back lands on the *last* clip of the previous day, so walking
    /// backwards is the exact reverse of walking forwards. That day's clip count
    /// isn't known until it's on screen, hence the `.max` sentinel resolved by
    /// `.task(id: day)`.
    private func step(_ delta: Int) {
        let next = safeIndex + delta
        if next < 0 {
            // Guarded so a refused day step can't strand the sentinel.
            guard canStepBack else { return }
            onStepDay(-1)
            clipIndex = .max
        } else if next >= clips.count {
            guard canStepForward else { return }
            onStepDay(1)
            clipIndex = 0
        } else {
            clipIndex = next
        }
    }

    /// Story-style position bars, one per clip of the day.
    private var progressBars: some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(clips.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= safeIndex ? Theme.accent : .white.opacity(0.3))
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 16)
            // Clears the three-line header above (title, day, the step hint)
            // rather than cutting across it.
            .padding(.top, 140)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("🎬").font(.system(size: 56))
            Text("No logs on this day")
                .foregroundStyle(Theme.textSecondary)
            Text("tap the edges to find one")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .allowsHitTesting(false)
    }

    private var footer: some View {
        VStack {
            Spacer()
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Image(systemName: "film.stack")
                        .foregroundStyle(Theme.accent)
                    Text(reelSummary)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.black.opacity(0.5)))

                // The honest footnote: photos and vibe clips have no video
                // track, so they aren't in the stitched reel or the saved file.
                if stillsLeftOut > 0 && !videoURLs.isEmpty {
                    Text("\(stillsLeftOut) photo\(stillsLeftOut == 1 ? "" : "s") not in the reel yet")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.black.opacity(0.45)))
                }
            }
            .padding(.bottom, 40)
        }
        .allowsHitTesting(false)
    }

    /// Where you are in the day, then how long the day saves out as.
    ///
    /// Position is over the whole day's clips, not the stitchable subset: it has
    /// to agree with the bar above it and with what a tap actually does, both of
    /// which walk every clip. The duration stays the *reel's*, since that
    /// describes the file the download button produces.
    private var reelSummary: String {
        let count = videoURLs.isEmpty ? clips.count : videoURLs.count
        let seconds = Int(Double(count) * CaptureContext.pulse.maxClipDuration)
        return "clip \(safeIndex + 1) of \(clips.count) · \(seconds)s vlog"
    }
}
