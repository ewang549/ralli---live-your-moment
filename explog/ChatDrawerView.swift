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

            // Real-time input bar with send — glass field, gold send.
            HStack(spacing: 10) {
                TextField("Message…", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background {
                        Capsule().fill(.ultraThinMaterial)
                            .overlay {
                                Capsule().strokeBorder(Theme.glassRimTop.opacity(0.35), lineWidth: 1)
                            }
                    }
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(send)
                SendButton(enabled: !draft.isEmpty, action: send)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background {
                Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(edges: .bottom)
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

/// The one gold control in a thread: a metal disc that dims to glass when
/// there's nothing to send. Shared by every composer in the app.
struct SendButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(enabled ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.textSecondary))
                .frame(width: 38, height: 38)
                .background {
                    Circle()
                        .fill(enabled ? AnyShapeStyle(Theme.goldSheen) : AnyShapeStyle(Material.ultraThinMaterial))
                        .shadow(color: enabled ? Theme.goldGlow.opacity(0.5) : .clear, radius: 10)
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

    var body: some View {
        VStack(spacing: 0) {
            Text(chat.displayName)
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
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
        .preferredColorScheme(.dark)
    }
}

// MARK: - Full-screen 1-on-1 direct messages (new: pushed from the Pulse list)

struct ChatDetailView: View {
    let chat: Chat
    /// Set when the thread is presented modally (from the Pulse list) so it
    /// gets an ✕. When pushed onto a nav stack this stays nil and the system
    /// back button handles dismissal — no double affordance.
    var onClose: (() -> Void)?

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
            .navigationTitle(chat.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                            .foregroundStyle(Theme.gold)
                    }
                }
            }
            .preferredColorScheme(.dark)
    }
}

// MARK: - Bubble

struct MessageBubble: View {
    let message: Message

    private var isMine: Bool { message.author?.isMe ?? false }
    private let tapbacks = ["❤️", "👍", "😂", "‼️", "❓"]

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 60) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 3) {
                if !isMine, let author = message.author {
                    Text(author.name)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let spotName = message.sharedSpotName {
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundStyle(Theme.gold)
                        Text(spotName)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background { GlassCard(cornerRadius: 12) { Color.clear } }
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        // Mine in gold metal, theirs in glass — the thread reads
                        // as two voices without a second accent colour.
                        .background {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(isMine ? AnyShapeStyle(Theme.goldSheen)
                                             : AnyShapeStyle(Material.ultraThinMaterial))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(isMine ? Color.clear : Theme.glassRimTop.opacity(0.3),
                                                      lineWidth: 1)
                                }
                                .shadow(color: isMine ? Theme.goldGlow.opacity(0.28) : .black.opacity(0.3),
                                        radius: 8, y: 3)
                        }
                        .foregroundStyle(isMine ? .black : Theme.textPrimary)
                        // iMessage-style tapback badge, on neutral glass so it
                        // never competes with the gold bubble beneath it.
                        .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                            if let tapback = message.tapback {
                                Text(tapback)
                                    .font(.caption)
                                    .padding(5)
                                    .background {
                                        Circle().fill(.ultraThinMaterial)
                                            .overlay { Circle().strokeBorder(Theme.glassRimTop.opacity(0.4), lineWidth: 1) }
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
                        }
                }
                Text(message.sentAt.clockTime)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !isMine { Spacer(minLength: 60) }
        }
    }
}
