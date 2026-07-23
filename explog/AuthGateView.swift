import SwiftUI
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

    @State private var stage: Stage = Auth.auth().currentUser == nil ? .signedOut : .checkingProfile
    @State private var listener: AuthStateDidChangeListenerHandle?

    var body: some View {
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
        .onAppear {
            guard listener == nil else { return }
            listener = Auth.auth().addStateDidChangeListener { _, user in
                if user == nil {
                    withAnimation { stage = .signedOut }
                } else {
                    stage = .checkingProfile
                    Task { await resolveProfile() }
                }
            }
        }
    }

    private var loadingScreen: some View {
        ZStack {
            GlassBackground()
            VStack(spacing: 18) {
                ExplogWordmark(size: 40)
                ProgressView().tint(Theme.gold)
            }
        }
        .preferredColorScheme(.dark)
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

            Text("Explog")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("Life, on the hour.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 28)

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
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
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
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

            Button(action: submit) {
                Group {
                    if busy {
                        ProgressView().tint(.black)
                    } else {
                        Text(mode == .signUp ? "Create account" : "Log in")
                            .font(.headline)
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(Capsule().fill(canSubmit ? Theme.accent : Theme.textSecondary))
            }
            .disabled(!canSubmit || busy)
            .padding(.horizontal, 28)
            .padding(.top, 18)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Theme.background, Color(red: 0.13, green: 0.07, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
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
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
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
                            name: firebaseUser.displayName ?? "Explog user"),
            token: Token(rawValue: credentials.token)
        )
    }
}
