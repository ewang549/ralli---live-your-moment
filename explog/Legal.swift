import SwiftUI

// MARK: - Legal: terms, privacy and the UGC agreement
//
// App Store Guideline 1.2 (Safety — User-Generated Content) asks for four
// things from an app where people post to each other. Three of them already
// exist in `Safety.swift`: reporting, blocking, and published contact details.
// The fourth — an agreement the user accepts before they can post, saying the
// service has no tolerance for objectionable content or abusive users — did
// not, and App Review checks for it specifically on social apps.
//
// This file is that agreement plus the links it points at, in one place so the
// sign-up screen and Settings can't drift apart on what was actually accepted.

enum Legal {
    // MARK: Hosted documents
    //
    // These must be live and reachable before submission. A legal link that
    // 404s is itself a rejection (Guideline 2.1, broken functionality), and the
    // privacy URL here has to match the one entered in App Store Connect →
    // App Privacy → Privacy Policy URL. Change them here only — nothing else
    // in the app hardcodes a legal URL.
    static let privacyPolicyURL = URL(string: "https://ralli.app/privacy")!
    static let termsOfUseURL = URL(string: "https://ralli.app/terms")!
    static let communityGuidelinesURL = URL(string: "https://ralli.app/guidelines")!

    // The support address deliberately isn't redeclared here — `SupportContact`
    // in `Safety.swift` owns it, and the links section below reads it from
    // there, so the address on the report sheet and the one in Settings are
    // always the same string.

    // MARK: The agreement

    /// Shown under the Create Account button, with both documents linked in
    /// place — including the zero-tolerance sentence App Review looks for.
    ///
    /// Built from the URLs above rather than written out with them inlined, so
    /// changing where the terms live can't leave this sentence pointing at the
    /// old address. Parsed once; a markdown failure here would be a programmer
    /// error in the literal below, and the plain text is still correct and
    /// still readable, so it falls back rather than trapping.
    static let signUpConsent: AttributedString = {
        let markdown = """
            I agree to the [Terms of Use](\(termsOfUseURL.absoluteString)) and \
            [Privacy Policy](\(privacyPolicyURL.absoluteString)), and I understand \
            that Ralli has zero tolerance for objectionable content or abusive \
            behaviour. Accounts that post it are removed.
            """
        return (try? AttributedString(markdown: markdown))
            ?? AttributedString(markdown.replacingOccurrences(
                of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression))
    }()

    /// The same commitment stated back to the user in Settings, where there's
    /// no decision to make — just the record of what they accepted.
    static let standingCommitment = """
        Ralli has zero tolerance for objectionable content and abusive users. \
        Reports are reviewed within 24 hours and offending content and accounts \
        are removed.
        """
}

// MARK: - Sign-up consent

/// The accept-the-terms control on the sign-up form.
///
/// A plain `Toggle` would let the label's links fight the switch for the tap,
/// so the checkbox is its own button and the text beside it keeps its links
/// live — tapping "Terms of Use" must open the terms, not silently accept them.
struct LegalConsentRow: View {
    @Binding var accepted: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { accepted.toggle() }
            } label: {
                Image(systemName: accepted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(accepted ? Theme.accent : Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("I agree to the Terms of Use and Privacy Policy")
            .accessibilityAddTraits(accepted ? [.isSelected] : [])

            Text(Legal.signUpConsent)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .tint(Theme.accent)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Settings section

/// Legal and safety links, always reachable from inside the app.
///
/// Apple expects the privacy policy to be readable in the app itself, not only
/// on the store listing, and a user who wants to know the rules they agreed to
/// shouldn't have to go find the App Store page to read them again.
struct LegalLinksSection: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LEGAL & SAFETY")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)

            VStack(spacing: 0) {
                row("Privacy Policy", icon: "hand.raised.square", url: Legal.privacyPolicyURL)
                divider
                row("Terms of Use", icon: "doc.text", url: Legal.termsOfUseURL)
                divider
                row("Community Guidelines", icon: "checkmark.shield", url: Legal.communityGuidelinesURL)
                if let mail = SupportContact.mailtoURL {
                    divider
                    row("Contact support", icon: "envelope", url: mail)
                }
            }
            .padding(.horizontal, 14)
            .background { GlassCard(cornerRadius: 12) { Color.clear } }

            Text(Legal.standingCommitment)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private var divider: some View {
        Divider().overlay(Theme.textTertiary.opacity(0.3))
    }

    private func row(_ title: String, icon: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
