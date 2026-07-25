import Foundation
import FirebaseAuth
import Observation

/// The signed-in user's follow graph — the accounts they follow.
///
/// Deliberately much thinner than `FriendGraph`. A follow is one-directional,
/// needs no acceptance, and creates nothing locally: there's no `Friend` row to
/// reconcile, no chat channel, no requests inbox. All it does is decide whose
/// highlights land in the Following tab under Places, and what the Follow button
/// on a public profile reads.
///
/// Firestore is the source of truth; this is a cache of `listFollowing` that the
/// follow/unfollow actions keep current so the UI settles on the same frame as
/// the tap rather than a round trip later.
@Observable
@MainActor
final class FollowGraph {
    private(set) var following: [RemoteProfile] = []
    private(set) var isRefreshing = false
    /// Last failure, for surfacing "couldn't reach the server".
    private(set) var lastError: String?

    /// Display names of everyone followed, lowercased. The Following feed
    /// matches place clips by author name — the same signal the public
    /// profile's own Highlights grid uses, since `SpotClip` carries a plain
    /// author name rather than an account reference.
    var followedNames: Set<String> {
        Set(following.map { $0.name.lowercased() })
    }

    /// Uids of everyone followed — the exact signal, used for any clip that
    /// carries a real author rather than just a name.
    var followedUIDs: Set<String> {
        Set(following.map(\.uid))
    }

    func isFollowing(_ uid: String) -> Bool {
        following.contains { $0.uid == uid }
    }

    /// Pulls the followed list. Signed-out is a no-op, and the account is
    /// re-checked after the call so a sign-out landing mid-flight can't leave
    /// the previous account's list on screen.
    func refresh() async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let loaded = try await FirestoreService.listFollowing()
            guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }
            following = loaded
            lastError = nil
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't reach the server."
        }
    }

    /// Drops everything held in memory, so a new sign-in can't briefly render
    /// the previous account's Following feed.
    func clear() {
        following = []
        lastError = nil
    }

    // MARK: Actions
    //
    // Both apply the server's answer to the local list immediately. Callers do
    // their own optimistic button state and roll it back if these throw.

    @discardableResult
    func follow(_ profile: RemoteProfile) async throws -> FirestoreService.FollowResult {
        let result = try await FirestoreService.followUser(profile.uid)
        if !following.contains(where: { $0.uid == profile.uid }) {
            following.append(profile)
        }
        return result
    }

    @discardableResult
    func unfollow(_ profile: RemoteProfile) async throws -> FirestoreService.FollowResult {
        let result = try await FirestoreService.unfollowUser(profile.uid)
        following.removeAll { $0.uid == profile.uid }
        return result
    }
}
