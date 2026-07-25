import SwiftUI
import StreamChat
import StreamChatSwiftUI
import os

private let chatLog = Logger(subsystem: "com.ej.explog", category: "chat")

// Minimum custom factory (required members per SDK: `styles` has no default).
// Central place for future ViewFactory customizations.
//
// The "Explog" prefix is deliberate: the Ralli rebrand is user-facing only.
// Internal identifiers keep the old name so the bundle id, the Firebase
// project (explog-723b7), the Cloud Function names, and the Stream app all
// keep resolving. Rename these and the backend stops answering.
final class ExplogViewFactory: ViewFactory {
    @Injected(\.chatClient) var chatClient
    var styles = RegularStyles()
    static let shared = ExplogViewFactory()
    private init() {}

    /// Adds Ralli's own Report and Block to the SDK's message actions.
    ///
    /// The SDK ships a Flag action, but that files with Stream's moderation
    /// service — App Store Guideline 1.2 wants the report reaching *us*, and
    /// wants blocking available from the same place. Both are appended rather
    /// than replacing the defaults, so copy, edit and reactions all stay.
    ///
    /// The actions can't own presentation state (this factory is a singleton
    /// with no view), so they hand the target to `SafetyPresentation.chat`,
    /// which `StreamThreadView` is watching.
    func makeMessageActionsView(options: MessageActionsViewOptions) -> some View {
        var actions = InjectedValues[\.utils].messageListConfig.supportedMessageActions(
            SupportedMessageActionsOptions(
                message: options.message,
                channel: options.channel,
                onFinish: options.onFinish,
                onError: options.onError
            )
        )

        let authorId = options.message.author.id
        // Nothing to report or block about your own message.
        if authorId != chatClient.currentUserId {
            let target = SafetyTarget.message(id: options.message.id,
                                              authorUid: authorId,
                                              authorName: options.message.author.name ?? "this member")

            actions.append(MessageAction(
                id: "ralli.report",
                title: "Report to Ralli",
                iconName: "flag",
                action: {
                    // Dismiss the actions overlay first — presenting a sheet
                    // from underneath it lands on nothing.
                    options.onFinish(MessageActionInfo(message: options.message,
                                                       identifier: "ralli.report"))
                    SafetyPresentation.chat.reporting = target
                },
                confirmationPopup: nil,
                isDestructive: true
            ))

            actions.append(MessageAction(
                id: "ralli.block",
                title: "Block \(target.displayName)",
                iconName: "hand.raised",
                action: {
                    options.onFinish(MessageActionInfo(message: options.message,
                                                       identifier: "ralli.block"))
                    SafetyPresentation.chat.blocking = target
                },
                confirmationPopup: nil,
                isDestructive: true
            ))
        }

        return MessageActionsView(messageActions: actions)
    }
}

/// Real messaging surface: renders a Stream channel with the SDK's full
/// message list + composer (typing, receipts, reactions, attachments).
/// Creating a controller for an id that already exists is safe, so every
/// app chat maps lazily onto a Stream channel the first time it opens.
struct StreamThreadView: View {
    @Injected(\.chatClient) var chatClient

    let channelId: String
    let name: String
    let memberIds: [String]

    @State private var controller: ChatChannelController?
    @State private var failed = false
    /// `controller` is now only published after the channel syncs, so it can't
    /// double as the "already connecting" flag the way it used to — without
    /// this, a re-entrant `.task` would open a second channel mid-sync.
    @State private var isConnecting = false

    var body: some View {
        Group {
            if let controller {
                ChatChannelView(viewFactory: ExplogViewFactory.shared, channelController: controller)
                    // Report/Block raised from a message action. The thread
                    // serves many authors, so the target comes from whichever
                    // action fired rather than being fixed here.
                    .modifier(SafetySheets(presentation: SafetyPresentation.chat))
            } else if failed {
                VStack(spacing: 8) {
                    Text("💬").font(.system(size: 44))
                    Text("Couldn't open this conversation")
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await makeController() }
    }

    private func makeController() async {
        guard controller == nil, !isConnecting else { return }
        isConnecting = true
        do {
            // Client-side creation can't grant membership on a channel that
            // already exists without the caller in it (adding yourself
            // requires already being a member), so an admin-privileged
            // server call guarantees membership first, whether the channel
            // is brand new or pre-existed without this user.
            try await StreamTokenProvider.joinChannel(channelId: channelId, otherMemberIds: memberIds, name: name)

            var members = Set(memberIds)
            if let currentUserId = chatClient.currentUserId {
                members.insert(currentUserId)
            }
            // Safe for already-existing channels (per SDK: it's a get-or-create).
            let newController = try chatClient.channelController(
                createChannelWithId: ChannelId(type: .messaging, id: channelId),
                name: name,
                members: members
            )
            // The controller is only handed to `ChatChannelView` once it has
            // actually synced. Assigning it unconditionally rendered a live-
            // looking composer on top of a channel that never reached the
            // server: messages appeared to send and went nowhere. A channel
            // that can't sync is the same failure as one that can't be
            // created, and gets the same "couldn't open" state.
            newController.synchronize { error in
                Task { @MainActor in
                    isConnecting = false
                    if let error {
                        chatLog.error("channel sync failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        failed = true
                    } else {
                        controller = newController
                    }
                }
            }
        } catch {
            chatLog.error("channel create failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            isConnecting = false
            failed = true
        }
    }
}

// MARK: - Presence header

/// Online dot + "typing…" for a one-to-one thread.
///
/// The SDK already renders typing indicators and read receipts *inside* the
/// message list; what it doesn't give you at a glance is whether the other
/// person is there right now. This is that: a mint dot when they're online,
/// and a live subtitle that switches to "typing…" while they are.
///
/// Watches the same `ChatChannelController` the thread uses, so it costs one
/// extra observer rather than a second channel connection.
struct ChatPresenceHeader: View {
    @Injected(\.chatClient) var chatClient

    let channelId: String
    let name: String

    @State private var controller: ChatChannelController?
    @State private var observer: ChannelPresenceObserver?

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 7) {
                Text(name)
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if observer?.isOnline == true {
                    Circle()
                        .fill(Theme.mint)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Online")
                }
            }
            if let subtitle = observer?.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(observer?.isTyping == true ? Theme.accent : Theme.textSecondary)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: observer?.subtitle)
        .task {
            guard controller == nil else { return }
            let created = chatClient.channelController(for: ChannelId(type: .messaging, id: channelId))
            let watcher = ChannelPresenceObserver(controller: created)
            created.synchronize()
            controller = created
            observer = watcher
        }
    }
}

/// Bridges `ChatChannelControllerDelegate` callbacks into observable state.
///
/// The delegate protocol is class-bound and not itself observable, so presence
/// lands here and SwiftUI reads it from one place.
@MainActor
@Observable
final class ChannelPresenceObserver: NSObject, ChatChannelControllerDelegate {
    private(set) var isOnline = false
    private(set) var isTyping = false
    private(set) var lastSeen: Date?

    private let controller: ChatChannelController

    /// "typing…" wins over presence — it's the more immediate fact, and it's
    /// what tells you a reply is actually coming.
    var subtitle: String? {
        if isTyping { return "typing…" }
        if isOnline { return "Online" }
        guard let lastSeen else { return nil }
        return "Active \(lastSeen.shortRelative) ago"
    }

    init(controller: ChatChannelController) {
        self.controller = controller
        super.init()
        controller.delegate = self
        refreshPresence()
    }

    nonisolated func channelController(_ channelController: ChatChannelController,
                                       didUpdateChannel channel: EntityChange<ChatChannel>) {
        Task { @MainActor in refreshPresence() }
    }

    nonisolated func channelController(_ channelController: ChatChannelController,
                                       didChangeTypingUsers typingUsers: Set<ChatUser>) {
        Task { @MainActor in
            let others = typingUsers.filter { $0.id != controller.client.currentUserId }
            isTyping = !others.isEmpty
        }
    }

    /// Presence of the *other* member. Group threads have several, so this
    /// reports "someone is here" rather than picking one arbitrarily.
    private func refreshPresence() {
        guard let channel = controller.channel else { return }
        let me = controller.client.currentUserId
        let others = channel.lastActiveMembers.filter { $0.id != me }
        isOnline = others.contains { $0.isOnline }
        lastSeen = others.compactMap(\.lastActiveAt).max()
    }
}

// MARK: - App model → Stream channel mapping

/// A friend's Stream user id.
///
/// Real accounts *are* their Firebase uid on Stream — that's the id
/// `getStreamToken` upserts. Demo rows have no uid, so they keep the original
/// name-slug identity, which is all a local-only friend ever needed.
func streamUserId(for friend: Friend) -> String {
    friend.remoteUID.isEmpty
        ? friend.name.lowercased().filter { $0.isLetter || $0.isNumber }
        : friend.remoteUID
}

extension Chat {
    /// Deterministic channel id: same chat always lands on the same channel.
    ///
    /// For a DM this has to agree with what the server computes when it creates
    /// the channel on accept (`dm-` + sorted uids), or the two sides would open
    /// different channels and neither would see the other's messages.
    var streamChannelId: String {
        if isGroup {
            let titleSlug = (title ?? "group").lowercased().filter { $0.isLetter || $0.isNumber }
            return "group-\(titleSlug)"
        }
        let slugs = members.map { streamUserId(for: $0) }.sorted().joined(separator: "-")
        return "dm-\(slugs)"
    }

    /// Everyone except me — `StreamThreadView` adds the connected user back in
    /// before creating the channel.
    var streamMemberIds: [String] {
        members.filter { !$0.isMe }.map { streamUserId(for: $0) }
    }
}

extension Beacon {
    /// Each activity gets its own group channel.
    var streamChannelId: String {
        "activity-\(id.uuidString.lowercased().prefix(12))"
    }

    var streamMemberIds: [String] {
        attendees.filter { !$0.isMe }.map { streamUserId(for: $0) }
    }
}
