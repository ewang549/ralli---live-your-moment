import SwiftUI
import SwiftData

/// After capture: pick who gets this log. Each chat enforces its own 1-hour cooldown
/// (you choose when to log — you just can't send twice to the same chat within an hour).
struct SendLogView: View {
    let media: CapturedMedia
    let onSent: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Chat.createdAt) private var chats: [Chat]
    @Query private var friends: [Friend]

    @State private var selected: Set<UUID> = []
    @State private var label = ""
    @State private var emoji = "✨"
    @State private var hueA = Double.random(in: 0...1)

    private let emojiOptions = ["✨", "💻", "☕️", "🏃", "🎧", "🌳", "🍜", "🌆", "📚", "🎮"]
    private var me: Friend? { friends.first { $0.isMe } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                if media.kind == .vibe {
                    vibeComposer
                }

                TextField("What are you up to?", text: $label)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.baseRaised))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)

                List {
                    Section("Send to") {
                        ForEach(chats) { chat in
                            AudienceRow(chat: chat, isSelected: selected.contains(chat.id)) {
                                toggle(chat)
                            }
                        }
                    }
                    .listRowBackground(Theme.baseElevated)
                }
                .scrollContentBackground(.hidden)

                Button {
                    send()
                } label: {
                    Text(selected.isEmpty ? "Pick at least one chat" : "Send to \(selected.count) chat\(selected.count == 1 ? "" : "s")")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(selected.isEmpty ? Theme.textSecondary : Theme.gold))
                }
                .disabled(selected.isEmpty)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            .background(GlassBackground())
            .navigationTitle("Send log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var preview: some View {
        switch media.kind {
        case .vibe:
            VibeClipView(emoji: emoji, label: label, hueA: hueA,
                         hueB: (hueA + 0.15).truncatingRemainder(dividingBy: 1))
        case .video, .photo:
            let clip = Clip(author: nil, chat: nil, capturedAt: .now, kind: media.kind,
                            assetFileName: media.assetFileName, label: label, emoji: emoji,
                            hueA: hueA, hueB: hueA)
            ClipView(clip: clip)
        }
    }

    private var vibeComposer: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(emojiOptions, id: \.self) { option in
                    Button {
                        emoji = option
                        hueA = Double.random(in: 0...1)
                    } label: {
                        Text(option)
                            .font(.system(size: 26))
                            .padding(8)
                            .background(
                                Circle().fill(emoji == option ? Theme.gold.opacity(0.35) : Theme.baseRaised)
                            )
                    }
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 14)
    }

    private func toggle(_ chat: Chat) {
        guard chat.cooldownRemaining <= 0 else { return }
        if selected.contains(chat.id) {
            selected.remove(chat.id)
        } else {
            selected.insert(chat.id)
        }
    }

    private func send() {
        let finalLabel = label.isEmpty ? "right now" : label
        let calendar = Calendar.current
        for chat in chats where selected.contains(chat.id) {
            // Streak bumps on the first log of the day to that chat.
            let loggedTodayAlready = chat.clips.contains {
                $0.author?.isMe == true && calendar.isDateInToday($0.capturedAt)
            }
            let clip = Clip(author: me, chat: chat, capturedAt: .now, kind: media.kind,
                            assetFileName: media.assetFileName, label: finalLabel, emoji: emoji,
                            hueA: hueA, hueB: (hueA + 0.15).truncatingRemainder(dividingBy: 1))
            modelContext.insert(clip)
            chat.clips.append(clip)
            chat.lastSentAt = .now
            if !loggedTodayAlready { chat.streak += 1 }
        }
        try? modelContext.save()
        dismiss()
        onSent()
    }
}

private struct AudienceRow: View {
    let chat: Chat
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let remaining = chat.cooldownRemaining
            let locked = remaining > 0
            Button(action: onTap) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chat.displayName)
                            .foregroundStyle(locked ? Theme.textSecondary : Theme.textPrimary)
                        if locked {
                            Text("next log in \(cooldownString(remaining))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        } else if chat.streak > 0 {
                            Text("🔥 \(chat.streak)")
                                .font(.caption)
                                .foregroundStyle(Theme.gold)
                        }
                    }
                    Spacer()
                    if locked {
                        Image(systemName: "hourglass")
                            .foregroundStyle(Theme.textSecondary)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Theme.gold : Theme.textSecondary)
                    }
                }
            }
            .disabled(locked)
        }
    }
}
