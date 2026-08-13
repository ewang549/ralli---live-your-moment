import SwiftUI

/// The hour banner burned horizontally across a log's frame.
///
/// Ralli logs are filmed once per clock hour, so the hour *is* the stamp — the
/// minute is never meaningful (see `Date.hourOnlyClockTime`). This one component
/// is the single definition of how that stamp looks, and it is deliberately
/// shared by every surface that shows it: the live viewfinder, the post-capture
/// review, and each pane of the stacked feed. Rebuilding it per screen is what
/// would let the three drift apart in size or weight.
///
/// Styled to read over live video without chrome: heavy rounded type, white,
/// with a soft shadow doing the legibility work instead of a plate.
struct HourOverlay: View {
    let date: Date

    var body: some View {
        Text(date.hourOnlyClockTime)
            .font(.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
            .shadow(color: .black.opacity(0.3), radius: 2)
            // Horizontal banner across the frame rather than a hugging label,
            // so the stamp is centred on the *media*, not on its own text box.
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
            .accessibilityLabel("Filmed at \(date.hourOnlyClockTime)")
    }
}

// MARK: - Caption type

extension Font {
    /// The one type a log's caption is ever drawn in.
    ///
    /// `Clip.label` used to be styled independently at six call sites — the
    /// profile grid, the recap, Pulse, the log player, and twice in Places —
    /// each picking its own size and weight for the same string, so the same
    /// caption changed shape as you moved between screens. Defined here, next
    /// to `HourOverlay`, because it is deliberately the stamp's family one step
    /// down: same rounded face, lighter weight, smaller size. The two read as
    /// one block wherever they appear together.
    static let logCaption = Font.system(size: 17, weight: .semibold, design: .rounded)

    /// `logCaption` a size down, for the compose field on the review screen
    /// and the send preview — secondary to the hour stamp it sits under.
    static let logCaptionCompact = Font.system(size: 15, weight: .semibold, design: .rounded)
}

// MARK: - The stamp block

/// The hour banner with the log's caption directly beneath it.
///
/// These two are one block, not two overlays — `PostCaptureReview` composes them
/// this way before a log is ever sent, and every surface that plays the log back
/// has to keep them together or the caption a user watched sit under the time on
/// the review screen jumps somewhere else the moment it's sent.
///
/// Defined here rather than inside any one feed because it is genuinely shared:
/// the stacked panes (Pulse, the 1-on-1 and group and all-friends feeds) and the
/// daily recap all draw it. The recap used to draw nothing at all, and
/// `MontageView` drew its own plain-`Text` version — a third shape for the same
/// two strings. One definition is what stops that happening again.
struct ClipStamp: View {
    let date: Date
    /// `Clip.label`. Empty hides the caption line and leaves the hour alone.
    let caption: String

    var body: some View {
        VStack(spacing: 6) {
            HourOverlay(date: date)
            if !caption.isEmpty {
                Text(caption)
                    .font(.logCaptionCompact)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 24)
            }
        }
        // Pure readout: left hit-testable it sits above the scrub zones and
        // swallows taps landing mid-frame.
        .allowsHitTesting(false)
    }
}

/// The legibility wash the stamp is read against.
///
/// Captions sit over live video, which is bright and moving and cannot be relied
/// on to stay dark behind white type. Paired with `ClipStamp` wherever it's drawn
/// over media.
struct ClipStampScrim: View {
    var body: some View {
        LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.55)],
                       startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
    }
}

/// `HourOverlay` over the current hour, kept current while the screen is up.
///
/// Used where there is no captured clip to stamp yet — the live viewfinder —
/// so the banner rolls over on its own at the top of the hour instead of
/// freezing at whatever hour the camera happened to open in. Ticks every
/// minute, which is as fine-grained as an hour-only readout can need.
struct LiveHourOverlay: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            HourOverlay(date: context.date)
        }
    }
}
