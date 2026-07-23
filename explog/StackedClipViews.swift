import SwiftUI
import SwiftData

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

    @Environment(ClipSyncClock.self) private var clock

    var body: some View {
        ZStack {
            if let clip {
                ClipView(clip: clip, isActive: true)
                    // Keying on the clock's cycle is what synchronizes the
                    // stack: every pane rebuilds its player on the same tick,
                    // so all clips restart together instead of drifting.
                    .id("\(clip.id)-\(clock.cycle)")
            } else {
                noClipPlaceholder
            }

            // Legibility scrim — captions sit over live video.
            LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)

            VStack {
                header
                    .padding(.top, headerTopPadding)
                Spacer()
                if let caption = clip?.label, !caption.isEmpty {
                    captionOverlay(caption)
                }
            }
            .padding(14)
        }
        .clipped()
        .contentShape(Rectangle())
    }

    private var header: some View {
        HStack(spacing: 9) {
            // Gold ring marks the author who actually posted this slot.
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
            Spacer()
            if let capturedAt = clip?.capturedAt {
                Text(capturedAt.clockTime)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.gold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay { Capsule().strokeBorder(Theme.gold.opacity(0.3), lineWidth: 1) }
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

// MARK: - A. 1-on-1 split stack with vertical paging

/// Your 2-second clip on top, the friend's underneath, with the whole pair
/// paging vertically to the next friend — TikTok-style, but each "page" is a
/// pair rather than a single video.
///
/// Your clip and the timestamp banner stay put across pages; only the bottom
/// half swaps as you swipe, which is what makes it read as "same moment, next
/// person" instead of an unrelated feed.
struct FriendPairFeedView: View {
    let friends: [Friend]
    let me: Friend?
    /// Friend to open on first appearance.
    var startingFriend: Friend?

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()
    @State private var currentIndex: Int = 0

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
                // Pages fill the safe area rather than the raw screen, so a
                // pane's author chip never lands under the status bar.
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
        .task {
            if let startingFriend, let index = friends.firstIndex(where: { $0.id == startingFriend.id }) {
                currentIndex = index
            }
            clock.start()
        }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }

    /// One page: two vertically stacked panes splitting the screen evenly.
    private func pairPage(for friend: Friend, height: CGFloat) -> some View {
        VStack(spacing: 2) {
            // Top half — you. Stays conceptually fixed across pages.
            StackedClipPane(
                clip: me?.latestClip,
                authorName: me?.name ?? "You",
                authorEmoji: me?.emoji ?? "🙂",
                authorHue: me?.hue ?? 0.58,
                roleLabel: "you",
                // Clears the floating timestamp banner above it.
                headerTopPadding: 96
            )
            .frame(height: (height - 2) / 2)

            // Bottom half — the friend this page belongs to.
            StackedClipPane(
                clip: friend.latestClip,
                authorName: friend.name,
                authorEmoji: friend.emoji,
                authorHue: friend.hue,
                roleLabel: friend.displayUserId.isEmpty ? nil : friend.displayUserId
            )
            .frame(height: (height - 2) / 2)
        }
        .frame(height: height)
    }

    /// Synchronized timestamp banner, pinned above both panes.
    private var timestampBanner: some View {
        HStack(spacing: 10) {
            CloseButton(overMedia: true) { dismiss() }

            Spacer()

            HStack(spacing: 7) {
                GlowDot(size: 7, breathing: true)
                Text(Date.now.clockTime)
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

// MARK: - B. Group chat video feed

/// Every member's current 2-second clip, one clip per full screen, paging
/// vertically. One member fills the screen at a time — you never see the edge
/// of the next or previous clip while at rest.
struct GroupClipFeedView: View {
    let chat: Chat

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()
    @State private var currentIndex: Int = 0

    /// One clip per member, most recent first, skipping members with nothing.
    private var entries: [(friend: Friend, clip: Clip?)] {
        chat.members.map { member in
            (member, chat.sortedClips.first { $0.author?.id == member.id })
        }
        .sorted { ($0.clip?.capturedAt ?? .distantPast) > ($1.clip?.capturedAt ?? .distantPast) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.base.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.friend.id) { index, entry in
                            StackedClipPane(
                                clip: entry.clip,
                                authorName: entry.friend.name,
                                authorEmoji: entry.friend.emoji,
                                authorHue: entry.friend.hue,
                                roleLabel: entry.friend.isMe ? "you" : nil,
                                // Clears the floating title bar above.
                                headerTopPadding: 96
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
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
                // One clip per swipe, snapped — no peek at the neighbours.
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.hidden)
                .scrollPosition(id: syncedIndex)
            }
            .ignoresSafeArea()

            header
        }
        .environment(clock)
        .task { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
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
    @State private var clock = ClipSyncClock()
    @State private var currentIndex: Int = 0

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
                                headerTopPadding: 96
                            )
                            .frame(width: proxy.size.width, height: proxy.size.height)
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
        .task { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
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
