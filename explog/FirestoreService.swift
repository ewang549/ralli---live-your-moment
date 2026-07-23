import Foundation
import SwiftData
import FirebaseAuth
import FirebaseFirestore

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

    var id: String { uid }
    var atHandle: String { "@\(handleDisplay.isEmpty ? handle : handleDisplay)" }
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
            friendCode: data["friendCode"] as? String
        )
    }

    // MARK: Writes (via callables)

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

    /// Soft profile edits the security rules allow the client to write directly.
    static func updateSoftFields(_ fields: [String: Any]) async throws {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        var payload = fields
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

        try? context.save()
    }
}
