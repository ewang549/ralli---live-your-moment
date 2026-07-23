import SwiftUI
import SwiftData
import FirebaseAuth

/// Onboarding step between sign-up and the app: claim a unique @handle and
/// confirm name/avatar/city. The app does not proceed until `createProfile`
/// succeeds, so every real account has a directory entry from the start.
struct ProfileSetupView: View {
    /// Called once the profile exists remotely and is cached locally.
    let onComplete: (RemoteProfile) -> Void

    @Environment(\.modelContext) private var modelContext

    @State private var handle = ""
    @State private var name = Auth.auth().currentUser?.displayName ?? ""
    @State private var city = ""
    @State private var avatar = "🧑‍💻"

    @State private var availability: Availability = .idle
    @State private var busy = false
    @State private var errorMessage: String?
    /// Debounce token so we only check the handle the user settled on.
    @State private var checkTask: Task<Void, Never>?

    private let avatarOptions = ["🧑‍💻", "🏄", "🎸", "📷", "🧗", "☕️", "🏃", "🎮", "🌊", "⛰️", "🎧", "🍜"]

    private enum Availability: Equatable {
        case idle, checking, available, taken(String)

        var isBlocking: Bool {
            switch self {
            case .available: false
            default: true
            }
        }
    }

    var body: some View {
        ZStack {
            GlassBackground()

            ScrollView {
                VStack(spacing: 22) {
                    header
                    identityCard
                    detailsCard

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    GoldButton(title: "Claim @\(handle.isEmpty ? "handle" : handle)",
                               busy: busy,
                               enabled: canSubmit) {
                        submit()
                    }
                    .padding(.top, 2)

                    Text("Your handle is how friends find you. You can change your name, photo and city later.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                }
                .padding(.horizontal, 22)
                .padding(.top, 28)
                .padding(.bottom, 40)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
#if DEBUG
        // CLI verification hook:
        //   SIMCTL_CHILD_EXPLOG_AUTO_PROFILE="handle:Name:City"
        .task {
            guard let raw = ProcessInfo.processInfo.environment["EXPLOG_AUTO_PROFILE"] else { return }
            let parts = raw.split(separator: ":").map(String.init)
            guard let first = parts.first else { return }
            handle = first
            if parts.count > 1 { name = parts[1] }
            if parts.count > 2 { city = parts[2] }
            try? await Task.sleep(for: .seconds(2)) // let the availability check land
            submit()
        }
#endif
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            ExplogWordmark(size: 38)
            Text("Pick your handle")
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Text("One name, everywhere on Explog.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    /// Avatar orb + handle field with live availability.
    private var identityCard: some View {
        GlassCard {
            VStack(spacing: 18) {
                GlassOrbAvatar(emoji: avatar, hue: 0.58, size: 92, isActive: availability == .available)
                    .padding(.top, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(avatarOptions, id: \.self) { option in
                            Button { avatar = option } label: {
                                Text(option)
                                    .font(.system(size: 22))
                                    .frame(width: 42, height: 42)
                                    .background {
                                        Circle().fill(avatar == option
                                                      ? Theme.gold.opacity(0.22)
                                                      : Color.white.opacity(0.06))
                                    }
                                    .overlay {
                                        Circle().strokeBorder(
                                            avatar == option ? Theme.gold.opacity(0.7) : .clear,
                                            lineWidth: 1
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("@")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.gold)
                        TextField("handle", text: $handle)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: handle) { _, newValue in
                                normalizeAndCheck(newValue)
                            }
                        availabilityIndicator
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                            }
                    }

                    Text(availabilityMessage)
                        .font(.caption)
                        .foregroundStyle(availabilityColor)
                        .padding(.horizontal, 4)
                }
            }
            .padding(18)
        }
    }

    private var detailsCard: some View {
        GlassCard {
            VStack(spacing: 14) {
                GlassField(placeholder: "Your name", text: $name, systemImage: "person.fill")
                GlassField(placeholder: "City (optional)", text: $city, systemImage: "mappin.and.ellipse")
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var availabilityIndicator: some View {
        switch availability {
        case .checking:
            ProgressView().tint(Theme.textSecondary).scaleEffect(0.8)
        case .available:
            GlowDot(size: 10)
        case .taken:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red.opacity(0.85))
        case .idle:
            EmptyView()
        }
    }

    private var availabilityMessage: String {
        switch availability {
        case .idle: "3–20 characters: letters, numbers, underscores."
        case .checking: "Checking…"
        case .available: "@\(handle) is available."
        case .taken(let reason): reason
        }
    }

    private var availabilityColor: Color {
        switch availability {
        case .available: Theme.gold
        case .taken: .red.opacity(0.85)
        default: Theme.textSecondary
        }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        !busy && !name.trimmingCharacters(in: .whitespaces).isEmpty && !availability.isBlocking
    }

    /// Keeps the field to the server's handle alphabet, then debounces the
    /// availability check so we aren't calling on every keystroke.
    private func normalizeAndCheck(_ raw: String) {
        let cleaned = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if cleaned != raw { handle = String(cleaned.prefix(20)); return } // re-enters onChange
        checkTask?.cancel()

        guard handle.count >= 3 else {
            availability = .idle
            return
        }
        availability = .checking
        let candidate = handle
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                let result = try await FirestoreService.checkHandleAvailable(candidate)
                guard !Task.isCancelled, candidate == handle else { return }
                availability = result.available
                    ? .available
                    : .taken(result.reason ?? "That handle is taken.")
            } catch {
                guard !Task.isCancelled, candidate == handle else { return }
                // Network trouble shouldn't read as "taken" — createProfile is
                // the real gate and will fail loudly if it is.
                availability = .idle
            }
        }
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let profile = try await FirestoreService.createProfile(
                    handle: handle,
                    name: name.trimmingCharacters(in: .whitespaces),
                    avatarEmoji: avatar,
                    city: city.trimmingCharacters(in: .whitespaces),
                    referredBy: PendingReferral.code
                )
                FirestoreService.cacheLocally(profile, context: modelContext)
                PendingReferral.code = nil
                onComplete(profile)
            } catch let error as CallableFunctions.CallableError {
                if error.isAlreadyExists {
                    availability = .taken("That handle is taken.")
                }
                errorMessage = error.message
                busy = false
            } catch {
                errorMessage = error.localizedDescription
                busy = false
            }
        }
    }
}

/// Referral code captured from an `explog://add?code=XXXXXX` deep link before
/// sign-up, attributed on the profile at creation (ambassador loop, Phase 2).
enum PendingReferral {
    private static let key = "explog.pendingReferralCode"

    static var code: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
