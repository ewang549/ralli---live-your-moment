import SwiftUI
import StreamChat
import StreamChatSwiftUI

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

    var body: some View {
        Group {
            if let controller {
                ChatChannelView(viewFactory: ExplogViewFactory.shared, channelController: controller)
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
        guard controller == nil else { return }
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
            newController.synchronize { error in
                if let error { print("Channel sync failed: \(error)") }
            }
            controller = newController
        } catch {
            print("Channel create failed: \(error)")
            failed = true
        }
    }
}

// MARK: - App model → Stream channel mapping

/// Stream user ids are lowercase alphanumeric slugs of friend names.
func streamUserId(for friend: Friend) -> String {
    friend.name.lowercased().filter { $0.isLetter || $0.isNumber }
}

extension Chat {
    /// Deterministic channel id: same chat always lands on the same channel.
    var streamChannelId: String {
        let slugs = members.map { streamUserId(for: $0) }.sorted().joined(separator: "-")
        if isGroup {
            let titleSlug = (title ?? "group").lowercased().filter { $0.isLetter || $0.isNumber }
            return "group-\(titleSlug)"
        }
        return "dm-\(slugs)"
    }

    /// Everyone except me — `StreamThreadView` adds the connected user
    /// (a Firebase uid, not a slug) back in before creating the channel.
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
