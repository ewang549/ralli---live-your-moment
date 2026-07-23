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
    private let avatarOptions = ["🧑‍💻", "🏄", "🎸", "📷", "🧗", "☕️", "🏃", "🎮", "🌊", "⛰️"]

    private var me: Friend? { friends.first { $0.isMe } }

    @State private var isRecovering = false
    @State private var recoveryError: String?

    var body: some View {
        ZStack {
            GlassBackground()
            content
        }
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
                    ProgressView().tint(.black)
                } else {
                    Text("Reload profile").font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.gold))
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
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Profile")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    RalliWordmark(size: 22)
                }
                .padding(.top, 12)

                // Profile picture (emoji avatar) with picker.
                HStack(spacing: 16) {
                    GlassOrbAvatar(friend: me, size: 76, isActive: true)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(avatarOptions, id: \.self) { option in
                                let isOn = me.emoji == option
                                Button {
                                    profile.emoji = option
                                } label: {
                                    Text(option)
                                        .font(.system(size: 24))
                                        .padding(7)
                                        .background {
                                            Circle()
                                                .fill(.ultraThinMaterial)
                                                .overlay {
                                                    Circle().strokeBorder(
                                                        isOn ? AnyShapeStyle(Theme.goldRim)
                                                             : AnyShapeStyle(Theme.glassRimTop.opacity(0.3)),
                                                        lineWidth: isOn ? 1.5 : 1)
                                                }
                                                .shadow(color: isOn ? Theme.goldGlow.opacity(0.5) : .clear,
                                                        radius: 8)
                                        }
                                }
                            }
                        }
                    }
                }

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
                    .tint(Theme.gold)
                }
                .padding(14)
                .background {
                    GlassCard(cornerRadius: 16) { Color.clear }
                        // Public profiles carry a gold edge — the setting is
                        // legible without reading the label.
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(me.isPrivate ? Color.clear : Theme.gold.opacity(0.4),
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

                // Account: signed-in Firebase identity + log out.
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
                    }
                    .padding(.top, 6)
                }

#if DEBUG
                developerSection
#endif
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: me.isPrivate) { try? modelContext.save() }
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
                        .foregroundStyle(demoLoaded ? Theme.gold : Theme.textPrimary)
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
                        .foregroundStyle(isOn ? .black : Theme.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            Capsule()
                                .fill(isOn ? AnyShapeStyle(Theme.goldSheen) : AnyShapeStyle(Material.ultraThinMaterial))
                                .overlay { Capsule().strokeBorder(Theme.glassRimTop.opacity(isOn ? 0 : 0.35), lineWidth: 1) }
                                .shadow(color: isOn ? Theme.goldGlow.opacity(0.4) : .clear, radius: 8)
                        }
                }
            }
        }
    }
}

// MARK: - Public profile sheet (attendee cards open this)

struct PublicProfileSheet: View {
    let friend: Friend

    var body: some View {
        VStack(spacing: 14) {
            AvatarView(friend: friend, size: 84)
                .padding(.top, 28)
            Text(friend.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(Theme.textPrimary)

            if friend.isPrivate {
                // Privacy rule: private profiles expose nothing beyond the name.
                Label("Private profile", systemImage: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Text("This member keeps their details hidden.")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                if !friend.city.isEmpty {
                    Label("\(friend.city)\(friend.age > 0 ? " · \(friend.age)" : "")",
                          systemImage: "mappin.and.ellipse")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                }
                if !friend.bio.isEmpty {
                    Text(friend.bio)
                        .font(.body)
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
                if !friend.interests.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(friend.interests, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background { Capsule().fill(.ultraThinMaterial).overlay { Capsule().strokeBorder(Theme.glassRimTop.opacity(0.3), lineWidth: 1) } }
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(GlassBackground())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
