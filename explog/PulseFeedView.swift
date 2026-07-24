import SwiftUI
import SwiftData

/// Home tab: a vertical wall of 16:9 friend cards, all pinned to the *same* hour.
///
/// Three gestures share this surface without fighting each other:
///   • vertical drag  → the native `ScrollView` pan (never intercepted)
///   • tap left/right 25% edge → step the shared hour back / forward
///   • horizontal swipe right  → the user's own daily recap vlog
///
/// The edge taps and the swipe are attached with `simultaneousGesture`, so the
/// ScrollView keeps first claim on vertical drags; the painted edge affordances
/// are `allowsHitTesting(false)` so they can never swallow a scroll.
struct PulseFeedView: View {
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @Query private var friends: [Friend]
    @Query private var allClips: [Clip]

    @Environment(\.dismiss) private var dismiss

    /// One shared timestamp drives every card on screen.
    @State private var hourState = HourFeedState()
    @State private var openedChat: Chat?
    @State private var showVlog = false
    @State private var showMontage = false
    @State private var showChatList = false
    @State private var navPath = NavigationPath()
    /// Brief highlight on whichever edge was tapped, for tap feedback.
    @State private var flashedEdge: FeedEdge?

    /// Named to avoid shadowing SwiftUI's own `Edge`.
    private enum FeedEdge { case leading, trailing }

    /// Named space so edge-tap coordinates are measured against the feed frame,
    /// not the scrolling content (which moves under the finger).
    private let feedSpace = "pulse-feed"

    var body: some View {
        NavigationStack(path: $navPath) {
            VStack(spacing: 0) {
                header
                hourBadge
                feed
            }
            .background(GlassBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Chat.self) { chat in
                ChatDetailView(chat: chat)
            }
        }
        // Every card reads the hour from the environment — one tap re-times all.
        .environment(hourState)
        // Immersive media wall — stays dark whatever the system theme.
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $openedChat) { chat in
            LogPlayerView(startingChat: chat)
        }
        .fullScreenCover(isPresented: $showVlog) {
            DailyVlogView()
        }
        .fullScreenCover(isPresented: $showMontage) {
            MontageView()
        }
        .sheet(isPresented: $showChatList) {
            ChatListSheet(chats: chats) { chat in
                showChatList = false
                navPath.append(chat)
            }
        }
#if DEBUG
        .task {
            // CLI screenshot hooks: SIMCTL_CHILD_EXPLOG_AUTO_OPEN=log|group|montage
            try? await Task.sleep(for: .seconds(1))
            switch ProcessInfo.processInfo.environment["EXPLOG_AUTO_OPEN"] {
            case "log": openedChat = chats.first { !$0.isGroup }
            case "group": openedChat = chats.first { $0.isGroup }
            case "montage", "vlog": showVlog = true
            case "chat": if let chat = chats.first { navPath.append(chat) }
            default: break
            }
        }
#endif
    }

    // MARK: - Feed

    /// Continuous vertical scroll — no paging, no snapping. A 16:9 card at phone
    /// width is roughly a third of the screen, so ~3 cards read at once.
    private var feed: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    // Story-style montage of your own day, above the friend wall.
                    // (DailyVlogView is the stitched multi-day recap; this is the
                    // quick tap-through of today.)
                    if todaysClipCount > 0 {
                        montageCard
                    }
                    if entries.isEmpty {
                        emptyState
                    } else {
                        ForEach(entries) { entry in
                            PulseCard(entry: entry) { chat in
                                openedChat = chat
                            } onReply: { chat in
                                navPath.append(chat)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 100) // clears the floating tab bar
            }
            .scrollIndicators(.hidden)
            // Without this the feed can settle mid-content on first layout.
            .defaultScrollAnchor(.top)
            .coordinateSpace(.named(feedSpace))
            // Purely decorative: never hit-tested, so scrolling stays untouched.
            .overlay(edgeAffordances(width: proxy.size.width).allowsHitTesting(false))
            // Tap-only recognizer; a drag is not a tap, so the pan still wins.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(feedSpace))
                    .onEnded { value in
                        handleEdgeTap(x: value.location.x, width: proxy.size.width)
                    }
            )
            // Horizontal-dominant drag opens the daily recap.
            .simultaneousGesture(vlogSwipe)
        }
    }

    /// One card per friend, whether or not they logged this hour. Friends with a
    /// clip float to the top so the live part of the hour reads first.
    private var entries: [FeedEntry] {
        let roster = friends.filter { !$0.isMe }
        return roster
            .map { friend in
                let clip = allClips
                    .filter { $0.author?.id == friend.id && hourState.containsHour(of: $0.capturedAt) }
                    .max { $0.capturedAt < $1.capturedAt }
                return FeedEntry(friend: friend, clip: clip, chat: clip?.chat ?? chat(with: friend))
            }
            .sorted { lhs, rhs in
                if (lhs.clip != nil) != (rhs.clip != nil) { return lhs.clip != nil }
                return lhs.friend.name < rhs.friend.name
            }
    }

    private func chat(with friend: Friend) -> Chat? {
        chats.first { !$0.isGroup && $0.members.contains { $0.id == friend.id } }
            ?? chats.first { $0.members.contains { $0.id == friend.id } }
    }

    /// How many logs the user has captured today (drives the montage banner).
    private var todaysClipCount: Int {
        guard let me = friends.first(where: { $0.isMe }) else { return 0 }
        let startOfDay = Calendar.current.startOfDay(for: .now)
        return allClips.filter { $0.author?.id == me.id && $0.capturedAt >= startOfDay }.count
    }

    private var montageCard: some View {
        Button {
            showMontage = true
        } label: {
            GlassCard(cornerRadius: 18) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.clipGradient(hueA: 0.75, hueB: 0.95))
                            .frame(width: 44, height: 44)
                        Image(systemName: "film.stack")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Today's vlog")
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(todaysClipCount) clip\(todaysClipCount == 1 ? "" : "s") · auto-stitched from your day")
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.iris)
                }
                .padding(12)
            }
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("🫥").font(.system(size: 44))
            Text("No friends yet")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            Text("Add someone to start an hourly feed")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, 80)
    }

    // MARK: - Time navigation gestures

    private func handleEdgeTap(x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let edgeWidth = width * 0.25
        if x <= edgeWidth {
            step(-1, edge: .leading)
        } else if x >= width - edgeWidth {
            step(1, edge: .trailing)
        }
        // The middle 50% is deliberately inert: card actions live in the rail.
    }

    private func step(_ delta: Int, edge: FeedEdge) {
        let before = hourState.selectedHour
        withAnimation(.easeInOut(duration: 0.2)) { hourState.step(delta) }
        guard hourState.selectedHour != before else { return } // clamped at "now"
        flash(edge)
    }

    private func flash(_ edge: FeedEdge) {
        withAnimation(.easeOut(duration: 0.12)) { flashedEdge = edge }
        withAnimation(.easeIn(duration: 0.3).delay(0.12)) { flashedEdge = nil }
    }

    /// Right swipe → daily recap. `minimumDistance` keeps it off small taps, and
    /// the width/height comparison keeps it off vertical scrolls.
    private var vlogSwipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = value.translation.width
                guard horizontal > 80, abs(horizontal) > abs(value.translation.height) * 1.5 else { return }
                showVlog = true
            }
    }

    /// Faint chevrons marking the two 25% hit zones; they brighten on tap.
    private func edgeAffordances(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            edgeChevron(system: "chevron.left", active: flashedEdge == .leading)
                .frame(width: width * 0.25)
            Spacer(minLength: 0)
            edgeChevron(system: "chevron.right",
                        active: flashedEdge == .trailing,
                        dimmed: hourState.isAtCurrentHour) // nothing to see in the future
                .frame(width: width * 0.25)
        }
    }

    private func edgeChevron(system: String, active: Bool, dimmed: Bool = false) -> some View {
        Image(systemName: system)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(.white)
            .opacity(active ? 0.95 : (dimmed ? 0.06 : 0.18))
            .scaleEffect(active ? 1.25 : 1)
            .shadow(radius: 6)
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            // The hourly wall is presented modally, so it carries its own ✕.
            CloseButton(size: 38) { dismiss() }
            // Calendar → the user's own stitched day (same destination as swipe-right).
            circleButton(icon: "calendar") { showVlog = true }

            Spacer(minLength: 0)

            // Scope pill, matching the wireframe's centered title chip.
            Button {
                showChatList = true
            } label: {
                HStack(spacing: 6) {
                    Text("all friends")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(Capsule().fill(Theme.baseElevated))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // Chat → the 1-on-1 / group threads that used to be this screen's
            // list. Uses the custom chat mark instead of an SF speech bubble.
            circleButton(action: { showChatList = true }) {
                ChatGlyph(size: 17, color: Theme.textPrimary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func circleButton(icon: String, action: @escaping () -> Void) -> some View {
        circleButton(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    /// Circle-button chrome shared by the calendar and chat header actions,
    /// with an arbitrary glyph so the chat entry can use the custom mark.
    private func circleButton<Glyph: View>(action: @escaping () -> Void,
                                           @ViewBuilder glyph: () -> Glyph) -> some View {
        Button(action: action) {
            glyph()
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.baseElevated))
        }
        .buttonStyle(.plain)
    }

    /// The active-hour indicator: which slice of the day every card is showing.
    private var hourBadge: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.iris)
            Text(hourState.hourLabel)
                .font(.system(size: 15, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText())
            Text(hourState.dayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            if !hourState.isAtCurrentHour {
                Button("now") { withAnimation(.easeInOut(duration: 0.2)) { hourState.resetToNow() } }
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.iris)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.baseElevated.opacity(0.9)))
        .overlay(Capsule().stroke(.white.opacity(0.06), lineWidth: 1))
        .padding(.bottom, 8)
    }
}

// MARK: - Feed entry

/// A friend's slot in the feed for the currently selected hour.
struct FeedEntry: Identifiable {
    let friend: Friend
    let clip: Clip?
    let chat: Chat?

    var id: UUID { friend.id }
}

// MARK: - Card

/// One friend, one hour, 16:9 — the unit of the feed.
private struct PulseCard: View {
    let entry: FeedEntry
    let onOpen: (Chat) -> Void
    let onReply: (Chat) -> Void

    @Environment(HourFeedState.self) private var hourState
    @Environment(\.modelContext) private var modelContext
    @Query private var friends: [Friend]

    private var me: Friend? { friends.first { $0.isMe } }

    private var isLiked: Bool {
        guard let me, let clip = entry.clip else { return false }
        return clip.reactions.contains { $0.emoji == "❤️" && $0.authorName == me.name }
    }

    var body: some View {
        // Color.clear + aspectRatio pins the card to 16:9 at any width; the media
        // fills it via the overlay so nothing letterboxes.
        Color.clear
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack {
                    media
                    scrim
                    overlayChrome
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.07), lineWidth: 1)
            )
    }

    @ViewBuilder
    private var media: some View {
        if let clip = entry.clip {
            ClipView(clip: clip, isActive: true)
                .id(clip.id) // rebuild when the hour changes to a different clip
        } else {
            // "Nothing logged this hour" — still a card, so the wall stays legible.
            ZStack {
                Theme.baseElevated
                VStack(spacing: 6) {
                    Text(entry.friend.emoji).font(.system(size: 34)).opacity(0.5)
                    Text("no log at \(hourState.hourLabel)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// Keeps the name and timestamp readable over bright footage — the middle
    /// stop carries the centered clock, so it can't be fully clear.
    private var scrim: some View {
        LinearGradient(
            colors: [.black.opacity(0.45), .black.opacity(0.18), .black.opacity(0.3)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var overlayChrome: some View {
        ZStack {
            // Centered synced timestamp + caption, as in the reference. Empty
            // cards skip it — the placeholder already states the hour.
            if let clip = entry.clip {
                VStack(spacing: 2) {
                    Text(hourState.hourLabel)
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 6, y: 2)
                        .contentTransition(.numericText())
                    if !clip.label.isEmpty {
                        Text(clip.label)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.45), radius: 5, y: 1)
                            .lineLimit(1)
                    }
                }
            }

            VStack {
                // Author chip, top-leading.
                HStack(spacing: 8) {
                    AvatarView(friend: entry.friend, size: 30)
                        .overlay(Circle().stroke(.white.opacity(0.75), lineWidth: 1.5))
                    Text(entry.friend.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 4)
                    Spacer()
                }
                Spacer()
            }
            .padding(12)

            // Action rail, trailing — the card has no full-area tap so it can
            // never compete with the edge-tap hour navigation.
            HStack {
                Spacer()
                VStack(spacing: 16) {
                    railButton("sparkles") { if let chat = entry.chat { onOpen(chat) } }
                    railButton("arrowshape.turn.up.left.fill") { if let chat = entry.chat { onReply(chat) } }
                    railButton(isLiked ? "heart.fill" : "heart", tint: isLiked ? Theme.coral : .white) {
                        toggleLike()
                    }
                }
                .padding(.trailing, 12)
            }
            .opacity(entry.clip == nil ? 0 : 1)
        }
    }

    private func railButton(_ icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(tint)
                .shadow(color: .black.opacity(0.5), radius: 4)
                .frame(width: 34, height: 30) // generous target, still inside the middle-free zone
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleLike() {
        guard let me, let clip = entry.clip else { return }
        if let index = clip.reactions.firstIndex(where: { $0.emoji == "❤️" && $0.authorName == me.name }) {
            clip.reactions.remove(at: index)
        } else {
            clip.reactions.append(Reaction(emoji: "❤️", authorName: me.name))
        }
        try? modelContext.save()
    }
}

// MARK: - Chat list

/// The chat roster that used to be the Pulse feed itself: streaks, cooldowns and
/// the way into each thread, now one tap away behind the header.
private struct ChatListSheet: View {
    let chats: [Chat]
    let onOpen: (Chat) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(chats) { chat in
                        Button { onOpen(chat) } label: { ChatRow(chat: chat) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .background(GlassBackground())
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }
}

private struct ChatRow: View {
    let chat: Chat

    private var others: [Friend] { chat.members.filter { !$0.isMe } }
    private var latest: Clip? { chat.sortedClips.first }

    var body: some View {
        HStack(spacing: 14) {
            avatarStack

            VStack(alignment: .leading, spacing: 3) {
                Text(chat.displayName)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let latest {
                    Text("\(latest.author?.name ?? "") · \(latest.label)")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text("No logs yet")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                if chat.streak > 0 {
                    HStack(spacing: 3) {
                        Text("🔥")
                        Text("\(chat.streak)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.iris)
                    }
                }
                CooldownLabel(chat: chat)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.baseElevated))
        .contentShape(RoundedRectangle(cornerRadius: 18))
    }

    private var avatarStack: some View {
        ZStack {
            if chat.isGroup {
                ForEach(Array(others.prefix(3).enumerated()), id: \.element.id) { index, friend in
                    AvatarView(friend: friend, size: 34)
                        .offset(x: CGFloat(index) * 12 - 12)
                }
            } else if let friend = others.first {
                AvatarView(friend: friend, size: 48)
            }
        }
        .frame(width: 56, height: 48)
    }
}

/// Live "59:01"-style countdown until the user can log to this chat again.
struct CooldownLabel: View {
    let chat: Chat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = chat.cooldownRemaining
            if remaining > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "hourglass").font(.caption2)
                    Text(cooldownString(remaining))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.textSecondary)
            } else {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("ready")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.green)
            }
        }
    }
}
