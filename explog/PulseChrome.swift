import SwiftUI

// MARK: - Hourly cadence banner ("Life, on the hour")

/// Whether this hour's log is still owed or already sent — a status line, not a
/// countdown. The state is carried by one icon and one label: a coral record
/// dot while the hour is open, a mint checkmark once you've posted. When the
/// hour flips the whole card gives a brief coral pulse.
///
/// There is deliberately no clock on this control. A ticking "next log in
/// 23:14" turned the hour into a deadline being counted down at you; what
/// matters is only whether you're on the board yet, which is a two-state
/// question the icon already answers.
///
/// The status side is inert; only the trailing button does anything, and it
/// opens the day's recap. Neither raises the shutter — the tab bar's centre
/// camera stays the one entry point into capture.
struct HourlyCadenceBanner: View {
    /// True when the user has already posted a log during the current clock hour.
    let postedThisHour: Bool

    @State private var flipPulse = false
    @State private var showDailyVlog = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            banner(now: context.date)
        }
        .fullScreenCover(isPresented: $showDailyVlog) {
            DailyVlogView()
        }
    }

    private func banner(now: Date) -> some View {
        // The hour is still tracked, but only to fire the flip pulse — nothing
        // on the card reads the remaining time any more.
        let hourBucket = Calendar.current.component(.hour, from: now)

        return HStack(spacing: 12) {
            // The status readout. Inert: it reports whether this hour is on the
            // board and nothing more. It used to open the hourly wall, which
            // made most of the card a hidden navigation target — the recap
            // button is the only thing here that goes anywhere now.
            HStack(spacing: 14) {
                statusIcon

                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Spacer(minLength: 0)
            }
            // One element, not two: without `.ignore` the icon and the label
            // are read separately, so VoiceOver says the status twice and lands
            // on a decorative glyph. No `.isButton` trait — it isn't one.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)

            recapButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.surface)
                .overlay {
                    // A soft coral wash breathes in only during the flip pulse.
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Theme.accentWash)
                        .opacity(flipPulse ? 0.9 : 0)
                }
                .shadow(color: Theme.accent.opacity(flipPulse ? 0.28 : 0.08),
                        radius: flipPulse ? 20 : 12, y: 5)
        }
        .scaleEffect(flipPulse ? 1.015 : 1)
        .onChange(of: hourBucket) { _, _ in celebrateFlip() }
    }

    /// The whole state of the card in one glyph: a mint checkmark once you've
    /// posted, a coral record dot while the hour is still open. The ring is a
    /// plain disc now — its old trim tracked the elapsed fraction of the hour,
    /// which was the countdown wearing a different shape.
    private var statusIcon: some View {
        let tint = postedThisHour ? Theme.mint : Theme.accent
        return ZStack {
            Circle().fill(tint.opacity(0.14))
            Circle().strokeBorder(tint.opacity(0.35), lineWidth: 2)
            Image(systemName: postedThisHour ? "checkmark" : "record.circle")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(width: 44, height: 44)
        .animation(.easeInOut(duration: 0.25), value: postedThisHour)
    }

    /// The day's recap, one tap from the status it summarises.
    private var recapButton: some View {
        Button { showDailyVlog = true } label: {
            Image(systemName: "film.stack")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 42, height: 42)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Theme.accentWash)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Theme.accent.opacity(0.28), lineWidth: 1)
                        }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Daily recap")
    }

    private var title: String {
        postedThisHour ? "Logged for this hour" : "Send your Log for the hour"
    }

    private func celebrateFlip() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { flipPulse = true }
        withAnimation(.easeOut(duration: 0.7).delay(0.25)) { flipPulse = false }
    }
}

