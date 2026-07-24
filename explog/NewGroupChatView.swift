import SwiftUI
import SwiftData

/// Select multiple friends to start a group chat.
///
/// Creates the local `Chat` (isGroup) immediately so the row appears in the
/// home list, then provisions the matching Stream channel in the background —
/// the same `joinStreamChannel` path the rest of the app uses.
struct NewGroupChatView: View {
    let candidates: [Friend]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var friends: [Friend]

    @State private var selected: Set<UUID> = []
    @State private var groupName = ""
    @State private var busy = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var canCreate: Bool { selected.count >= 2 && !busy }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                VStack(spacing: 14) {
                    GlassField(placeholder: "Group name (optional)",
                               text: $groupName,
                               systemImage: "textformat")
                        .padding(.horizontal, 20)

                    // Selection count doubles as the rule hint.
                    Text(selected.count < 2
                         ? "Pick at least 2 friends"
                         : "\(selected.count) selected")
                        .font(.caption)
                        .foregroundStyle(selected.count < 2 ? Theme.textSecondary : Theme.iris)

                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(candidates) { friend in
                                selectableRow(friend)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)

                    PrimaryButton(title: "Create group", busy: busy, enabled: canCreate) {
                        createGroup()
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
                }
                .padding(.top, 10)
            }
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func selectableRow(_ friend: Friend) -> some View {
        let isSelected = selected.contains(friend.id)
        return Button {
            if isSelected { selected.remove(friend.id) } else { selected.insert(friend.id) }
        } label: {
            GlassCard(cornerRadius: 16) {
                HStack(spacing: 12) {
                    GlassOrbAvatar(friend: friend, size: 42, isActive: isSelected)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(friend.name)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        if !friend.displayUserId.isEmpty {
                            Text(friend.displayUserId)
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? Theme.iris : Theme.textSecondary.opacity(0.6))
                }
                .padding(11)
            }
        }
        .buttonStyle(.plain)
    }

    private func createGroup() {
        guard canCreate, let me else { return }
        busy = true

        let members = [me] + candidates.filter { selected.contains($0.id) }
        let title = groupName.trimmingCharacters(in: .whitespaces)
        let chat = Chat(title: title.isEmpty ? nil : title, isGroup: true, members: members)
        modelContext.insert(chat)
        try? modelContext.save()

        // Provision the Stream channel for the new group. Local creation
        // already succeeded, so a failure here doesn't lose the group — chat
        // just falls back until the channel is created on next open.
        let channelId = "group-\(chat.id.uuidString.prefix(12))".lowercased()
        let otherIds = members.filter { !$0.isMe }.compactMap { $0.remoteUID.isEmpty ? nil : $0.remoteUID }
        Task {
            try? await StreamTokenProvider.joinChannel(
                channelId: channelId,
                otherMemberIds: otherIds,
                name: chat.displayName
            )
            await MainActor.run { dismiss() }
        }
    }
}
