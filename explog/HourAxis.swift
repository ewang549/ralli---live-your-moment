import SwiftUI

// MARK: - The hour axis
//
// Ralli runs on the hour, so "which hour am I looking at" is a navigation axis
// and not a rendering detail. `HourFeedState` is the single source of truth for
// where you are on it — the Pulse feed has used it since the hourly wall was
// built, and the paired and all-friends feeds now share it rather than each
// keeping their own idea of the current hour.
//
// What lives here is the part `HourFeedState` doesn't cover: resolving a
// person's log for a given hour, and the tap gesture that walks the axis.

extension Friend {
    /// This person's log captured during the clock hour containing `date`.
    ///
    /// The most recent match rather than merely the first: `clips` is an
    /// unordered SwiftData relationship, and the send cooldown is per *chat*,
    /// so logging to two threads inside one hour leaves two clips in the same
    /// bucket. Taking the latest makes the slot deterministic instead of
    /// dependent on relationship ordering.
    /// The hour is resolved to a plain date range *once* and every clip is then
    /// compared against it. The obvious spelling — `Calendar.current.isDate(…,
    /// toGranularity: .hour)` inside the filter — re-reads `Calendar.current`
    /// and does full calendrical component maths for every clip in the
    /// relationship, and this runs once per friend per render on a scrolling
    /// feed. Same result, without the per-element calendar work.
    func clip(forHourContaining date: Date) -> Clip? {
        guard let hour = Calendar.current.dateInterval(of: .hour, for: date) else { return nil }
        // Half-open on purpose. `DateInterval.contains` includes its end, so a
        // clip captured exactly on the next hour's boundary would answer to
        // both hours — and the earlier one would then never be empty.
        return clips
            .filter { $0.capturedAt >= hour.start && $0.capturedAt < hour.end }
            .max { $0.capturedAt < $1.capturedAt }
    }
}

extension Chat {
    /// The clip I sent *into this thread* during the hour containing `date`.
    ///
    /// The chat-scoped counterpart to `Friend.clip(forHourContaining:)`, which
    /// searches a person's whole history and has no idea who a clip was
    /// addressed to. That distinction only matters for your own pane: asking
    /// "what did I make this hour" returns the same clip no matter which friend
    /// you're looking at, so a log sent to one person appeared in your pane
    /// opposite every friend on the roster — which reads exactly like the send
    /// having gone to all of them.
    ///
    /// Same shape as `GroupClipFeedView`, which has always resolved each
    /// member's clip from `chat.sortedClips` rather than from the member.
    /// Hour resolved once up front, as in `Friend.clip(forHourContaining:)`.
    func myClip(forHourContaining date: Date) -> Clip? {
        guard let hour = Calendar.current.dateInterval(of: .hour, for: date) else { return nil }
        return clips
            .filter { $0.author?.isMe == true
                && $0.capturedAt >= hour.start && $0.capturedAt < hour.end }
            .max { $0.capturedAt < $1.capturedAt }
    }
}

// MARK: - Edge step zones

/// The left and right quarters of a container as invisible tap targets, plus a
/// horizontal swipe across the whole of it: tap the leading edge (or swipe
/// right) to step back along an axis, tap the trailing edge (or swipe left) to
/// step forward.
///
/// Nothing here draws. The zones used to carry dim chevrons, which is the one
/// piece of chrome that sat permanently on top of every log — the media is the
/// content, so the affordance is the gesture rather than an icon.
///
/// The tap zones are deliberately quarters with an inert middle 50%, matching
/// the gesture the Pulse feed established for exactly this job: it leaves room
/// for a card's own controls, and a tap aimed at nothing in particular does
/// nothing rather than silently moving you through time. The *swipe* spans the
/// full width, since a swipe is unambiguous wherever it starts.
///
/// Layer this *above* the media but *below* anything tappable. It fills its
/// container, so whatever sits over it keeps its own taps — which is how the
/// action rails on these feeds survive sitting inside the trailing quarter.
struct EdgeStepZones: View {
    let onBack: () -> Void
    let onForward: () -> Void
    /// Ignores forward taps and swipes when the axis has nothing ahead — the
    /// live hour, or today on the recap.
    var canStepForward: Bool = true
    /// Same, for the far end of the archive.
    var canStepBack: Bool = true

    private enum Edge { case leading, trailing }

    /// How far a drag has to travel horizontally before it counts as a step.
    private let swipeThreshold: CGFloat = 60

    var body: some View {
        GeometryReader { proxy in
            let edgeWidth = max(1, proxy.size.width * 0.25)

            ZStack {
                // Full-width swipe catcher, under the tap zones so it never
                // steals their taps. It carries no tap gesture of its own, so
                // the middle stays inert exactly as it was.
                swipeCatcher

                HStack(spacing: 0) {
                    zone(width: edgeWidth, edge: .leading, enabled: canStepBack, action: onBack)

                    // The inert middle. No content shape, so it isn't hit-tested
                    // and taps fall through to the swipe catcher, which ignores
                    // them.
                    Color.clear.frame(maxWidth: .infinity)

                    zone(width: edgeWidth, edge: .trailing, enabled: canStepForward, action: onForward)
                }
            }
        }
    }

    /// Horizontal swipe → the same step the edge taps make.
    ///
    /// `.simultaneousGesture` rather than `.gesture`, and this matters: these
    /// panes live inside vertically-paging scroll views, and an exclusive drag
    /// gesture here would win the whole touch and kill scrolling between
    /// friends. Recognizing simultaneously lets the scroll view keep the
    /// vertical component while this reads the horizontal one — which the
    /// scroll view has no use for anyway.
    private var swipeCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        let dx = value.translation.width
                        // Horizontal-dominant only, so the tail end of a
                        // vertical page swipe can't drift into an hour step.
                        guard abs(dx) > swipeThreshold,
                              abs(dx) > abs(value.translation.height) else { return }
                        if dx < 0 {
                            guard canStepForward else { return }
                            onForward()
                        } else {
                            guard canStepBack else { return }
                            onBack()
                        }
                    }
            )
    }

    private func zone(width: CGFloat,
                      edge: Edge,
                      enabled: Bool,
                      action: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                guard enabled else { return }
                action()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(edge == .leading ? "Previous" : "Next")
    }
}
