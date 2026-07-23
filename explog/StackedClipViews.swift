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
            GlassOrbAvatar(emoji: authorEmoji, hue: authorHue, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                if let authorName {
                    Text(authorName)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }
                if let roleLabel {
                    Text(roleLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            if let capturedAt = clip?.capturedAt {
                Text(capturedAt.clockTime)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.35)))
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
            LinearGradient(colors: [Theme.surface, Theme.background],
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
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                // Vertical paging over friends. `.scrollTargetBehavior(.paging)`
                // snaps a whole pair into place per swipe.
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(friends.enumerated()), id: \.element.id) { index, friend in
                            pairPage(for: friend, height: proxy.size.height)
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
                headerTopPadding: 44
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
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.45)))
            }

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
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - B. Group chat video feed

/// Every member's current 2-second clip in one long continuous scroll —
/// deliberately *not* paged, so a group reads as a single column you can flick
/// through end to end.
struct GroupClipFeedView: View {
    let chat: Chat

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()

    /// One clip per member, most recent first, skipping members with nothing.
    private var entries: [(friend: Friend, clip: Clip?)] {
        chat.members.map { member in
            (member, chat.sortedClips.first { $0.author?.id == member.id })
        }
        .sorted { ($0.clip?.capturedAt ?? .distantPast) > ($1.clip?.capturedAt ?? .distantPast) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                // Continuous ScrollView, no paging behavior: panes are sized to
                // a little over half the screen so the next one always peeks in
                // and the column reads as continuous.
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(entries, id: \.friend.id) { entry in
                            StackedClipPane(
                                clip: entry.clip,
                                authorName: entry.friend.name,
                                authorEmoji: entry.friend.emoji,
                                authorHue: entry.friend.hue,
                                roleLabel: entry.friend.isMe ? "you" : nil
                            )
                            .frame(height: proxy.size.height * 0.62)
                        }
                    }
                    .padding(.top, 54)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }

            header
        }
        .environment(clock)
        .task { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
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
            Color.clear.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
}

// MARK: - C. All-friends continuous feed

/// Every friend's current 2-second clip, end to end in one scroll. Same
/// continuous mechanic as the group feed, but scoped to the whole roster.
struct AllFriendsFeedView: View {
    let friends: [Friend]

    @Environment(\.dismiss) private var dismiss
    @State private var clock = ClipSyncClock()

    private var entries: [Friend] {
        friends
            .filter { !$0.isMe }
            .sorted { ($0.latestClip?.capturedAt ?? .distantPast) > ($1.latestClip?.capturedAt ?? .distantPast) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { friend in
                            StackedClipPane(
                                clip: friend.latestClip,
                                authorName: friend.name,
                                authorEmoji: friend.emoji,
                                authorHue: friend.hue,
                                roleLabel: friend.displayUserId.isEmpty ? nil : friend.displayUserId
                            )
                            .frame(height: proxy.size.height * 0.62)
                        }
                    }
                    .padding(.top, 54)
                    .padding(.bottom, 30)
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.45)))
                }
                Spacer()
                Text("All friends")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
                Color.clear.frame(width: 34, height: 34)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .environment(clock)
        .task { clock.start() }
        .onDisappear { clock.stop() }
        .preferredColorScheme(.dark)
    }
}
