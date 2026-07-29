import Foundation
import SwiftData
import FirebaseAuth
import FirebaseStorage
import Observation
import os

private let beaconLog = Logger(subsystem: "com.ej.explog", category: "beaconsync")

/// Moves beacons between the device and the server.
///
/// Same shape as `LogSync`: up through `createBeacon`, down through
/// `listFriendBeacons` / `listPublicBeacons`, materialised into ordinary
/// `Beacon` rows so every screen keeps reading the SwiftData model it always
/// has. Nothing downstream of here knows a beacon came from the network, and
/// because they're ordinary rows `LocalStore.wipe` already clears them on an
/// account change.
///
/// A beacon carries no media, so unlike a log there's no upload step — the
/// callable is the whole publish.
@Observable
@MainActor
final class BeaconSync {
    private(set) var isSyncing = false
    /// Last failure, for surfacing "couldn't reach the server" on the feed.
    private(set) var lastError: String?

    func clearError() { lastError = nil }

    // MARK: Publish

    /// Records a locally-created beacon on the server and stamps it with its
    /// server identity.
    ///
    /// Best-effort, like publishing a log: a failure leaves the beacon on the
    /// device and visible to its host. Losing the network must not lose the
    /// plan — but it does mean nobody else sees it, which `publishPending`
    /// picks up on the next sync.
    func publish(_ beacon: Beacon, context: ModelContext) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard beacon.remoteID.isEmpty else { return }

        // The cover photo goes up first, because `createBeacon` stores its URL.
        //
        // Best-effort on purpose: a plan nobody can see is a worse outcome than
        // a plan without its picture, so a failed upload doesn't abort the
        // publish. The file stays in Documents and the host keeps seeing their
        // own cover locally either way.
        if beacon.coverImageURL.isEmpty, let local = beacon.coverImageLocalURL {
            do {
                let uploaded = try await Self.uploadCover(at: local, uid: uid)
                guard Auth.auth().currentUser?.uid == uid else { return }
                beacon.coverImageURL = uploaded.url
                beacon.coverStoragePath = uploaded.path
                try? context.save()
            } catch {
                beaconLog.error("""
                    cover upload failed, publishing without it: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }

        var payload: [String: Any] = [
            "note": beacon.note,
            "startsAt": beacon.startsAt.timeIntervalSince1970 * 1000,
            "capacity": beacon.capacity,
            "isPublic": beacon.isPublic,
        ]
        if let spotID = beacon.spot?.remoteID, !spotID.isEmpty {
            payload["spotId"] = spotID
        }
        if !beacon.coverImageURL.isEmpty, !beacon.coverStoragePath.isEmpty {
            payload["coverImageURL"] = beacon.coverImageURL
            payload["coverStoragePath"] = beacon.coverStoragePath
        }

        do {
            let response = try await CallableFunctions.call("createBeacon",
                                                            data: payload,
                                                            as: CreateResponse.self)

            // The account can change mid-flight; stamping a row that belongs to
            // a signed-out session would write into a store about to be wiped.
            guard Auth.auth().currentUser?.uid == uid else { return }

            beacon.remoteID = response.beacon.id
            beacon.hostUID = response.beacon.hostUid
            beacon.hostName = response.beacon.hostName
            beacon.hostEmoji = response.beacon.hostAvatarEmoji
            beacon.hostAvatarURL = response.beacon.hostAvatarURL
            beacon.joinedUIDs = response.beacon.joinedUids
            // The server clamps both of these, so take its answer rather than
            // leaving the card promising something it won't honour.
            beacon.capacity = response.beacon.capacity
            beacon.startsAt = Date(timeIntervalSince1970: response.beacon.startsAt / 1000)
            // Only ever adopted, never cleared: the server echoes back "" for a
            // beacon posted without a cover, and for one whose upload failed the
            // local file is still the only copy there is.
            if let cover = response.beacon.coverImageURL, !cover.isEmpty {
                beacon.coverImageURL = cover
            }
            try? context.save()
            beaconLog.info("published beacon \(response.beacon.id, privacy: .public)")
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
            beaconLog.error("createBeacon failed: \(error.message, privacy: .public)")
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't share that beacon."
            beaconLog.error("createBeacon failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts a picked cover photo in Storage under the host's own prefix, which
    /// is what both the Storage rules and `createBeacon` require.
    ///
    /// Same shape as `FirestoreService.uploadAvatarPhoto` and `LogSync`'s media
    /// step. Returns both halves because the callable wants both: the path is
    /// what it can verify, the URL is what it stores.
    private static func uploadCover(at localURL: URL, uid: String) async throws -> (path: String, url: String) {
        let path = "beacons/\(uid)/\(UUID().uuidString).jpg"
        let ref = Storage.storage().reference(withPath: path)
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"

        _ = try await ref.putFileAsync(from: localURL, metadata: metadata)
        return (path, try await ref.downloadURL().absoluteString)
    }

    /// Publishes every beacon the user hosts that hasn't reached the server —
    /// catches up anything created while offline. Runs alongside the sync-down
    /// on the feed's `.task`, the same way `LogSync.publishPending` rides along
    /// with Pulse's.
    func publishPending(context: ModelContext) async {
        guard Auth.auth().currentUser != nil else { return }
        // Comparing to "" rather than asking `isEmpty`: SwiftData can't
        // translate `String.isEmpty` into a fetch and silently matches nothing.
        // See the same note on `LogSync.publishPending`.
        let descriptor = FetchDescriptor<Beacon>(predicate: #Predicate { $0.remoteID == "" })
        let pending = ((try? context.fetch(descriptor)) ?? []).filter { $0.host?.isMe == true }
        for beacon in pending {
            await publish(beacon, context: context)
        }
    }

    // MARK: Sync down

    /// How many rows a sync-down asks for. Named because `prune` needs it: a
    /// response that filled the page might have left live beacons behind it,
    /// and deleting those would be pruning on incomplete information.
    private static let pageLimit = 80

    /// Pulls friends-only beacons hosted by the caller's friends (and their own)
    /// and mirrors them into the local cache.
    func syncDown(context: ModelContext) async {
        await load("listFriendBeacons", context: context)
    }

    /// Pulls the public community feed.
    func syncPublicDown(context: ModelContext) async {
        await load("listPublicBeacons", context: context)
    }

    private func load(_ callable: String, context: ModelContext) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let response = try await CallableFunctions.call(callable,
                                                            data: ["limit": Self.pageLimit],
                                                            as: BeaconsResponse.self)

            // Same guard as FriendGraph.refresh: never touch the store on
            // behalf of an account that is no longer signed in.
            guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }

            materialise(response.beacons, into: context)
            prune(against: response.beacons, from: callable, into: context)
            lastError = nil
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't reach the server."
        }
    }

    // MARK: RSVP

    /// RSVPs, applying the change locally first so the button settles on the
    /// same frame it's tapped, then reconciling with the server's answer.
    ///
    /// A rejection (full, ended, not a friend, private profile) rolls the local
    /// change back and reports why — the server is the one that decides, and a
    /// button that stays lit after a refused join is worse than no button.
    func join(_ beacon: Beacon, as me: Friend, context: ModelContext) async {
        apply(joining: true, beacon: beacon, me: me, context: context)

        // Seeded/offline beacons have no server row to tell about it.
        guard !beacon.remoteID.isEmpty else { return }

        do {
            let response = try await CallableFunctions.call(
                "joinBeacon", data: ["beaconId": beacon.remoteID], as: RSVPResponse.self)
            beacon.joinedUIDs = response.joinedUids
            try? context.save()
        } catch {
            apply(joining: false, beacon: beacon, me: me, context: context)
            report(error)
        }
    }

    func leave(_ beacon: Beacon, as me: Friend, context: ModelContext) async {
        apply(joining: false, beacon: beacon, me: me, context: context)

        guard !beacon.remoteID.isEmpty else { return }

        do {
            let response = try await CallableFunctions.call(
                "leaveBeacon", data: ["beaconId": beacon.remoteID], as: RSVPResponse.self)
            beacon.joinedUIDs = response.joinedUids
            try? context.save()
        } catch {
            apply(joining: true, beacon: beacon, me: me, context: context)
            report(error)
        }
    }

    /// Both halves of an RSVP, kept together so the optimistic apply and its
    /// rollback can never drift out of step.
    private func apply(joining: Bool, beacon: Beacon, me: Friend, context: ModelContext) {
        if joining {
            if !beacon.joined.contains(where: { $0.id == me.id }) {
                beacon.joined.append(me)
            }
            if !me.remoteUID.isEmpty, !beacon.joinedUIDs.contains(me.remoteUID) {
                beacon.joinedUIDs.append(me.remoteUID)
            }
        } else {
            beacon.joined.removeAll { $0.id == me.id }
            if !me.remoteUID.isEmpty {
                beacon.joinedUIDs.removeAll { $0 == me.remoteUID }
            }
        }
        try? context.save()
    }

    private func report(_ error: Error) {
        if let callable = error as? CallableFunctions.CallableError {
            lastError = callable.message
        } else {
            lastError = "Couldn't reach the server."
        }
    }

    // MARK: Local cache reconciliation

    /// Creates or updates a `Beacon` per remote row, keyed by `remoteID`.
    ///
    /// Unlike `LogSync.materialise`, nothing is skipped for want of a local
    /// `Friend`: a public beacon's host is usually a stranger, and the row
    /// carries their identity inline. Hosts and attendees are still resolved
    /// against local rows when they exist, so a friend's beacon renders with
    /// their real avatar and shows up in "my activities".
    private func materialise(_ remotes: [RemoteBeacon], into context: ModelContext) {
        guard !remotes.isEmpty else { return }

        let friends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        let byUID = Dictionary(
            friends.filter { !$0.remoteUID.isEmpty }.map { ($0.remoteUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let existing = (try? context.fetch(FetchDescriptor<Beacon>())) ?? []
        let byRemoteID = Dictionary(
            existing.filter { !$0.remoteID.isEmpty }.map { ($0.remoteID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var spots = Dictionary(
            ((try? context.fetch(FetchDescriptor<Spot>())) ?? [])
                .filter { !$0.remoteID.isEmpty }
                .map { ($0.remoteID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for remote in remotes {
            // A beacon needn't be pinned to a place; when it is, mirror the
            // spot the same way the public log feed does so the card's hero and
            // detail sheet have something to render.
            var spot: Spot?
            if !remote.spotId.isEmpty {
                if let known = spots[remote.spotId] {
                    spot = known
                } else {
                    let created = Spot(name: remote.spotName, category: remote.spotCategory,
                                       summary: "", aiInsight: "", distanceMiles: 0,
                                       emoji: remote.spotEmoji,
                                       hueA: remote.spotHueA, hueB: remote.spotHueB)
                    created.remoteID = remote.spotId
                    created.address = remote.spotAddress
                    context.insert(created)
                    spots[remote.spotId] = created
                    spot = created
                }
            }

            let beacon: Beacon
            if let known = byRemoteID[remote.id] {
                beacon = known
            } else {
                beacon = Beacon(spot: spot,
                                host: byUID[remote.hostUid],
                                note: remote.note,
                                startsAt: Date(timeIntervalSince1970: remote.startsAt / 1000),
                                capacity: remote.capacity)
                context.insert(beacon)
            }

            beacon.remoteID = remote.id
            beacon.hostUID = remote.hostUid
            beacon.hostName = remote.hostName
            beacon.hostEmoji = remote.hostAvatarEmoji
            beacon.hostAvatarURL = remote.hostAvatarURL
            beacon.note = remote.note
            beacon.startsAt = Date(timeIntervalSince1970: remote.startsAt / 1000)
            beacon.capacity = remote.capacity
            beacon.isPublic = remote.isPublic
            // As in `publish`: an absent cover doesn't wipe a local file that a
            // host is still waiting to upload.
            if let cover = remote.coverImageURL, !cover.isEmpty {
                beacon.coverImageURL = cover
            }
            beacon.joinedUIDs = remote.joinedUids
            if beacon.spot == nil { beacon.spot = spot }
            if beacon.host == nil { beacon.host = byUID[remote.hostUid] }

            // Mirror the roster onto the relationship for everyone we can name.
            // Rebuilt rather than appended to, so someone who dropped out on
            // another device disappears here too.
            let attending = remote.joinedUids.compactMap { byUID[$0] }
            beacon.joined = attending
        }

        try? context.save()
    }

    /// Deletes local rows a sync-down says are gone.
    ///
    /// `materialise` only ever adds and updates, so before this nothing removed
    /// a beacon from the device: one the host deleted, or one that aged past the
    /// server's six-hour window, stayed in the store for good. The feed hides
    /// expired ones now (`Beacon.isExpired`), but they were still accumulating
    /// behind it, and a deleted beacon has no expiry to hide behind at all.
    ///
    /// Two rules, because a single response never describes the whole store:
    ///
    /// - **Expired rows go unconditionally.** No response can bring one back —
    ///   the server filters them out — so keeping one is pure sediment.
    /// - **Rows missing from the response go only when the response is
    ///   authoritative about them.** Each callable covers one audience, so a
    ///   public sync must not delete friends-only beacons and vice versa; and a
    ///   response that filled its page may simply have run out of room, so
    ///   nothing is pruned on that basis unless it came back short.
    ///
    /// Beacons that never reached the server (`remoteID` empty — seed rows, and
    /// ones created offline that `publishPending` still owes an upload) are only
    /// ever pruned by the expiry rule: no server response knows about them.
    private func prune(against remotes: [RemoteBeacon], from callable: String, into context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Beacon>())) ?? []
        guard !all.isEmpty else { return }

        let returned = Set(remotes.map(\.id))
        let responseWasComplete = remotes.count < Self.pageLimit
        // `listPublicBeacons` speaks for public beacons, `listFriendBeacons` for
        // friends-only ones. A friend's public beacon shows up in both feeds but
        // is only ever *removed* on the authority of the public one.
        let scopeIsPublic = callable == "listPublicBeacons"

        var removed = 0
        for beacon in all {
            guard Self.shouldPrune(beacon,
                                   returned: returned,
                                   responseWasComplete: responseWasComplete,
                                   scopeIsPublic: scopeIsPublic) else { continue }
            context.delete(beacon)
            removed += 1
        }

        guard removed > 0 else { return }
        try? context.save()
        beaconLog.info("pruned \(removed, privacy: .public) stale beacon(s)")
    }

    /// The decision behind `prune`, split out so the scoping rules can be tested
    /// without a signed-in session and a network round trip. Getting these wrong
    /// deletes beacons that are still live, which is silent and unrecoverable —
    /// so they're worth pinning down.
    ///
    /// - Parameters:
    ///   - returned: `remoteID`s the response actually carried.
    ///   - responseWasComplete: false when the page filled, i.e. live beacons may
    ///     exist beyond it that this response says nothing about.
    ///   - scopeIsPublic: which audience the callable speaks for.
    static func shouldPrune(_ beacon: Beacon,
                            returned: Set<String>,
                            responseWasComplete: Bool,
                            scopeIsPublic: Bool) -> Bool {
        if beacon.isExpired { return true }

        return responseWasComplete
            && !beacon.remoteID.isEmpty
            && beacon.isPublic == scopeIsPublic
            && !returned.contains(beacon.remoteID)
    }

    // MARK: Wire types

    private struct BeaconsResponse: Decodable {
        let beacons: [RemoteBeacon]
    }

    private struct CreateResponse: Decodable {
        let beacon: RemoteBeacon
    }

    private struct RSVPResponse: Decodable {
        let joinedUids: [String]
    }

    /// A beacon as the server holds it. Host and spot identity are denormalised
    /// onto it for the same reason `RemotePublicLog` denormalises its author:
    /// the community feed shows activities hosted by people the viewer has no
    /// relationship with, so there's no local row to read a name off.
    struct RemoteBeacon: Decodable {
        let id: String
        let hostUid: String
        let hostName: String
        let hostHandle: String
        let hostAvatarEmoji: String
        let hostAvatarURL: String
        let spotId: String
        let spotName: String
        let spotCategory: String
        let spotAddress: String
        let spotEmoji: String
        let spotHueA: Double
        let spotHueB: Double
        let note: String
        let startsAt: Double
        let capacity: Int
        let isPublic: Bool
        let joinedUids: [String]
        /// Optional rather than defaulted: beacons created before covers existed
        /// carry no such field, and a non-optional would fail the whole decode —
        /// dropping the entire feed over a missing photo. Same convention as
        /// `LogSync`'s optional counters.
        let coverImageURL: String?
    }
}
