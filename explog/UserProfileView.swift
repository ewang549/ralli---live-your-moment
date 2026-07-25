import SwiftUI
import SwiftData
import FirebaseAuth
import StreamChat
import StreamChatSwiftUI

// MARK: - Tab 1: User profile & privacy settings

struct UserProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var friends: [Friend]

    private let interestOptions = ["surf", "climb", "hike", "food", "music", "photo", "code", "games"]

    private var me: Friend? { friends.first { $0.isMe } }

    @State private var isRecovering = false
    @State private var recoveryError: String?
    @State private var showBlockedAccounts = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deleteError: String?
    /// Debounces pushing edited profile fields to Firestore — the fields are
    /// bound straight to SwiftData, so they change on every keystroke.
    @State private var profileSyncTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            GlassBackground()
            content
        }
#if DEBUG
        // CLI verification hook: SIMCTL_CHILD_EXPLOG_AUTO_LOGOUT=1 taps Log out
        // after the profile settles, so the "logout doesn't crash" invariant is
        // checkable from the command line.
        //
        // Pair it with EXPLOG_AUTO_AUTH only to exercise the sign-out → wipe →
        // sign-in cycle: WelcomeView's own hook logs straight back in, so the
        // app lands back on Profile rather than Welcome. To *see* the signed-out
        // state, run this hook with no EXPLOG_AUTO_AUTH and rely on the session
        // Firebase already persisted.
        .task {
            guard ProcessInfo.processInfo.environment["EXPLOG_AUTO_LOGOUT"] == "1" else { return }
            try? await Task.sleep(for: .seconds(3))
            logOut()
        }
#endif
    }

    @ViewBuilder
    private var content: some View {
        if let me {
            profileForm(for: me)
        } else {
            // No local "me" row. Normally AuthGateView caches it from Firestore
            // on launch; if that hasn't happened (offline, or the cache was
            // wiped mid-session) show a real state with a way out instead of a
            // spinner that never resolves.
            missingProfileState
        }
    }

    private var missingProfileState: some View {
        VStack(spacing: 14) {
            Text("👤").font(.system(size: 52))
            Text("Profile not loaded")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(recoveryError ?? "Your profile lives on the server and hasn't been cached on this device yet.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                reloadProfile()
            } label: {
                if isRecovering {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    Text("Reload profile").font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.accent))
            .disabled(isRecovering)

#if DEBUG
            demoDataButton
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Pulls the profile from Firestore and rebuilds the local `isMe` row.
    private func reloadProfile() {
        isRecovering = true
        recoveryError = nil
        Task { @MainActor in
            do {
                if let profile = try await FirestoreService.currentProfile() {
                    FirestoreService.cacheLocally(profile, context: modelContext)
                } else {
                    recoveryError = "No profile found for this account."
                }
            } catch {
                recoveryError = error.localizedDescription
            }
            isRecovering = false
        }
    }

#if DEBUG
    /// Dev-only: demo content is gated off real accounts, so this is how you
    /// get the fake roster back while signed in.
    private var demoDataButton: some View {
        Button {
            SeedData.seed(context: modelContext)
        } label: {
            Label("Load demo data", systemImage: "wand.and.stars")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 6)
    }
#endif

    private func profileForm(for me: Friend) -> some View {
        @Bindable var profile = me
        return ScrollViewReader { scrollProxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Profile")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    RalliWordmark(size: 22)
                }
                .padding(.top, 12)

                // Profile picture — one large, centred photo. Ralli uses real
                // photos only now, so there's no emoji picker beside it; the
                // emoji orb survives purely as the fallback fill inside
                // `GlassOrbAvatar` when no photo has been chosen yet.
                AvatarPhotoButton(onPicked: { fileName in
                    profile.avatarPhotoFileName = fileName
                    try? modelContext.save()
                    uploadAvatar(fileName: fileName)
                }) {
                    ZStack(alignment: .bottomTrailing) {
                        GlassOrbAvatar(friend: me, size: 112, isActive: true)
                        AvatarPhotoBadge().offset(x: 2, y: 2)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .accessibilityLabel("Change profile photo")

                // NEW: Public/Private privacy toggle — gates all community features.
                VStack(alignment: .leading, spacing: 6) {
                    Toggle(isOn: Binding(get: { !me.isPrivate },
                                         set: { profile.isPrivate = !$0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(me.isPrivate ? "Private profile" : "Public profile")
                                .font(.headline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(me.isPrivate
                                 ? "Hidden from community feeds. Public activities are locked."
                                 : "Visible in community feeds. You can host and join public activities.")
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .tint(Theme.accent)
                }
                .padding(14)
                .background {
                    GlassCard(cornerRadius: 16) { Color.clear }
                        // Public profiles carry an coral edge — the setting is
                        // legible without reading the label.
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(me.isPrivate ? Color.clear : Theme.accent.opacity(0.5),
                                              lineWidth: 1)
                        }
                }

                // Primary metadata fields.
                VStack(spacing: 10) {
                    field("Full name", text: $profile.name)
                    field("Email", text: $profile.email, keyboard: .emailAddress)
                    field("Phone", text: $profile.phone, keyboard: .phonePad)
                    field("City", text: $profile.city)
                    HStack {
                        Text("Age")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Stepper("\(me.age)", value: $profile.age, in: 13...120)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background { GlassCard(cornerRadius: 12) { Color.clear } }
                }

                // Bio.
                VStack(alignment: .leading, spacing: 6) {
                    Text("BIO")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Say something about yourself…", text: $profile.bio, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12)
                        .background { GlassCard(cornerRadius: 12) { Color.clear } }
                        .foregroundStyle(Theme.textPrimary)
                }

                // Interest tags (multi-select chips).
                VStack(alignment: .leading, spacing: 8) {
                    Text("INTERESTS")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                    FlowChips(options: interestOptions, selection: $profile.interests)
                }

                // Account: signed-in Firebase identity, safety, log out, delete.
                if let firebaseUser = Auth.auth().currentUser {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ACCOUNT")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.textSecondary)
                        HStack {
                            Text(firebaseUser.email ?? firebaseUser.uid)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Button(role: .destructive) {
                                logOut()
                            } label: {
                                Text("Log out")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                        .padding(14)
                        .background { GlassCard(cornerRadius: 12) { Color.clear } }

                        // Unblocking is only reachable here — a blocked account
                        // is by design absent from search, feeds and chat.
                        Button {
                            showBlockedAccounts = true
                        } label: {
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

                        deleteAccountRow
                    }
                    .padding(.top, 6)
                    .id("account")
                }

#if DEBUG
                developerSection
#endif
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: me.isPrivate) {
            try? modelContext.save()
            scheduleProfileSync(me)
        }
        .onChange(of: me.name) { scheduleProfileSync(me) }
        .onChange(of: me.city) { scheduleProfileSync(me) }
        .onChange(of: me.bio) { scheduleProfileSync(me) }
        .sheet(isPresented: $showBlockedAccounts) {
            BlockedAccountsView()
        }
#if DEBUG
        // CLI screenshot hooks, same family as EXPLOG_AUTO_OPEN elsewhere:
        // the account controls live below the fold, so a screenshot script has
        // no other way to reach them.
        //   SIMCTL_CHILD_EXPLOG_AUTO_ACCOUNT=section|blocked|delete
        .task {
            guard let hook = ProcessInfo.processInfo.environment["EXPLOG_AUTO_ACCOUNT"] else { return }
            try? await Task.sleep(for: .seconds(1.2))
            withAnimation { scrollProxy.scrollTo("account", anchor: .bottom) }
            try? await Task.sleep(for: .seconds(0.8))
            switch hook {
            case "blocked": showBlockedAccounts = true
            case "delete": confirmingDelete = true
            default: break
            }
        }
#endif
        .confirmationDialog("Delete your account?",
                            isPresented: $confirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete everything", role: .destructive) { deleteAccount() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes your profile, your logs and their photos and videos, your friends, and your messages. It can't be undone.")
        }
        }
    }

#if DEBUG
    /// Dev-only controls. Demo content no longer loads automatically for a
    /// signed-in account (that's what leaked fake friends into real accounts),
    /// so loading and clearing it is now an explicit action.
    private var developerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Developer")
                .font(.caption.weight(.bold))
                .foregroundStyle(Theme.textSecondary)

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
                    clearDemoData()
                } label: {
                    Text("Clear demo").font(.caption.weight(.semibold))
                }
                .disabled(!demoLoaded)
            }
            .padding(14)
            .background { GlassCard(cornerRadius: 12) { Color.clear } }
        }
        .padding(.top, 6)
    }

    private var demoLoaded: Bool { friends.contains { $0.isDemo } }

    /// Removes only the seeded rows, leaving the real account intact. Chats and
    /// clips go too, since every one of them references a demo friend.
    private func clearDemoData() {
        for friend in friends where friend.isDemo {
            modelContext.delete(friend)
        }
        let chats = (try? modelContext.fetch(FetchDescriptor<Chat>())) ?? []
        for chat in chats where chat.members.isEmpty || chat.members.allSatisfy({ $0.isMe }) {
            modelContext.delete(chat)
        }
        try? modelContext.save()
    }
#endif

    /// Tear down the Stream session fully, then sign out of Firebase —
    /// the auth gate flips back to the Welcome screen.
    private func logOut() {
        Task { @MainActor in
            let chatClient = InjectedValues[\.chatClient]
            if chatClient.currentUserId != nil {
                await chatClient.logout()
            }
            try? Auth.auth().signOut()
        }
    }

    // MARK: Delete account (App Store Guideline 5.1.1(v))

    /// Sits below Log out, styled as the destructive thing it is rather than
    /// hidden behind a support email.
    private var deleteAccountRow: some View {
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
        }
    }

    /// Pushes a newly picked profile photo to Storage and records its URL on the
    /// profile. Best-effort, mirroring `LogSync.publish`: the photo is already on
    /// disk and already showing, so a failed upload must not undo the pick.
    private func uploadAvatar(fileName: String) {
        let localURL = URL.documentsDirectory.appending(path: fileName)
        Task { try? await FirestoreService.uploadAvatarPhoto(at: localURL) }
    }

    /// Mirrors edited profile fields to Firestore so search and other people's
    /// views of this account stay in step with what's on screen here. Debounced
    /// because the fields write to SwiftData on every keystroke.
    private func scheduleProfileSync(_ me: Friend) {
        let fields: [String: Any] = [
            "name": me.name,
            "city": me.city,
            "bio": me.bio,
            "isPrivate": me.isPrivate,
        ]
        profileSyncTask?.cancel()
        profileSyncTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            try? await FirestoreService.updateSoftFields(fields)
        }
    }

    private func field(_ label: String, text: Binding<String>,
                       keyboard: UIKeyboardType = .default) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 90, alignment: .leading)
            TextField(label, text: text)
                .keyboardType(keyboard)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background { GlassCard(cornerRadius: 12) { Color.clear } }
    }
}

/// Simple wrapping chip selector for interest tags.
struct FlowChips: View {
    let options: [String]
    @Binding var selection: [String]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 82), spacing: 8)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(options, id: \.self) { tag in
                let isOn = selection.contains(tag)
                Button {
                    if isOn {
                        selection.removeAll { $0 == tag }
                    } else {
                        selection.append(tag)
                    }
                } label: {
                    Text(tag)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isOn ? Theme.onAccent : Theme.textSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            Capsule()
                                .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.sunken))
                        }
                }
            }
        }
    }
}

// MARK: - Public profile sheet (attendee cards, search results, avatars)

/// One profile sheet for every entry point.
///
/// Opens from a local `Friend` (attendee cards, Pulse rows) or from a bare uid
/// (search results, suggestions). When the account is a real one it loads the
/// server's view — handle, city, bio, mutual count, and the relationship — and
/// offers the matching action: Add / Requested / Accept / Message / Unblock,
/// with Report and Block always one tap away in the overflow.
///
/// Demo rows have no `remoteUID`, so they render exactly as they always did
/// from local data with no network call and no actions.
struct PublicProfileSheet: View {
    /// Local row, when there is one. Supplies interests and the avatar hue,
    /// neither of which the public projection carries.
    private let friend: Friend?
    private let uid: String
    private let fallbackName: String
    private let fallbackEmoji: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FriendGraph.self) private var friendGraph
    @Environment(FollowGraph.self) private var followGraph
    @Environment(AppRouter.self) private var router
    @Query private var friends: [Friend]
    @Query(sort: \SpotClip.capturedAt, order: .reverse) private var allSpotClips: [SpotClip]

    @State private var remote: RemoteProfile?
    @State private var status: FriendshipStatus = .none
    @State private var mutuals = 0
    @State private var isFollowing = false
    @State private var followerCount = 0
    @State private var followWorking = false
    @State private var loading = false
    @State private var working = false
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var openChat: Chat?
    @State private var safety = SafetyPresentation()

    init(friend: Friend) {
        self.friend = friend
        self.uid = friend.remoteUID
        self.fallbackName = friend.name
        self.fallbackEmoji = friend.emoji
    }

    /// Entry point for search results and suggestions, where all we have is an
    /// account id and whatever the row was already showing.
    init(uid: String, name: String, emoji: String = "🙂") {
        self.friend = nil
        self.uid = uid
        self.fallbackName = name
        self.fallbackEmoji = emoji
    }

    private var isRemote: Bool { !uid.isEmpty }
    private var displayName: String { remote?.name ?? fallbackName }

    /// This account's profile photo as held on the server. Empty-string URLs
    /// come back from profiles that never set one.
    private var remoteAvatarURL: URL? {
        guard let raw = remote?.avatarURL, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }
    private var isPrivate: Bool { remote?.isPrivate ?? friend?.isPrivate ?? false }
    /// A private account shows nothing beyond its name until you're friends.
    private var detailsHidden: Bool { isPrivate && status != .friends }

    /// This person's place clips — casual video/photo posts, not a follower-style
    /// grid. Matched by name, the same signal Places itself uses to tell a
    /// friend's clip from a stranger's (`SpotClip` carries a plain author name
    /// rather than a `Friend` relationship).
    private var highlights: [SpotClip] {
        allSpotClips.filter { clip in
            // A clip that carries a real author is matched on it and nothing
            // else, so two accounts sharing a display name can't inherit each
            // other's highlights. Name matching is the fallback for seed and
            // legacy clips, which have no account behind them at all.
            if !clip.authorUID.isEmpty { return clip.authorUID == uid }
            return clip.authorName.caseInsensitiveCompare(displayName) == .orderedSame
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()
                ScrollView {
                    VStack(spacing: 13) {
                        header
                        if let loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 30)
                                .multilineTextAlignment(.center)
                        } else if detailsHidden {
                            privateNotice
                        } else {
                            details
                        }
                        if isRemote { actionRow }
                        if !detailsHidden && !highlights.isEmpty { highlightsSection }
                        Spacer(minLength: 20)
                    }
                    .padding(.top, 22)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Prominent, always-present way out — this is a full-screen
                // cover, not a sheet, so there's no swipe-down to fall back on.
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(Theme.sunken))
                    }
                    .accessibilityLabel("Close")
                }
                if isRemote {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            SafetyMenuItems(
                                target: .user(uid: uid, name: displayName),
                                presentation: safety
                            )
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel("More options")
                    }
                }
            }
        }
        .task { await load() }
        .sheet(item: Binding(get: { safety.reporting }, set: { safety.reporting = $0 })) { target in
            ReportSheet(target: target) { dismiss() }
        }
        .confirmationDialog(
            "Block \(displayName)?",
            isPresented: Binding(get: { safety.blocking != nil },
                                 set: { if !$0 { safety.blocking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Block", role: .destructive) { Task { await blockThem() } }
            Button("Cancel", role: .cancel) { safety.blocking = nil }
        } message: {
            Text("They won't be able to message you or see your logs, and you won't see theirs. Your friendship and any pending requests are removed.")
        }
        .fullScreenCover(item: $openChat) { chat in
            NavigationStack {
                ChatDetailView(chat: chat) { openChat = nil }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            // A local row's own photo wins; otherwise fall back to whatever the
            // server holds for this account, and to the emoji orb if it holds
            // nothing.
            if let friend, friend.avatarPhotoURL != nil {
                AvatarView(friend: friend, size: 84)
            } else {
                GlassOrbAvatar(emoji: remote?.avatarEmoji ?? friend?.emoji ?? fallbackEmoji,
                               hue: friend?.hue ?? 0.58, size: 84, isActive: false,
                               remotePhotoURL: remoteAvatarURL)
            }
            Text(displayName)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
            if let remote, !remote.handle.isEmpty {
                Text(remote.atHandle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
            }
            // Followers — the one count this profile carries, and only for a
            // real account. It's what the Follow button below acts on, so
            // hiding it would leave that button with nothing to move.
            if isRemote {
                Text("\(followerCount) follower\(followerCount == 1 ? "" : "s")")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            if loading {
                ProgressView().tint(Theme.textSecondary).scaleEffect(0.7)
            }
        }
    }

    private var privateNotice: some View {
        VStack(spacing: 6) {
            Label("Private profile", systemImage: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            Text("This member keeps their details hidden.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    @ViewBuilder
    private var details: some View {
        let city = remote?.city ?? friend?.city ?? ""
        let bio = remote?.bio ?? friend?.bio ?? ""
        let age = friend?.age ?? 0

        if !city.isEmpty {
            Label("\(city)\(age > 0 ? " · \(age)" : "")", systemImage: "mappin.and.ellipse")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }

        // Mutuals are the strongest "do I know this person?" signal, so they sit
        // above the bio rather than buried under it.
        if mutuals > 0 {
            Label("\(mutuals) mutual friend\(mutuals == 1 ? "" : "s")",
                  systemImage: "person.2.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background { Capsule().fill(Theme.accentWash) }
        }

        if !bio.isEmpty {
            Text(bio)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
        }

        if let friend, !friend.interests.isEmpty {
            HStack(spacing: 6) {
                ForEach(friend.interests, id: \.self) { tag in
                    Text(tag)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background { Capsule().fill(Theme.sunken) }
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// A quiet grid of this person's place clips — no like counts or captions
    /// up front, just what they've been up to. Tapping one hands the whole
    /// screen over to Places, focused on that exact clip.
    private var highlightsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Highlights")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                      spacing: 10) {
                ForEach(highlights) { clip in
                    Button { openHighlight(clip) } label: {
                        HighlightThumbnail(clip: clip)
                    }
                    .buttonStyle(PressScaleStyle())
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    /// Tears this profile down, switches the active tab to Places, and hands
    /// it the clip to scroll to and autoplay.
    private func openHighlight(_ clip: SpotClip) {
        router.tab = .places
        router.focusedPlaceClipId = clip.id
        dismiss()
    }

    /// The context action. One primary control per state, matching what the
    /// server says the relationship is rather than what the caller assumed.
    @ViewBuilder
    private var actionRow: some View {
        VStack(spacing: 8) {
            // Follow sits above the friendship action: it's the lighter of the
            // two commitments and the one that's always available, whatever
            // the friendship state happens to be.
            followButton

            switch status {
            case .none:
                primaryButton("Add friend", icon: "plus") {
                    try await friendGraph.send(to: profileForActions, context: modelContext)
                }
            case .incoming:
                primaryButton("Accept request", icon: "checkmark") {
                    try await friendGraph.accept(profileForActions, context: modelContext)
                    return .friends
                }
            case .requested:
                settledPill("Requested", icon: "clock")
            case .friends:
                messageButton
                settledPill("Friends", icon: "checkmark.circle.fill")
            case .blocked:
                primaryButton("Unblock", icon: "hand.raised.slash") {
                    try await friendGraph.unblock(profileForActions, context: modelContext)
                    return FriendshipStatus.none
                }
            }

            if let actionError {
                Text(actionError)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 6)
        .padding(.horizontal, 30)
    }

    /// Follow / Following — outlined while the offer is open, filling in once
    /// taken, the same way Beacons' "Going" confirms.
    ///
    /// Deliberately the inverse of `primaryButton`'s grammar: Follow stacks
    /// directly above "Add friend", and only one coral fill may sit in that
    /// stack by default. Add friend keeps it — it's the more consequential
    /// action, since a mutual friendship is what unlocks messaging.
    private var followButton: some View {
        Button(action: toggleFollow) {
            HStack(spacing: 6) {
                Image(systemName: isFollowing ? "checkmark" : "plus")
                    .font(.system(size: 13, weight: .bold))
                Text(isFollowing ? "Following" : "Follow")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(isFollowing ? Theme.onAccent : Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background {
                if isFollowing {
                    Capsule().fill(Theme.accentGradient)
                } else {
                    Capsule().fill(Theme.accentWash)
                        .overlay { Capsule().strokeBorder(Theme.accent, lineWidth: 1.5) }
                }
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(followWorking)
        .accessibilityLabel(isFollowing ? "Following \(displayName)" : "Follow \(displayName)")
    }

    /// Flips the button and the count on the spot, then reconciles with the
    /// server — and puts both back exactly as they were if the call fails.
    private func toggleFollow() {
        guard isRemote, !followWorking else { return }
        let wasFollowing = isFollowing
        let previousCount = followerCount
        let profile = profileForActions

        withAnimation(.easeOut(duration: 0.18)) {
            isFollowing = !wasFollowing
            followerCount = max(0, previousCount + (wasFollowing ? -1 : 1))
        }
        followWorking = true
        actionError = nil

        Task {
            defer { followWorking = false }
            do {
                let result = wasFollowing ? try await followGraph.unfollow(profile)
                                          : try await followGraph.follow(profile)
                withAnimation(.easeOut(duration: 0.18)) {
                    isFollowing = result.following
                    followerCount = result.followerCount
                }
            } catch {
                withAnimation(.easeOut(duration: 0.18)) {
                    isFollowing = wasFollowing
                    followerCount = previousCount
                }
                if let callable = error as? CallableFunctions.CallableError {
                    actionError = callable.message
                } else {
                    actionError = "Couldn't reach the server."
                }
            }
        }
    }

    private var messageButton: some View {
        Button {
            openChat = chatWithThem()
        } label: {
            Label("Message", systemImage: "bubble.left.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background { Capsule().fill(Theme.accentGradient) }
        }
        .buttonStyle(PressScaleStyle())
    }

    private func primaryButton(_ title: String,
                               icon: String,
                               action: @escaping () async throws -> FriendshipStatus) -> some View {
        Button {
            Task { await perform(action) }
        } label: {
            HStack(spacing: 6) {
                if working {
                    ProgressView().tint(Theme.onAccent).scaleEffect(0.75)
                } else {
                    Image(systemName: icon).font(.system(size: 13, weight: .bold))
                }
                Text(title).font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background { Capsule().fill(Theme.accentGradient) }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(working)
    }

    private func settledPill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background { Capsule().fill(Theme.accentWash) }
    }

    // MARK: Data

    /// The profile the graph actions operate on. Prefers the server's copy and
    /// falls back to what the row already had, so an action still works if the
    /// profile load failed.
    private var profileForActions: RemoteProfile {
        remote ?? RemoteProfile(uid: uid,
                                handle: "",
                                handleDisplay: "",
                                name: fallbackName,
                                avatarEmoji: fallbackEmoji,
                                city: "",
                                bio: "",
                                isPrivate: false)
    }

    private func load() async {
        guard isRemote, remote == nil else { return }
        loading = true
        defer { loading = false }
        // Seed from what the graph already knows so the button doesn't flash
        // "Follow" for someone this user is plainly already following.
        isFollowing = followGraph.isFollowing(uid)
        do {
            let loaded = try await FirestoreService.publicProfile(uid: uid)
            remote = loaded.profile
            status = loaded.friendship
            mutuals = loaded.mutualCount
            isFollowing = loaded.isFollowing
            followerCount = loaded.profile.followers
        } catch let error as CallableFunctions.CallableError {
            loadError = error.message
        } catch {
            loadError = "Couldn't load this profile."
        }
    }

    private func perform(_ work: @escaping () async throws -> FriendshipStatus) async {
        guard !working else { return }
        working = true
        actionError = nil
        defer { working = false }
        do {
            let resolved = try await work()
            withAnimation(.easeOut(duration: 0.18)) { status = resolved }
        } catch let error as CallableFunctions.CallableError {
            actionError = error.message
        } catch {
            actionError = "Couldn't reach the server."
        }
    }

    private func blockThem() async {
        safety.blocking = nil
        working = true
        defer { working = false }
        try? await friendGraph.block(profileForActions, context: modelContext)
        dismiss()
    }

    /// The DM with this account, creating one if this is the first message.
    private func chatWithThem() -> Chat? {
        guard let them = friend ?? friends.first(where: { $0.remoteUID == uid }),
              let me = friends.first(where: { $0.isMe }) else { return nil }
        return Chat.dm(with: them, me: me, in: modelContext)
    }
}

/// One rounded card in a profile's Highlights grid — the clip's own gradient
/// and emoji, plus a caption clipped to a single line. No like/view counts;
/// this is a scrapbook, not a leaderboard.
private struct HighlightThumbnail: View {
    let clip: SpotClip

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Theme.clipGradient(hueA: clip.hueA, hueB: clip.hueB)
            Text(clip.emoji)
                .font(.system(size: 30))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            if !clip.label.isEmpty {
                Text(clip.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        LinearGradient(colors: [.black.opacity(0.55), .clear],
                                       startPoint: .bottom, endPoint: .top)
                    }
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
