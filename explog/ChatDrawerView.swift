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

            // Real-time input bar with send.
            HStack(spacing: 10) {
                TextField("Message…", text: $draft)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.surfaceLight))
                    .foregroundStyle(Theme.textPrimary)
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(draft.isEmpty ? Theme.textSecondary : Theme.accent)
                }
                .disabled(draft.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
        .background(Theme.surface)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Full-screen 1-on-1 direct messages (new: pushed from the Pulse list)

struct ChatDetailView: View {
    let chat: Chat

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
            // Clear the floating tab bar so the input bar stays reachable.
            .padding(.bottom, 84)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle(chat.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Streak lives in the nav bar so the thread stays clean.
                ToolbarItem(placement: .topBarTrailing) {
                    if chat.streak > 0 {
                        Text("🔥 \(chat.streak)")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.accent)
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
                            .foregroundStyle(Theme.accent)
                        Text(spotName)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceLight))
                }
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isMine ? Theme.accent : Theme.surfaceLight)
                        )
                        .foregroundStyle(isMine ? .black : Theme.textPrimary)
                        // iMessage-style tapback badge.
                        .overlay(alignment: isMine ? .topLeading : .topTrailing) {
                            if let tapback = message.tapback {
                                Text(tapback)
                                    .font(.caption)
                                    .padding(5)
                                    .background(Circle().fill(Theme.surface))
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
