import SwiftUI
import SwiftData
import Photos

/// Your own day, clip by clip.
///
/// The horizontal axis walks the whole timeline, with the same split the hour
/// feeds use: a tap on the leading or trailing quarter steps *one hour*, rolling
/// over into the neighbouring day once you run off the end of one, while a
/// horizontal swipe jumps a whole day at a time. Forward stops at today (there
/// is no tomorrow to recap) and back stops at the edge of the archive.
struct DailyVlogView: View {
    @Environment(\.dismiss) private var dismiss
    @Query private var allClips: [Clip]
    @Query private var friends: [Friend]

    /// How far back the recap archive goes.
    private static let dayCount = 30

    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var saveState: SaveState = .idle
    /// Whether the stitched "watch as one video" reel is up.
    @State private var showReel = false

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
        .fullScreenCover(isPresented: $showReel) {
            RecapReelView(day: selectedDay, clips: clips)
        }
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
                    // Which day this is, is the whole orientation for this screen —
                    // it reads at the same weight as the title above it rather
                    // than as fine print under it.
                    Text(selectedDay.dayLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .contentTransition(.numericText())
                }

                Spacer()

                HStack(spacing: 10) {
                    watchButton
                    downloadButton
                }
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

            Text("tap the edges to step an hour · swipe for a whole day")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 6)
        .animation(.easeOut(duration: 0.2), value: saveState)
    }

    /// Opens the stitched reel.
    ///
    /// Sits beside the download button rather than replacing it: one watches the
    /// day in the app, the other puts a file in Photos. Enabled whenever there's
    /// any media at all, not just video — photos become segments of the reel now
    /// (see `StillSegmentWriter`), which is exactly the difference between this
    /// and the export next to it.
    private var watchButton: some View {
        Button { showReel = true } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background {
                    Circle().fill(.black.opacity(0.45))
                        .overlay { Circle().strokeBorder(.white.opacity(0.16), lineWidth: 1) }
                }
        }
        .buttonStyle(.plain)
        .disabled(stitchableCount == 0)
        .opacity(stitchableCount == 0 ? 0.35 : 1)
        .accessibilityLabel("Watch this day as one video")
    }

    /// Clips the reel can turn into a segment — on disk here, or fetchable from
    /// Storage. Deliberately the same test `RecapClipInfo.isStitchable` applies,
    /// so the button is never enabled onto a reel that turns out to be empty.
    private var stitchableCount: Int {
        clips.filter { RecapClipInfo($0).isStitchable }.count
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
}

// MARK: - Hourly order

extension Array where Element == Clip {
    /// These clips bucketed by clock hour, chronological.
    ///
    /// This is the axis a tap on the recap actually walks, and it isn't the clip
    /// list. The send cooldown is per *chat* while the recap collects everything
    /// you filmed across every chat, so logging to two friends inside one hour
    /// leaves two clips in the same bucket — stepping by clip index would make
    /// that hour cost two taps while the other feeds cross it in one. Grouping
    /// first is what makes "tap = one hour" mean the same thing on the recap as
    /// on the paired and all-friends feeds.
    ///
    /// It is also the reel's running order. Flattening these buckets rather than
    /// re-sorting by `capturedAt` is what guarantees the stitched video plays the
    /// day in exactly the order tapping through it does — two orderings derived
    /// separately are two orderings that can disagree.
    ///
    /// Assumes the receiver is already sorted chronologically, which is how the
    /// recap builds it, so a run of same-hour clips is contiguous and one pass
    /// builds the buckets.
    var hourGroups: [[Clip]] {
        let calendar = Calendar.current
        var groups: [[Clip]] = []
        for clip in self {
            if let previous = groups.last?.last,
               calendar.isDate(previous.capturedAt, equalTo: clip.capturedAt, toGranularity: .hour) {
                groups[groups.count - 1].append(clip)
            } else {
                groups.append([clip])
            }
        }
        return groups
    }
}

// MARK: - One day's mini vlog

/// Plays a single day one clip at a time, advanced an hour per edge tap.
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

    /// The hour-of-day a swipe left from, held until the day it landed on has
    /// its clips in hand and the landing can be resolved. See `swipeDay(_:)`.
    @State private var pendingHour: Int?

    /// `clipIndex` brought inside the day's real bounds, including the `.max`
    /// sentinel and the window between a day change and the task that resolves
    /// it.
    private var safeIndex: Int {
        guard !clips.isEmpty else { return 0 }
        return min(max(clipIndex, 0), clips.count - 1)
    }

    /// The day's clips bucketed by clock hour — see `Array.hourGroups`.
    private var hourGroups: [[Clip]] { clips.hourGroups }

    /// Which hour bucket the clip on screen belongs to.
    private var currentGroup: Int {
        var seen = 0
        for (index, group) in hourGroups.enumerated() {
            seen += group.count
            if safeIndex < seen { return index }
        }
        return max(hourGroups.count - 1, 0)
    }

    /// The edge zones stay live if there's another hour *or* another day beyond
    /// it, so stepping only goes inert at the true ends of the archive.
    private var canGoBack: Bool { currentGroup > 0 || canStepBack }
    private var canGoForward: Bool { currentGroup + 1 < hourGroups.count || canStepForward }

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

                // The same stamp block every other feed draws over a log, so a
                // clip looks the same in the recap as it does in Pulse or a
                // chat feed. This screen used to render the bare `ClipView`
                // alone: the hour and caption are plain data on `Clip` rather
                // than pixels, so nothing drawing them meant the recap simply
                // never showed them.
                //
                // Composed from `ClipStamp` directly rather than by adopting
                // `StackedClipPane` wholesale: the pane carries an author chip
                // (this screen is your own day — the chip would name you on
                // every clip), reaction badges, and its own scrub zones, which
                // would fight the day-rollover ones this page already has. The
                // stamp is the part that's genuinely shared, so that's the part
                // that's reused.
                ClipStampScrim()
                    .ignoresSafeArea()
                ClipStamp(date: clip.capturedAt, caption: clip.label)
            }

            // Scrubbing, over the media and under the footer readout.
            EdgeStepZones(onBack: { step(-1) },
                          onForward: { step(1) },
                          onSwipeBack: { swipeDay(-1) },
                          onSwipeForward: { swipeDay(1) },
                          canStepForward: canGoForward,
                          canStepBack: canGoBack)

            if !clips.isEmpty {
                progressBars
                footer
            }
        }
        .task(id: day) {
            // The new day's `clips` are already in hand here, which is the whole
            // reason both the "last clip" and "same hour" landings are resolved
            // on arrival rather than at the moment of the gesture.
            if let hour = pendingHour {
                clipIndex = startIndex(ofGroupNearest: hour)
            } else {
                clipIndex = clipIndex == .max ? max(clips.count - 1, 0) : 0
            }
            pendingHour = nil
        }
    }

    /// A tap: one hour along the timeline, rolling over to the neighbouring day
    /// at either end.
    ///
    /// The hour is the unit, not the clip — see `hourGroups`. Landing on the
    /// first clip of the hour keeps a two-clip hour costing exactly one tap in
    /// each direction, so walking backwards is the exact reverse of walking
    /// forwards.
    private func step(_ delta: Int) {
        let groups = hourGroups
        let next = currentGroup + delta
        guard !groups.isEmpty, next >= 0, next < groups.count else {
            // Off the end of this day's hours — the rollover, unchanged.
            crossDay(delta)
            return
        }
        // Where that hour's first clip sits in `clips`: everything before it.
        clipIndex = groups[..<next].reduce(0) { $0 + $1.count }
    }

    /// A swipe: the whole neighbouring day in one gesture, landing at the same
    /// time of day you were already watching.
    ///
    /// Distinct from `step(_:)`'s hour-by-hour walk on purpose — the point of
    /// the swipe is to skip the walk, not to reset where you are in the day. The
    /// hour is what carries across; which clip that turns out to be can't be
    /// known until the new day's clips load, so `.task(id: day)` finishes it.
    private func swipeDay(_ delta: Int) {
        guard delta < 0 ? canStepBack : canStepForward else { return }
        pendingHour = clips.isEmpty ? nil
            : Calendar.current.component(.hour, from: clips[safeIndex].capturedAt)
        onStepDay(delta)
    }

    /// The tap's rollover past either end of a day's hours.
    ///
    /// Stepping back lands on the *last* clip of the previous day. That day's
    /// clip count isn't known until it's on screen, hence the `.max` sentinel
    /// resolved by `.task(id: day)`.
    private func crossDay(_ delta: Int) {
        pendingHour = nil // A tap's landing is its own; it never inherits a swipe's.
        if delta < 0 {
            // Guarded so a refused day step can't strand the sentinel.
            guard canStepBack else { return }
            onStepDay(-1)
            clipIndex = .max
        } else {
            guard canStepForward else { return }
            onStepDay(1)
            clipIndex = 0
        }
    }

    /// Where in the flat `clips` list the hour bucket closest to `hour` starts.
    ///
    /// A swipe carries a time of day across, and the day it lands on won't
    /// necessarily hold a log at that exact hour — nearest is the honest answer,
    /// and it's what stops a swipe from dumping you at 6 AM just because that's
    /// when the new day happened to begin. Ties go to the earlier hour.
    private func startIndex(ofGroupNearest hour: Int) -> Int {
        let calendar = Calendar.current
        var landing = 0
        var bestDistance = Int.max
        var offset = 0
        for group in hourGroups {
            if let first = group.first {
                let distance = abs(calendar.component(.hour, from: first.capturedAt) - hour)
                if distance < bestDistance {
                    bestDistance = distance
                    landing = offset
                }
            }
            offset += group.count
        }
        return landing
    }

    /// Story-style position bars, one per *hour* of the day.
    ///
    /// One per hour rather than one per clip because that's what a tap steps
    /// through: with a segment per clip, an hour holding two of them would show
    /// a segment the edge zones can never land on.
    private var progressBars: some View {
        VStack {
            HStack(spacing: 4) {
                ForEach(hourGroups.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentGroup ? Theme.accent : .white.opacity(0.3))
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
