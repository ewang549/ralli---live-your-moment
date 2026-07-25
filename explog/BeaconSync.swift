import Foundation
import SwiftData
import FirebaseAuth
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

        var payload: [String: Any] = [
            "note": beacon.note,
            "startsAt": beacon.startsAt.timeIntervalSince1970 * 1000,
            "capacity": beacon.capacity,
            "isPublic": beacon.isPublic,
        ]
        if let spotID = beacon.spot?.remoteID, !spotID.isEmpty {
            payload["spotId"] = spotID
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
                                                            data: ["limit": 80],
                                                            as: BeaconsResponse.self)

            // Same guard as FriendGraph.refresh: never touch the store on
            // behalf of an account that is no longer signed in.
            guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }

            materialise(response.beacons, into: context)
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
    }
}
