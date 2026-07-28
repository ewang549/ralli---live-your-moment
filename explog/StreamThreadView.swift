import SwiftUI
import SwiftData
import StreamChat
import StreamChatSwiftUI
import os

private let chatLog = Logger(subsystem: "com.ej.explog", category: "chat")

// MARK: - Ralli's own message payloads
//
// Keys carried in a Stream message's `extraData`. They are the wire format for
// everything the app sends into a thread from outside the composer, so they are
// named once here rather than spelled out at each end.

enum RalliMessageKey {
    /// A shared place. Holds the *server* spot id (`spots/{id}`) — the local
    /// SwiftData `Spot.id` is a per-device UUID and means nothing on the
    /// receiving phone.
    static let sharedSpotId = "ralliSharedSpotId"
    static let sharedSpotName = "ralliSharedSpotName"
    static let sharedSpotEmoji = "ralliSharedSpotEmoji"
    static let reactionEmoji = "ralliReactionEmoji"
    static let clipId = "ralliClipId"
    static let clipKind = "ralliClipKind"
}

// `StreamMessage` rather than `ChatMessage`: this module has its own type by
// that name. See StreamMessage.swift.
extension StreamMessage {
    /// The shared place on this message, if it is one. Empty id means it isn't.
    var ralliSharedSpotId: String {
        extraData[RalliMessageKey.sharedSpotId]?.stringValue ?? ""
    }

    var ralliSharedSpotName: String {
        extraData[RalliMessageKey.sharedSpotName]?.stringValue ?? ""
    }

    var ralliSharedSpotEmoji: String {
        extraData[RalliMessageKey.sharedSpotEmoji]?.stringValue ?? ""
    }
}

/// Teaches the message list that a shared place is its own kind of message.
///
/// The SDK asks this before it decides how to draw a bubble, and a `true` here
/// routes the message to `ExplogViewFactory.makeCustomAttachmentViewType`.
/// Only that one question is answered; every other kind falls through to
/// `MessageTypeResolving`'s defaults, so text, images and the reaction frames
/// posted by `postReaction` keep the SDK's own rendering.
///
/// Conforms to the protocol directly rather than subclassing the SDK's
/// `MessageTypeResolver`: that class inherits every method from the protocol
/// extension, and an extension's implementation is the witness — a subclass
/// override would never be dispatched through the protocol the SDK holds this
/// as.
final class RalliMessageTypeResolver: MessageTypeResolving {
    func hasCustomAttachment(message: StreamMessage) -> Bool {
        !message.ralliSharedSpotId.isEmpty
    }
}

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

    /// Draws a shared place as a card instead of a line of text.
    ///
    /// Reached only for messages `RalliMessageTypeResolver` has flagged, which
    /// is exactly the ones carrying `ralliSharedSpotId`.
    func makeCustomAttachmentViewType(options: CustomAttachmentViewTypeOptions) -> some View {
        SharedSpotBubble(message: options.message)
    }
}

// MARK: - Shared place bubble

/// A place someone sent you, rendered as a card that opens the place.
///
/// The spot travels as an id and a name rather than as data, so this resolves
/// it on the receiving device: the local mirror if this account has already
/// seen the place, otherwise one lookup against the server, mirrored into
/// SwiftData through the same `Spot.mirror` every other place-sync path uses.
/// That keeps `SpotDetailView` — which needs a real `Spot` — reachable for a
/// friend who has never been anywhere near this place before.
private struct SharedSpotBubble: View {
    let message: StreamMessage

    @Environment(\.modelContext) private var modelContext
    @Query private var spots: [Spot]

    @State private var opened: Spot?
    @State private var resolving = false
    @State private var failed = false

    private var spotID: String { message.ralliSharedSpotId }
    private var spotName: String {
        message.ralliSharedSpotName.isEmpty ? "a place" : message.ralliSharedSpotName
    }
    private var spotEmoji: String {
        message.ralliSharedSpotEmoji.isEmpty ? "📍" : message.ralliSharedSpotEmoji
    }

    /// Already mirrored locally? Then tapping is instant and offline-safe.
    private var localSpot: Spot? {
        spots.first { !$0.remoteID.isEmpty && $0.remoteID == spotID }
    }

    /// There's a place to open iff the share carried a server id.
    private var isOpenable: Bool { !spotID.isEmpty }

    private var subtitle: String {
        if resolving { return "Opening…" }
        return isOpenable ? "Tap to see this place" : "Shared a place"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
            }

            // A share of a place that never had a server record — a seed or
            // demo spot — carries a name and nothing to open. It still renders
            // as a card, because the message is still "I sent you this place",
            // but it doesn't offer a tap that can only fail.
            if isOpenable {
                Button { open() } label: { card }
                    .buttonStyle(.plain)
                    .disabled(resolving)
            } else {
                card
            }

            if failed {
                Text("Couldn't load this place. Check your connection.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .sheet(item: $opened) { spot in
            SpotDetailView(spot: spot)
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            Text(spotEmoji).font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(spotName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            if resolving {
                ProgressView().tint(Theme.textSecondary).scaleEffect(0.7)
            } else if isOpenable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 240, alignment: .leading)
        .background { GlassCard(cornerRadius: 14) { Color.clear } }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        }
    }

    private func open() {
        failed = false
        if let localSpot {
            opened = localSpot
            return
        }
        guard isOpenable, !resolving else { return }
        resolving = true
        Task {
            defer { resolving = false }
            // `searchSpots` is a prefix search over place names, and a name is
            // a prefix of itself — so the shared place comes back on the first
            // page. The id is what actually selects it; the name only narrows
            // the query.
            let matches = try? await FirestoreService.searchSpots(message.ralliSharedSpotName, limit: 25)
            guard let remote = matches?.first(where: { $0.id == spotID }) else {
                failed = true
                return
            }
            opened = Spot.mirror(remote, into: modelContext)
        }
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
            //
            // Only on the session's first open of this channel: threads get
            // re-opened constantly, and re-joining one we're already in bought
            // nothing while holding the composer behind a token mint plus a
            // Cloud Function round trip.
            try await StreamTokenProvider.joinChannelIfNeeded(channelId: channelId, otherMemberIds: memberIds, name: name)

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

// MARK: - Outgoing send recorder

extension View {
    /// Keeps `chat.lastOutgoingMessageAt` in step with what I've sent on the
    /// chat's Stream channel. Attach wherever a thread is presented.
    func recordsOutgoingSends(to chat: Chat) -> some View {
        modifier(OutgoingSendRecorder(chat: chat))
    }
}

/// Watches an open thread's channel and stamps its newest message onto the
/// local `Chat` — outgoing and incoming, on their own fields.
///
/// The SDK's composer writes straight to Stream: nothing in the app sees a text
/// go out, and no local `Message` row is ever written for it. Without this,
/// Pulse's "who did I last reach out to" order could only see logs, and a
/// friend you'd messaged and nothing more would never move.
///
/// It watches a *second* controller on the same channel — the pattern
/// `ChatPresenceHeader` already uses — because the thread's own controller
/// delegate belongs to the SDK's message list, and taking it breaks the list.
/// The initial sync replays existing messages as inserts, so opening a thread
/// also backfills threads that predate this.
private struct OutgoingSendRecorder: ViewModifier {
    let chat: Chat

    @Environment(\.modelContext) private var modelContext
    @State private var observer: OutgoingMessageObserver?

    func body(content: Content) -> some View {
        content.task {
            guard StreamConfig.isEnabled, observer == nil else { return }
            let client = InjectedValues[\.chatClient]
            guard client.currentUserId != nil else { return }

            let controller = client.channelController(
                for: ChannelId(type: .messaging, id: chat.streamChannelId)
            )
            observer = OutgoingMessageObserver(controller: controller) { sentAt, isMine in
                if isMine {
                    chat.noteOutgoingMessage(at: sentAt)
                } else {
                    chat.noteIncomingMessage(at: sentAt)
                    // Arriving in a thread you have open is arriving read. The
                    // inbox watcher stamps this same message on `Chat`, which
                    // moves `lastActivityAt` past `lastReadAt` — so without
                    // this, replying to someone lit an unread dot on the very
                    // conversation you were sitting in.
                    chat.markRead()
                }
                try? modelContext.save()
            }
            controller.synchronize()
        }
    }
}

/// Bridges `ChatChannelControllerDelegate`'s message callbacks into a plain
/// closure, the same way `ChannelPresenceObserver` does for presence.
@MainActor
final class OutgoingMessageObserver: NSObject, ChatChannelControllerDelegate {
    private let controller: ChatChannelController
    /// `(sentAt, isMine)` — the direction is reported rather than filtered so
    /// the caller can stamp the right field and decide what an arrival while
    /// the thread is open means.
    private let onSend: (Date, Bool) -> Void

    init(controller: ChatChannelController, onSend: @escaping (Date, Bool) -> Void) {
        self.controller = controller
        self.onSend = onSend
        super.init()
        controller.delegate = self
    }

    // `StreamMessage` rather than `ChatMessage`: the app's own typealias for
    // the local `Message` model owns that name (see `StreamMessage.swift`).
    nonisolated func channelController(_ channelController: ChatChannelController,
                                       didUpdateMessages changes: [ListChange<StreamMessage>]) {
        // Only inserts. An edit or a reaction landing on an old message isn't
        // either side saying something new.
        let inserts = changes.compactMap { change -> (Date, Bool)? in
            guard case .insert(let message, _) = change else { return nil }
            return (message.createdAt, message.isSentByCurrentUser)
        }
        // Newest per direction, so a batch carrying both sides of an exchange
        // stamps both fields instead of only whichever happened to be latest.
        for isMine in [true, false] {
            guard let latest = inserts.filter({ $0.1 == isMine }).map(\.0).max() else { continue }
            Task { @MainActor in onSend(latest, isMine) }
        }
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

// MARK: - Posting into a thread from outside it

/// Sends a message into a chat's real Stream channel without opening the thread.
///
/// Reacting to a friend's log in Pulse is supposed to land in the DM as well as
/// on the clip. That used to be an inserted `Message` row, which only the
/// local-only `MessageThreadView` renders — so once `StreamConfig.isEnabled`
/// started correctly reporting a connected Stream user, real accounts rendered
/// `StreamThreadView` and the reaction reached nobody. This puts it on the same
/// channel the thread itself opens.
enum StreamThreadPoster {
    /// Posts a reaction to `clip` into `chat`'s channel.
    ///
    /// Membership is guaranteed server-side first, for the same reason
    /// `StreamThreadView.makeController` does it: a client can't add itself to
    /// a channel it isn't already in, and reacting is very often the first
    /// thing that touches a DM whose channel was created on the other side.
    @MainActor
    static func postReaction(_ emoji: String, to clip: Clip, in chat: Chat) async {
        let client = InjectedValues[\.chatClient]
        guard client.currentUserId != nil else { return }

        let channelId = chat.streamChannelId
        do {
            try await StreamTokenProvider.joinChannelIfNeeded(channelId: channelId,
                                                              otherMemberIds: chat.streamMemberIds,
                                                              name: chat.displayName)
        } catch {
            chatLog.error("reaction join failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        let controller = client.channelController(for: ChannelId(type: .messaging, id: channelId))

        // The reaction travels as a picture of the log it's about: a still of
        // the clip with the emoji stamped on it, composited here and uploaded
        // as an ordinary image attachment. "🔥 reacted to your log" never said
        // *which* log, which is the whole point of a reaction.
        //
        // Stream has no server-side overlay, so the file has to exist before
        // the send. When it can't be built — a clip whose media is gone, or a
        // frame that won't decode — the old text is still better than an empty
        // bubble, so it stays as the fallback and only as the fallback.
        var attachments: [AnyAttachmentPayload] = []
        if let stickerURL = await ReactionSticker.makeImageFile(for: clip, emoji: emoji) {
            do {
                attachments = [try AnyAttachmentPayload(localFileURL: stickerURL, attachmentType: .image)]
            } catch {
                chatLog.error("reaction attachment failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // `extraData` carries the clip identity alongside it, so tapping a
        // reaction can be made to jump back to that log without changing the
        // wire format. Per the SDK, sending needs no prior `synchronize`.
        controller.createNewMessage(
            text: attachments.isEmpty ? "\(emoji) reacted to your log" : "",
            attachments: attachments,
            extraData: [
                RalliMessageKey.reactionEmoji: .string(emoji),
                RalliMessageKey.clipId: .string(clip.remoteID.isEmpty ? clip.id.uuidString : clip.remoteID),
                RalliMessageKey.clipKind: .string(clip.kind.rawValue),
            ]
        ) { result in
            if case .failure(let error) = result {
                chatLog.error("reaction send failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Posts a shared place into `chat`'s channel.
    ///
    /// Same reason as `postReaction`: sharing a spot used to insert a local
    /// `Message` row, which only the pre-Stream `MessageThreadView` renders.
    /// Every signed-in session renders `StreamThreadView` instead, so the
    /// sender saw "Sent" and the friend received nothing at all.
    ///
    /// The *server* spot id goes on the wire. A local `Spot.id` is a UUID
    /// minted on this device and would resolve to nothing on the other end.
    /// Returns false when there is nothing shareable to send, so the caller
    /// can avoid claiming a send that didn't happen.
    @MainActor
    @discardableResult
    static func postSpotShare(_ spot: Spot, to chat: Chat) async -> Bool {
        let client = InjectedValues[\.chatClient]
        guard client.currentUserId != nil else { return false }

        let channelId = chat.streamChannelId
        do {
            try await StreamTokenProvider.joinChannelIfNeeded(channelId: channelId,
                                                              otherMemberIds: chat.streamMemberIds,
                                                              name: chat.displayName)
        } catch {
            chatLog.error("spot share join failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }

        let controller = client.channelController(for: ChannelId(type: .messaging, id: channelId))
        // Text still carries the message on its own, so the push notification
        // and any client without the custom bubble both read sensibly; the
        // card is drawn from `extraData` on top of it.
        controller.createNewMessage(
            text: "check this spot out 👀",
            extraData: [
                RalliMessageKey.sharedSpotId: .string(spot.remoteID),
                RalliMessageKey.sharedSpotName: .string(spot.name),
                RalliMessageKey.sharedSpotEmoji: .string(spot.emoji),
            ]
        ) { result in
            if case .failure(let error) = result {
                chatLog.error("spot share send failed for \(channelId, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }
}
