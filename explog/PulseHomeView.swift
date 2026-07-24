import SwiftUI
import SwiftData

/// Pulse — the activity list: who logged what, and how recently.
///
/// Layout, top to bottom:
///   • header — Ralli wordmark, search, notifications bell, iris add-friend
///   • filter chips — Unread / Today / Streaks / Groups, active chip in iris
///   • "All friends" entry into the unified stacked clip feed
///   • one row per friend or group — orb avatar, name, status line, timestamp,
///     a iris glow dot when there's something new, and a quick-chat action
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
                    LazyVStack(spacing: 0) {
                        allFriendsCard

                        ForEach(entries) { entry in
                            ChatRowView(entry: entry) {
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
                    .padding(.top, 4)
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
                // the only solid-iris control in the header.
                GlassCircleButton(icon: "plus", label: "Add friend", isProminent: true) {
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
            // Solid canvas so the list scrolls cleanly under the header, with a
            // hairline to separate it from the content beneath.
            Rectangle()
                .fill(Theme.base)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Theme.hairline)
                        .frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: Rows

    /// Explicit entry point to the unified feed of everyone's clips. Shares the
    /// chat row's geometry so it reads as the first line of the list, not a card
    /// bolted on above it — the iris disc is the only thing marking it apart.
    private var allFriendsCard: some View {
        Button {
            showAllFriends = true
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.iris)
                        .frame(width: 52, height: 52)
                        .shadow(color: Theme.iris.opacity(0.3), radius: 10, y: 3)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.onIris)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("All friends")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Everyone's latest clip, end to end")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
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
    /// Caption of this person's (or crew's) latest video log — the row's subtitle.
    let status: String
    let streak: Int
    let activityAt: Date?
    let members: [Friend]
    let isOnline: Bool

    init(friend: Friend) {
        kind = .friend(friend)
        id = friend.id
        name = friend.name
        status = friend.latestCaption
        streak = friend.streakCount
        activityAt = friend.latestClip?.capturedAt
        members = [friend]
        isOnline = friend.isOnline
    }

    init(group: Chat) {
        kind = .group(group)
        id = group.id
        name = group.displayName
        status = group.latestCaption
        streak = group.streakCount
        activityAt = group.sortedClips.first?.capturedAt
        members = group.members.filter { !$0.isMe }
        // A crew is "live" when anyone but you is.
        isOnline = group.members.contains { !$0.isMe && $0.isOnline }
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

    /// "2h" — trails the caption on the row's subtitle line.
    var shortTimestamp: String { activityAt?.shortRelative ?? "" }
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

    /// Shown as a small iris pill on the chip. "All" carries no count — a total
    /// of everything isn't information.
    func count(in entries: [PulseEntry]) -> Int {
        self == .all ? 0 : entries.filter(matches).count
    }
}

// MARK: - List row

/// One chat-list row on black: avatar (with a green dot when they're live), the
/// name, and underneath it the caption of their latest video log followed by how
/// old it is. A blue dot on the trailing edge marks unread.
///
/// Deliberately flat — no card, no divider. The rows are separated by rhythm and
/// the avatar column alone, which is what keeps a long list quiet.
struct ChatRowView: View {
    let entry: PulseEntry
    let onOpen: () -> Void
    let onChat: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(entry.name)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        if entry.streak > 0 {
                            Text("🔥\(entry.streak)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.coral)
                                .fixedSize()
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if entry.isUnread {
                    Circle()
                        .fill(Theme.iris)
                        .frame(width: 9, height: 9)
                        .accessibilityLabel("Unread")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The row itself opens the video feed, so the DM keeps its own way in.
        .contextMenu {
            Button(action: onChat) {
                Label("Open chat", systemImage: "bubble.left.and.bubble.right.fill")
            }
        }
    }

    /// "Latest video caption · 2h". The timestamp is dropped rather than shown
    /// dangling when there's no log to date.
    private var subtitle: String {
        let caption = entry.status.isEmpty ? "No logs yet" : entry.status
        let stamp = entry.shortTimestamp
        return stamp.isEmpty ? caption : "\(caption) · \(stamp)"
    }

    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarImage

            if entry.isOnline {
                Circle()
                    .fill(Theme.mint)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Theme.base, lineWidth: 2.5))
                    .accessibilityLabel("Online")
            }
        }
        .frame(width: 52, height: 52)
    }

    @ViewBuilder
    private var avatarImage: some View {
        // Note the `count >= 2` rather than `isGroup`: a crew you're the only
        // remaining member of, or a one-other-person group, has nothing to stack
        // — it falls through to the single avatar, then to the placeholder,
        // instead of rendering an empty 52pt hole.
        if entry.members.count >= 2 {
            // Two faces, offset — enough to read as a crew at 52pt without
            // shrinking either one into an unrecognisable dot.
            ZStack {
                ForEach(Array(entry.members.prefix(2).enumerated()), id: \.element.id) { index, member in
                    AvatarView(friend: member, size: 38)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Theme.base, lineWidth: 2))
                        .offset(x: index == 0 ? -7 : 7, y: index == 0 ? -7 : 7)
                }
            }
            .frame(width: 52, height: 52)
        } else if let friend = entry.members.first {
            AvatarView(friend: friend, size: 52)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(Theme.sunken)
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                }
        }
    }
}
