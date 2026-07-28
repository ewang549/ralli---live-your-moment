import SwiftUI
import SwiftData
import FirebaseAuth
import StreamChat
import StreamChatSwiftUI
import os

private let settingsLog = Logger(subsystem: "com.ej.explog", category: "settings")

// MARK: - Settings
//
// Account administration, as opposed to self-presentation: how you're reached,
// who you've blocked, ending the session, and ending the account. Anything
// other people see when they look at you lives in Edit Profile instead.

struct SettingsView: View {
    @Bindable var me: Friend

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var friends: [Friend]

    @State private var showBlockedAccounts = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        contactSection
                        notificationsSection
                        accountSection
                        dangerSection
#if DEBUG
                        developerSection
#endif
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .font(.subheadline.weight(.semibold))
                }
            }
        }
        .onDisappear { try? modelContext.save() }
        .sheet(isPresented: $showBlockedAccounts) {
            BlockedAccountsView()
        }
        .confirmationDialog("Delete your account?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes your profile, your logs and their photos and videos, your friends, and your messages. It can't be undone.")
        }
#if DEBUG
        // CLI screenshot/verification hooks, same family as EXPLOG_AUTO_OPEN
        // elsewhere. They live here now because the controls they drive do.
        //   SIMCTL_CHILD_EXPLOG_AUTO_ACCOUNT=section|blocked|delete
        //   SIMCTL_CHILD_EXPLOG_AUTO_LOGOUT=1
        .task {
            if ProcessInfo.processInfo.environment["EXPLOG_AUTO_LOGOUT"] == "1" {
                try? await Task.sleep(for: .seconds(3))
                logOut()
                return
            }
            guard let hook = ProcessInfo.processInfo.environment["EXPLOG_AUTO_ACCOUNT"] else { return }
            try? await Task.sleep(for: .seconds(1.2))
            switch hook {
            case "blocked": showBlockedAccounts = true
            case "delete": confirmingDelete = true
            default: break
            }
        }
#endif
    }

    // MARK: Sections

    /// How you're reached. Editable because these are ours to store — the
    /// signed-in identity below is the server's and is shown read-only.
    private var contactSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("CONTACT")
            ProfileFieldRow(label: "Email", text: $me.email, keyboard: .emailAddress)
            ProfileFieldRow(label: "Phone", text: $me.phone, keyboard: .phonePad)
        }
    }

    /// One switch per thing the backend sends.
    ///
    /// The switch is only half the mechanism: the server checks the copy on
    /// `users/{uid}` before every send, because a preference held only on this
    /// device could never stop a push that is decided in a Cloud Function. Each
    /// change writes the whole map straight away — there are seven switches and
    /// nobody flips them in bulk, so there is nothing to debounce.
    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("NOTIFICATIONS")

            VStack(spacing: 0) {
                ForEach(Array(NotificationCategory.allCases.enumerated()), id: \.element.id) { index, category in
                    Toggle(isOn: binding(for: category)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.title)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(category.detail)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(.vertical, 10)
                    // Otherwise the switch announces as its title *and* its
                    // explanation run together, which is a mouthful to listen
                    // to and impossible to address by name.
                    .accessibilityLabel(category.title)
                    .accessibilityHint(category.detail)

                    if index < NotificationCategory.allCases.count - 1 {
                        Divider().overlay(Theme.textTertiary.opacity(0.3))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background { GlassCard(cornerRadius: 12) { Color.clear } }

            Text("Turning one off stops that kind of notification everywhere, on every device you're signed in on.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
        }
    }

    private func binding(for category: NotificationCategory) -> Binding<Bool> {
        Binding(
            get: { me.wantsNotification(category) },
            set: { enabled in
                me.setNotification(category, enabled: enabled)
                try? modelContext.save()
                syncNotificationPrefs()
            }
        )
    }

    /// Mirrors the switches onto the profile doc the Cloud Functions read.
    ///
    /// Best-effort, like every other profile edit: the switch has already moved
    /// and the local row is already saved, so a failed write leaves the setting
    /// visibly on this device and retried by the next change. The server keeps
    /// treating anything it can't read as "on".
    private func syncNotificationPrefs() {
        let payload = me.notificationPrefsPayload
        Task {
            do {
                try await FirestoreService.updateSoftFields(["notificationPrefs": payload])
            } catch {
                // Still best-effort — the switch has moved and the local row is
                // saved, and the next change retries. But a swallowed failure
                // here is indistinguishable from a working one, and the symptom
                // ("I turned it off and still get them") points at the server's
                // gating rather than at a write that never landed. Logging it
                // is what makes that difference visible.
                settingsLog.error("notificationPrefs sync failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("ACCOUNT")

            if let firebaseUser = Auth.auth().currentUser {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Signed in as")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        Text(firebaseUser.email ?? firebaseUser.uid)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button(role: .destructive) { logOut() } label: {
                        Text("Log out").font(.subheadline.weight(.semibold))
                    }
                }
                .padding(14)
                .background { GlassCard(cornerRadius: 12) { Color.clear } }
            }

            // Unblocking is only reachable here — a blocked account is by
            // design absent from search, feeds and chat.
            Button { showBlockedAccounts = true } label: {
                HStack {
                    Label("Blocked accounts", systemImage: "hand.raised")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
                .background { GlassCard(cornerRadius: 12) { Color.clear } }
            }
            .buttonStyle(.plain)
        }
        .id("account")
    }

    /// Delete account (App Store Guideline 5.1.1(v)) — styled as the
    /// destructive thing it is rather than hidden behind a support email.
    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                HStack {
                    if deleting {
                        ProgressView().tint(Theme.accent).scaleEffect(0.8)
                        Text("Deleting…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Label("Delete account", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                }
                .padding(14)
                .background { GlassCard(cornerRadius: 12) { Color.clear } }
            }
            .buttonStyle(.plain)
            .disabled(deleting)

            if let deleteError {
                Text(deleteError)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(Theme.textSecondary)
    }

    // MARK: Actions

    /// Tear down the Stream session fully, then sign out of Firebase — the auth
    /// gate flips back to the Welcome screen.
    private func logOut() {
        Task { @MainActor in
            let chatClient = InjectedValues[\.chatClient]
            if chatClient.currentUserId != nil {
                await chatClient.logout()
            }
            try? Auth.auth().signOut()
            // Cached channel membership is per-user; the next account to sign
            // in on this launch must re-join rather than inherit it. Cached
            // clip files are this user's friends' media and go with them.
            StreamTokenProvider.resetJoinedChannels()
            VideoCache.shared.clear()
        }
    }

    /// Deletes everything server-side, then follows the exact logout path.
    ///
    /// The ordering matters and is the same one the logout invariant depends
    /// on: sign out and let the auth gate swap to Welcome — which unmounts
    /// every data-bound view, this one included — and leave the local store
    /// alone. The next `LocalStore.claim` clears it. Wiping models here would
    /// fault this very view's `@Bindable me` while it's still on screen, which
    /// is the "backing data detached from context" crash.
    private func deleteAccount() {
        guard !deleting else { return }
        deleting = true
        deleteError = nil
        Task { @MainActor in
            do {
                try await FirestoreService.deleteAccount()
            } catch let error as CallableFunctions.CallableError {
                deleteError = error.message
                deleting = false
                return
            } catch {
                deleteError = "Couldn't delete your account. Check your connection and try again."
                deleting = false
                return
            }

            let chatClient = InjectedValues[\.chatClient]
            if chatClient.currentUserId != nil {
                await chatClient.logout()
            }
            try? Auth.auth().signOut()
            // Cached channel membership is per-user; the next account to sign
            // in on this launch must re-join rather than inherit it. Cached
            // clip files are this user's friends' media and go with them.
            StreamTokenProvider.resetJoinedChannels()
            VideoCache.shared.clear()
        }
    }

#if DEBUG
    /// Dev-only controls. Demo content no longer loads automatically for a
    /// signed-in account (that's what leaked fake friends into real accounts),
    /// so loading and clearing it is an explicit action.
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("DEVELOPER")

            HStack(spacing: 10) {
                Button {
                    SeedData.seed(context: modelContext)
                } label: {
                    Label(demoLoaded ? "Demo data loaded" : "Load demo data",
                          systemImage: demoLoaded ? "checkmark.circle.fill" : "wand.and.stars")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(demoLoaded ? Theme.accent : Theme.textPrimary)
                }
                .disabled(demoLoaded)

                Spacer()

                Button(role: .destructive) {
                    SeedData.purgeDemoData(context: modelContext)
                } label: {
                    Text("Clear demo").font(.caption.weight(.semibold))
                }
                .disabled(!demoLoaded)
            }
            .padding(14)
            .background { GlassCard(cornerRadius: 12) { Color.clear } }
        }
    }

    private var demoLoaded: Bool { friends.contains { $0.isDemo } }
#endif
}
