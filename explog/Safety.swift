import SwiftUI
import SwiftData

// MARK: - Safety: block & report (Phase 4)
//
// App Store Guideline 1.2 requires a way to block and report from anywhere a
// user or their content appears. This file is the single implementation of
// both, so "anywhere" stays one code path: profiles, message bubbles and log
// rows all attach `.safetyActions(...)` and get the same menu, the same sheet
// and the same copy.

/// Where to reach a human. Shown on the report sheet — reporting has to come
/// with a way to follow up, not just a form that swallows the complaint.
enum SupportContact {
    static let email = "support@ralli.app"
    static var mailtoURL: URL? { URL(string: "mailto:\(email)") }
}

/// What a reporter can pick. Raw values match the server's `REPORT_REASONS`
/// set — anything else is rejected as `invalid-argument`.
enum ReportReason: String, CaseIterable, Identifiable {
    case spam
    case harassment
    case nudity
    case violence
    case hate
    case impersonation
    case selfHarm = "self_harm"
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .spam: "Spam or scam"
        case .harassment: "Harassment or bullying"
        case .nudity: "Nudity or sexual content"
        case .violence: "Violence or threats"
        case .hate: "Hate speech"
        case .impersonation: "Pretending to be someone else"
        case .selfHarm: "Self-harm or suicide"
        case .other: "Something else"
        }
    }
}

/// The thing being acted on. A report needs to know both *what* was reported
/// and *who* authored it — blocking only ever needs the account.
struct SafetyTarget: Equatable {
    enum Kind: String, Equatable {
        case user
        case log
        case message
    }

    let kind: Kind
    /// The account responsible. This is what a block applies to.
    let uid: String
    /// Log or message id. Equal to `uid` when the target is the account itself.
    let contentId: String
    /// For the confirmation copy — "Block Sam?" reads better than "Block user?".
    let displayName: String

    static func user(uid: String, name: String) -> SafetyTarget {
        SafetyTarget(kind: .user, uid: uid, contentId: uid, displayName: name)
    }

    static func log(id: String, authorUid: String, authorName: String) -> SafetyTarget {
        SafetyTarget(kind: .log, uid: authorUid, contentId: id, displayName: authorName)
    }

    static func message(id: String, authorUid: String, authorName: String) -> SafetyTarget {
        SafetyTarget(kind: .message, uid: authorUid, contentId: id, displayName: authorName)
    }

    var isContent: Bool { kind != .user }
}

// MARK: - Attaching the actions

/// Presentation state shared by the menu, the block confirmation and the report
/// sheet. Held by the modifier so a caller only supplies a target.
@MainActor
@Observable
final class SafetyPresentation {
    var reporting: SafetyTarget?
    var blocking: SafetyTarget?

    /// Shared by the Stream message actions. Those are built inside the view
    /// factory, which has no view of its own to hang `@State` on, so the
    /// thread view observes this instance instead.
    static let chat = SafetyPresentation()
}

/// Adds Block and Report to any view, as both a context menu (long-press) and
/// the sheets those actions open.
///
/// Attached rather than inlined so every surface gets identical behaviour and
/// nothing has to re-implement the confirm step — the part that's easy to skip
/// and the part that makes a block feel safe to tap.
struct SafetyActions: ViewModifier {
    let target: SafetyTarget
    /// Shown as a long-press context menu when true. Rows that already own
    /// their long-press (message bubbles have tapbacks) pass `false` and
    /// surface the actions through their own menu instead.
    var includeContextMenu = true
    /// Called after a successful block, so the presenting screen can dismiss
    /// itself — you shouldn't be left looking at someone you just blocked.
    var onBlocked: (() -> Void)?

    @State private var presentation = SafetyPresentation()

    func body(content: Content) -> some View {
        content
            .modifier(ConditionalContextMenu(enabled: includeContextMenu) {
                SafetyMenuItems(target: target, presentation: presentation)
            })
            .modifier(SafetySheets(target: target,
                                   presentation: presentation,
                                   onBlocked: onBlocked))
    }
}

/// The report sheet and the block confirmation, shared by every entry point so
/// the confirm step can't be skipped by whoever adds the next one.
struct SafetySheets: ViewModifier {
    /// The target this surface is about, when it has exactly one. Screens that
    /// serve many targets — a message list — pass nil and let the pending
    /// action name itself.
    var target: SafetyTarget?
    let presentation: SafetyPresentation
    var onBlocked: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph

    private var blockName: String {
        presentation.blocking?.displayName ?? target?.displayName ?? "this person"
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { presentation.reporting },
                                 set: { presentation.reporting = $0 })) { target in
                ReportSheet(target: target, onBlocked: onBlocked)
            }
            .confirmationDialog(
                "Block \(blockName)?",
                isPresented: Binding(get: { presentation.blocking != nil },
                                     set: { if !$0 { presentation.blocking = nil } }),
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    Task { await block() }
                }
                Button("Cancel", role: .cancel) { presentation.blocking = nil }
            } message: {
                Text("They won't be able to message you or see your logs, and you won't see theirs. Your friendship and any pending requests are removed.")
            }
    }

    private func block() async {
        guard let pending = presentation.blocking else { return }
        presentation.blocking = nil
        let profile = RemoteProfile(uid: pending.uid,
                                    handle: "",
                                    handleDisplay: "",
                                    name: pending.displayName,
                                    avatarEmoji: "🙂",
                                    city: "",
                                    bio: "",
                                    isPrivate: false)
        try? await friendGraph.block(profile, context: modelContext)
        onBlocked?()
    }
}

/// An overflow control for surfaces where a long-press is already taken or
/// wouldn't be discovered — the log player's chrome, chat headers.
struct SafetyMenuButton: View {
    let target: SafetyTarget
    var tint: Color = .white
    var onBlocked: (() -> Void)?

    @State private var presentation = SafetyPresentation()

    var body: some View {
        Menu {
            SafetyMenuItems(target: target, presentation: presentation)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.black.opacity(0.35)))
        }
        .accessibilityLabel("More options")
        .modifier(SafetySheets(target: target,
                               presentation: presentation,
                               onBlocked: onBlocked))
    }
}

/// `contextMenu` has no "off" switch, so the choice is made at the type level.
private struct ConditionalContextMenu<MenuContent: View>: ViewModifier {
    let enabled: Bool
    @ViewBuilder let menuContent: () -> MenuContent

    func body(content: Content) -> some View {
        if enabled {
            content.contextMenu { menuContent() }
        } else {
            content
        }
    }
}

/// The two buttons themselves, so a screen with its own `Menu` can drop them in
/// without going through the modifier.
struct SafetyMenuItems: View {
    let target: SafetyTarget
    let presentation: SafetyPresentation

    var body: some View {
        Button(role: .destructive) {
            presentation.reporting = target
        } label: {
            Label(target.isContent ? "Report this" : "Report", systemImage: "flag")
        }

        Button(role: .destructive) {
            presentation.blocking = target
        } label: {
            Label("Block \(target.displayName)", systemImage: "hand.raised")
        }
    }
}

extension View {
    /// Makes a user or a piece of their content reportable and blockable.
    func safetyActions(for target: SafetyTarget,
                       includeContextMenu: Bool = true,
                       onBlocked: (() -> Void)? = nil) -> some View {
        modifier(SafetyActions(target: target,
                               includeContextMenu: includeContextMenu,
                               onBlocked: onBlocked))
    }
}

// MARK: - Report sheet

extension SafetyTarget: Identifiable {
    var id: String { "\(kind.rawValue):\(contentId)" }
}

/// Pick a reason, optionally add context, optionally block at the same time.
///
/// "Also block" defaults on for account reports: someone who has just been
/// harassed shouldn't have to make a second decision to stop it.
struct ReportSheet: View {
    let target: SafetyTarget
    var onBlocked: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph
    @Environment(\.openURL) private var openURL

    @State private var reason: ReportReason?
    @State private var details = ""
    @State private var alsoBlock = true
    @State private var submitting = false
    @State private var errorMessage: String?
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                if submitted {
                    thanks
                } else {
                    form
                }
            }
            .navigationTitle(target.isContent ? "Report content" : "Report account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(submitted ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What's wrong?")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                VStack(spacing: 8) {
                    ForEach(ReportReason.allCases) { option in
                        reasonRow(option)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("ANYTHING ELSE? (OPTIONAL)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Add context for the review team…",
                              text: $details, axis: .vertical)
                        .lineLimit(3...6)
                        .padding(12)
                        .background { GlassCard(cornerRadius: 12) { Color.clear } }
                        .foregroundStyle(Theme.textPrimary)
                }

                Toggle(isOn: $alsoBlock) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also block \(target.displayName)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Removes the friendship and stops all contact.")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .tint(Theme.accent)
                .padding(14)
                .background { GlassCard(cornerRadius: 14) { Color.clear } }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.accent)
                }

                submitButton

                supportFooter
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func reasonRow(_ option: ReportReason) -> some View {
        let isOn = reason == option
        return Button {
            reason = option
        } label: {
            HStack(spacing: 11) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isOn ? Theme.accent : Theme.textTertiary)
                Text(option.label)
                    .font(.subheadline.weight(isOn ? .semibold : .regular))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Theme.accentWash : Theme.sunken)
            }
        }
        .buttonStyle(.plain)
    }

    private var submitButton: some View {
        Button {
            Task { await submit() }
        } label: {
            HStack(spacing: 7) {
                if submitting {
                    ProgressView().tint(Theme.onAccent).scaleEffect(0.8)
                }
                Text("Submit report")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                Capsule().fill(reason == nil ? AnyShapeStyle(Theme.textTertiary)
                                             : AnyShapeStyle(Theme.accentGradient))
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(reason == nil || submitting)
    }

    private var supportFooter: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Reports go to our review team. We look at every one.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
            Button {
                if let url = SupportContact.mailtoURL { openURL(url) }
            } label: {
                Text("Need help now? Email \(SupportContact.email)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thanks: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
            Text("Thanks for telling us")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            Text(alsoBlock
                 ? "We'll review this. \(target.displayName) has been blocked."
                 : "We'll review this shortly.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button {
                if let url = SupportContact.mailtoURL { openURL(url) }
            } label: {
                Text(SupportContact.email)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submit() async {
        guard let reason, !submitting else { return }
        submitting = true
        errorMessage = nil
        defer { submitting = false }

        do {
            if target.isContent {
                try await FirestoreService.reportContent(id: target.contentId,
                                                         kind: target.kind.rawValue,
                                                         authorUid: target.uid,
                                                         reason: reason.rawValue,
                                                         details: details)
                if alsoBlock { try await blockTarget() }
            } else {
                // One call does both, so a dropped connection can't leave the
                // report filed but the block un-applied.
                try await FirestoreService.reportUser(target.uid,
                                                      reason: reason.rawValue,
                                                      details: details,
                                                      alsoBlock: alsoBlock)
                if alsoBlock {
                    await friendGraph.refresh(context: modelContext)
                    onBlocked?()
                }
            }
            submitted = true
        } catch let error as CallableFunctions.CallableError {
            errorMessage = error.message
        } catch {
            errorMessage = "Couldn't reach the server."
        }
    }

    private func blockTarget() async throws {
        let profile = RemoteProfile(uid: target.uid,
                                    handle: "",
                                    handleDisplay: "",
                                    name: target.displayName,
                                    avatarEmoji: "🙂",
                                    city: "",
                                    bio: "",
                                    isPrivate: false)
        try await friendGraph.block(profile, context: modelContext)
        onBlocked?()
    }
}

// MARK: - Blocked accounts list

/// The only place a block can be lifted. Once someone is blocked they're gone
/// from search, feeds and chat by design, so there's nowhere else to tap them.
struct BlockedAccountsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph

    @State private var loading = true
    @State private var working: String?

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                if loading {
                    ProgressView().tint(Theme.textSecondary)
                } else if friendGraph.blocked.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("Blocked accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await friendGraph.loadBlocked()
                loading = false
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 40))
                .foregroundStyle(Theme.textTertiary)
            Text("No blocked accounts")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("People you block stop being able to reach you, and disappear from your feeds.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 44)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(friendGraph.blocked) { profile in
                    HStack(spacing: 12) {
                        GlassOrbAvatar(emoji: profile.avatarEmoji, hue: 0.58, size: 44, isActive: false)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(profile.atHandle)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            Task { await unblock(profile) }
                        } label: {
                            if working == profile.uid {
                                ProgressView().tint(Theme.accent).scaleEffect(0.7)
                            } else {
                                Text("Unblock")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(PressScaleStyle())
                        .disabled(working != nil)
                    }
                    .padding(13)
                    .background { GlassCard(cornerRadius: 16) { Color.clear } }
                }

                Text("Unblocking restores visibility. It doesn't make you friends again.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
    }

    private func unblock(_ profile: RemoteProfile) async {
        working = profile.uid
        defer { working = nil }
        try? await friendGraph.unblock(profile, context: modelContext)
    }
}
