import Foundation
import SwiftData
import FirebaseAuth
import Observation
import os

/// Account/cache lifecycle logging — this path decides whether one account can
/// see another's data, so it says what it did.
let accountLog = Logger(subsystem: "com.ej.explog", category: "account")

/// Resolved Firebase auth state, shared across the app.
///
/// The distinction that matters: `Auth.auth().currentUser` is restored
/// *asynchronously* at launch, so reading it synchronously returns `nil` for a
/// moment even when someone is signed in. Anything that branches on "is this a
/// real account?" must wait for `isResolved`, or it will make the wrong call on
/// a cold start — which is exactly how demo data leaked into a real account.
@Observable
@MainActor
final class AuthSession {
    /// Firebase uid, or nil when signed out. Meaningless until `isResolved`.
    private(set) var uid: String?
    /// True once the auth listener has reported at least once.
    private(set) var isResolved = false

    @ObservationIgnored private var listener: AuthStateDidChangeListenerHandle?

    /// Fires on every resolved change, including the first. `nil` = signed out.
    var onChange: ((String?) -> Void)?

    func start() {
        guard listener == nil else { return }
        listener = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            self.uid = user?.uid
            self.isResolved = true
            self.onChange?(user?.uid)
        }
    }

    func stop() {
        if let listener { Auth.auth().removeStateDidChangeListener(listener) }
        listener = nil
    }

    /// True only when we *know* nobody is signed in.
    var isConfirmedSignedOut: Bool { isResolved && uid == nil }
}

// MARK: - Local store ownership

/// The SwiftData store is a per-account cache, not a shared database.
///
/// It therefore has an owner: the uid whose data it holds (`nil` = demo /
/// signed-out). When the owner changes — sign in, sign out, or switching
/// accounts — the cache is wiped, so one account can never inherit another's
/// friends, clips or chats, and a real account can never inherit demo seed data.
enum LocalStore {
    private static let ownerKey = "explog.localStoreOwnerUID"

    static var ownerUID: String? {
        get { UserDefaults.standard.string(forKey: ownerKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: ownerKey)
            } else {
                UserDefaults.standard.removeObject(forKey: ownerKey)
            }
        }
    }

    /// Marks the store as belonging to `uid`, wiping it first if it belonged to
    /// someone else. Returns true when a wipe happened.
    @MainActor
    @discardableResult
    static func claim(by uid: String?, context: ModelContext) -> Bool {
        let previous = ownerUID
        guard previous != uid else {
            accountLog.info("local store already owned by \(uid ?? "demo", privacy: .public)")
            return false
        }
        accountLog.info("local store owner \(previous ?? "demo", privacy: .public) -> \(uid ?? "demo", privacy: .public); wiping cache")
        wipe(context: context)
        ownerUID = uid
        return true
    }

    /// Deletes every locally cached model. Cascade rules handle the children,
    /// but each type is deleted explicitly so nothing survives a rule change.
    @MainActor
    static func wipe(context: ModelContext) {
        let before = (try? context.fetchCount(FetchDescriptor<Friend>())) ?? -1

        // Instance deletes, not `context.delete(model:)`. The batch form fails
        // on this schema — "mandatory OTO nullify inverse on Clip/author" —
        // because it can't nullify the to-one inverses. Deleting objects lets
        // SwiftData maintain the relationships as it goes.
        //
        // Children before parents, so cascades never race the explicit deletes.
        deleteAll(Clip.self, in: context)
        deleteAll(Message.self, in: context)
        deleteAll(SpotClip.self, in: context)
        deleteAll(Beacon.self, in: context)
        deleteAll(Chat.self, in: context)
        deleteAll(Spot.self, in: context)
        deleteAll(Friend.self, in: context)

        do {
            try context.save()
        } catch {
            accountLog.error("cache wipe failed: \(error.localizedDescription.prefix(500), privacy: .public)")
        }
        let after = (try? context.fetchCount(FetchDescriptor<Friend>())) ?? -1
        accountLog.info("cache wipe: friends \(before) -> \(after)")
    }

    @MainActor
    private static func deleteAll<T: PersistentModel>(_ type: T.Type, in context: ModelContext) {
        let objects = (try? context.fetch(FetchDescriptor<T>())) ?? []
        for object in objects { context.delete(object) }
    }
}
