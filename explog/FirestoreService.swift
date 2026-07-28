import Foundation
import SwiftData
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import os

// MARK: - Callable Cloud Functions

/// Thin client for callable Cloud Functions, following the same request shape
/// `StreamTokenProvider` uses: POST `{"data": {...}}` with a Firebase ID token,
/// response decoded out of `{"result": ...}`.
///
/// Writes that need validation (handle claims, friend requests) go through
/// callables rather than direct Firestore writes, which keeps the security
/// rules simple and gives one place to enforce abuse guards.
enum CallableFunctions {
    static let region = "us-central1"
    static let projectId = "explog-723b7"

    private struct Envelope<T: Decodable>: Decodable {
        let result: T
    }

    /// Server-side `HttpsError`s come back as `{"error": {"status", "message"}}`.
    private struct ErrorEnvelope: Decodable {
        struct Payload: Decodable {
            let status: String?
            let message: String?
        }
        let error: Payload
    }

    struct CallableError: LocalizedError {
        let status: String
        let message: String
        var errorDescription: String? { message }
        /// True when the failure is "someone already took this", not a bug.
        var isAlreadyExists: Bool { status == "ALREADY_EXISTS" }
    }

    static func url(for name: String) -> URL {
        URL(string: "https://\(region)-\(projectId).cloudfunctions.net/\(name)")!
    }

    static func call<T: Decodable>(_ name: String,
                                   data: [String: Any] = [:],
                                   as type: T.Type = T.self) async throws -> T {
        guard let user = Auth.auth().currentUser else {
            throw CallableError(status: "UNAUTHENTICATED", message: "Sign in first.")
        }
        let idToken = try await user.getIDToken()

        var request = URLRequest(url: url(for: name))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": data])

        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        guard http.statusCode == 200 else {
            // Surface the server's message ("That handle is taken.") verbatim.
            if let failure = try? JSONDecoder().decode(ErrorEnvelope.self, from: payload) {
                throw CallableError(status: failure.error.status ?? "UNKNOWN",
                                    message: failure.error.message ?? "Something went wrong.")
            }
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Envelope<T>.self, from: payload).result
    }
}

// MARK: - Profile model

/// A user's public directory record (`users/{uid}` in Firestore).
struct RemoteProfile: Codable, Identifiable, Hashable {
    let uid: String
    let handle: String
    var handleDisplay: String
    var name: String
    var avatarEmoji: String
    var city: String
    var bio: String
    var isPrivate: Bool
    /// Only present on your own profile — never returned for other users.
    var friendCode: String?
    /// Total distinct profile-sheet views from other accounts. Absent on
    /// older server responses that predate the counter — treated as 0.
    var viewerCount: Int? = nil
    /// How many accounts follow this one. Absent on older server responses
    /// that predate the follow graph — treated as 0.
    var followerCount: Int? = nil
    /// Storage download URL for the profile photo. Empty when none is set.
    var avatarURL: String? = nil
    /// Which push categories this account wants, keyed by
    /// `NotificationCategory.rawValue`. Nil on a profile written before
    /// preferences existed, which means "everything" — see
    /// `Friend.wantsNotification`.
    var notificationPrefs: [String: Bool]? = nil

    var id: String { uid }
    /// Follower total, with the "server predates the counter" case folded in.
    var followers: Int { followerCount ?? 0 }
    var atHandle: String { "@\(handleDisplay.isEmpty ? handle : handleDisplay)" }
}

/// A place as the server holds it (`spots/{id}`).
///
/// Distinct from the local `Spot` SwiftData row, which stays the read model for
/// the UI and is a mirror of these — same split as `RemoteProfile` and `Friend`.
struct RemoteSpot: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let category: String
    let summary: String
    let address: String
    let latitude: Double
    let longitude: Double
    let emoji: String
    let hueA: Double
    let hueB: Double
    let clipCount: Int
}

// MARK: - Firestore service

/// Reads the user directory and mirrors the current user's profile into the
/// local SwiftData cache. All validated writes go through `CallableFunctions`.
enum FirestoreService {
    private static var db: Firestore { Firestore.firestore() }

    struct HandleAvailability: Decodable {
        let available: Bool
        let reason: String?
        let handle: String?
    }

    private struct ProfileResponse: Decodable {
        let profile: RemoteProfile
    }

    /// Result of a directory lookup: who they are, and where you stand with them.
    struct LookupResult: Decodable {
        let profile: RemoteProfile
        /// Absent on older server builds — treated as `.none`.
        private let status: String?

        var friendship: FriendshipStatus {
            FriendshipStatus(rawValue: status ?? "none") ?? .none
        }
    }

    private struct StatusResponse: Decodable {
        let status: String
        var friendship: FriendshipStatus { FriendshipStatus(rawValue: status) ?? .none }
    }

    private struct FriendsResponse: Decodable {
        let friends: [RemoteProfile]
    }

    struct RequestsResponse: Decodable {
        let incoming: [RemoteProfile]
        let outgoing: [RemoteProfile]
    }

    private struct BlockedResponse: Decodable {
        let blocked: [RemoteProfile]
    }

    /// One row of a people search: who they are and where you stand with them,
    /// so the list can render its Add / Requested / Friends pill without a
    /// per-row round trip.
    struct SearchHit: Decodable, Identifiable, Hashable {
        let profile: RemoteProfile
        /// Raw relationship string from the server; read through `friendship`.
        let status: String?
        /// Only present on suggestions.
        let mutuals: Int?

        var id: String { profile.uid }
        var friendship: FriendshipStatus { FriendshipStatus(rawValue: status ?? "none") ?? .none }
        var mutualCount: Int { mutuals ?? 0 }
    }

    private struct SearchResponse: Decodable {
        let results: [SearchHit]
    }

    private struct SuggestionsResponse: Decodable {
        let suggestions: [SearchHit]
    }

    /// A full public profile plus the viewer's relationship to it.
    struct PublicProfile: Decodable {
        let profile: RemoteProfile
        private let status: String?
        private let mutuals: Int?
        /// Whether the caller follows this account. Absent on older server
        /// builds that predate the follow graph — treated as "not following".
        private let following: Bool?

        var friendship: FriendshipStatus { FriendshipStatus(rawValue: status ?? "none") ?? .none }
        var mutualCount: Int { mutuals ?? 0 }
        var isFollowing: Bool { following ?? false }
    }

    /// What a follow/unfollow settles on: the edge's new state and the target's
    /// resulting follower total, so the button and the count land together.
    struct FollowResult: Decodable {
        let following: Bool
        let followerCount: Int
    }

    // MARK: Reads

    /// Loads `users/{uid}` for the signed-in user. `nil` means onboarding has
    /// not completed yet — the caller should show profile setup.
    static func currentProfile() async throws -> RemoteProfile? {
        guard let uid = Auth.auth().currentUser?.uid else { return nil }
        return try await profile(uid: uid)
    }

    static func profile(uid: String) async throws -> RemoteProfile? {
        let snapshot = try await db.collection("users").document(uid).getDocument()
        guard snapshot.exists else { return nil }
        return decodeProfile(from: snapshot.data(), uid: uid)
    }

    /// Hand-decoded rather than `Codable`-decoded: Firestore stores `createdAt`
    /// as a Timestamp, which would trip the synthesized decoder.
    private static func decodeProfile(from data: [String: Any]?, uid: String) -> RemoteProfile? {
        guard let data, let handle = data["handle"] as? String else { return nil }
        return RemoteProfile(
            uid: data["uid"] as? String ?? uid,
            handle: handle,
            handleDisplay: data["handleDisplay"] as? String ?? handle,
            name: data["name"] as? String ?? "",
            avatarEmoji: data["avatarEmoji"] as? String ?? "🙂",
            city: data["city"] as? String ?? "",
            bio: data["bio"] as? String ?? "",
            isPrivate: data["isPrivate"] as? Bool ?? false,
            friendCode: data["friendCode"] as? String,
            viewerCount: data["viewerCount"] as? Int ?? 0,
            followerCount: data["followerCount"] as? Int ?? 0,
            avatarURL: data["avatarURL"] as? String ?? "",
            notificationPrefs: data["notificationPrefs"] as? [String: Bool]
        )
    }

    // MARK: Writes (via callables)

    /// "Add friend by User ID" — resolves a handle *or* a friend code, and
    /// reports the existing relationship so the Add button doesn't flash the
    /// wrong state. Rate limited server-side; a lockout surfaces as a
    /// CallableError.
    static func lookupUser(_ query: String) async throws -> LookupResult {
        try await CallableFunctions.call("lookupUser",
                                         data: ["query": query],
                                         as: LookupResult.self)
    }

    // MARK: Friend graph

    /// Asks to be friends. Returns the resulting state: `.requested` normally,
    /// or `.friends` when they had already requested us and this tap closed the
    /// loop.
    @discardableResult
    static func sendFriendRequest(to uid: String) async throws -> FriendshipStatus {
        try await CallableFunctions.call("sendFriendRequest",
                                         data: ["toUid": uid],
                                         as: StatusResponse.self).friendship
    }

    /// Accepts, creating both friend edges and the DM channel server-side, so
    /// the per-row message button works the moment the friendship lands.
    @discardableResult
    static func acceptFriendRequest(from uid: String) async throws -> FriendshipStatus {
        try await CallableFunctions.call("acceptFriendRequest",
                                         data: ["fromUid": uid],
                                         as: StatusResponse.self).friendship
    }

    static func declineFriendRequest(from uid: String) async throws {
        _ = try await CallableFunctions.call("declineFriendRequest",
                                             data: ["fromUid": uid],
                                             as: StatusResponse.self)
    }

    static func cancelFriendRequest(to uid: String) async throws {
        _ = try await CallableFunctions.call("cancelFriendRequest",
                                             data: ["toUid": uid],
                                             as: StatusResponse.self)
    }

    static func removeFriend(_ uid: String) async throws {
        _ = try await CallableFunctions.call("removeFriend",
                                             data: ["friendUid": uid],
                                             as: StatusResponse.self)
    }

    static func listFriends() async throws -> [RemoteProfile] {
        try await CallableFunctions.call("listFriends", as: FriendsResponse.self).friends
    }

    static func listRequests() async throws -> RequestsResponse {
        try await CallableFunctions.call("listRequests", as: RequestsResponse.self)
    }

    // MARK: Discovery

    /// Prefix search over handles *and* names. Returns a ranked list; the
    /// server drops anyone either side has blocked, so a hit here is always
    /// someone the caller can act on.
    static func searchUsers(_ query: String, limit: Int = 15) async throws -> [SearchHit] {
        try await CallableFunctions.call("searchUsers",
                                         data: ["query": query, "limit": limit],
                                         as: SearchResponse.self).results
    }

    /// "People you may know" — friends-of-friends first, then same city.
    static func suggestedFriends(limit: Int = 10) async throws -> [SearchHit] {
        try await CallableFunctions.call("suggestedFriends",
                                         data: ["limit": limit],
                                         as: SuggestionsResponse.self).suggestions
    }

    /// The profile behind an avatar or a search row, with mutual count and the
    /// viewer's relationship. Throws `not-found` when the target has blocked
    /// the caller — by design, that's indistinguishable from a deleted account.
    static func publicProfile(uid: String) async throws -> PublicProfile {
        try await CallableFunctions.call("publicProfileFor",
                                         data: ["uid": uid],
                                         as: PublicProfile.self)
    }

    // MARK: Follow graph

    /// Follows an account. One-directional and needs no acceptance — this is
    /// the lightweight "put their highlights in my feed" edge, not friendship.
    /// Idempotent server-side, so a double tap settles rather than erroring.
    @discardableResult
    static func followUser(_ uid: String) async throws -> FollowResult {
        try await CallableFunctions.call("followUser",
                                         data: ["uid": uid],
                                         as: FollowResult.self)
    }

    @discardableResult
    static func unfollowUser(_ uid: String) async throws -> FollowResult {
        try await CallableFunctions.call("unfollowUser",
                                         data: ["uid": uid],
                                         as: FollowResult.self)
    }

    private struct FollowingResponse: Decodable {
        let following: [RemoteProfile]
    }

    /// Everyone this account follows — the source list behind the Following
    /// tab under Places.
    static func listFollowing() async throws -> [RemoteProfile] {
        try await CallableFunctions.call("listFollowing", as: FollowingResponse.self).following
    }

    // MARK: Spots

    private struct SpotResponse: Decodable { let spot: RemoteSpot }
    private struct SpotsResponse: Decodable { let spots: [RemoteSpot] }

    /// Creates the place, or returns the existing one if somebody already did.
    ///
    /// The server derives the spot's id from its name and coordinates, so two
    /// accounts picking the same café out of location search converge on the
    /// same record rather than each minting their own.
    static func upsertSpot(name: String,
                           latitude: Double,
                           longitude: Double,
                           category: String = "",
                           summary: String = "",
                           address: String = "",
                           emoji: String = "📍",
                           hueA: Double = 0.03,
                           hueB: Double = 0.09) async throws -> RemoteSpot {
        try await CallableFunctions.call("upsertSpot",
                                         data: ["name": name,
                                                "latitude": latitude,
                                                "longitude": longitude,
                                                "category": category,
                                                "summary": summary,
                                                "address": address,
                                                "emoji": emoji,
                                                "hueA": hueA,
                                                "hueB": hueB],
                                         as: SpotResponse.self).spot
    }

    /// Places other people have already created — how a second account finds a
    /// spot without re-deriving it from a map search.
    static func searchSpots(_ query: String, limit: Int = 15) async throws -> [RemoteSpot] {
        try await CallableFunctions.call("searchSpots",
                                         data: ["query": query, "limit": limit],
                                         as: SpotsResponse.self).spots
    }

    // MARK: Safety

    /// Blocks an account: severs the friendship, drops pending requests both
    /// ways, and bans them from the shared Stream channel. Not reversible into
    /// a friendship — unblocking only restores visibility.
    static func blockUser(_ uid: String) async throws {
        _ = try await CallableFunctions.call("blockUser",
                                             data: ["uid": uid],
                                             as: StatusResponse.self)
    }

    static func unblockUser(_ uid: String) async throws {
        _ = try await CallableFunctions.call("unblockUser",
                                             data: ["uid": uid],
                                             as: StatusResponse.self)
    }

    static func listBlocked() async throws -> [RemoteProfile] {
        try await CallableFunctions.call("listBlocked", as: BlockedResponse.self).blocked
    }

    private struct ReportResponse: Decodable {
        let id: String
    }

    /// Reports an account for review. `alsoBlock` does both in one call —
    /// reporting someone almost always means wanting them gone too.
    static func reportUser(_ uid: String,
                           reason: String,
                           details: String,
                           alsoBlock: Bool) async throws {
        _ = try await CallableFunctions.call("reportUser",
                                             data: ["targetUid": uid,
                                                    "reason": reason,
                                                    "details": details,
                                                    "block": alsoBlock],
                                             as: ReportResponse.self)
    }

    /// Reports a specific log or message rather than the whole account.
    static func reportContent(id: String,
                              kind: String,
                              authorUid: String,
                              reason: String,
                              details: String) async throws {
        _ = try await CallableFunctions.call("reportContent",
                                             data: ["targetId": id,
                                                    "targetType": kind,
                                                    "targetUid": authorUid,
                                                    "reason": reason,
                                                    "details": details],
                                             as: ReportResponse.self)
    }

    // MARK: Account

    private struct OKResponse: Decodable {
        let ok: Bool
    }

    /// Erases the account everywhere: directory record, edges other people
    /// hold, handle and code claims, published logs and their media, the
    /// Stream identity, and the Firebase Auth user itself.
    ///
    /// The Auth user goes last server-side, so a failure part-way through
    /// leaves the account signed-in and retryable rather than orphaned.
    static func deleteAccount() async throws {
        _ = try await CallableFunctions.call("deleteAccount", as: OKResponse.self)
    }

    /// Removes one published log and its media from the server.
    ///
    /// Authors only — the server checks the stored `authorUid` rather than
    /// anything the caller supplies, so this can't be pointed at someone
    /// else's log. Deleting a log that's already gone is a no-op, which makes a
    /// retry after a dropped connection safe.
    static func deleteLog(id: String) async throws {
        _ = try await CallableFunctions.call("deleteLog", data: ["id": id], as: OKResponse.self)
    }

    static func checkHandleAvailable(_ handle: String) async throws -> HandleAvailability {
        try await CallableFunctions.call("checkHandleAvailable",
                                         data: ["handle": handle],
                                         as: HandleAvailability.self)
    }

    /// Claims the handle and creates `users/{uid}`. Idempotent server-side.
    static func createProfile(handle: String,
                              name: String,
                              avatarEmoji: String,
                              city: String,
                              referredBy: String? = nil) async throws -> RemoteProfile {
        var payload: [String: Any] = [
            "handle": handle,
            "name": name,
            "avatarEmoji": avatarEmoji,
            "city": city,
        ]
        if let referredBy { payload["referredBy"] = referredBy }
        let response = try await CallableFunctions.call("createProfile",
                                                        data: payload,
                                                        as: ProfileResponse.self)
        return response.profile
    }

    /// Uploads a picked profile photo and records its download URL on the
    /// profile, so other people's views of this account can render it.
    ///
    /// Same shape as `LogSync.publish`'s media upload: straight to Storage
    /// under a prefix scoped to the user's own uid (which is what the Storage
    /// rules enforce), then a metadata write. Returns the download URL.
    @discardableResult
    static func uploadAvatarPhoto(at localURL: URL) async throws -> String {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw CallableFunctions.CallableError(status: "UNAUTHENTICATED",
                                                  message: "Sign in first.")
        }
        let ref = Storage.storage().reference(withPath: "avatars/\(uid)/\(UUID().uuidString).jpg")
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await ref.putFileAsync(from: localURL, metadata: metadata)
        let url = try await ref.downloadURL().absoluteString

        // The account can change while a photo uploads; writing the URL onto
        // whoever is signed in *now* would stamp it on the wrong profile.
        guard Auth.auth().currentUser?.uid == uid else { return url }
        try await updateSoftFields(["avatarURL": url])
        return url
    }

    /// `uploadAvatarPhoto` with a short backoff, for the one caller that runs
    /// during onboarding.
    ///
    /// The upload happens seconds after the account is created, and Storage can
    /// still be rejecting a token that hasn't finished propagating — the same
    /// race `AuthGateView.resolveProfile` already retries around. A single
    /// `try?` there meant one unlucky attempt left the account with no
    /// `avatarURL` at all, permanently and silently: the photo showed on the
    /// device that picked it and nowhere else, with nothing to retry it.
    /// Throws the last error when every attempt is spent, so the caller can
    /// say so rather than swallowing it.
    @discardableResult
    static func uploadAvatarPhoto(at localURL: URL, attempts: Int) async throws -> String {
        var lastError: Error = CallableFunctions.CallableError(status: "UNKNOWN",
                                                              message: "Couldn't upload that photo.")
        for attempt in 0..<max(attempts, 1) {
            do {
                return try await uploadAvatarPhoto(at: localURL)
            } catch {
                lastError = error
                guard attempt < attempts - 1 else { break }
                try? await Task.sleep(for: .milliseconds(400 * (attempt + 1)))
            }
        }
        throw lastError
    }

    /// Soft profile edits the security rules allow the client to write directly.
    ///
    /// `nameLower` is derived here rather than left to callers: it's what name
    /// search ranges over, and the rules reject any write where it doesn't
    /// match `name` exactly.
    static func updateSoftFields(_ fields: [String: Any]) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        var payload = fields
        if let name = fields["name"] as? String {
            payload["nameLower"] = name.lowercased()
        }
        payload["updatedAt"] = FieldValue.serverTimestamp()
        try await db.collection("users").document(uid).updateData(payload)
    }

    // MARK: Local cache

    /// Mirrors the remote profile onto the local `Friend` row marked `isMe`,
    /// creating it if this is the first launch for the account. SwiftData stays
    /// the read model for the UI; Firestore is the source of truth.
    @MainActor
    static func cacheLocally(_ profile: RemoteProfile, context: ModelContext) {
        let descriptor = FetchDescriptor<Friend>()
        let existing = (try? context.fetch(descriptor)) ?? []

        // Prefer a row already bound to this account, then any `isMe` row.
        let me = existing.first { $0.remoteUID == profile.uid }
            ?? existing.first { $0.isMe }

        let friend: Friend
        if let me {
            friend = me
        } else {
            friend = Friend(name: profile.name, emoji: profile.avatarEmoji, hue: 0.58, isMe: true)
            context.insert(friend)
        }

        friend.isMe = true
        friend.remoteUID = profile.uid
        friend.handle = profile.handle
        friend.handleDisplay = profile.handleDisplay
        friend.friendCode = profile.friendCode ?? friend.friendCode
        friend.name = profile.name
        friend.emoji = profile.avatarEmoji
        friend.city = profile.city
        friend.bio = profile.bio
        friend.isPrivate = profile.isPrivate
        // Same soft field `FriendGraph.sync` copies for everyone else. Keeping
        // it here too means your own avatar survives a reinstall, where the
        // locally-picked file is gone but the uploaded copy isn't.
        friend.avatarURL = profile.avatarURL ?? ""
        // The server's copy is the one that decides whether a push is sent, so
        // it wins here — otherwise signing in on a second device would show
        // every switch on while the backend was honouring the ones turned off.
        // Nil means the account predates preferences and wants everything,
        // which an empty map already says.
        if let prefs = profile.notificationPrefs {
            friend.notificationPrefs = prefs
        }

        try? context.save()

        // There must be exactly one "me". Two would mean demo seeding created a
        // second profile alongside the real account, and every screen that
        // resolves the current user would pick one at random.
        let meCount = ((try? context.fetch(descriptor)) ?? []).filter(\.isMe).count
        accountLog.info("cached profile @\(profile.handle, privacy: .public); isMe rows = \(meCount)")
    }
}
