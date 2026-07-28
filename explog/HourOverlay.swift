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
