import SwiftUI
import SwiftData

/// Pulse — the activity list: who logged what, and how recently.
///
/// Layout, top to bottom:
///   • header — Ralli wordmark, search, Friend Hub, coral new-group-chat
///   • filter chips — Unread / Today / Streaks / Groups, active chip in coral
///   • "All friends" entry into the unified stacked clip feed
///   • one row per friend or group — orb avatar, name, status line, timestamp,
///     a coral glow dot when there's something new, and a quick-chat action
struct PulseHomeView: View {
    @Query private var friends: [Friend]
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @Environment(AppRouter.self) private var router
    @Environment(FriendGraph.self) private var friendGraph
    @Environment(LogSync.self) private var logSync
    @Environment(\.modelContext) private var modelContext

    @State private var showFriendHub = false
    /// Which tab Friend Hub opens on — flipped to `.requests` by a notification
    /// deep link, otherwise the default `.add`.
    @State private var friendHubTab: FriendHubView.Tab = .add
    @State private var showNewGroup = false
    /// The one full-screen destination Pulse can be showing.
    ///
    /// These were five separate `@State` flags behind five stacked
    /// `.fullScreenCover` modifiers on the same view node. SwiftUI's
    /// presentation graph can't reliably tell which of them owns a transition,
    /// and tapping between rows mid-transition recursed through
    /// `PairPreferenceCombiner` and crashed. They're mutually exclusive by
    /// nature — only one thing can be full-screen — so they're one optional
    /// behind one modifier.
    @State private var destination: PulseDestination?
    @State private var filter: PulseFilter = .all
    @State private var search = ""
    @State private var searching = false
#if DEBUG
    /// CLI screenshot hook only: the public profile sheet has no command-line
    /// entry point of its own (its real one is tapping a row's avatar, which a
    /// script can't do), so the hook below raises it from here.
    @State private var showDebugProfile = false
#endif

    private var me: Friend? { friends.first { $0.isMe } }

    /// Whether the user has posted a log during the current clock hour — drives
    /// the hourly banner's "done for this hour" state.
    private var postedThisHour: Bool {
        guard let at = me?.latestClip?.capturedAt else { return false }
        return Calendar.current.isDate(at, equalTo: .now, toGranularity: .hour)
    }

    private var roster: [Friend] {
        friends.filter { !$0.isMe }.sorted { $0.name < $1.name }
    }
    private var groups: [Chat] { chats.filter(\.isGroup) }

    /// Every friend and group as one comparable list, newest activity first so
    /// the live part of the hour reads before the quiet part.
    private var allEntries: [PulseEntry] {
        let people = roster.map { PulseEntry(friend: $0, chat: existingChat(with: $0)) }
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

    var body: some View {
        NavigationStack {
            ZStack {
                GlassBackground()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        HourlyCadenceBanner(postedThisHour: postedThisHour) {
                            destination = .hourlyWall
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                        .padding(.bottom, 10)

                        allFriendsCard

                        ForEach(entries) { entry in
                            ChatRowView(entry: entry) {
                                switch entry.kind {
                                case .friend(let friend): destination = .friend(friend)
                                case .group(let chat): destination = .group(chat)
                                }
                            } onChat: {
                                switch entry.kind {
                                case .friend(let friend):
                                    if let chat = chat(orCreateWith: friend) {
                                        destination = .quickChat(chat)
                                    }
                                case .group(let chat): destination = .quickChat(chat)
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
        // One modifier for every full-screen destination. `.friend` is the
        // 1-on-1 split stack, paging vertically through the whole roster from
        // whichever friend was tapped.
        .fullScreenCover(item: $destination) { destination in
            switch destination {
            case .friend(let friend):
                FriendPairFeedView(friends: roster, me: me, startingFriend: friend)
            case .group(let group):
                GroupClipFeedView(chat: group)
            case .allFriends:
                AllFriendsFeedView(friends: roster)
            case .hourlyWall:
                PulseFeedView()
            case .quickChat(let chat):
                NavigationStack {
                    ChatDetailView(chat: chat) { self.destination = nil }
                }
            }
        }
        .sheet(isPresented: $showFriendHub) { FriendHubView(initialTab: friendHubTab) }
        .sheet(isPresented: $showNewGroup) { NewGroupChatView(candidates: roster) }
        // Pick up requests that landed while the app was backgrounded, and
        // reconcile the roster after an accept on the other device. Friends'
        // logs follow, since a log needs its author's row to exist.
        .task {
            await friendGraph.refresh(context: modelContext)
            await logSync.syncDown(context: modelContext)
            // Anything that failed to upload gets another go while we're
            // already on the network, so a send lost to a flaky moment usually
            // recovers without the user having to act on the banner.
            await logSync.publishPending(context: modelContext)
        }
        // Notification deep links land on the router; Pulse owns the sheets, so
        // it's the one that actually presents them.
        .onChange(of: router.showRequestsInbox) { _, wants in
            guard wants else { return }
            friendHubTab = .requests
            showFriendHub = true
            router.showRequestsInbox = false
        }
        .onChange(of: router.openThreadChannelId) { _, channelId in
            guard let channelId else { return }
            // Match the notification's channel to a local chat. If the chat
            // isn't cached yet the tap still lands on Pulse rather than
            // nowhere, and the row's message button opens it a moment later.
            if let match = chats.first(where: { $0.streamChannelId == channelId }) {
                destination = .quickChat(match)
            }
            router.openThreadChannelId = nil
        }
#if DEBUG
        // CLI verification hooks. The env var still says EXPLOG_* on purpose —
        // it's an internal name, not user-facing, and renaming it would break
        // every existing screenshot script.
        // SIMCTL_CHILD_EXPLOG_AUTO_OPEN=pair|group|allfriends|addfriend|newgroup
        .task {
            try? await Task.sleep(for: .seconds(1.2))
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "pair": destination = roster.first.map(PulseDestination.friend)
            case "group": destination = groups.first.map(PulseDestination.group)
            case "allfriends": destination = .allFriends
            case "addfriend": friendHubTab = .add; showFriendHub = true
            case "requests": friendHubTab = .requests; showFriendHub = true
            case "newgroup": showNewGroup = true
            case "chat": destination = chats.first { !$0.isGroup }.map(PulseDestination.quickChat)
            case "profilesheet": showDebugProfile = true
            default: break
            }
        }
        // Defaults to your own account so the hook works with no setup;
        // SIMCTL_CHILD_EXPLOG_AUTO_PROFILE_UID points it at someone else,
        // which is the only way to exercise Follow (the server refuses a
        // self-follow, correctly).
        .fullScreenCover(isPresented: $showDebugProfile) {
            let override = ProcessInfo.processInfo.environment["EXPLOG_AUTO_PROFILE_UID"]
            PublicProfileSheet(uid: override ?? me?.remoteUID ?? "",
                               name: override == nil ? (me?.name ?? "") : "",
                               emoji: me?.emoji ?? "🙂")
        }
#endif
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                RalliWordmark()

                Spacer(minLength: 4)

                GlassCircleButton(icon: "magnifyingglass", label: "Search") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        searching.toggle()
                        if !searching { search = "" }
                    }
                }
                // Add & manage friends: search, add-by-code, your own code, and
                // pending requests all live behind this one entry point. Badged
                // whenever someone's waiting on a decision.
                GlassCircleButton(icon: "person.2.badge.plus.fill", label: "Friends",
                                  badgeCount: friendGraph.pendingCount) {
                    // Land straight on the inbox when someone's waiting —
                    // opening on "Add Friends" buries the thing being badged.
                    friendHubTab = friendGraph.pendingCount > 0 ? .requests : .add
                    showFriendHub = true
                }
                // The screen's primary action: start a new group chat. The only
                // solid-coral control in the header.
                GlassCircleButton(icon: "plus", label: "New group chat", isProminent: true) {
                    showNewGroup = true
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
    /// bolted on above it — the coral disc is the only thing marking it apart.
    private var allFriendsCard: some View {
        Button {
            destination = .allFriends
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 52, height: 52)
                        .shadow(color: Theme.accent.opacity(0.3), radius: 10, y: 3)
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
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

    /// The 1-on-1 chat with this friend, creating one if it doesn't exist yet, so
    /// the per-row message button always lands in a real conversation rather than
    /// silently doing nothing for a friend you haven't messaged before.
    private func chat(orCreateWith friend: Friend) -> Chat? {
        guard let me else { return nil }
        return Chat.dm(with: friend, me: me, in: modelContext)
    }

    /// Read-only lookup, unlike `chat(orCreateWith:)` — used to build row
    /// entries, which shouldn't spawn a chat just to render a list.
    private func existingChat(with friend: Friend) -> Chat? {
        chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
    }
}

// MARK: - Full-screen destinations

/// Where Pulse can take you full-screen.
///
/// One case per destination, so the five presentations that used to be five
/// stacked modifiers are one. The `id` is per-destination rather than per-case
/// so switching directly between two friends is a genuine identity change and
/// SwiftUI rebuilds the cover instead of reusing it.
private enum PulseDestination: Identifiable {
    case friend(Friend)
    case group(Chat)
    case allFriends
    case hourlyWall
    case quickChat(Chat)

    var id: String {
        switch self {
        case .friend(let friend): "friend-\(friend.id)"
        case .group(let chat): "group-\(chat.id)"
        case .allFriends: "allFriends"
        case .hourlyWall: "hourlyWall"
        case .quickChat(let chat): "quickChat-\(chat.id)"
        }
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
    /// The underlying thread, when one exists — the real source of the
    /// unread dot. A friend with no chat yet (never messaged) has none.
    let chat: Chat?

    init(friend: Friend, chat: Chat?) {
        kind = .friend(friend)
        id = friend.id
        name = friend.name
        status = friend.latestCaption
        streak = friend.streakCount
        // A message with no accompanying log still counts as activity, so a
        // reply-only exchange bumps this row the same way a new clip does.
        activityAt = chat?.lastActivityAt ?? friend.latestClip?.capturedAt
        members = [friend]
        isOnline = friend.isOnline
        self.chat = chat
    }

    init(group: Chat) {
        kind = .group(group)
        id = group.id
        name = group.displayName
        status = group.latestCaption
        streak = group.streakCount
        activityAt = group.lastActivityAt
        members = group.members.filter { !$0.isMe }
        // A crew is "live" when anyone but you is.
        isOnline = group.members.contains { !$0.isMe && $0.isOnline }
        chat = group
    }

    var isGroup: Bool { if case .group = kind { true } else { false } }

    /// The chat's own read cursor is authoritative whenever there is a chat.
    /// Only a friend with no thread yet falls back to a time-based proxy —
    /// there's nothing else to read as "new" until a first message exists.
    var isUnread: Bool {
        if let chat { return chat.hasUnread }
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

    /// Shown as a small coral pill on the chip. "All" carries no count — a total
    /// of everything isn't information.
    func count(in entries: [PulseEntry]) -> Int {
        self == .all ? 0 : entries.filter(matches).count
    }
}

// MARK: - List row

/// The per-row chat affordance: a small, quiet coral-tinted circle carrying the
/// Ralli chat mark, right-aligned in a Pulse row. Tapping it opens that row's
/// conversation directly. A coral dot rides the top-trailing corner when the
/// conversation has something unread — Snapchat-style, so unread reads at a
/// glance without a heavy badge.
struct RowChatButton: View {
    let hasUnread: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChatGlyph(size: 17, color: Theme.accent)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.accentWash))
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().strokeBorder(Theme.base, lineWidth: 2))
                            .offset(x: 1, y: -1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .accessibilityLabel(hasUnread ? "Open chat, unread" : "Open chat")
    }
}

/// One chat-list row: avatar (with a green dot when they're live), the name, and
/// underneath it the caption of their latest video log followed by how old it is.
/// A coral message button on the trailing edge opens that exact conversation.
///
/// Two distinct tap targets: the body (name/avatar) opens the video feed; the
/// right-side button opens the chat. Deliberately flat — no card, no divider.
/// The rows are separated by rhythm and the avatar column alone, which is what
/// keeps a long list quiet.
struct ChatRowView: View {
    let entry: PulseEntry
    let onOpen: () -> Void
    let onChat: () -> Void

    @State private var showProfile = false

    /// The row's single friend, when it isn't a group — the only case with an
    /// unambiguous profile to open from the avatar.
    private var singleFriend: Friend? {
        if case .friend(let friend) = entry.kind { friend } else { nil }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Avatar — its own tap target, opening this person's profile.
            // A group's stacked avatar has no single owner, so it stays part
            // of the row's open-feed button instead (rendered there, below).
            // Exactly one of the two branches draws it: rendering here *and*
            // inside the button is what doubled every group row's cluster.
            if singleFriend != nil {
                Button { showProfile = true } label: { avatar }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(entry.name)'s profile")
            }

            // Body — opens the log/clip feed.
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    if singleFriend == nil { avatar }

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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Right-side chat button — opens this exact conversation directly,
            // with a coral unread dot when there's something new to read.
            RowChatButton(hasUnread: entry.isUnread, action: onChat)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .fullScreenCover(isPresented: $showProfile) {
            if let singleFriend { PublicProfileSheet(friend: singleFriend) }
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
            // A single merged badge, not two duplicate 52pt circles: the back
            // face sits small and inset top-left, the front face reads as the
            // "primary" one bottom-right — a ring the row's own background
            // color cuts a clean gap between them, so it reads as one crew
            // glyph rather than a pair of overlapping avatars.
            ZStack {
                AvatarView(friend: entry.members[0], size: 30)
                    .clipShape(Circle())
                    .offset(x: -9, y: -9)
                AvatarView(friend: entry.members[1], size: 34)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.base, lineWidth: 2.5))
                    .offset(x: 8, y: 8)
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
