import Testing
import Foundation
import SwiftData
import UIKit
@testable import explog

@MainActor
struct explogTests {
    /// A store of this test's own.
    ///
    /// Named per call so tests that count all rows of a type can't be affected
    /// by the ones Swift Testing is running alongside them in the same process.
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Friend.self, Chat.self, Clip.self, Message.self,
                             Spot.self, SpotClip.self, Beacon.self])
        let configuration = ModelConfiguration(UUID().uuidString,
                                               schema: schema,
                                               isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return ModelContext(container)
    }

    @Test func cooldownBlocksWithinTheHour() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        // Sent at the top of the current clock hour — pinned to the hour
        // boundary rather than "n seconds ago" so the case under test is the
        // same whatever time of day this runs at.
        let thisHour = Calendar.current.dateInterval(of: .hour, for: .now)!.start
        let chat = Chat(isGroup: false, members: [me, pal], lastSentAt: thisHour)
        context.insert(chat)

        // What's left is the time to the next :00 — *not* a fixed 60 minutes
        // from the send. That's the whole point of the top-of-hour rule.
        let remaining = chat.cooldownRemaining
        #expect(remaining > 0)
        #expect(remaining <= 3600)
        #expect(abs(remaining - thisHour.addingTimeInterval(3600).timeIntervalSince(.now)) < 2)
    }

    /// The rule is one send per *clock* hour, so crossing `:00` clears the
    /// cooldown even when the send itself was only moments ago.
    @Test func cooldownClearsOnceTheHourRollsOver() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let justBeforeThisHour = Calendar.current.dateInterval(of: .hour, for: .now)!
            .start.addingTimeInterval(-1)
        let chat = Chat(isGroup: false, members: [me, pal], lastSentAt: justBeforeThisHour)
        context.insert(chat)

        #expect(chat.cooldownRemaining == 0)
    }

    @Test func cooldownExpiresAfterAnHour() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let chat = Chat(isGroup: false, members: [me], lastSentAt: Date(timeIntervalSinceNow: -3700))
        context.insert(chat)
        #expect(chat.cooldownRemaining == 0)
    }

    @Test func neverSentMeansNoCooldown() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let chat = Chat(isGroup: false, members: [me])
        context.insert(chat)
        #expect(chat.cooldownRemaining == 0)
    }

    @Test func cooldownStringMatchesSketchFormat() {
        #expect(cooldownString(3541) == "59:01")
        #expect(cooldownString(0) == "00:00")
        #expect(cooldownString(61) == "01:01")
    }

    @Test func membershipInMultipleChatsIsPreserved() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let solo = Chat(isGroup: false, members: [me, pal])
        let group = Chat(title: "crew", isGroup: true, members: [me, pal])
        context.insert(solo)
        context.insert(group)
        try context.save()

        // Regression test: implicit inverses used to drop `pal` from the first chat.
        #expect(solo.members.count == 2)
        #expect(group.members.count == 2)
        #expect(solo.displayName == "Pal")
    }

    @Test func latestClipPerFriendPicksNewest() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        let old = Clip(author: pal, chat: chat, capturedAt: Date(timeIntervalSinceNow: -7200),
                       kind: .vibe, label: "old", emoji: "a", hueA: 0, hueB: 0)
        let new = Clip(author: pal, chat: chat, capturedAt: Date(timeIntervalSinceNow: -60),
                       kind: .vibe, label: "new", emoji: "b", hueA: 0, hueB: 0)
        context.insert(old)
        context.insert(new)
        chat.clips = [old, new]

        #expect(chat.latestClip(by: pal)?.label == "new")
        #expect(chat.sortedClips.first?.label == "new")
    }

    @Test func beaconCapacityAndJoinState() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let a = Friend(name: "A", emoji: "a", hue: 0.1)
        let b = Friend(name: "B", emoji: "b", hue: 0.2)
        let beacon = Beacon(spot: nil, host: nil, note: "", startsAt: .now, capacity: 2, joined: [a])
        context.insert(beacon)

        #expect(!beacon.isFull)
        #expect(beacon.hasJoined(a))
        #expect(!beacon.hasJoined(me))

        beacon.joined.append(b)
        #expect(beacon.isFull)
    }

    @Test func attendeeRosterPutsHostFirst() throws {
        let context = try makeContext()
        let host = Friend(name: "Host", emoji: "h", hue: 0.1)
        let guest = Friend(name: "Guest", emoji: "g", hue: 0.2)
        let beacon = Beacon(spot: nil, host: host, note: "", startsAt: .now,
                            capacity: 5, joined: [guest, host])
        context.insert(beacon)

        // Host leads the roster and is not double-counted even if also in `joined`.
        #expect(beacon.attendees.map(\.name) == ["Host", "Guest"])
        #expect(beacon.isAttending(host))
        #expect(beacon.isAttending(guest))
    }

    @Test func activityChatIsScopedByActivityKey() throws {
        let context = try makeContext()
        let a = Beacon(spot: nil, host: nil, note: "", startsAt: .now, capacity: 5)
        let b = Beacon(spot: nil, host: nil, note: "", startsAt: .now, capacity: 5)
        context.insert(a)
        context.insert(b)

        let inA = Message(chat: nil, author: nil, text: "hi A")
        inA.activityId = a.activityKey
        let inB = Message(chat: nil, author: nil, text: "hi B")
        inB.activityId = b.activityKey
        let direct = Message(chat: nil, author: nil, text: "dm")
        [inA, inB, direct].forEach { context.insert($0) }
        try context.save()

        let key = a.activityKey
        let scoped = try context.fetch(FetchDescriptor<Message>(
            predicate: #Predicate { $0.activityId == key }))
        #expect(scoped.map(\.text) == ["hi A"])
    }

    @Test func privacyDefaultsToPublic() throws {
        let friend = Friend(name: "New", emoji: "n", hue: 0.5)
        // Business rule baseline: new profiles start public; beacons start friends-only.
        #expect(!friend.isPrivate)
        let beacon = Beacon(spot: nil, host: friend, note: "", startsAt: .now, capacity: 5)
        #expect(!beacon.isPublic)
    }

    // MARK: - Camera capture modes

    @Test func selfTimerCyclesInOrderAndWraps() {
        // One tap per step: off → 3s → 10s → back to off.
        #expect(SelfTimer.off.next == .three)
        #expect(SelfTimer.three.next == .ten)
        #expect(SelfTimer.ten.next == .off)
    }

    @Test func cyclingEverySelfTimerReturnsToStart() {
        // Whatever the case count, a full lap lands back where it began — the
        // guard that keeps `next` honest if a step is ever added.
        var timer = SelfTimer.off
        for _ in SelfTimer.allCases { timer = timer.next }
        #expect(timer == .off)
    }

    @Test func onlyArmedSelfTimersCountDown() {
        #expect(SelfTimer.off.seconds == 0)
        #expect(!SelfTimer.off.isOn)
        #expect(SelfTimer.three.seconds == 3)
        #expect(SelfTimer.ten.seconds == 10)
    }

    @Test func onlyArmedSelfTimersShowANumber() {
        // Off is icon-only; the armed states put the count on the pill.
        #expect(SelfTimer.off.label.isEmpty)
        for timer in SelfTimer.allCases where timer.isOn {
            #expect(timer.label == "\(timer.seconds)")
        }
    }

    @Test func everyCaptureModeHasATitle() {
        // The mode strip renders `title` directly, so a blank one is a blank
        // button.
        for mode in CaptureMode.allCases {
            #expect(!mode.title.isEmpty)
            #expect(mode.id == mode.rawValue)
        }
    }

    @Test func reactionsToggleCleanly() throws {
        let context = try makeContext()
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let clip = Clip(author: pal, chat: nil, capturedAt: .now, kind: .vibe,
                        label: "x", emoji: "y", hueA: 0, hueB: 0)
        context.insert(clip)

        let mine = Reaction(emoji: "❤️", authorName: "Ethan")
        clip.reactions.append(mine)
        #expect(clip.reactions.count == 1)

        // Same reaction from the same person removes it (toggle), a different emoji stacks.
        if let index = clip.reactions.firstIndex(of: mine) {
            clip.reactions.remove(at: index)
        }
        clip.reactions.append(Reaction(emoji: "🔥", authorName: "Ethan"))
        #expect(clip.reactions == [Reaction(emoji: "🔥", authorName: "Ethan")])
    }

    // MARK: - DM get-or-create

    @Test func dmIsCreatedForAFriendWithNoChatYet() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        context.insert(me)
        context.insert(pal)
        try context.save()

        // A freshly accepted friend has a Friend row and nothing else. Sending
        // to them must not require having opened their thread first.
        let chat = Chat.dm(with: pal, me: me, in: context)
        #expect(!chat.isGroup)
        #expect(chat.members.contains { $0.id == pal.id })
        #expect(chat.members.contains { $0.id == me.id })
        #expect(chat.displayName == "Pal")
    }

    @Test func dmReturnsTheSameChatForEveryCaller() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        context.insert(me)
        context.insert(pal)
        try context.save()

        // Pulse, the profile's Message button and Send Log all land on one row —
        // and so on one Stream channel.
        let first = Chat.dm(with: pal, me: me, in: context)
        let second = Chat.dm(with: pal, me: me, in: context)
        #expect(first.id == second.id)
        #expect(first.streamChannelId == second.streamChannelId)

        let all = try context.fetch(FetchDescriptor<Chat>())
        #expect(all.count == 1)
    }

    @Test func dmIgnoresGroupChatsSharedWithTheSameFriend() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let crew = Chat(title: "crew", isGroup: true, members: [me, pal])
        context.insert(crew)
        try context.save()

        // Being in a crew together isn't a DM.
        let dm = Chat.dm(with: pal, me: me, in: context)
        #expect(dm.id != crew.id)
        #expect(!dm.isGroup)
    }

    // MARK: - Orphaned DM cleanup

    @Test func deletingAFriendLeavesAnOrphanedDMBehind() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let dm = Chat(isGroup: false, members: [me, pal])
        context.insert(dm)
        try context.save()

        // `Chat.members` has no cascade rule: un-friending drops them from the
        // array and the chat survives, renaming itself "Just me". This is the
        // bug the prune below exists to clean up.
        context.delete(pal)
        try context.save()
        #expect(dm.displayName == "Just me")
    }

    @Test func pruneRemovesOrphanedDMsAndKeepsEverythingElse() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let gone = Friend(name: "Gone", emoji: "👋", hue: 0.2)
        let liveDM = Chat(isGroup: false, members: [me, pal])
        let orphanedDM = Chat(isGroup: false, members: [me, gone])
        let crew = Chat(title: "crew", isGroup: true, members: [me, pal])
        context.insert(liveDM)
        context.insert(orphanedDM)
        context.insert(crew)
        try context.save()

        context.delete(gone)
        try context.save()

        Chat.pruneOrphanedDMs(in: context)

        let remaining = try context.fetch(FetchDescriptor<Chat>())
        #expect(remaining.count == 2)
        #expect(!remaining.contains { $0.displayName == "Just me" })
        #expect(remaining.contains { $0.id == liveDM.id })
        #expect(remaining.contains { $0.id == crew.id })
    }

    @Test func pruneLeavesAGroupChatThatLostItsMembers() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let gone = Friend(name: "Gone", emoji: "👋", hue: 0.2)
        let crew = Chat(title: "crew", isGroup: true, members: [me, gone])
        context.insert(crew)
        try context.save()

        // A crew keeps its history and its title when someone leaves — only
        // 1-on-1 threads are meaningless without the other person.
        context.delete(gone)
        try context.save()
        Chat.pruneOrphanedDMs(in: context)

        #expect(try context.fetch(FetchDescriptor<Chat>()).count == 1)
    }

    // MARK: - Send state

    @Test func aFreshCaptureIsPendingNotFailed() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let clip = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                        label: "x", emoji: "✨", hueA: 0, hueB: 0)
        context.insert(clip)

        // Nothing has failed yet — a capture on its way up must not read as a
        // failure, or the banner would fire on every send.
        #expect(clip.sendState == .pending)
        #expect(!clip.publishFailed)
        #expect(!clip.isPublished)
    }

    @Test func aFailedUploadIsDistinguishableFromOneStillInFlight() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let inFlight = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                            label: "a", emoji: "✨", hueA: 0, hueB: 0)
        let dead = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                        label: "b", emoji: "✨", hueA: 0, hueB: 0)
        context.insert(inFlight)
        context.insert(dead)

        // This is the distinction the whole fix rests on: both are unpublished,
        // but only one is something to tell the user about.
        dead.publishFailed = true
        #expect(inFlight.sendState == .pending)
        #expect(dead.sendState == .failed)
    }

    @Test func publishingClearsTheFailedState() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let clip = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                        label: "x", emoji: "✨", hueA: 0, hueB: 0)
        clip.publishFailed = true
        context.insert(clip)
        #expect(clip.sendState == .failed)

        // What a successful retry writes. `published` has to win over a stale
        // failure flag, or the banner would outlive the problem.
        clip.remoteID = "log-1"
        clip.publishFailed = false
        #expect(clip.sendState == .published)
        #expect(clip.isPublished)
    }

    @Test func failedSendsAreFoundByTheRetryPredicate() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        // Tagged per test so the fetch can only see this test's rows.
        let tag = UUID().uuidString
        let failed = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                          label: "failed", emoji: tag, hueA: 0, hueB: 0)
        failed.publishFailed = true
        let sent = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                        label: "sent", emoji: tag, hueA: 0, hueB: 0)
        sent.remoteID = "log-1"
        let theirs = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                          label: "theirs", emoji: tag, hueA: 0, hueB: 0)
        theirs.isRemote = true
        for clip in [failed, sent, theirs] { context.insert(clip) }
        try context.save()

        // Mirrors the fetch `LogSync` counts failures with: only the user's own
        // unpublished captures, never a published one and never a downloaded
        // friend's clip.
        let descriptor = FetchDescriptor<Clip>(
            predicate: #Predicate<Clip> {
                $0.emoji == tag && $0.publishFailed && $0.remoteID == "" && !$0.isRemote
            }
        )
        let found = try context.fetch(descriptor)
        #expect(found.count == 1)
        #expect(found.first?.label == "failed")
    }

    @Test func stringIsEmptyMatchesNothingInAFetchPredicate() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let tag = UUID().uuidString
        let clip = Clip(author: me, chat: nil, capturedAt: .now, kind: .vibe,
                        label: "unsent", emoji: tag, hueA: 0, hueB: 0)
        context.insert(clip)
        try context.save()
        #expect(clip.remoteID.isEmpty)

        // The trap that made `publishPending` a no-op: SwiftData can't
        // translate `String.isEmpty`, and returns no rows rather than raising.
        // Pinned here so the `== ""` form in `LogSync` doesn't get "tidied"
        // back into `.isEmpty` by someone reading it as a style nit.
        let viaIsEmpty = try context.fetch(FetchDescriptor<Clip>(
            predicate: #Predicate<Clip> { $0.emoji == tag && $0.remoteID.isEmpty }))
        let viaComparison = try context.fetch(FetchDescriptor<Clip>(
            predicate: #Predicate<Clip> { $0.emoji == tag && $0.remoteID == "" }))

        #expect(viaIsEmpty.isEmpty)
        #expect(viaComparison.count == 1)
    }

    // MARK: - Still orientation

    /// A solid JPEG of the given pixel dimensions, tagged `.up`.
    private func jpeg(width: Int, height: Int) throws -> Data {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try #require(image.jpegData(compressionQuality: 0.9))
    }

    @Test func aStillMatchingItsCaptureAngleIsLeftAlone() throws {
        // Landscape pixels, landscape interface: nothing to correct, and the
        // original bytes are handed straight through rather than re-encoded.
        let landscape = try jpeg(width: 400, height: 300)
        #expect(CameraModel.orientedJPEG(from: landscape, rotationAngle: 0) == landscape)
        #expect(CameraModel.orientedJPEG(from: landscape, rotationAngle: 180) == landscape)

        let portrait = try jpeg(width: 300, height: 400)
        #expect(CameraModel.orientedJPEG(from: portrait, rotationAngle: 90) == portrait)
    }

    @Test func aStillFightingItsCaptureAngleIsRotatedToMatch() throws {
        // The bug: landscape-locked capture, portrait-shaped file. Whatever the
        // connection claimed, the written image has to come out landscape.
        let portrait = try jpeg(width: 300, height: 400)

        for angle in [CGFloat(0), 180] {
            let corrected = try #require(CameraModel.orientedJPEG(from: portrait, rotationAngle: angle))
            let image = try #require(UIImage(data: corrected))
            #expect(image.size.width > image.size.height,
                    "angle \(angle) should produce a landscape still")
            // Baked, not tagged — the review screen and the upload read pixels.
            #expect(image.imageOrientation == .up)
        }
    }

    @Test func aPortraitCaptureCorrectsALandscapeStill() throws {
        // The same guard in the other direction, so a portrait capture can't
        // start writing landscape stills unnoticed.
        let landscape = try jpeg(width: 400, height: 300)
        let corrected = try #require(CameraModel.orientedJPEG(from: landscape, rotationAngle: 90))
        let image = try #require(UIImage(data: corrected))
        #expect(image.size.height > image.size.width)
        #expect(image.imageOrientation == .up)
    }

    @Test func anUndecodableStillFallsBackRatherThanCrashing() throws {
        // Callers write the original bytes when this returns nil; it must not
        // trap on a truncated or non-image payload.
        #expect(CameraModel.orientedJPEG(from: Data([0x00, 0x01, 0x02]), rotationAngle: 0) == nil)
    }

}
