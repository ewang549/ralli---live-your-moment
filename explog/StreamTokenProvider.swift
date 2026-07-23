import Foundation
import FirebaseAuth

/// Production token path: after Firebase sign-in the app calls the
/// `getStreamToken` Cloud Function, which quietly upserts a matching Stream
/// user (id = Firebase uid) and returns a token. Users never see Stream.
enum StreamTokenProvider {
    struct Credentials: Decodable {
        let apiKey: String
        let userId: String
        let token: String
    }

    private struct CallableResponse: Decodable {
        let result: Credentials
    }

    /// Callable endpoint (deployed via `firebase deploy --only functions`).
    private static let endpoint = URL(string: "https://us-central1-explog-723b7.cloudfunctions.net/getStreamToken")!

    static func fetchToken(for user: User) async throws -> Credentials {
        let idToken = try await user.getIDToken()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": [:]])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CallableResponse.self, from: data).result
    }

    /// Calls `joinStreamChannel` (admin-privileged server secret) to guarantee
    /// the current user is a member of `channelId`, whether it's brand new or
    /// already existed without them — a client-side create can't fix the
    /// latter case since adding yourself requires already being a member.
    private static let joinChannelEndpoint = URL(string: "https://us-central1-explog-723b7.cloudfunctions.net/joinStreamChannel")!

    static func joinChannel(channelId: String, otherMemberIds: [String], name: String?) async throws {
        guard let user = Auth.auth().currentUser else { return }
        let idToken = try await user.getIDToken()

        var request = URLRequest(url: joinChannelEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        var payload: [String: Any] = ["channelId": channelId, "members": otherMemberIds]
        if let name { payload["name"] = name }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": payload])

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }
}
