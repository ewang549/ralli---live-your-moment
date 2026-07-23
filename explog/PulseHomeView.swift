import SwiftUI
import SwiftData

/// Pulse — the activity list: who logged what, and how recently.
///
/// Layout, top to bottom:
///   • header — Ralli wordmark, search, notifications bell, gold add-friend
///   • filter chips — Unread / Today / Streaks / Groups, active chip in gold
///   • "All friends" entry into the unified stacked clip feed
///   • one row per friend or group — orb avatar, name, status line, timestamp,
///     a gold glow dot when there's something new, and a quick-chat action
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
    @State private var filter: PulseFilter = .all
    @State private var search = ""
    @State private var searching = false

    private var me: Friend? { friends.first { $0.isMe } }
    private var roster: [Friend] {
        friends.filter { !$0.isMe }.sorted { $0.name < $1.name }
    }
    private var groups: [Chat] { chats.filter(\.isGroup) }

    /// Every friend and group as one comparable list, newest activity first so
    /// the live part of the hour reads before the quiet part.
    private var allEntries: [PulseEntry] {
        let people = roster.map(PulseEntry.init(friend:))
        let crews = groups.map(PulseEntry.init(group:))
        return (people + crews).sorted { lhs, rhs in
            switch (lhs.activityAt, rhs.activityAt) {
            case let (l?, r?): l > r
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.name < rhs.name
            }
        }
    }

    private var entries: [PulseEntry] {
        allEntries
            .filter { filter.matches($0) }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    /// Unread total drives both the bell badge and the Unread chip's pill.
    private var unreadCount: Int { allEntries.filter(\.isUnread).count }

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        allFriendsCard

                        ForEach(entries) { entry in
                            PulseRow(entry: entry) {
                                switch entry.kind {
                                case .friend(let friend): openedFriend = friend
                                case .group(let chat): openedGroup = chat
                                }
                            } onChat: {
                                switch entry.kind {
                                case .friend(let friend): quickChat = chat(with: friend)
                                case .group(let chat): quickChat = chat
                                }
                            }
                        }

                        if entries.isEmpty { emptyState }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 118)
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
            NavigationStack {
                ChatDetailView(chat: chat) { quickChat = nil }
            }
        }
        .sheet(isPresented: $showAddFriend) { AddFriendView() }
        .sheet(isPresented: $showNewGroup) { NewGroupChatView(candidates: roster) }
#if DEBUG
        // CLI verification hooks. The env var still says EXPLOG_* on purpose —
        // it's an internal name, not user-facing, and renaming it would break
        // every existing screenshot script.
        // SIMCTL_CHILD_EXPLOG_AUTO_OPEN=pair|group|allfriends|addfriend|newgroup
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "pair": openedFriend = roster.first
            case "group": openedGroup = groups.first
            case "allfriends": showAllFriends = true
            case "addfriend": showAddFriend = true
            case "newgroup": showNewGroup = true
            case "chat": quickChat = chats.first { !$0.isGroup }
            default: break
            }
        }
#endif
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                RalliWordmark(size: 30)

                Spacer(minLength: 4)

                GlassCircleButton(icon: "magnifyingglass", label: "Search") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        searching.toggle()
                        if !searching { search = "" }
                    }
                }
                GlassCircleButton(icon: "bell.fill", label: "Notifications",
                                  hasBadge: unreadCount > 0) {
                    showHourlyWall = true
                }
                GlassCircleButton(icon: "person.2.badge.plus.fill", label: "New group") {
                    showNewGroup = true
                }
                // The screen's primary action, and the way into add-by-handle:
                // the only solid-gold control in the header.
                GlassCircleButton(icon: "plus", label: "Add friend", isGold: true) {
                    showAddFriend = true
                }
            }
            .padding(.horizontal, 16)

            if searching {
                GlassField(placeholder: "Search friends and groups",
                           text: $search, systemImage: "magnifyingglass")
                    .padding(.horizontal, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(PulseFilter.allCases) { option in
                        FilterChip(title: option.title,
                                   count: option.count(in: allEntries),
                                   isActive: filter == option) {
                            withAnimation(.easeOut(duration: 0.18)) { filter = option }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background {
            // Glass needs something behind it: the header floats over the
            // gradient and the scrolling rows, not over a flat fill.
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.glassRimTop.opacity(0.25))
                        .frame(height: 1)
                }
                .ignoresSafeArea(edges: .top)
        }
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
                            .shadow(color: Theme.goldGlow.opacity(0.45), radius: 12)
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
                        .foregroundStyle(Theme.goldSoft)
                }
                .padding(14)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(filter == .all && search.isEmpty ? "👋" : "🔍")
                .font(.system(size: 44))
            Text(filter == .all && search.isEmpty ? "No friends yet" : "Nothing here")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text(filter == .all && search.isEmpty
                 ? "Tap + to add someone by their User ID"
                 : "Try another filter")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 70)
    }

    private func chat(with friend: Friend) -> Chat? {
        chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
    }
}

// MARK: - Entry model

/// One line in the Pulse list — a person or a crew, flattened to the handful of
/// values the row actually renders.
struct PulseEntry: Identifiable {
    enum Kind {
        case friend(Friend)
        case group(Chat)
    }

    let kind: Kind
    let id: UUID
    let name: String
    let status: String
    let streak: Int
    let activityAt: Date?
    let members: [Friend]

    init(friend: Friend) {
        kind = .friend(friend)
        id = friend.id
        name = friend.name
        status = friend.latestCaption
        streak = friend.streakCount
        activityAt = friend.latestClip?.capturedAt
        members = [friend]
    }

    init(group: Chat) {
        kind = .group(group)
        id = group.id
        name = group.displayName
        status = group.latestCaption
        streak = group.streakCount
        activityAt = group.sortedClips.first?.capturedAt
        members = group.members.filter { !$0.isMe }
    }

    var isGroup: Bool { if case .group = kind { true } else { false } }

    /// "New" is time-based rather than a read receipt: nothing in the local
    /// model tracks what you've opened, so anything from the last three hours
    /// counts as unseen. Swap this for a real read cursor when one exists.
    var isUnread: Bool {
        guard let activityAt else { return false }
        return Date.now.timeIntervalSince(activityAt) < 3 * 3600
    }

    var isToday: Bool {
        guard let activityAt else { return false }
        return Calendar.current.isDateInToday(activityAt)
    }

    var timestamp: String { activityAt?.relativeHour ?? "" }
}

// MARK: - Filters

enum PulseFilter: String, CaseIterable, Identifiable {
    case all, unread, today, streaks, groups

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .unread: "Unread"
        case .today: "Today"
        case .streaks: "Streaks"
        case .groups: "Groups"
        }
    }

    func matches(_ entry: PulseEntry) -> Bool {
        switch self {
        case .all: true
        case .unread: entry.isUnread
        case .today: entry.isToday
        case .streaks: entry.streak > 0
        case .groups: entry.isGroup
        }
    }

    /// Shown as a small gold pill on the chip. "All" carries no count — a total
    /// of everything isn't information.
    func count(in entries: [PulseEntry]) -> Int {
        self == .all ? 0 : entries.filter(matches).count
    }
}

// MARK: - List row

/// A friend or group row: orb avatar, name, status line, timestamp, and the
/// quick way into the thread. Unread rows carry a gold glow dot and heavier type.
private struct PulseRow: View {
    let entry: PulseEntry
    let onOpen: () -> Void
    let onChat: () -> Void

    var body: some View {
        Button(action: onOpen) {
            GlassCard(cornerRadius: 20) {
                HStack(spacing: 13) {
                    avatar

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.system(size: 16,
                                              weight: entry.isUnread ? .heavy : .bold,
                                              design: .rounded))
                                .foregroundStyle(entry.isUnread
                                                 ? Theme.textPrimary
                                                 : Theme.textPrimary.opacity(0.82))
                                .lineLimit(1)
                            if entry.streak > 0 {
                                StreakBadge(count: entry.streak)
                            }
                        }
                        Text(entry.status.isEmpty ? "No logs yet" : entry.status)
                            .font(.system(size: 13))
                            .foregroundStyle(entry.status.isEmpty
                                             ? Theme.textSecondary.opacity(0.6)
                                             : Theme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    VStack(alignment: .trailing, spacing: 6) {
                        Text(entry.timestamp)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(entry.isUnread ? Theme.gold : Theme.textSecondary)
                        if entry.isUnread {
                            GlowDot(size: 9)
                        }
                    }

                    QuickChatButton(action: onChat)
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var avatar: some View {
        if entry.isGroup {
            ZStack {
                ForEach(Array(entry.members.prefix(3).enumerated()), id: \.element.id) { index, member in
                    GlassOrbAvatar(friend: member, size: 38)
                        .offset(x: CGFloat(index) * 13 - 13)
                }
            }
            .frame(width: 52, height: 52)
        } else if let friend = entry.members.first {
            // Gold ring when they've posted recently — the row's "live" signal.
            GlassOrbAvatar(friend: friend, size: 52, isActive: entry.isUnread)
        }
    }
}

/// 🔥 + count, in gold.
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
        .background {
            Capsule().fill(Theme.gold.opacity(0.14))
                .overlay { Capsule().strokeBorder(Theme.gold.opacity(0.3), lineWidth: 0.5) }
        }
    }
}

/// Straight into the 1-on-1 DM, without opening the video view first.
private struct QuickChatButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bubble.left.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.goldSoft)
                .frame(width: 38, height: 38)
                .background {
                    Circle().fill(.ultraThinMaterial)
                        .overlay(Circle().strokeBorder(Theme.gold.opacity(0.28), lineWidth: 1))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chat")
    }
}
