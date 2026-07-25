import SwiftUI
import SwiftData

// MARK: - Shared message thread engine
// Used by both the log player's bottom drawer and the full ChatDetailView,
// so message history and input behave identically everywhere.

struct MessageThreadView: View {
    let chat: Chat

    @Environment(\.modelContext) private var modelContext
    @Query private var friends: [Friend]
    @State private var draft = ""

    private var me: Friend? { friends.first { $0.isMe } }
    private var messages: [Message] { chat.messages.sorted { $0.sentAt < $1.sentAt } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(messages) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onAppear {
                    if let last = messages.last { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: messages.count) {
                    if let last = messages.last {
                        withAnimation { scrollProxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            // Real-time input bar with send — sunken field, coral send.
            HStack(spacing: 10) {
                TextField("Message…", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().fill(Theme.sunken)
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(send)
                SendButton(enabled: !draft.isEmpty, action: send)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Rectangle().fill(Theme.surface).ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let message = Message(chat: chat, author: me, text: text)
        modelContext.insert(message)
        chat.messages.append(message)
        try? modelContext.save()
        draft = ""
    }
}

/// The one coral control in a thread: a solid disc that dims to sunken when
/// there's nothing to send. Shared by every composer in the app.
struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? Theme.onAccent : Theme.textSecondary)
                .frame(width: 38, height: 38)
                .background {
                    Circle()
                        .fill(enabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.sunken))
                        .shadow(color: enabled ? Theme.accent.opacity(0.35) : .clear, radius: 10, y: 2)
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .animation(.easeOut(duration: 0.18), value: enabled)
        .accessibilityLabel("Send")
    }
}

// MARK: - Bottom drawer (inside the log player)

struct ChatDrawerView: View {
    let chat: Chat

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if StreamConfig.isEnabled {
                    // Presence and typing come off the live channel; the plain
                    // title is all a local-only thread can offer.
                    ChatPresenceHeader(channelId: chat.streamChannelId,
                                       name: chat.displayName)
                } else {
                    Text(chat.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .padding(.top, 18)
            .padding(.bottom, 10)

            if StreamConfig.isEnabled {
                // Real messaging over Stream Chat.
                StreamThreadView(channelId: chat.streamChannelId,
                                 name: chat.displayName,
                                 memberIds: chat.streamMemberIds)
            } else {
                MessageThreadView(chat: chat)
            }
        }
        .background(GlassBackground())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        // Opening the drawer is reading the thread — clear its unread dot.
        .onAppear {
            chat.markRead()
            try? modelContext.save()
        }
    }
}

// MARK: - Full-screen 1-on-1 direct messages (new: pushed from the Pulse list)

struct ChatDetailView: View {
    let chat: Chat
    /// Set when the thread is presented modally (from the Pulse list) so it
    /// gets an ✕. When pushed onto a nav stack this stays nil and the system
    /// back button handles dismissal — no double affordance.
    var onClose: (() -> Void)?

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if StreamConfig.isEnabled {
                // Real messaging over Stream Chat.
                StreamThreadView(channelId: chat.streamChannelId,
                                 name: chat.displayName,
                                 memberIds: chat.streamMemberIds)
            } else {
                MessageThreadView(chat: chat)
            }
        }
            .background(GlassBackground())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A principal item rather than `navigationTitle`, so the online
                // dot and "typing…" can live under the name.
                ToolbarItem(placement: .principal) {
                    if StreamConfig.isEnabled {
                        ChatPresenceHeader(channelId: chat.streamChannelId,
                                           name: chat.displayName)
                    } else {
                        Text(chat.displayName)
                            .font(.headline)
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) {
                        CloseButton(size: 32, action: onClose)
                    }
                }
                // Streak lives in the nav bar so the thread stays clean.
                ToolbarItem(placement: .topBarTrailing) {
                    if chat.streak > 0 {
                        Text("🔥 \(chat.streak)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.coral)
                    }
                }
            }
            // Opening the thread is reading it — clear its unread dot, and
            // stay caught up so returning to Pulse doesn't show it again.
            .onAppear {
                chat.markRead()
                try? modelContext.save()
            }
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: Message

    @State private var showSpotDetail = false
    @State private var showProfile = false
    @State private var safety = SafetyPresentation()

    private var isMine: Bool { message.author?.isMe ?? false }
    private let tapbacks = ["❤️", "👍", "😂", "‼️", "❓"]

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine, let author = message.author {
                    Button { showProfile = true } label: {
                        Text(author.name)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                if let spotName = message.sharedSpotName {
                    // A shared-location card. When the real spot rode along with
                    // the message it's a button into the same detail sheet the
                    // Places feed opens; legacy/name-only shares stay static.
                    locationCard(name: spotName)
                }
                // A reaction broadcast: the reacted clip's preview with the
                // reaction emoji overlaid on top of it, per spec.
                if message.isReaction, let emoji = message.reactionEmoji {
                    reactionCard(clip: message.reactedClip, emoji: emoji)
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Mine in coral, theirs on a sunken surface — the thread
                        // reads as two voices without a second accent colour.
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isMine ? AnyShapeStyle(Theme.accent)
                                             : AnyShapeStyle(Theme.sunken))
                        }
                        .foregroundStyle(isMine ? Theme.onAccent : Theme.textPrimary)
                        // iMessage-style tapback badge, on a surface chip so it
                        // never competes with the bubble beneath it.
                        .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                            if let tapback = message.tapback {
                                Text(tapback)
                                    .font(.caption)
                                    .padding(5)
                                    .background {
                                        Circle().fill(Theme.surface)
                                            .shadow(color: Color(hex: 0x14121E, alpha: 0.12), radius: 4, y: 1)
                                    }
                                    .offset(x: isMine ? -10 : 10, y: -12)
                            }
                        }
                        // Long-press for tapbacks + copy, like Messages.
                        .contextMenu {
                            ForEach(tapbacks, id: \.self) { emoji in
                                Button(emoji) {
                                    message.tapback = message.tapback == emoji ? nil : emoji
                                }
                            }
                            Button {
                                UIPasteboard.general.string = message.text
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            // Same long-press that carries tapbacks also
                            // carries the way out, for messages from a real
                            // account that isn't yours.
                            if let author = message.author,
                               !author.isMe, !author.remoteUID.isEmpty {
                                Divider()
                                SafetyMenuItems(
                                    target: .message(id: message.id.uuidString,
                                                     authorUid: author.remoteUID,
                                                     authorName: author.name),
                                    presentation: safety
                                )
                            }
                        }
                }
                Text(message.sentAt.clockTime)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !isMine { Spacer(minLength: 60) }
        }
        // Reuses the Places detail view verbatim — one source of truth for a
        // spot's metadata, AI insight, and visitor clips.
        .sheet(isPresented: $showSpotDetail) {
            if let spot = message.sharedSpot {
                SpotDetailView(spot: spot)
            }
        }
        .fullScreenCover(isPresented: $showProfile) {
            if let author = message.author {
                PublicProfileSheet(friend: author)
            }
        }
        .modifier(SafetySheets(presentation: safety))
    }

    /// A reaction broadcast bubble: a small looping preview of the friend's log
    /// with the reaction emoji stamped on its bottom-left, mirroring where the
    /// badge lands on the video container itself. Falls back to an emoji-only
    /// chip if the underlying clip is gone.
    @ViewBuilder
    private func reactionCard(clip: Clip?, emoji: String) -> some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
            Text(isMine ? "You reacted" : "Reacted")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)

            if let clip {
                ClipView(clip: clip, isActive: true)
                    .frame(width: 118, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
                    // Reaction context overlaid on the preview, bottom-left.
                    .overlay(alignment: .bottomLeading) {
                        Text(emoji)
                            .font(.system(size: 24))
                            .padding(7)
                            .background(Circle().fill(.black.opacity(0.55)))
                            .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                            .padding(8)
                    }
                    .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
            } else {
                Text(emoji)
                    .font(.system(size: 30))
                    .padding(10)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
            }
        }
    }

    /// The location preview card. Tappable when the spot data came along.
    @ViewBuilder
    private func locationCard(name: String) -> some View {
        let card = HStack(spacing: 6) {
            Image(systemName: "mappin.circle.fill")
                .foregroundStyle(Theme.accent)
            Text(name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
            if message.sharedSpot != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background { GlassCard(cornerRadius: 12) { Color.clear } }

        if message.sharedSpot != nil {
            Button { showSpotDetail = true } label: { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }
}
