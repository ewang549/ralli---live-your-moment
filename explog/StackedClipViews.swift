import SwiftUI
import SwiftData

// MARK: - Layout safety

/// Clamps a dimension derived from a `GeometryReader` so it can never be passed
/// to `.frame(width:height:)` as a negative, zero, or non-finite value — the
/// exact inputs that trigger SwiftUI's "invalid frame dimension" runtime error.
/// During a full-screen cover's present/dismiss transition `proxy.size` can
/// momentarily read 0, so every geometry-driven frame in this file routes
/// through this.
extension CGFloat {
    var safeDimension: CGFloat { (isFinite && self > 0) ? self : 1 }
}

/// One place that defines what a "video container" is, so every feed renders
/// clips in identically-proportioned cards (per the uniform-sizing rule).
enum VideoCard {
    /// Portrait 9:16 — the aspect every clip container is normalized to.
    static let aspectRatio: CGFloat = 9.0 / 16.0
    static let cornerRadius: CGFloat = 24
    /// How many equal cards the continuous group feed fits per screen height.
    static let groupVisibleCount: CGFloat = 3
}

// MARK: - Shared clip pane
//
// One full-bleed clip with its caption overlaid. This is the unit every stacked
// layout is built from, so captions, avatars and sync behave identically
// whether you're in a 1-on-1, a group, or the all-friends feed.

struct StackedClipPane: View {
    let clip: Clip?
    /// Name shown on the pane; nil hides the chip (used for "you").
    let authorName: String?
    let authorEmoji: String
    let authorHue: Double
    /// Label under the name, e.g. "you".
    var roleLabel: String?
    /// Extra space above the author chip so it clears the timestamp banner /
    /// status bar on whichever pane sits at the top of the screen.
    var headerTopPadding: CGFloat = 0
    /// The real friend behind this pane, when tapping the author should open
    /// their profile. Nil for "you" (nothing to view) and for placeholder panes.
    var authorFriend: Friend?

    @Environment(ClipSyncClock.self) private var clock
    @State private var showProfile = false

    var body: some View {
        ZStack {
            if let clip {
                ClipView(clip: clip, isActive: true)
                    // Keying on the clock's cycle is what synchronizes the
                    // stack: every pane rebuilds its player on the same tick,
                    // so all clips restart together instead of drifting.
                    //
                    // Video only. A photo has nothing to restart, and rebuilding
                    // one every cycle made a remote photo re-fetch and flash its
                    // `AsyncImage` placeholder — the emoji orb — on each tick.
                    .id(clip.kind == .video ? "\(clip.id)-\(clock.cycle)" : "\(clip.id)")
            } else {
                noClipPlaceholder
            }

            // Legibility scrim — captions sit over live video.
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)

            // The hour this log was filmed, burned across the middle of the
            // frame — the same banner the camera and the review screen show,
            // so a log carries one stamp from capture through to the feed.
            if let capturedAt = clip?.capturedAt {
                HourOverlay(date: capturedAt)
            }

            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.top, headerTopPadding)
                Spacer()
                if let caption = clip?.label, !caption.isEmpty {
                    captionOverlay(caption)
                }
                // Reaction badges sit at the container's bottom-left, beneath
                // the caption — where a friend's reactions land on their log.
                if let reactions = clip?.reactions, !reactions.isEmpty {
                    reactionBadges(reactions)
                }
            }
            .padding(14)
        }
        .clipped()
        .contentShape(Rectangle())
        .fullScreenCover(isPresented: $showProfile) {
            if let authorFriend { PublicProfileSheet(friend: authorFriend) }
        }
    }

    /// De-duplicated reaction chips (emoji + count) pinned bottom-left.
    private func reactionBadges(_ reactions: [Reaction]) -> some View {
        // Group identical emoji so "❤️❤️🔥" reads as "❤️ 2  🔥 1".
        let counts = reactions.reduce(into: [String: Int]()) { $0[$1.emoji, default: 0] += 1 }
        return HStack(spacing: 6) {
            ForEach(counts.keys.sorted(), id: \.self) { emoji in
                HStack(spacing: 3) {
                    Text(emoji).font(.system(size: 15))
                    if let count = counts[emoji], count > 1 {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.5)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
            }
        }
        .transition(.scale(scale: 0.6, anchor: .bottomLeading).combined(with: .opacity))
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button {
                guard authorFriend != nil else { return }
                showProfile = true
            } label: {
                HStack(spacing: 9) {
                    // Coral ring marks the author who actually posted this slot.
                    GlassOrbAvatar(emoji: authorEmoji, hue: authorHue, size: 32,
                                   isActive: clip != nil)
                    VStack(alignment: .leading, spacing: 1) {
                        if let authorName {
                            Text(authorName)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .shadow(color: .black.opacity(0.6), radius: 4)
                        }
                        if let roleLabel {
                            Text(roleLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(authorFriend == nil)

            Spacer()
            if let capturedAt = clip?.capturedAt {
                Text(capturedAt.hourOnlyClockTime)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1) }
                    }
            }
        }
    }

    /// The friend's caption sits directly on top of their own clip, per spec —
    /// not in a shared bar — so in a stack you can tell who said what.
    private func captionOverlay(_ caption: String) -> some View {
        HStack {
            Text(caption)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    private var noClipPlaceholder: some View {
        ZStack {
            LinearGradient(colors: [Theme.baseElevated, Theme.base],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 6) {
                Text(authorEmoji).font(.system(size: 34)).opacity(0.5)
                Text("no clip yet")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

// MARK: - A. 1-on-1 stacked log detail with vertical paging

/// The friend's 2-second log on top (the larger card, carrying the reply +
/// reaction overlay), your own underneath (the smaller card), with the whole
/// pair paging vertically to the next friend.
///
/// The two cards are inset rounded panes rather than a flush split, and the
/// split is deliberately *not* 50/50 — the friend's log is the focus, so it
/// gets the taller container.
struct FriendPairFeedView: View {
    let friends: [Friend]
    let me: Friend?
    /// Friend to open on first appearance.
    var startingFriend: Friend?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @State private var clock = ClipSyncClock()
    @State private var currentIndex: Int = 0
    /// The friend thread to open when Reply is tapped on a friend's card.
    @State private var replyChat: Chat?

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            GeometryReader { proxy in
                // Vertical paging over friends. `.scrollTargetBehavior(.paging)`
                // snaps a whole pair into place per swipe.
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                            pairPage(for: friend, height: proxy.size.height)
                                .scrollTransition(.interactive.threshold(.visible(0.9))) { view, phase in
                                    view
                                        .opacity(phase.isIdentity ? 1 : 0.5)
                                        .scaleEffect(phase.isIdentity ? 1 : 0.93)
                                }
                                .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: Binding(
                    get: { currentIndex },
                    set: { newValue in
                        guard let newValue, newValue != currentIndex else { return }
                        currentIndex = newValue
                        // Restart the pair together rather than mid-cycle.
                        clock.resync()
                    }
                ))
            }
            .ignoresSafeArea()

            timestampBanner
        }
        .environment(clock)
        // Reply opens the very same thread engine used everywhere else.
        .sheet(item: $replyChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .task {
            if let startingFriend, let index = friends.firstIndex(where: { $0.id == startingFriend.id }) {
                currentIndex = index
            }
            clock.start()
        }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }

    /// One page: the friend's card on top (with actions), yours below —
    /// identically sized per the uniform video-sizing rule.
    private func pairPage(for friend: Friend, height: CGFloat) -> some View {
        // Insets carve the pair out of the screen: the top inset clears the
        // floating timestamp banner, and the cards leave a margin all round.
        let topInset: CGFloat = 92
        let bottomInset: CGFloat = 22
        let gap: CGFloat = 10
        // Uniform sizing: both containers get exactly half the usable height,
        // so your clip and the friend's clip render at identical dimensions.
        // Clamped so a transient 0-height geometry pass can't emit a negative
        // frame ("invalid frame dimension").
        let usable = height - topInset - bottomInset - gap
        let cardHeight = (usable / 2).safeDimension

        return VStack(spacing: gap) {
            // Top — the friend's log, carrying the reaction + reply overlay.
            logCard {
                StackedClipPane(
                    clip: friend.latestClip,
                    authorName: friend.name,
                    authorEmoji: friend.emoji,
                    authorHue: friend.hue,
                    roleLabel: friend.displayUserId.isEmpty ? nil : friend.displayUserId,
                    authorFriend: friend
                )
            }
            .frame(height: cardHeight)
            .overlay(alignment: .bottomTrailing) {
                FriendLogActions(clip: friend.latestClip, me: me,
                                 resolveChat: { dmChat(with: friend) }) {
                    replyChat = dmChat(with: friend)
                }
                .padding(16)
            }

            // Bottom — your own log: the identical container.
            logCard {
                StackedClipPane(
                    clip: me?.latestClip,
                    authorName: me?.name ?? "You",
                    authorEmoji: me?.emoji ?? "🙂",
                    authorHue: me?.hue ?? 0.58,
                    roleLabel: "you"
                )
            }
            .frame(height: cardHeight)
        }
        .padding(.horizontal, 12)
        .padding(.top, topInset)
        .padding(.bottom, bottomInset)
        .frame(height: height.safeDimension)
    }

    /// Rounded, hairline-ringed container shared by both panes.
    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func dmChat(with friend: Friend) -> Chat? {
        resolveDMChat(with: friend, me: me, chats: chats, context: modelContext)
    }

    /// Synchronized timestamp banner, pinned above both panes.
    private var timestampBanner: some View {
        HStack(spacing: 10) {
            CloseButton(overMedia: true) { dismiss() }

            Spacer()

            HStack(spacing: 7) {
                GlowDot(size: 7, breathing: true)
                Text(Date.now.hourOnlyClockTime)
                    .font(.system(size: 14, weight: .heavy, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.5)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))

            Spacer()

            // Balances the leading button.
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - Thread resolution

/// The 1-on-1 thread with `friend`, created if there isn't one yet.
///
/// The read-only lookup this replaces returned nil for a friend you'd accepted
/// but never messaged or sent a log to — they have no `Chat` row until
/// something makes one (see `Chat.dm`). That silently broke half of each action
/// on their card: a reaction still added its badge, but the broadcast into the
/// DM was skipped, and Reply opened nothing at all.
///
/// Call this from a button's action, never from `body`. Resolving it while
/// rendering would write a chat row for every friend merely scrolled past.
private func resolveDMChat(with friend: Friend, me: Friend?,
                           chats: [Chat], context: ModelContext) -> Chat? {
    guard let me else {
        // No local "me" row yet — fall back to a read-only lookup rather than
        // fabricating a thread with no sender in it.
        return chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
            ?? chats.first { $0.members.contains { $0.id == friend.id } }
    }
    return Chat.dm(with: friend, me: me, in: context)
}

// MARK: - Friend log action overlay (reply + emoji reaction)

/// The two vertically-stacked actions on the bottom-right of a friend's log
/// card: emoji reaction on top, reply beneath it (per the reference).
///
/// Reaction gestures are isolated so they never fight the paging swipe or a
/// tap: the button's own action opens the full picker, and a `.simultaneous`
/// long-press reveals the 5-emoji quick tray.
private struct FriendLogActions: View {
    let clip: Clip?
    let me: Friend?
    /// Thread this friend's log belongs to; a reaction is broadcast here so it
    /// also lands in the chat as a message. nil → badge-only (no thread).
    ///
    /// A closure rather than a value because resolving it can *create* the
    /// thread, and that must happen when the button is pressed — not while the
    /// feed renders. See `FriendPairFeedView.dmChat(with:)`.
    var resolveChat: () -> Chat?
    let onReply: () -> Void

    @Environment(\.modelContext) private var modelContext
    @State private var showQuickTray = false
    @State private var showEmojiPicker = false

    /// The 5 popular reactions in the quick tray.
    private let quickEmoji = ["❤️", "🔥", "😂", "😮", "👏"]

    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
            // Quick-reaction tray — revealed by long-pressing the react button.
            if showQuickTray {
                HStack(spacing: 14) {
                    ForEach(quickEmoji, id: \.self) { emoji in
                        Button { react(with: emoji) } label: {
                            Text(emoji).font(.system(size: 26))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(.black.opacity(0.55)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .transition(.scale(scale: 0.6, anchor: .bottomTrailing).combined(with: .opacity))
            }

            // Emoji reaction: tap → full picker, long-press → quick tray.
            actionButton(system: "face.smiling.inverse") {
                showEmojiPicker = true
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                    withAnimation(.spring(duration: 0.3)) { showQuickTray.toggle() }
                }
            )

            // Reply: opens the message thread with this friend.
            actionButton(system: "arrowshape.turn.up.left.fill", action: onReply)
        }
        .sheet(isPresented: $showEmojiPicker) {
            EmojiReactionPicker { emoji in
                react(with: emoji)
                showEmojiPicker = false
            }
        }
    }

    private func actionButton(system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(.black.opacity(0.4))
                        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                }
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func react(with emoji: String) {
        guard let clip else { return }
        let mine = Reaction(emoji: emoji, authorName: me?.name ?? "You")
        // Toggle: tapping the same reaction again removes it.
        withAnimation(.spring(duration: 0.3)) {
            if let index = clip.reactions.firstIndex(of: mine) {
                clip.reactions.remove(at: index)
            } else {
                clip.reactions.append(mine)
                // Broadcast the reaction into the chat thread — the same
                // reaction shows up as a message overlaying this clip's
                // preview. Only on add, so removing a reaction doesn't post.
                if let chat = resolveChat() {
                    let message = Message.reaction(emoji, to: clip, from: me, in: chat)
                    modelContext.insert(message)
                    chat.messages.append(message)
                }
            }
        }
        try? modelContext.save()
        withAnimation(.spring(duration: 0.3)) { showQuickTray = false }
    }
}

// MARK: - Full emoji picker

/// A scrollable grid of reactions, presented when the emoji button is tapped.
/// Deliberately broad so "any emoji" is a reasonable claim without pulling in
/// a full system keyboard.
struct EmojiReactionPicker: View {
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let emojis: [String] = [
        "❤️", "🔥", "😂", "😮", "👏", "🥰", "😍", "🤩", "😭", "🥺", "😅", "😎",
        "🙌", "👍", "👎", "🙏", "💯", "✨", "🎉", "😳", "🤔", "😴", "🤯", "😤",
        "🥳", "😱", "🫶", "💀", "👀", "😇", "🤗", "😆", "😉", "😜", "🤪", "😏",
    ]
    private let columns = Array(repeating: GridItem(.flexible()), count: 6)

    var body: some View {
        VStack(spacing: 0) {
            Text("React")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 18)
                .padding(.bottom, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(emojis, id: \.self) { emoji in
                        Button { onPick(emoji) } label: {
                            Text(emoji).font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
        .background(GlassBackground())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

// MARK: - B. Group chat video feed

/// Every member's current 2-second clip in one continuous vertical scroll —
/// about three equal-sized cards to a screen, scrolling smoothly like a long
/// sheet (no page snapping). Every card is the same width, height, and aspect
/// ratio, so no member's clip renders larger than another's.
struct GroupClipFeedView: View {
    let chat: Chat

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()
    /// Thread to open when Reply is tapped — the group's own chat.
    @State private var replyChat: Chat?

    private var me: Friend? { chat.members.first { $0.isMe } }

    /// One clip per member, most recent first, skipping members with nothing.
    private var entries: [(friend: Friend, clip: Clip?)] {
        chat.members.map { member in
            (member, chat.sortedClips.first { $0.author?.id == member.id })
        }
        .sorted { ($0.clip?.capturedAt ?? .distantPast) > ($1.clip?.capturedAt ?? .distantPast) }
    }

    private let cardSpacing: CGFloat = 12

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            GeometryReader { proxy in
                // Height that fits `groupVisibleCount` equal cards plus the gaps
                // between them. Clamped so a transient 0-height layout pass can
                // never emit a negative/zero frame.
                let count = VideoCard.groupVisibleCount
                let totalGaps = cardSpacing * (count - 1)
                let cardHeight = ((proxy.size.height - totalGaps) / count).safeDimension
                let cardWidth = (proxy.size.width - 24).safeDimension

                // Continuous scroll — no `.scrollTargetBehavior(.paging)`, so it
                // glides rather than snapping one clip at a time.
                ScrollView(.vertical) {
                    LazyVStack(spacing: cardSpacing) {
                        // Top spacer clears the floating title bar so the first
                        // card starts below it.
                        Color.clear.frame(height: 74)

                        ForEach(Array(entries.enumerated()), id: \.element.friend.id) { _, entry in
                            groupCard(entry: entry, width: cardWidth, height: cardHeight)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .ignoresSafeArea()

            header
        }
        .environment(clock)
        .sheet(item: $replyChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .task { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }

    /// One uniform member card. A friend's card carries the reaction + reply
    /// overlay; your own card doesn't (you don't react to yourself).
    @ViewBuilder
    private func groupCard(entry: (friend: Friend, clip: Clip?), width: CGFloat, height: CGFloat) -> some View {
        logCard {
            StackedClipPane(
                clip: entry.clip,
                authorName: entry.friend.name,
                authorEmoji: entry.friend.emoji,
                authorHue: entry.friend.hue,
                roleLabel: entry.friend.isMe ? "you" : nil,
                authorFriend: entry.friend.isMe ? nil : entry.friend
            )
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            if !entry.friend.isMe {
                // The group's own thread — it always exists, so there's
                // nothing to create here.
                FriendLogActions(clip: entry.clip, me: me, resolveChat: { chat }) {
                    replyChat = chat
                }
                .padding(14)
            }
        }
    }

    /// Rounded, hairline-ringed container — matches the 1-on-1 feed's card.
    private func logCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .clipShape(RoundedRectangle(cornerRadius: VideoCard.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VideoCard.cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var header: some View {
        HStack(spacing: 10) {
            CloseButton(overMedia: true) { dismiss() }
            Spacer()
            VStack(spacing: 1) {
                Text(chat.displayName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("\(chat.members.count) members")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            Color.clear.frame(width: 38, height: 38)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - C. All-friends continuous feed

/// Every friend's current 2-second clip, one per full screen, paging vertically.
/// Same full-screen paging mechanic as the group feed, scoped to the roster.
struct AllFriendsFeedView: View {
    let friends: [Friend]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @State private var clock = ClipSyncClock()
    @State private var currentIndex: Int = 0
    /// The friend thread to open when Reply is tapped on a card.
    @State private var replyChat: Chat?

    private var me: Friend? { friends.first { $0.isMe } }

    private var entries: [Friend] {
        friends
            .filter { !$0.isMe }
            .sorted { ($0.latestClip?.capturedAt ?? .distantPast) > ($1.latestClip?.capturedAt ?? .distantPast) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, friend in
                            StackedClipPane(
                                clip: friend.latestClip,
                                authorName: friend.name,
                                authorEmoji: friend.emoji,
                                authorHue: friend.hue,
                                roleLabel: friend.displayUserId.isEmpty ? nil : friend.displayUserId,
                                headerTopPadding: 96,
                                authorFriend: friend
                            )
                            .frame(width: proxy.size.width.safeDimension,
                                   height: proxy.size.height.safeDimension)
                            // Same react + reply overlay the 1-on-1 and group
                            // feeds carry. Without it this feed — the one that
                            // shows every friend's log — was the only place you
                            // could watch a friend's clip and not respond to it.
                            .overlay(alignment: .bottomTrailing) {
                                FriendLogActions(clip: friend.latestClip, me: me,
                                                 resolveChat: { dmChat(with: friend) }) {
                                    replyChat = dmChat(with: friend)
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 96)
                            }
                            .scrollTransition(.interactive.threshold(.visible(0.9))) { view, phase in
                                view
                                    .opacity(phase.isIdentity ? 1 : 0.5)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.93)
                            }
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: syncedIndex)
            }
            .ignoresSafeArea()

            HStack(spacing: 10) {
                CloseButton(overMedia: true) { dismiss() }
                Spacer()
                Text("All friends")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 38, height: 38)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .environment(clock)
        .sheet(item: $replyChat) { chat in
            ChatDrawerView(chat: chat)
        }
        .task { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }

    private func dmChat(with friend: Friend) -> Chat? {
        resolveDMChat(with: friend, me: me, chats: chats, context: modelContext)
    }

    /// Restarts every clip together whenever a swipe lands on a new page.
    private var syncedIndex: Binding<Int?> {
        Binding(
            get: { currentIndex },
            set: { newValue in
                guard let newValue, newValue != currentIndex else { return }
                currentIndex = newValue
                clock.resync()
            }
        )
    }
}
