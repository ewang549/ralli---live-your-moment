import Testing
import Foundation
import SwiftData
@testable import explog

/// A beacon used to stay on the feed forever.
///
/// The server stops returning one six hours past its start time, but that only
/// governs what arrives — nothing removed a row already in the local store, and
/// nothing on the feed asked how old a row was. So yesterday's plans piled up at
/// the top of the list on any device that had synced them.
///
/// These pin the boundary the client now enforces, and its agreement with
/// `BEACON_LIFETIME_MS` in `functions/index.js` — the two are independent copies
/// of one number, and the whole point is that they match.
@MainActor
struct BeaconExpiryTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Friend.self, Chat.self, Clip.self, Message.self,
                             Spot.self, SpotClip.self, Beacon.self])
        let configuration = ModelConfiguration(UUID().uuidString,
                                               schema: schema,
                                               isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    private func beacon(startingIn offset: TimeInterval) -> Beacon {
        Beacon(spot: nil, host: nil, note: "Plan",
               startsAt: .now.addingTimeInterval(offset), capacity: 4)
    }

    @Test func lifetimeMatchesTheServer() {
        // BEACON_LIFETIME_MS = 6 * 60 * 60 * 1000.
        #expect(Beacon.lifetime == 6 * 60 * 60)
    }

    @Test func aBeaconYetToStartIsLive() {
        #expect(beacon(startingIn: 3600).isExpired == false)
    }

    @Test func aBeaconUnderwayIsStillLive() {
        // Started an hour ago: well inside the window, and the case that matters
        // most — an activity in progress must not vanish from under its guests.
        #expect(beacon(startingIn: -3600).isExpired == false)
    }

    @Test func aBeaconJustInsideTheWindowIsLive() {
        #expect(beacon(startingIn: -Beacon.lifetime + 60).isExpired == false)
    }

    @Test func aBeaconPastTheWindowIsExpired() {
        #expect(beacon(startingIn: -Beacon.lifetime - 60).isExpired)
    }

    @Test func expiresAtIsTheStartPlusTheLifetime() {
        let subject = beacon(startingIn: 0)
        #expect(abs(subject.expiresAt.timeIntervalSince(subject.startsAt) - Beacon.lifetime) < 0.001)
    }

    /// Expiry has to be readable off a row that came out of the store, not just
    /// off one held in memory — the feed's rows all arrive via `@Query`.
    @Test func expiryHoldsForStoredRows() throws {
        let context = try makeContext()
        let stale = beacon(startingIn: -Beacon.lifetime - 3600)
        let live = beacon(startingIn: 1800)
        context.insert(stale)
        context.insert(live)
        try context.save()

        let stored = try context.fetch(FetchDescriptor<Beacon>())
        #expect(stored.count == 2)
        #expect(stored.filter { !$0.isExpired }.count == 1)
        #expect(stored.first { !$0.isExpired }?.startsAt == live.startsAt)
    }
}

/// `BeaconSync.prune` is the only thing that deletes a beacon locally, and a
/// wrong answer here removes a plan that's still happening — silently, with no
/// way to get it back short of another sync that happens to mention it. Each
/// rule that narrows it is pinned separately.
@MainActor
struct BeaconPruneTests {
    private func beacon(remoteID: String,
                        isPublic: Bool,
                        startingIn offset: TimeInterval = 3600) -> Beacon {
        let subject = Beacon(spot: nil, host: nil, note: "Plan",
                             startsAt: .now.addingTimeInterval(offset), capacity: 4)
        subject.remoteID = remoteID
        subject.isPublic = isPublic
        return subject
    }

    private func shouldPrune(_ subject: Beacon,
                             returned: Set<String> = [],
                             complete: Bool = true,
                             scopeIsPublic: Bool = false) -> Bool {
        BeaconSync.shouldPrune(subject,
                               returned: returned,
                               responseWasComplete: complete,
                               scopeIsPublic: scopeIsPublic)
    }

    @Test func aRowStillInTheResponseStays() {
        let subject = beacon(remoteID: "abc", isPublic: false)
        #expect(shouldPrune(subject, returned: ["abc"]) == false)
    }

    @Test func aRowMissingFromItsOwnScopeGoes() {
        let subject = beacon(remoteID: "abc", isPublic: false)
        #expect(shouldPrune(subject, returned: ["other"]))
    }

    /// The bug this rule exists to prevent: the two feeds load one after the
    /// other, so if a public sync could delete friends-only rows it would wipe
    /// them every single time the Beacons tab appeared.
    @Test func aPublicSyncLeavesFriendsOnlyRowsAlone() {
        let friendsOnly = beacon(remoteID: "abc", isPublic: false)
        #expect(shouldPrune(friendsOnly, returned: ["other"], scopeIsPublic: true) == false)
    }

    @Test func aFriendsSyncLeavesPublicRowsAlone() {
        let publicOne = beacon(remoteID: "abc", isPublic: true)
        #expect(shouldPrune(publicOne, returned: ["other"], scopeIsPublic: false) == false)
    }

    /// A full page means there may be more behind it, so absence proves nothing.
    @Test func aTruncatedResponsePrunesNothingLive() {
        let subject = beacon(remoteID: "abc", isPublic: false)
        #expect(shouldPrune(subject, returned: ["other"], complete: false) == false)
    }

    /// A beacon created offline has no server identity yet, so no response can
    /// speak for it — deleting it would throw away a plan that was never sent.
    @Test func anUnpublishedRowSurvives() {
        let subject = beacon(remoteID: "", isPublic: false)
        #expect(shouldPrune(subject, returned: ["other"]) == false)
    }

    /// Expiry overrides every one of the rules above — no response can bring an
    /// expired beacon back, so none of them can argue for keeping it.
    @Test func anExpiredRowGoesWhateverTheScope() {
        let stale = beacon(remoteID: "", isPublic: false,
                           startingIn: -Beacon.lifetime - 60)
        #expect(shouldPrune(stale, returned: ["abc"], complete: false, scopeIsPublic: true))
    }

    @Test func anExpiredRowStillInTheResponseGoesToo() {
        let stale = beacon(remoteID: "abc", isPublic: true,
                           startingIn: -Beacon.lifetime - 60)
        #expect(shouldPrune(stale, returned: ["abc"], scopeIsPublic: true))
    }
}

/// A beacon's cover photo has two sources — the file picked on this device and
/// the uploaded copy — and which one a view should draw is the only real
/// decision in it.
@MainActor
struct BeaconCoverTests {
    private func beacon() -> Beacon {
        Beacon(spot: nil, host: nil, note: "Plan", startsAt: .now, capacity: 4)
    }

    @Test func noCoverByDefault() {
        let subject = beacon()
        #expect(subject.hasCoverImage == false)
        #expect(subject.coverImageLocalURL == nil)
        #expect(subject.coverImageRemoteURL == nil)
    }

    /// The host's own device must not wait on a round trip to see its own photo.
    @Test func aLocalFileIsEnough() {
        let subject = beacon()
        subject.coverImageFileName = "beacon-cover-test.jpg"
        #expect(subject.hasCoverImage)
        #expect(subject.coverImageLocalURL?.lastPathComponent == "beacon-cover-test.jpg")
    }

    /// Everyone else only ever has the URL.
    @Test func aRemoteURLIsEnough() {
        let subject = beacon()
        subject.coverImageURL = "https://example.com/cover.jpg"
        #expect(subject.hasCoverImage)
        #expect(subject.coverImageRemoteURL?.absoluteString == "https://example.com/cover.jpg")
    }

    /// An unparseable string is the same as no cover — better the place's
    /// artwork than an empty banner.
    @Test func anUnusableURLIsNoCover() {
        let subject = beacon()
        subject.coverImageURL = ""
        #expect(subject.hasCoverImage == false)
    }
}

/// A clip's publish key is what stops one capture becoming two posts, so the
/// thing worth testing is that it's stable — a key regenerated per attempt
/// deduplicates nothing.
@MainActor
struct ClipRequestIDTests {
    private func clip() -> Clip {
        Clip(author: nil, chat: nil, capturedAt: .now, kind: .video,
             label: "", emoji: "✨", hueA: 0, hueB: 0)
    }

    @Test func everyClipGetsAKey() {
        #expect(clip().clientRequestID.isEmpty == false)
    }

    @Test func theKeyIsTheClipsOwnIdentity() {
        let subject = clip()
        #expect(subject.clientRequestID == subject.id.uuidString)
    }

    @Test func separateCapturesGetSeparateKeys() {
        #expect(clip().clientRequestID != clip().clientRequestID)
    }

    /// The place composer overwrites the key so a double-tapped Post — which
    /// makes two `Clip` rows for one capture — still publishes one log.
    @Test func theKeyCanBePinnedToTheCapture() {
        let shared = UUID().uuidString
        let first = clip()
        let second = clip()
        first.clientRequestID = shared
        second.clientRequestID = shared
        #expect(first.clientRequestID == second.clientRequestID)
        #expect(first.id != second.id)
    }
}
