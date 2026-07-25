import Foundation
import SwiftData
import FirebaseAuth
import Observation

/// Where the current user stands with another account.
///
/// Raw values match the strings the callables return, so the server is the one
/// place that decides what a relationship is.
enum FriendshipStatus: String, Codable, Hashable {
    /// No edge either way.
    case none
    /// We asked them; waiting on them.
    case requested
    /// They asked us; ours to accept or decline.
    case incoming
    /// Accepted, both edges exist.
    case friends
    /// We blocked them. Only ever reported for a profile we open ourselves —
    /// someone who blocked *us* is reported as missing, not as blocked.
    case blocked
}

/// The signed-in user's friend graph: accepted friends plus pending requests in
/// both directions.
///
/// Firestore is the source of truth. This mirrors accepted friends into the
/// SwiftData cache as `Friend` rows so every existing screen — Pulse, the
/// stacked feeds, chats — keeps reading the local model it always has, and
/// nothing downstream needs to know friendships became real.
@Observable
@MainActor
final class FriendGraph {
    private(set) var friends: [RemoteProfile] = []
    private(set) var incoming: [RemoteProfile] = []
    private(set) var outgoing: [RemoteProfile] = []
    /// Accounts this user has blocked. Loaded lazily — it's only needed by the
    /// blocked-accounts list, and most people never block anyone.
    private(set) var blocked: [RemoteProfile] = []
    private(set) var isRefreshing = false
    /// Last failure, for surfacing "couldn't reach the server" in the inbox.
    private(set) var lastError: String?

    /// Drives the badge next to the add-friend control on Pulse.
    var pendingCount: Int { incoming.count }

    /// Pulls friends and requests, then reconciles the local cache.
    ///
    /// Signed-out and demo builds are a no-op: a failed call here must never
    /// clear a roster the user can see.
    ///
    /// The account is pinned before the network call and re-checked after it.
    /// Without that, a sign-out landing mid-flight would let the continuation
    /// resume and start deleting `Friend` rows in a context that the logout
    /// path is concurrently wiping — which faults any still-mounted view
    /// holding one of those objects (Profile's `$interests` binding is the one
    /// that bites) and crashes with "backing data detached from context".
    /// Touching the store after the owner changed is never correct here.
    func refresh(context: ModelContext) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            async let remoteFriends = FirestoreService.listFriends()
            async let remoteRequests = FirestoreService.listRequests()
            let (loadedFriends, requests) = try await (remoteFriends, remoteRequests)

            // Still the same signed-in account, and still wanted?
            guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }

            friends = loadedFriends
            incoming = requests.incoming
            outgoing = requests.outgoing
            lastError = nil

            sync(loadedFriends, into: context)
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't reach the server."
        }
    }

    /// Drops everything held in memory. Called when the account changes so a
    /// new sign-in can't briefly render the previous account's roster.
    func clear() {
        friends = []
        incoming = []
        outgoing = []
        blocked = []
        lastError = nil
    }

    /// Relationship with a specific account, from whatever we last loaded.
    func status(of uid: String) -> FriendshipStatus {
        if friends.contains(where: { $0.uid == uid }) { return .friends }
        if outgoing.contains(where: { $0.uid == uid }) { return .requested }
        if incoming.contains(where: { $0.uid == uid }) { return .incoming }
        return .none
    }

    // MARK: Actions
    //
    // Each one applies the server's answer to the local state optimistically
    // enough that the UI settles immediately, then refreshes to reconcile.

    func send(to profile: RemoteProfile, context: ModelContext) async throws -> FriendshipStatus {
        let status = try await FirestoreService.sendFriendRequest(to: profile.uid)
        switch status {
        case .friends: friends.append(profile)
        case .requested: outgoing.append(profile)
        default: break
        }
        incoming.removeAll { $0.uid == profile.uid }
        await refresh(context: context)
        return status
    }

    func accept(_ profile: RemoteProfile, context: ModelContext) async throws {
        _ = try await FirestoreService.acceptFriendRequest(from: profile.uid)
        incoming.removeAll { $0.uid == profile.uid }
        friends.append(profile)
        await refresh(context: context)
    }

    func decline(_ profile: RemoteProfile, context: ModelContext) async throws {
        try await FirestoreService.declineFriendRequest(from: profile.uid)
        incoming.removeAll { $0.uid == profile.uid }
        await refresh(context: context)
    }

    func cancel(_ profile: RemoteProfile, context: ModelContext) async throws {
        try await FirestoreService.cancelFriendRequest(to: profile.uid)
        outgoing.removeAll { $0.uid == profile.uid }
        await refresh(context: context)
    }

    func remove(_ profile: RemoteProfile, context: ModelContext) async throws {
        try await FirestoreService.removeFriend(profile.uid)
        friends.removeAll { $0.uid == profile.uid }
        await refresh(context: context)
    }

    // MARK: Safety

    /// Blocks an account and drops it from every in-memory list at once, so the
    /// person disappears from the UI on the same frame the button is tapped
    /// rather than a network round trip later.
    func block(_ profile: RemoteProfile, context: ModelContext) async throws {
        try await FirestoreService.blockUser(profile.uid)
        friends.removeAll { $0.uid == profile.uid }
        incoming.removeAll { $0.uid == profile.uid }
        outgoing.removeAll { $0.uid == profile.uid }
        if !blocked.contains(where: { $0.uid == profile.uid }) {
            blocked.append(profile)
        }
        await refresh(context: context)
    }

    func unblock(_ profile: RemoteProfile, context: ModelContext) async throws {
        try await FirestoreService.unblockUser(profile.uid)
        blocked.removeAll { $0.uid == profile.uid }
        await refresh(context: context)
    }

    /// Loads the blocked list on demand. The block/unblock actions keep it
    /// current afterwards, so this only has to run when the screen opens.
    func loadBlocked() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        do {
            let loaded = try await FirestoreService.listBlocked()
            guard Auth.auth().currentUser?.uid == uid else { return }
            blocked = loaded
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't reach the server."
        }
    }

    // MARK: Local cache reconciliation

    /// Upserts a `Friend` row per accepted friendship and drops rows for
    /// friendships that no longer exist.
    ///
    /// Only rows that came from the server are touched: demo rows (`isDemo`)
    /// and the `isMe` row are left completely alone, so forcing demo data in a
    /// DEBUG build and having real friends can coexist without either erasing
    /// the other.
    private func sync(_ profiles: [RemoteProfile], into context: ModelContext) {
        let existing = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        let byUID = Dictionary(
            existing.filter { !$0.remoteUID.isEmpty && !$0.isMe }.map { ($0.remoteUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let liveUIDs = Set(profiles.map(\.uid))

        for profile in profiles {
            let friend = byUID[profile.uid] ?? {
                let created = Friend(name: profile.name,
                                     emoji: profile.avatarEmoji,
                                     hue: Self.hue(for: profile.uid))
                context.insert(created)
                return created
            }()

            friend.remoteUID = profile.uid
            friend.handle = profile.handle
            friend.handleDisplay = profile.handleDisplay
            friend.userId = profile.handleDisplay.isEmpty ? profile.handle : profile.handleDisplay
            friend.name = profile.name
            friend.emoji = profile.avatarEmoji
            friend.city = profile.city
            friend.bio = profile.bio
            friend.avatarURL = profile.avatarURL ?? ""
            friend.isPrivate = profile.isPrivate
            friend.isDemo = false
        }

        // Un-friended accounts: delete the row so they leave Pulse. Demo rows
        // have an empty remoteUID and so are never in `byUID` to begin with.
        //
        // Their DM goes with them. `Chat.members` has no cascade rule, so
        // deleting only the `Friend` leaves the chat standing with nobody but
        // "me" in it, showing up in every audience and thread list as "Just me"
        // for good. Group chats keep their history and just lose a member.
        let allChats = (try? context.fetch(FetchDescriptor<Chat>())) ?? []
        for (uid, friend) in byUID where !liveUIDs.contains(uid) {
            for chat in allChats where !chat.isGroup && chat.members.contains(where: { $0.id == friend.id }) {
                context.delete(chat)
            }
            context.delete(friend)
        }

        try? context.save()
    }

    /// Stable pastel hue per account, so an avatar keeps its colour across
    /// launches and devices without the server having to store one.
    private static func hue(for uid: String) -> Double {
        let hash = uid.unicodeScalars.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1.value) }
        return Double(hash % 360) / 360.0
    }
}
