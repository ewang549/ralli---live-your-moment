import SwiftUI

// MARK: - Hourly cadence banner ("Life, on the hour")

/// A live countdown to the top of the next hour — the next window to post a log.
/// A coral progress ring fills as the hour elapses; the copy frames the action
/// ("Next log in 23:14"), and the trailing capture button posts. When the hour
/// flips the whole card gives a brief coral pulse and nudges a capture; once the
/// user has posted this hour it settles into a satisfied "logged" state.
///
/// Tapping the body opens the synced hourly wall. The card no longer carries
/// its own capture button — the bottom tab bar's center camera is the one
/// entry point into capture, so this card is a status readout you tap into,
/// not a second way to raise the shutter.
struct HourlyCadenceBanner: View {
    /// True when the user has already posted a log during the current clock hour.
    let postedThisHour: Bool
    let onOpenHour: () -> Void

    @State private var flipPulse = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            banner(now: context.date)
        }
    }

    private func banner(now: Date) -> some View {
        let cal = Calendar.current
        let nextHour = cal.nextDate(after: now,
                                    matching: DateComponents(minute: 0, second: 0),
                                    matchingPolicy: .nextTime) ?? now
        let remaining = max(0, nextHour.timeIntervalSince(now))
        let fraction = min(1, max(0, (3600 - remaining) / 3600))
        let minutesLeft = max(1, Int(ceil(remaining / 60)))
        let hourBucket = cal.component(.hour, from: now)

        return Button(action: onOpenHour) {
            HStack(spacing: 14) {
                progressRing(fraction: fraction, minutesLeft: minutesLeft)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title(remaining: remaining))
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    private func progressRing(fraction: Double, minutesLeft: Int) -> some View {
        let tint = postedThisHour ? Theme.mint : Theme.accent
        return ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: 5)
            Circle()
                .trim(from: 0, to: postedThisHour ? 1 : fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)

            if postedThisHour {
                Image(systemName: "checkmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Theme.mint)
            } else {
                VStack(spacing: -1) {
                    Text("\(minutesLeft)")
                        .font(.system(size: 17, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text("min")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(width: 50, height: 50)
    }

    private func title(remaining: TimeInterval) -> String {
        if postedThisHour { return "Logged this hour" }
        return "Next log in \(cooldownString(remaining))"
    }

    private var subtitle: String {
        postedThisHour ? "You're on the board — next hour opens soon"
                       : "Ralli runs on the hour. Post yours."
    }

    private func celebrateFlip() {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.55)) { flipPulse = true }
        withAnimation(.easeOut(duration: 0.7).delay(0.25)) { flipPulse = false }
    }
}

