import Foundation
import SwiftData
import FirebaseAuth
import FirebaseStorage
import Observation
import os

private let syncLog = Logger(subsystem: "com.ej.explog", category: "logsync")

/// Moves logs between the device and the server.
///
/// Up: media goes straight to Storage under `logs/{uid}/`, then `publishLog`
/// records the metadata. Down: `listFriendLogs` returns friends' recent logs,
/// which are materialised as `Clip` rows hanging off the author's `Friend`.
///
/// SwiftData stays the read model for every screen — nothing downstream of here
/// knows a clip came from the network. Because synced clips are ordinary `Clip`
/// rows, `LocalStore.wipe` already clears them on an account change.
@Observable
@MainActor
final class LogSync {
    private(set) var isSyncing = false
    private(set) var lastError: String?
    /// Set while a capture is on its way up, so the UI can show it's sending.
    private(set) var isPublishing = false

    /// Why the last upload didn't make it, or nil when nothing is outstanding.
    ///
    /// Separate from `lastError`, which any sync-down failure also writes to:
    /// this one means *your send didn't go out*, which is the only failure the
    /// sender has to act on. The share screen dismisses the moment a capture is
    /// queued, so this is what carries the bad news back to a screen the user
    /// is actually looking at.
    private(set) var lastPublishError: String?
    /// How many of the user's own captures are sitting locally after a failed
    /// upload. Drives the banner's wording — "a log" versus "3 logs".
    private(set) var failedPublishCount = 0

    /// Clears the failure banner. Called when a retry starts and when the user
    /// dismisses it, so a stale message can't outlive the problem.
    func clearPublishError() {
        lastPublishError = nil
        failedPublishCount = 0
    }

    // MARK: Publish

    /// Uploads a clip's media (if any) and records it, then stamps the clip
    /// with its server identity.
    ///
    /// Best-effort by design: a failure here leaves the clip local and visible
    /// to its author. Losing the network must never lose the capture.
    /// Who a captured log goes to.
    ///
    /// `friends` is the default and matches what publishing has always done.
    /// `public` additionally pins the log to a place, which is what puts it in
    /// the Places feed and gives it a real author for Follow to act on.
    enum Audience {
        case friends
        case publicAt(spotID: String)

        var wireValue: String {
            switch self {
            case .friends: "friends"
            case .publicAt: "public"
            }
        }

        var spotID: String? {
            switch self {
            case .friends: nil
            case .publicAt(let id): id
            }
        }
    }

    /// - Parameter recipientUids: For a friends-only log, the accounts it was
    ///   actually addressed to. Empty means the whole friend roster, which is
    ///   what publishing has always meant — the share screen passes the people
    ///   who were picked, so selecting two friends out of ten no longer reaches
    ///   the other eight.
    func publish(_ clip: Clip,
                 context: ModelContext,
                 audience: Audience = .friends,
                 recipientUids: [String] = []) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard !clip.isPublished else { return }

        isPublishing = true
        defer { isPublishing = false }

        // This attempt owns the clip's verdict from here on: a retry that's
        // still in flight isn't a failure, and leaving the old flag set would
        // keep the banner up while the upload is actually succeeding.
        clip.publishFailed = false

        do {
            var storagePath = ""
            var mediaURL = ""

            // Vibe clips are generated from emoji + hues, so there's nothing to
            // upload — the receiving client renders them from the metadata.
            if clip.kind != .vibe, let local = clip.assetURL,
               FileManager.default.fileExists(atPath: local.path) {
                let ext = local.pathExtension.isEmpty ? "dat" : local.pathExtension
                let path = "logs/\(uid)/\(UUID().uuidString).\(ext)"
                let ref = Storage.storage().reference(withPath: path)

                let metadata = StorageMetadata()
                metadata.contentType = Self.contentType(forExtension: ext, kind: clip.kind)

                _ = try await ref.putFileAsync(from: local, metadata: metadata)
                mediaURL = try await ref.downloadURL().absoluteString
                storagePath = path
            }

            var payload: [String: Any] = [
                "kind": clip.kind.rawValue,
                "caption": clip.label,
                "emoji": clip.emoji,
                "hueA": clip.hueA,
                "hueB": clip.hueB,
                "capturedAt": clip.capturedAt.timeIntervalSince1970 * 1000,
            ]
            if !storagePath.isEmpty {
                payload["storagePath"] = storagePath
                payload["mediaURL"] = mediaURL
            }
            payload["audience"] = audience.wireValue
            if let spotID = audience.spotID {
                payload["spotId"] = spotID
            }
            // Omitted when empty so an unaddressed log keeps the server's
            // legacy "everyone you're friends with" meaning rather than
            // becoming a log addressed to nobody.
            let recipients = recipientUids.filter { !$0.isEmpty }
            if !recipients.isEmpty {
                payload["recipientUids"] = Array(Set(recipients))
            }

            let response = try await CallableFunctions.call("publishLog",
                                                            data: payload,
                                                            as: PublishResponse.self)

            // The account can change while a large video uploads; stamping a
            // clip that belongs to a signed-out session would write into a
            // store that's about to be wiped.
            guard Auth.auth().currentUser?.uid == uid else { return }

            clip.remoteID = response.id
            clip.remoteURLString = mediaURL
            clip.authorUID = uid
            clip.publishFailed = false
            try? context.save()
            syncLog.info("published log \(response.id, privacy: .public)")
        } catch {
            // The capture stays on the device either way — that's the point of
            // publishing in the background. What changes here is that the
            // failure is now recorded on the clip and counted, so the UI can
            // say so and offer a retry instead of looking identical to a send
            // that worked.
            clip.publishFailed = true
            try? context.save()
            lastError = "Couldn't share that log."
            lastPublishError = "Couldn't send that log."
            failedPublishCount = Self.failedCount(in: context)
            syncLog.error("publish failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The user's own captures currently sitting on a failed upload.
    ///
    /// Compares `remoteID` to "" rather than asking `isEmpty`: `String.isEmpty`
    /// does not survive translation into a SwiftData fetch and quietly matches
    /// no rows at all. See `publishPending`, where that cost us every retry.
    private static func failedCount(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<Clip>(
            predicate: #Predicate { $0.publishFailed && $0.remoteID == "" && !$0.isRemote }
        )
        return ((try? context.fetch(descriptor)) ?? []).filter { $0.author?.isMe == true }.count
    }

    /// Publishes every local clip of the signed-in user that hasn't reached the
    /// server yet — catches up anything captured while offline.
    ///
    /// This is also the retry path behind the failure banner, and it runs
    /// opportunistically (launch, app foreground, Pulse appearing), so a send
    /// that died on a flaky network usually recovers before the user has to do
    /// anything about it.
    func publishPending(context: ModelContext) async {
        guard Auth.auth().currentUser != nil else { return }
        // `$0.remoteID.isEmpty` here matched nothing: SwiftData can't translate
        // `String.isEmpty` into a fetch and returns an empty result rather than
        // failing, so this catch-up silently did nothing on every launch since
        // it was written. Comparing to "" is the form that actually round-trips.
        let descriptor = FetchDescriptor<Clip>(
            predicate: #Predicate { $0.remoteID == "" && !$0.isRemote }
        )
        let pending = ((try? context.fetch(descriptor)) ?? []).filter { $0.author?.isMe == true }
        guard !pending.isEmpty else {
            clearPublishError()
            return
        }
        // Clear first: a retry in progress isn't a failure, and every clip that
        // fails again re-raises it below.
        clearPublishError()
        for clip in pending {
            // Retry with the audience the capture was actually meant for — a
            // public post that failed to upload must not come back as a
            // friends-only one.
            let audience: Audience = clip.intendedSpotID.isEmpty
                ? .friends
                : .publicAt(spotID: clip.intendedSpotID)
            // A clip that hangs off a chat was addressed to particular people,
            // and the only record of who they were is on the clip itself. With
            // that list empty there is nothing to scope the retry to, and
            // publishing unaddressed means "every friend" server-side — so it
            // isn't sent at all. This also covers the extra local copies a
            // multi-chat send makes: only the copy that carries the recipients
            // is the one meant to go up, the rest are on-device duplicates and
            // must not each become their own log.
            if clip.chat != nil, clip.intendedRecipientUIDs.isEmpty { continue }
            // Same reasoning for the recipient list: a send scoped to two
            // friends must not come back from a retry as a broadcast.
            await publish(clip, context: context, audience: audience,
                          recipientUids: clip.intendedRecipientUIDs)
        }
    }

    // MARK: Sync down

    /// Pulls friends' recent logs and mirrors them into the local cache.
    func syncDown(context: ModelContext) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let response = try await CallableFunctions.call("listFriendLogs",
                                                            data: ["limit": 80],
                                                            as: FriendLogsResponse.self)

            // Same guard as FriendGraph.refresh: never touch the store on
            // behalf of an account that is no longer signed in.
            guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }

            materialise(response.logs, into: context)
            lastError = nil
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't reach the server."
        }
    }

    /// Pulls the public feed and mirrors it into local `SpotClip` rows — the
    /// read model the Places tab already renders.
    ///
    /// Unlike `syncDown`, nothing here is skipped for want of a local `Friend`:
    /// the whole point of the public feed is content from people the viewer has
    /// no relationship with, and each log carries its own author identity.
    func syncPublicDown(context: ModelContext, spotID: String? = nil) async {
        guard let uid = Auth.auth().currentUser?.uid else { return }

        do {
            var payload: [String: Any] = ["limit": 80]
            if let spotID { payload["spotId"] = spotID }
            let response = try await CallableFunctions.call("listPublicLogs",
                                                            data: payload,
                                                            as: PublicLogsResponse.self)

            guard !Task.isCancelled, Auth.auth().currentUser?.uid == uid else { return }

            materialisePublic(response.logs, into: context)
            lastError = nil
        } catch let error as CallableFunctions.CallableError {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = error.message
        } catch {
            guard Auth.auth().currentUser?.uid == uid else { return }
            lastError = "Couldn't reach the server."
        }
    }

    /// Creates or updates a `SpotClip` per public log, hanging it off a local
    /// mirror of its spot.
    private func materialisePublic(_ logs: [RemotePublicLog], into context: ModelContext) {
        guard !logs.isEmpty else { return }

        let existing = (try? context.fetch(FetchDescriptor<SpotClip>())) ?? []
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

        for log in logs {
            // A public log always has a spot server-side; a row that somehow
            // lost one is skipped rather than shown floating in the feed.
            guard !log.spotId.isEmpty else { continue }

            let spot: Spot
            if let known = spots[log.spotId] {
                spot = known
            } else {
                spot = Spot(name: log.spotName, category: "", summary: "", aiInsight: "",
                            distanceMiles: 0, emoji: log.emoji,
                            hueA: log.hueA, hueB: log.hueB)
                spot.remoteID = log.spotId
                context.insert(spot)
                spots[log.spotId] = spot
            }

            let clip: SpotClip
            if let known = byRemoteID[log.id] {
                clip = known
            } else {
                clip = SpotClip(spot: spot,
                                authorName: log.authorName,
                                authorUID: log.authorUid,
                                label: log.caption,
                                emoji: log.emoji,
                                hueA: log.hueA,
                                hueB: log.hueB,
                                capturedAt: Date(timeIntervalSince1970: log.capturedAt / 1000))
                context.insert(clip)
            }

            clip.remoteID = log.id
            clip.remoteURLString = log.mediaURL
            // The server has always sent the kind; nothing used to read it, so
            // a real photo or video landed in the feed indistinguishable from a
            // vibe placeholder. Rows published before `SpotClip` had a kind
            // decode to `.vibe` and keep rendering as they did.
            clip.kindRaw = (ClipKind(rawValue: log.kind) ?? .vibe).rawValue
            clip.authorUID = log.authorUid
            clip.authorName = log.authorName
            // The server sends both of these on every public log and nothing
            // used to read them, so the Places feed drew a generic orb for
            // authors who had a real profile photo the whole time.
            clip.authorAvatarURL = log.authorAvatarURL
            clip.authorAvatarEmoji = log.authorAvatarEmoji
            clip.label = log.caption
            clip.emoji = log.emoji
            if clip.spot == nil { clip.spot = spot }
        }

        try? context.save()
    }

    /// Creates or updates a `Clip` per remote log, attached to its author.
    ///
    /// Logs whose author has no local `Friend` row are skipped rather than
    /// invented: the roster is the friend graph's job, and a clip with no owner
    /// would render as a ghost row.
    private func materialise(_ logs: [RemoteLog], into context: ModelContext) {
        guard !logs.isEmpty else { return }

        let friends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []
        let byUID = Dictionary(
            friends.filter { !$0.remoteUID.isEmpty }.map { ($0.remoteUID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let existing = (try? context.fetch(FetchDescriptor<Clip>())) ?? []
        let byRemoteID = Dictionary(
            existing.filter { !$0.remoteID.isEmpty }.map { ($0.remoteID, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for log in logs {
            guard let author = byUID[log.authorUid] else { continue }

            let clip: Clip
            if let known = byRemoteID[log.id] {
                clip = known
            } else {
                clip = Clip(author: author,
                            chat: nil,
                            capturedAt: Date(timeIntervalSince1970: log.capturedAt / 1000),
                            kind: ClipKind(rawValue: log.kind) ?? .vibe,
                            label: log.caption,
                            emoji: log.emoji,
                            hueA: log.hueA,
                            hueB: log.hueB)
                context.insert(clip)
            }

            clip.remoteID = log.id
            clip.remoteURLString = log.mediaURL
            clip.authorUID = log.authorUid
            clip.isRemote = true
            clip.label = log.caption
            clip.emoji = log.emoji
            if clip.author == nil { clip.author = author }
        }

        try? context.save()
    }

    private static func contentType(forExtension ext: String, kind: ClipKind) -> String {
        switch ext.lowercased() {
        case "mov": "video/quicktime"
        case "mp4", "m4v": "video/mp4"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "heic": "image/heic"
        default: kind == .video ? "video/mp4" : "image/jpeg"
        }
    }

    // MARK: Wire types

    private struct PublishResponse: Decodable {
        let id: String
        let capturedAt: Double
    }

    private struct FriendLogsResponse: Decodable {
        let logs: [RemoteLog]
    }

    private struct PublicLogsResponse: Decodable {
        let logs: [RemotePublicLog]
    }

    /// A public log. Carries its author's identity inline — the Places feed
    /// renders attribution for people the viewer has no relationship with, so
    /// there's no local row to read a name off.
    struct RemotePublicLog: Decodable {
        let id: String
        let authorUid: String
        let authorName: String
        let authorHandle: String
        let authorAvatarEmoji: String
        let authorAvatarURL: String
        let spotId: String
        let spotName: String
        let kind: String
        let mediaURL: String
        let caption: String
        let emoji: String
        let hueA: Double
        let hueB: Double
        let capturedAt: Double
    }

    struct RemoteLog: Decodable {
        let id: String
        let authorUid: String
        let kind: String
        let mediaURL: String
        let caption: String
        let emoji: String
        let hueA: Double
        let hueB: Double
        let capturedAt: Double
    }
}
