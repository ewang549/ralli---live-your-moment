import SwiftUI

/// Whether the beta thank-you has already been shown.
///
/// Same shape as `PushNotifications.hasPrimed`: a single `UserDefaults` flag, so
/// it's once per install rather than once per launch. Deliberately *not* tied to
/// an account — it's a thank-you for installing early, not an entitlement, so
/// signing out and back in must not bring it back.
enum ProWelcome {
    private static let seenKey = "ralli.hasSeenProWelcome"

    static var hasSeen: Bool {
        get { UserDefaults.standard.bool(forKey: seenKey) }
        set { UserDefaults.standard.set(newValue, forKey: seenKey) }
    }

    /// Whether to show it for this launch. Read once, at the root view's init.
    static var shouldShowAtLaunch: Bool {
#if DEBUG
        resetIfRequested()
#endif
        return !hasSeen
    }

#if DEBUG
    /// Guards against the reset firing more than once: SwiftUI re-runs a
    /// `@State` default expression on every struct init, and clearing the flag
    /// again after dismissal would loop the screen forever.
    private static var didResetThisLaunch = false

    /// CLI hook, same family as `EXPLOG_RESET_CACHE`: replays the one-time
    /// screen without needing to reinstall the app.
    ///   SIMCTL_CHILD_EXPLOG_RESET_PRO_WELCOME=1
    private static func resetIfRequested() {
        guard !didResetThisLaunch else { return }
        didResetThisLaunch = true
        guard ProcessInfo.processInfo.environment["EXPLOG_RESET_PRO_WELCOME"] == "1" else { return }
        UserDefaults.standard.removeObject(forKey: seenKey)
    }
#endif
}

/// One-time beta thank-you, shown ahead of sign-in on a fresh install.
///
/// Presentation only: there is no entitlement behind "Pro" yet and nothing in
/// the app checks for one. This screen says thank you and sets the expectation;
/// when a real tier exists it can reuse `RalliProBadge` without touching this.
struct ProWelcomeView: View {
    /// Dismisses into the normal sign-in flow. The caller owns persisting the
    /// flag, so this view stays presentation-only and previewable.
    let onContinue: () -> Void

    @State private var revealed = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // The gift is the hero, so it gets the top of the optical centre and
            // the only decoration on screen.
            RalliProWordmark(size: 52)
                .scaleEffect(revealed ? 1 : 0.86)
                .opacity(revealed ? 1 : 0)
                .padding(.bottom, 34)

            Text("Thank you for being one of our first.")
                .font(.system(size: 27, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)

            // "Ralli Pro" reads inline here rather than as a separate lockup, so
            // the sentence stays a sentence — the gold does the emphasis.
            HStack(spacing: 5) {
                Text("You've got")
                RalliWordmark(size: 17)
                RalliProBadge(size: 17, showsGlow: false)
                Text("— on us.")
            }
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.top, 16)

            Text("Every premium feature we build, free for as long as you're with us in beta.")
                .font(.system(size: 15))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 40)
                .padding(.top, 14)

            Spacer()

            PrimaryButton(title: "Let's go", busy: false, enabled: true, action: onContinue)
                .padding(.horizontal, 28)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(revealed ? 1 : 0)
        // Warm canvas with the same coral bloom `WelcomeView` uses, plus a
        // single gold wash behind the lockup — the only hint that this screen is
        // about something other than the brand.
        .background {
            ZStack {
                Theme.appBackground
                RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                               center: .init(x: 0.5, y: 0.30),
                               startRadius: 0, endRadius: 400)
                RadialGradient(colors: [ProGold.glow.opacity(revealed ? 0.20 : 0), .clear],
                               center: .init(x: 0.5, y: 0.32),
                               startRadius: 0, endRadius: 260)
            }
            .ignoresSafeArea()
        }
        .onAppear {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.72)) {
                revealed = true
            }
        }
    }
}

#Preview {
    ProWelcomeView {}
}
