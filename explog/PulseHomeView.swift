import SwiftUI
import SwiftData

/// Home: the friends + group list.
///
/// Layout, top to bottom:
///   • header — "Ralli" wordmark left, group-create and add-friend actions right
///   • "All friends" quick action — opens the unified stacked clip feed
///   • one row per friend or group — avatar, name, latest caption, streak,
///     and a quick-chat button straight into the DM
struct PulseHomeView: View {
    @Query private var friends: [Friend]
    @Query(sort: \Chat.createdAt) private var chats: [Chat]

    @State private var showAddFriend = false
    @State private var showNewGroup = false
    @State private var showAllFriends = false
    @State private var openedFriend: Friend?
    @State private var openedGroup: Chat?
    @State private var quickChat: Chat?
    @State private var showHourlyWall = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var roster: [Friend] {
        friends.filter { !$0.isMe }.sorted { $0.name < $1.name }
    }
    private var groups: [Chat] { chats.filter(\.isGroup) }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        allFriendsCard

                        // Groups first, then people.
                        ForEach(groups) { group in
                            GroupRow(chat: group) {
                                openedGroup = group
                            } onChat: {
                                quickChat = group
                            }
                        }

                        ForEach(roster) { friend in
                            FriendRow(friend: friend) {
                                openedFriend = friend
                            } onChat: {
                                quickChat = chat(with: friend)
                            }
                        }

                        if roster.isEmpty && groups.isEmpty {
                            emptyState
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 110)
                }
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .top) { header }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        // 1-on-1 split stack, paging vertically through the whole roster from
        // whichever friend was tapped.
        .fullScreenCover(item: $openedFriend) { friend in
            FriendPairFeedView(friends: roster, me: me, startingFriend: friend)
        }
        .fullScreenCover(item: $openedGroup) { group in
            GroupClipFeedView(chat: group)
        }
        .fullScreenCover(isPresented: $showAllFriends) {
            AllFriendsFeedView(friends: roster)
        }
        .fullScreenCover(isPresented: $showHourlyWall) {
            PulseFeedView()
        }
        .fullScreenCover(item: $quickChat) { chat in
            NavigationStack { ChatDetailView(chat: chat) }
        }
        .sheet(isPresented: $showAddFriend) { AddFriendView() }
        .sheet(isPresented: $showNewGroup) { NewGroupChatView(candidates: roster) }
#if DEBUG
        // CLI verification hooks:
        // SIMCTL_CHILD_EXPLOG_AUTO_OPEN=pair|group|allfriends|addfriend|newgroup
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "pair": openedFriend = roster.first
            case "group": openedGroup = groups.first
            case "allfriends": showAllFriends = true
            case "addfriend": showAddFriend = true
            case "newgroup": showNewGroup = true
            default: break
            }
        }
#endif
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            // Top-left: the wordmark.
            RalliWordmark(size: 30)

            Spacer()

            // Top-right action 1: create a group chat from multiple friends.
            headerButton(icon: "person.2.badge.plus.fill", label: "New group") {
                showNewGroup = true
            }
            // Top-right action 2: add a friend by their User ID.
            headerButton(icon: "plus", label: "Add friend") {
                showAddFriend = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial.opacity(0.9))
    }

    private func headerButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(Theme.glassRimTop.opacity(0.5), lineWidth: 1))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Rows

    /// Explicit entry point to the unified feed of everyone's clips.
    private var allFriendsCard: some View {
        Button {
            showAllFriends = true
        } label: {
            GlassCard(cornerRadius: 20) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Theme.goldSheen)
                            .frame(width: 46, height: 46)
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("All friends")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Everyone's latest clip, end to end")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("👋").font(.system(size: 44))
            Text("No friends yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Tap + to add someone by their User ID")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 70)
    }

    private func chat(with friend: Friend) -> Chat? {
        chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
    }
}

// MARK: - Wordmark

/// "Ralli" in the app's serif + gold sheen.
struct RalliWordmark: View {
    var size: CGFloat = 30

    var body: some View {
        Text("Ralli")
            .font(.system(size: size, weight: .bold, design: .serif))
            .foregroundStyle(Theme.goldSheen)
            .shadow(color: Theme.goldGlow.opacity(0.35), radius: 10)
    }
}

// MARK: - List rows

/// A friend row: avatar, name, their latest caption, streak badge, quick chat.
private struct FriendRow: View {
    let friend: Friend
    let onOpen: () -> Void
    let onChat: () -> Void

    var body: some View {
        Button(action: onOpen) {
            GlassCard(cornerRadius: 20) {
                HStack(spacing: 13) {
                    // Gold ring when they've posted — the row's "live" signal.
                    GlassOrbAvatar(friend: friend, size: 52,
                                   isActive: friend.latestClip != nil)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(friend.name)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            if friend.streakCount > 0 {
                                StreakBadge(count: friend.streakCount)
                            }
                        }
                        // Status line: caption from their most recent log.
                        Text(friend.latestCaption.isEmpty ? "No logs yet" : friend.latestCaption)
                            .font(.caption)
                            .foregroundStyle(friend.latestCaption.isEmpty
                                             ? Theme.textSecondary.opacity(0.7)
                                             : Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    QuickChatButton(action: onChat)
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A group row — same anatomy, with a stacked avatar cluster.
private struct GroupRow: View {
    let chat: Chat
    let onOpen: () -> Void
    let onChat: () -> Void

    private var others: [Friend] { chat.members.filter { !$0.isMe } }

    var body: some View {
        Button(action: onOpen) {
            GlassCard(cornerRadius: 20) {
                HStack(spacing: 13) {
                    ZStack {
                        ForEach(Array(others.prefix(3).enumerated()), id: \.element.id) { index, member in
                            GlassOrbAvatar(friend: member, size: 38)
                                .offset(x: CGFloat(index) * 13 - 13)
                        }
                    }
                    .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(chat.displayName)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            if chat.streakCount > 0 {
                                StreakBadge(count: chat.streakCount)
                            }
                        }
                        Text(chat.latestCaption.isEmpty ? "No logs yet" : chat.latestCaption)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    QuickChatButton(action: onChat)
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 🔥 + count.
private struct StreakBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 2) {
            Text("🔥").font(.system(size: 11))
            Text("\(count)")
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.gold)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Theme.gold.opacity(0.14)))
    }
}

/// Straight into the 1-on-1 DM, without opening the video view first.
private struct QuickChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat")
    }
}
