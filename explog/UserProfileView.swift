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

    var body: some View {
        if let me {
            profileForm(for: me)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func profileForm(for me: Friend) -> some View {
        @Bindable var profile = me
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Profile")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, 12)

                // Profile picture (emoji avatar) with picker.
                HStack(spacing: 16) {
                    AvatarView(friend: me, size: 76)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(avatarOptions, id: \.self) { option in
                                Button {
                                    profile.emoji = option
                                } label: {
                                    Text(option)
                                        .font(.system(size: 24))
                                        .padding(7)
                                        .background(
                                            Circle().fill(me.emoji == option
                                                          ? Theme.accent.opacity(0.35)
                                                          : Theme.surfaceLight)
                                        )
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
                    .tint(Theme.accent)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(me.isPrivate ? Color.clear : Theme.accent.opacity(0.35), lineWidth: 1)
                        )
                )

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
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                }

                // Bio.
                VStack(alignment: .leading, spacing: 6) {
                    Text("BIO")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Say something about yourself…", text: $profile.bio, axis: .vertical)
                        .lineLimit(2...4)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
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
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
                    }
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 110)
        }
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: me.isPrivate) { try? modelContext.save() }
    }

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
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
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
                        .background(Capsule().fill(isOn ? Theme.accent : Theme.surfaceLight))
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
                                .background(Capsule().fill(Theme.surfaceLight))
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}
