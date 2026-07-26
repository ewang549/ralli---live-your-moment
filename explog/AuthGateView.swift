import SwiftUI
import SwiftData
import FirebaseAuth
import StreamChat
import StreamChatSwiftUI

// MARK: - Gate: Welcome screen until a Firebase user exists, then the app.

struct AuthGateView: View {
    /// Signed in is no longer enough to enter the app — a real account also
    /// needs a directory profile (`users/{uid}`), so the gate has three states.
    private enum Stage: Equatable {
        case signedOut
        case checkingProfile
        case needsProfile
        case ready
    }

    /// Start in `.checkingProfile`, never `.signedOut`: auth resolves
    /// asynchronously, so we don't know yet. Guessing here is what let demo
    /// data reach a real account.
    @State private var stage: Stage = .checkingProfile
    @State private var session = AuthSession()
    /// Last uid we saw, so a sign-out knows whose push token to remove.
    @State private var signedInUID: String?
    /// Read once at init, not on every render: the flag flips as the screen
    /// dismisses, and re-reading would tear it down mid-animation.
    @State private var showProWelcome = ProWelcome.shouldShowAtLaunch
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            gate
            // Sits over the gate rather than in front of it in the switch, so
            // auth still resolves underneath while this is up — dismissing lands
            // on a sign-in screen that's already settled.
            if showProWelcome {
                ProWelcomeView {
                    ProWelcome.hasSeen = true
                    withAnimation(.easeOut(duration: 0.3)) { showProWelcome = false }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    private var gate: some View {
        Group {
            switch stage {
            case .signedOut:
                WelcomeView()
            case .checkingProfile:
                loadingScreen
            case .needsProfile:
                ProfileSetupView { _ in
                    withAnimation { stage = .ready }
                }
            case .ready:
                MainTabView()
            }
        }
        .environment(session)
        .onAppear {
#if DEBUG
            // CLI hook: SIMCTL_CHILD_EXPLOG_RESET_CACHE=1 forces the next claim
            // to treat the local store as another account's and wipe it.
            if ProcessInfo.processInfo.environment["EXPLOG_RESET_CACHE"] == "1" {
                LocalStore.ownerUID = nil
            }
#endif
            session.onChange = { uid in
                // Move the push token with the account. Captured before the
                // branch below because a sign-out has to delete the token from
                // the account we're *leaving* — by the time this fires,
                // `Auth.currentUser` is already nil.
                let previous = signedInUID
                signedInUID = uid
                if previous != uid, let previous {
                    Task { await PushNotifications.shared.clearToken(for: previous) }
                }

                // Swap the UI OFF the previous account's data views *before*
                // wiping their models. If we wipe first, a still-mounted view
                // that holds a live reference to a now-deleted object — e.g.
                // Profile's `@Bindable me` and its `$interests` binding — faults
                // on access and crashes ("backing data detached from context").
                guard let uid else {
                    // Sign-out: flip to Welcome and touch nothing else.
                    //
                    // Wiping here is what used to make logout crash. Deferring
                    // the wipe by a runloop only *usually* outran SwiftUI's
                    // teardown, so the crash came back whenever anything else
                    // was busy on the main actor. The cache is instead cleared
                    // by the next `claim` (below), which runs while the gate is
                    // showing its loading screen and no data-bound view exists
                    // — an ordering that holds by construction rather than by
                    // timing. Nothing renders cached rows while signed out, so
                    // leaving them on disk until then is not observable.
                    stage = .signedOut
                    return
                }

                stage = .checkingProfile

                // Data views are torn down (or never mounted, on a cold start):
                // scope the cache to the account, then resolve the profile.
                // Still deferred a runloop so the loading screen is up first.
                DispatchQueue.main.async {
                    LocalStore.claim(by: uid, context: modelContext)
                    Task { await resolveProfile() }
                    // A token minted while signed out has nowhere to live, so
                    // re-file it under the account that just signed in.
                    Task { await PushNotifications.shared.syncTokenForCurrentUser() }
                }
            }
            session.start()
        }
    }

    private var loadingScreen: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 18) {
                RalliWordmark(size: 40)
                ProgressView().tint(Theme.accent)
            }
        }
    }

    /// Decides between onboarding and the app. A lookup failure (offline) is
    /// treated as "needs profile" only when we're sure there is none — a
    /// network error keeps the user out of a destructive re-onboarding by
    /// retrying rather than assuming.
    @MainActor
    private func resolveProfile() async {
        for attempt in 0..<3 {
            do {
                let profile = try await FirestoreService.currentProfile()
                if let profile {
                    // Refresh the local cache on every launch, not just at
                    // sign-up. Without this the app has no `isMe` Friend row
                    // after a cache wipe, and every screen that resolves "me"
                    // (Profile, montage, capture) has nothing to show.
                    FirestoreService.cacheLocally(profile, context: modelContext)
                    // A real account has no business holding seeded friends.
                    // If this device ever ran a Debug build against it, they're
                    // still in the roster — photoless, un-messageable, and
                    // untouched by any other cleanup. Self-healing here rather
                    // than behind the Debug-only "Clear demo" button, which a
                    // TestFlight build can't reach at all.
                    SeedData.purgeDemoData(context: modelContext)
                    retryAvatarUploadIfNeeded(for: profile)
                }
                withAnimation { stage = profile == nil ? .needsProfile : .ready }
                return
            } catch {
                // Back off and retry; Firestore may still be warming up after
                // sign-in while the auth token propagates.
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        withAnimation { stage = .needsProfile }
    }

    /// Re-uploads a profile photo that exists on this device but never reached
    /// the account.
    ///
    /// The onboarding upload used to be a bare `try?`, so a single failure
    /// during the post-sign-up token race left the account with no `avatarURL`
    /// forever — the photo rendered locally and nowhere else, with nothing
    /// anywhere that would try again. That path retries now, but accounts
    /// already in that state need a way out, and this is it: the local file is
    /// the evidence a photo was picked, and an empty `avatarURL` the evidence
    /// it never landed.
    @MainActor
    private func retryAvatarUploadIfNeeded(for profile: RemoteProfile) {
        guard profile.avatarURL?.isEmpty ?? true else { return }
        let descriptor = FetchDescriptor<Friend>()
        guard let me = (try? modelContext.fetch(descriptor))?.first(where: { $0.remoteUID == profile.uid }),
              let fileName = me.avatarPhotoFileName else { return }
        let localURL = URL.documentsDirectory.appending(path: fileName)
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }

        Task {
            // Best-effort and out of the way: the app is already usable, and
            // the next launch tries again if this one doesn't land.
            try? await FirestoreService.uploadAvatarPhoto(at: localURL, attempts: 2)
        }
    }
}

// MARK: - Sign up / log in

struct WelcomeView: View {
    @Injected(\.chatClient) private var chatClient

    enum Mode: String, CaseIterable {
        case signUp = "Sign up"
        case logIn = "Log in"
    }

    @State private var mode: Mode = .signUp
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            RalliWordmark(size: 52)
            Text("Life, on the hour.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
                .padding(.bottom, 28)

            HStack(spacing: 8) {
                ForEach(Mode.allCases, id: \.self) { option in
                    FilterChip(title: option.rawValue, isActive: mode == option) {
                        withAnimation(.easeOut(duration: 0.18)) { mode = option }
                    }
                }
            }
            .padding(.bottom, 20)

            VStack(spacing: 12) {
                if mode == .signUp {
                    authField("Your name", text: $name)
                        .textContentType(.name)
                }
                authField("Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background { GlassCard(cornerRadius: 14) { Color.clear } }
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 28)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, 10)
                    .padding(.horizontal, 28)
            }

            PrimaryButton(title: mode == .signUp ? "Create account" : "Log in",
                       busy: busy, enabled: canSubmit, action: submit)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Onboarding has no content of its own, so a soft coral bloom behind the
        // warm canvas gives the hero some warmth without competing with the copy.
        .background {
            ZStack {
                Theme.appBackground
                RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                               center: .init(x: 0.5, y: 0.22),
                               startRadius: 0, endRadius: 380)
            }
            .ignoresSafeArea()
        }
#if DEBUG
        // CLI verification hook: SIMCTL_CHILD_EXPLOG_AUTO_AUTH="signup|login:email:password:Name"
        .task {
            guard let raw = ProcessInfo.processInfo.environment["EXPLOG_AUTO_AUTH"] else { return }
            let parts = raw.split(separator: ":").map(String.init)
            guard parts.count >= 3 else { return }
            mode = parts[0] == "signup" ? .signUp : .logIn
            email = parts[1]
            password = parts[2]
            name = parts.count > 3 ? parts[3] : "Test User"
            submit()
        }
#endif
    }

    private var canSubmit: Bool {
        !email.isEmpty && password.count >= 6 && (mode == .logIn || !name.isEmpty)
    }

    private func authField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background { GlassCard(cornerRadius: 14) { Color.clear } }
            .foregroundStyle(Theme.textPrimary)
    }

    private func submit() {
        guard !busy else { return }
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let firebaseUser: FirebaseAuth.User
                switch mode {
                case .signUp:
                    let result = try await Auth.auth().createUser(withEmail: email, password: password)
                    let change = result.user.createProfileChangeRequest()
                    change.displayName = name
                    try await change.commitChanges()
                    firebaseUser = result.user
                case .logIn:
                    firebaseUser = try await Auth.auth().signIn(withEmail: email, password: password).user
                }
                // Behind the scenes: backend mints the Stream token and quietly
                // creates the matching Stream user. The user only sees chat work.
                try await connectStream(as: firebaseUser)
            } catch {
                errorMessage = error.localizedDescription
                busy = false
            }
        }
    }

    @MainActor
    private func connectStream(as firebaseUser: FirebaseAuth.User) async throws {
        // The app may already be connected with the dev token — tear that
        // session down fully before connecting the real account.
        if chatClient.currentUserId != nil {
            await chatClient.logout()
        }
        let credentials = try await StreamTokenProvider.fetchToken(for: firebaseUser)
        try await chatClient.connectUser(
            userInfo: .init(id: credentials.userId,
                            name: firebaseUser.displayName ?? "Ralli user"),
            token: Token(rawValue: credentials.token)
        )
    }
}
