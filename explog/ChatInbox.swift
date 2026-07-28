import SwiftUI
import SwiftData
import StreamChat
import StreamChatSwiftUI

// MARK: - Incoming Stream messages → local `Chat` stamps
//
// The counterpart to `OutgoingSendRecorder` in `StreamThreadView`, and the half
// that was missing. That one watches a *single* channel, and only while its
// thread is on screen — fine for recording what you send, because you can only
// send from an open thread. Nothing you receive obeys that rule: a friend's
// message arrives while you're on Pulse, on the camera, or nowhere near the
// conversation, and there was no observer alive anywhere to notice it.
//
// So this watches the whole inbox instead — every channel you're a member of —
// for as long as the app's main UI is up, and stamps `lastIncomingMessageAt` on
// the matching local `Chat`. That one field is what makes `Chat.lastActivityAt`
// genuinely any-party, which in turn is what Pulse's order and the unread dot
// both read.

extension View {
    /// Keeps every local `Chat` in step with messages friends send, whether or
    /// not that thread is open. Attach once, high enough up to outlive any
    /// single screen.
    func watchesIncomingMessages() -> some View {
        modifier(IncomingMessageWatcher())
    }
}

private struct IncomingMessageWatcher: ViewModifier {
    @Environment(\.modelContext) private var modelContext
    @State private var observer: ChannelInboxObserver?

    func body(content: Content) -> some View {
        content.task {
            guard StreamConfig.isEnabled, observer == nil else { return }
            let client = InjectedValues[\.chatClient]
            guard let currentUserId = client.currentUserId else { return }

            let controller = client.channelListController(
                query: ChannelListQuery(filter: .containMembers(userIds: [currentUserId]))
            )
            observer = ChannelInboxObserver(controller: controller) { stamps in
                record(stamps)
            }
            // Replays the channels already cached as changes, so threads that
            // predate this — and anything that arrived while the app was shut —
            // are backfilled rather than only counting from now on.
            controller.synchronize()
        }
    }

    /// Maps `channel id → newest incoming message` onto the local chats.
    ///
    /// The join is on `Chat.streamChannelId`, which is computed from the
    /// members rather than stored, so it can't be pushed into a `#Predicate` —
    /// hence the fetch-and-match. The chat table is one row per conversation,
    /// and this only runs when a batch of channels actually changed.
    private func record(_ stamps: [String: Date]) {
        guard !stamps.isEmpty else { return }
        let chats = (try? modelContext.fetch(FetchDescriptor<Chat>())) ?? []
        var touched = false
        for chat in chats {
            guard let sentAt = stamps[chat.streamChannelId] else { continue }
            chat.noteIncomingMessage(at: sentAt)
            touched = true
        }
        if touched { try? modelContext.save() }
    }
}

/// Bridges `ChatChannelListControllerDelegate` into a plain closure, the same
/// way `OutgoingMessageObserver` does for a single channel.
@MainActor
final class ChannelInboxObserver: NSObject, ChatChannelListControllerDelegate {
    private let controller: ChatChannelListController
    private let onIncoming: ([String: Date]) -> Void

    init(controller: ChatChannelListController,
         onIncoming: @escaping ([String: Date]) -> Void) {
        self.controller = controller
        self.onIncoming = onIncoming
        super.init()
        controller.delegate = self
    }

    nonisolated func controller(_ controller: ChatChannelListController,
                               didChangeChannels changes: [ListChange<ChatChannel>]) {
        var newest: [String: Date] = [:]
        for change in changes {
            let channel = change.item
            guard let sentAt = Self.newestIncoming(in: channel) else { continue }
            let id = channel.cid.id
            if sentAt > (newest[id] ?? .distantPast) { newest[id] = sentAt }
        }
        guard !newest.isEmpty else { return }
        Task { @MainActor in onIncoming(newest) }
    }

    /// When a *friend* last said something on this channel.
    ///
    /// Read from `latestMessages` rather than the channel's `lastMessageAt`,
    /// because that timestamp doesn't care who sent it: your own reply would
    /// register as though the friend had just written to you, and light the
    /// unread dot on a thread you had just answered.
    nonisolated private static func newestIncoming(in channel: ChatChannel) -> Date? {
        channel.latestMessages
            .filter { !$0.isSentByCurrentUser }
            .map(\.createdAt)
            .max()
    }
}
