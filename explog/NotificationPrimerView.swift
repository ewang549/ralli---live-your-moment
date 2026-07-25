import SwiftUI

/// The "why" before the system's "allow?".
///
/// Shown once, at the end of onboarding. iOS gives an app exactly one shot at
/// the permission prompt — a denial is effectively permanent — so this states
/// what the notifications actually are before spending it. "Not now" is a real
/// choice and leaves the system prompt unspent for later.
struct NotificationPrimerView: View {
    let onFinish: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var busy = false

    private let reasons: [(icon: String, title: String, detail: String)] = [
        ("person.badge.plus", "Friend requests", "Know when someone wants to add you."),
        ("bubble.left.fill", "Messages and logs", "When a friend sends you something."),
        ("flame.fill", "Streaks", "A nudge before a streak runs out."),
    ]

    var body: some View {
        ZStack {
            GlassBackground()

            VStack(spacing: 0) {
                Spacer(minLength: 20)

                ZStack {
                    Circle()
                        .fill(Theme.accentWash)
                        .frame(width: 96, height: 96)
                    Image(systemName: "bell.badge.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }

                Text("Stay in the loop")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 20)

                Text("Ralli runs on the hour. Notifications are how you catch the moment.")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.top, 8)

                VStack(spacing: 14) {
                    ForEach(reasons, id: \.title) { reason in
                        HStack(spacing: 14) {
                            Image(systemName: reason.icon)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(Theme.accentWash))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(reason.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Text(reason.detail)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 28)

                Spacer(minLength: 24)

                PrimaryButton(title: "Turn on notifications", busy: busy, enabled: !busy) {
                    Task {
                        busy = true
                        await PushNotifications.shared.requestAuthorization()
                        busy = false
                        finish()
                    }
                }
                .padding(.horizontal, 28)

                Button("Not now") { finish() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
                    .disabled(busy)
            }
        }
#if DEBUG
        // CLI hook: scripted runs shouldn't stall on a modal, so the primer
        // dismisses itself during them. SIMCTL_CHILD_EXPLOG_HOLD_PRIMER=1 keeps
        // it up when the point of the run *is* to photograph this screen.
        .task {
            let env = ProcessInfo.processInfo.environment
            guard env["EXPLOG_HOLD_PRIMER"] != "1" else { return }
            guard env["EXPLOG_AUTO_AUTH"] != nil || env["EXPLOG_AUTO_PROFILE"] != nil
                    || env["EXPLOG_AUTO_OPEN"] != nil else { return }
            try? await Task.sleep(for: .seconds(1))
            finish()
        }
#endif
    }

    private func finish() {
        dismiss()
        onFinish()
    }
}
