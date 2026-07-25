import SwiftUI
import SwiftData

/// Full-screen log player. Vertical paging moves between chats (sketch: "scroll to
/// next person"); inside a chat, horizontal swipes travel back through clip history.
struct LogPlayerView: View {
    let startingChat: Chat

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @State private var visibleChatID: UUID?

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(chats) { chat in
                        Group {
                            if chat.isGroup {
                                GroupLogPage(chat: chat, isActive: visibleChatID == chat.id)
                            } else {
                                SoloLogPage(chat: chat, isActive: visibleChatID == chat.id)
                            }
                        }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(chat.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleChatID)
        }
        .ignoresSafeArea()
        .background(Theme.base.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Circle().fill(.black.opacity(0.35)))
            }
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
        .onAppear { visibleChatID = startingChat.id }
        .preferredColorScheme(.dark)
    }
}

// MARK: - 1-on-1 page

private struct SoloLogPage: View {
    let chat: Chat
    let isActive: Bool

    @State private var clipIndex = 0
    @State private var showChat = false

    /// Newest first: index 0 is "now", swiping right reveals earlier hours.
    private var clips: [Clip] { chat.sortedClips }

    var body: some View {
        ZStack {
            if clips.isEmpty {
                emptyState
            } else {
                TabView(selection: $clipIndex) {
                    ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                        ClipView(clip: clip, isActive: isActive && index == clipIndex)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()

                LogOverlay(chat: chat,
                           clip: clips[min(clipIndex, clips.count - 1)],
                           clipIndex: clipIndex,
                           clipCount: clips.count,
                           showChat: $showChat)
            }
        }
        .sheet(isPresented: $showChat) {
            ChatDrawerView(chat: chat)
        }
        .onChange(of: isActive) { _, active in
            if active { clipIndex = 0 }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Text("👋").font(.system(size: 60))
            Text("No logs with \(chat.displayName) yet")
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Shared overlay (name, time, reactions, chat)

private struct LogOverlay: View {
    let chat: Chat
    let clip: Clip
    let clipIndex: Int
    let clipCount: Int
    @Binding var showChat: Bool
    var showHeader = true

    var body: some View {
        VStack {
            if showHeader { header }
            Spacer()
            footer
        }
        .overlay(alignment: .trailing) {
            ReactionRail(clip: clip, showChat: $showChat)
                .padding(.trailing, 14)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let author = clip.author {
                AvatarView(friend: author, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(author.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(clip.capturedAt.relativeHour)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer()
            // Report/block the log itself. Only for content that actually came
            // from someone else's account — there's nothing to report about a
            // local capture or a demo row.
            if clip.isRemote, !clip.remoteID.isEmpty, !clip.authorUID.isEmpty {
                SafetyMenuButton(target: .log(id: clip.remoteID,
                                              authorUid: clip.authorUID,
                                              authorName: clip.author?.name ?? "this member"))
            }
            if clipCount > 1 {
                Text("\(clipIndex + 1)/\(clipCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.35)))
            }
        }
        // Room for the close button pinned at topTrailing by the player.
        .padding(.trailing, 40)
        .padding(.horizontal, 16)
        .padding(.top, 54)
        .background(
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !clip.reactions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(Set(clip.reactions.map(\.emoji))).sorted(), id: \.self) { emoji in
                        let count = clip.reactions.filter { $0.emoji == emoji }.count
                        Text(count > 1 ? "\(emoji) \(count)" : emoji)
                            .font(.subheadline)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(.white.opacity(0.15)))
                    }
                }
            }
            HStack {
                Text(clip.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Spacer()
                if chat.streak > 0 {
                    Text("🔥 \(chat.streak)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            if clipIndex == 0 && clipCount > 1 {
                Text("swipe for earlier hours →")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }
}

/// Right-edge rail from the sketch: ♥ + 💬, long-press the heart for the emoji row.
struct ReactionRail: View {
    let clip: Clip
    @Binding var showChat: Bool

    @State private var expanded = false
    private let quickEmoji = ["❤️", "🙌", "😂", "😮", "🔥"]

    var body: some View {
        VStack(spacing: 18) {
            if expanded {
                VStack(spacing: 12) {
                    ForEach(quickEmoji, id: \.self) { emoji in
                        Button {
                            react(with: emoji)
                        } label: {
                            Text(emoji).font(.system(size: 26))
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(Capsule().fill(.black.opacity(0.45)))
                .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
            }

            Button {
                react(with: "❤️")
            } label: {
                Image(systemName: myReactionCount > 0 ? "heart.fill" : "heart")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(myReactionCount > 0 ? Theme.coral : .white)
                    .shadow(radius: 4)
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3).onEnded { _ in
                    withAnimation(.spring(duration: 0.3)) { expanded.toggle() }
                }
            )

            Button {
                showChat = true
            } label: {
                ChatGlyph(size: 25, color: .white)
                    .shadow(radius: 4)
            }
        }
    }

    private var myReactionCount: Int {
        clip.reactions.filter { $0.authorName == "Ethan" }.count
    }

    private func react(with emoji: String) {
        let mine = Reaction(emoji: emoji, authorName: "Ethan")
        if let index = clip.reactions.firstIndex(of: mine) {
            clip.reactions.remove(at: index)
        } else {
            clip.reactions.append(mine)
        }
        withAnimation(.spring(duration: 0.3)) { expanded = false }
    }
}

// MARK: - Group page (sequential reel by default, 2×2 grid to compare)

private struct GroupLogPage: View {
    let chat: Chat
    let isActive: Bool

    @State private var mode: Mode
    @State private var reelIndex = 0
    @State private var showChat = false

    enum Mode: String, CaseIterable {
        case reel = "Reel"
        case grid = "Grid"
    }

    init(chat: Chat, isActive: Bool) {
        self.chat = chat
        self.isActive = isActive
        var initialMode = Mode.reel
#if DEBUG
        if ProcessInfo.processInfo.environment["EXPLOG_GROUP_MODE"] == "grid" {
            initialMode = .grid
        }
#endif
        _mode = State(initialValue: initialMode)
    }

    /// Latest clip per member, most recent first — the "group pulse".
    private var latestPerMember: [Clip] {
        chat.members.compactMap { chat.latestClip(by: $0) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }

    var body: some View {
        ZStack {
            switch mode {
            case .reel: reelBody
            case .grid: gridBody
            }

            VStack {
                header
                Spacer()
            }
        }
        .sheet(isPresented: $showChat) {
            ChatDrawerView(chat: chat)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode == .reel && latestPerMember.count > 1 {
                HStack(spacing: 4) {
                    ForEach(0..<latestPerMember.count, id: \.self) { index in
                        Capsule()
                            .fill(index <= reelIndex ? Theme.accent : .white.opacity(0.3))
                            .frame(height: 3)
                    }
                }
            }
            HStack(spacing: 10) {
                Text(chat.displayName)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("🔥 \(chat.streak)")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Picker("Mode", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)
                .padding(.trailing, 44)
            }
            if mode == .reel, let clip = currentReelClip, let author = clip.author {
                HStack(spacing: 8) {
                    AvatarView(friend: author, size: 30)
                    Text(author.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(clip.capturedAt.relativeHour)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 58)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
        )
    }

    private var currentReelClip: Clip? {
        let clips = latestPerMember
        guard !clips.isEmpty else { return nil }
        return clips[min(reelIndex, clips.count - 1)]
    }

    // Sequential reel: everyone's latest clip, auto-advancing every 3 seconds.
    private var reelBody: some View {
        let clips = latestPerMember
        return ZStack {
            if clips.isEmpty {
                Text("No logs yet today")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                let clip = clips[min(reelIndex, clips.count - 1)]
                ClipView(clip: clip, isActive: isActive)
                    .id(clip.id)
                    .transition(.opacity)
                    .ignoresSafeArea()

                LogOverlay(chat: chat, clip: clip,
                           clipIndex: reelIndex, clipCount: clips.count,
                           showChat: $showChat, showHeader: false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { advanceReel(clipCount: clips.count) }
        .task(id: "\(isActive)-\(reelIndex)-\(mode)") {
            guard isActive, mode == .reel, clips.count > 1 else { return }
            try? await Task.sleep(for: .seconds(clipDuration))
            advanceReel(clipCount: clips.count)
        }
    }

    private func advanceReel(clipCount: Int) {
        guard clipCount > 0 else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            reelIndex = (reelIndex + 1) % clipCount
        }
    }

    // 2×2 synchronized grid; vertical scroll reveals members beyond four (per sketch).
    private var gridBody: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)],
                      spacing: 2) {
                ForEach(latestPerMember, id: \.id) { clip in
                    GridCell(clip: clip, isActive: isActive)
                }
            }
            .padding(.top, 120)
            .padding(.bottom, 40)
        }
        .background(Color.black)
        .scrollIndicators(.hidden)
    }
}

private struct GridCell: View {
    let clip: Clip
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ClipView(clip: clip, isActive: isActive)
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.author?.name ?? "")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                Text(clip.capturedAt.relativeHour)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                if !clip.reactions.isEmpty {
                    Text(clip.reactions.map(\.emoji).joined())
                        .font(.caption)
                }
            }
            .padding(10)
        }
        .frame(height: 330)
        .clipped()
    }
}
