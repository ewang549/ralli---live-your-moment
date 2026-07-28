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

    // MARK: - Whose thread a clip of mine belongs to

    /// The pairing feed's "you" pane must be scoped to the thread on screen.
    ///
    /// Reading my clip off `Friend.clip(forHourContaining:)` searches my whole
    /// history, so a log sent to one friend showed up in my pane opposite every
    /// friend on the roster — which looks exactly like the send having gone to
    /// all of them.
    @Test func myClipIsScopedToTheChatItWasSentTo() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let sent = Friend(name: "Sent", emoji: "🙃", hue: 0.1)
        let unsent = Friend(name: "Unsent", emoji: "😐", hue: 0.2)
        let sentChat = Chat(isGroup: false, members: [me, sent])
        let unsentChat = Chat(isGroup: false, members: [me, unsent])
        context.insert(sentChat)
        context.insert(unsentChat)

        let hour = Calendar.current.dateInterval(of: .hour, for: .now)!.start
        let clip = Clip(author: me, chat: sentChat, capturedAt: hour,
                        kind: .vibe, label: "for one person", emoji: "✨",
                        hueA: 0, hueB: 0.1)
        context.insert(clip)

        // The thread it went to shows it...
        #expect(sentChat.myClip(forHourContaining: hour)?.id == clip.id)
        // ...and the thread it didn't go to shows nothing, which is the bug.
        #expect(unsentChat.myClip(forHourContaining: hour) == nil)
        // The unscoped lookup still finds it either way — that's precisely why
        // the pairing feed can't use it for my own pane.
        #expect(me.clip(forHourContaining: hour)?.id == clip.id)
    }

    @Test func myClipIgnoresOtherPeoplesClipsInTheSameThread() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        let hour = Calendar.current.dateInterval(of: .hour, for: .now)!.start
        let theirs = Clip(author: pal, chat: chat, capturedAt: hour,
                          kind: .vibe, label: "theirs", emoji: "✨",
                          hueA: 0, hueB: 0.1)
        context.insert(theirs)

        // The friend's own log lives in this thread too; my pane must not
        // render it as mine.
        #expect(chat.myClip(forHourContaining: hour) == nil)
    }

    @Test func myClipTakesTheLatestWithinTheHour() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        // `clips` is an unordered SwiftData relationship, so "latest" has to be
        // computed rather than taken from position.
        let hour = Calendar.current.dateInterval(of: .hour, for: .now)!.start
        let earlier = Clip(author: me, chat: chat, capturedAt: hour,
                           kind: .vibe, label: "earlier", emoji: "✨",
                           hueA: 0, hueB: 0.1)
        let later = Clip(author: me, chat: chat, capturedAt: hour.addingTimeInterval(600),
                         kind: .vibe, label: "later", emoji: "✨",
                         hueA: 0, hueB: 0.1)
        context.insert(earlier)
        context.insert(later)

        #expect(chat.myClip(forHourContaining: hour)?.id == later.id)
        // A different hour is a different slot, not a fallback to the nearest.
        #expect(chat.myClip(forHourContaining: hour.addingTimeInterval(-3600)) == nil)
    }

    // MARK: - Pulse outreach ordering

    /// The distinction the whole ordering rests on: `lastActivityAt` counts
    /// either party, `lastSentByMeAt` counts only me.
    @Test func incomingActivityIsNotAnOutgoingSend() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        let theirs = Clip(author: pal, chat: chat, capturedAt: .now,
                          kind: .vibe, label: "theirs", emoji: "✨",
                          hueA: 0, hueB: 0.1)
        context.insert(theirs)
        let theirMessage = Message(chat: chat, author: pal, text: "you around?")
        context.insert(theirMessage)
        chat.messages.append(theirMessage)

        // Something clearly happened here...
        #expect(chat.lastActivityAt >= theirs.capturedAt)
        // ...but none of it was me, so Pulse has nothing to float.
        #expect(chat.lastSentByMeAt == nil)
    }

    @Test func lastSentByMeTakesTheNewestOfMyLogsAndMessages() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        let anHourAgo = Date(timeIntervalSinceNow: -3600)
        let myClip = Clip(author: me, chat: chat, capturedAt: anHourAgo,
                          kind: .vibe, label: "mine", emoji: "✨",
                          hueA: 0, hueB: 0.1)
        context.insert(myClip)
        #expect(chat.lastSentByMeAt == anHourAgo)

        // A message with no accompanying log counts just as much as a log.
        let tenMinutesAgo = Date(timeIntervalSinceNow: -600)
        let myMessage = Message(chat: chat, author: me, text: "on my way",
                                sentAt: tenMinutesAgo)
        context.insert(myMessage)
        chat.messages.append(myMessage)
        #expect(chat.lastSentByMeAt == tenMinutesAgo)

        // A Stream message writes no local `Message` row, so the stamp is the
        // only trace of it — and it has to count the same as the rest.
        let justNow = Date(timeIntervalSinceNow: -5)
        chat.noteOutgoingMessage(at: justNow)
        #expect(chat.lastSentByMeAt == justNow)
    }

    /// Channel history replays as inserts every time a thread opens, so the
    /// stamp has to be a high-water mark rather than a plain assignment — an
    /// old message arriving late must not undo a send that just happened.
    @Test func outgoingStampNeverMovesBackwards() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let chat = Chat(isGroup: false, members: [me])
        context.insert(chat)

        let recent = Date(timeIntervalSinceNow: -60)
        chat.noteOutgoingMessage(at: recent)
        chat.noteOutgoingMessage(at: Date(timeIntervalSinceNow: -9000))

        #expect(chat.lastOutgoingMessageAt == recent)
    }

    /// The list is "who did I last exchange anything with", so a friend
    /// writing to me outranks an older send of my own.
    ///
    /// This deliberately inverts the rule that used to hold here: leading on
    /// my own sends meant somebody messaging me and getting no reply never
    /// moved at all, which is the person the list most needs to surface.
    @Test func pulseOrdersByActivityInEitherDirection() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let messaged = Friend(name: "Messaged", emoji: "🙃", hue: 0.1)
        let noisy = Friend(name: "Noisy", emoji: "😐", hue: 0.2)
        let messagedChat = Chat(isGroup: false, members: [me, messaged])
        let noisyChat = Chat(isGroup: false, members: [me, noisy])
        context.insert(messagedChat)
        context.insert(noisyChat)

        // I wrote to one of them an hour ago...
        let mine = Message(chat: messagedChat, author: me, text: "hey",
                           sentAt: Date(timeIntervalSinceNow: -3600))
        context.insert(mine)
        messagedChat.messages.append(mine)
        // ...and the other one wrote to me a minute ago.
        let theirs = Message(chat: noisyChat, author: noisy, text: "yo",
                             sentAt: Date(timeIntervalSinceNow: -60))
        context.insert(theirs)
        noisyChat.messages.append(theirs)

        let entries = [PulseEntry(friend: messaged, chat: messagedChat),
                       PulseEntry(friend: noisy, chat: noisyChat)]
            .sorted(by: PulseEntry.byOutreach)

        #expect(entries.map(\.name) == ["Noisy", "Messaged"])
    }

    /// A Stream message from a friend carries no local `Message` row, so the
    /// incoming stamp is the only trace of it — and it has to move Pulse.
    @Test func incomingStreamMessageFloatsTheFriendToTheTop() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let quiet = Friend(name: "Quiet", emoji: "🙃", hue: 0.1)
        let texter = Friend(name: "Texter", emoji: "😐", hue: 0.2)
        let quietChat = Chat(isGroup: false, members: [me, quiet])
        let texterChat = Chat(isGroup: false, members: [me, texter])
        context.insert(quietChat)
        context.insert(texterChat)

        // I reached out to one of them an hour ago; the other one texted me a
        // minute ago and I haven't answered.
        quietChat.noteOutgoingMessage(at: Date(timeIntervalSinceNow: -3600))
        texterChat.noteIncomingMessage(at: Date(timeIntervalSinceNow: -60))

        let entries = [PulseEntry(friend: quiet, chat: quietChat),
                       PulseEntry(friend: texter, chat: texterChat)]
            .sorted(by: PulseEntry.byOutreach)

        #expect(entries.map(\.name) == ["Texter", "Quiet"])
    }

    /// Nobody drops off the list for having no history — they just sit under
    /// everyone who does.
    @Test func friendsWithNoActivitySortLast() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let reached = Friend(name: "Reached", emoji: "🙃", hue: 0.1)
        let recent = Friend(name: "Recent", emoji: "😐", hue: 0.2)
        let quiet = Friend(name: "Quiet", emoji: "😶", hue: 0.3)
        let reachedChat = Chat(isGroup: false, members: [me, reached])
        let recentChat = Chat(isGroup: false, members: [me, recent])
        let emptyChat = Chat(isGroup: false, members: [me, quiet])
        context.insert(reachedChat)
        context.insert(recentChat)
        context.insert(emptyChat)

        reachedChat.noteOutgoingMessage(at: Date(timeIntervalSinceNow: -3 * 86_400))
        let theirs = Message(chat: recentChat, author: recent, text: "yo",
                             sentAt: Date(timeIntervalSinceNow: -60))
        context.insert(theirs)
        recentChat.messages.append(theirs)

        let entries = [PulseEntry(friend: quiet, chat: emptyChat),
                       PulseEntry(friend: reached, chat: reachedChat),
                       PulseEntry(friend: recent, chat: recentChat)]
            .sorted(by: PulseEntry.byOutreach)

        // `emptyChat` was created just now, so if bare creation counted as
        // activity it would sort first — the exact trap `lastRealActivityAt`
        // exists to avoid once the order leads on activity.
        #expect(entries.map(\.name) == ["Recent", "Reached", "Quiet"])
    }

    // MARK: - Unread dot

    /// The bug this fixes: a friend's text writes neither a `Clip` nor a local
    /// `Message`, so a guard that counted only those two collections kept the
    /// dot dark no matter how far `lastActivityAt` had moved.
    @Test func incomingStreamMessageLightsTheUnreadDot() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        // Read five minutes ago, and nothing has happened since.
        chat.lastReadAt = Date(timeIntervalSinceNow: -300)
        #expect(!chat.hasUnread)

        chat.noteIncomingMessage(at: Date(timeIntervalSinceNow: -60))
        #expect(chat.hasUnread)

        // Opening the thread clears it, and it stays clear.
        chat.markRead()
        #expect(!chat.hasUnread)
    }

    /// The dot is for what *arrived*, not for what I did. My own send moves
    /// `lastActivityAt` too, so this is the case that would false-positive if
    /// `markRead` weren't the thing gating it.
    @Test func freshEmptyChatHasNothingUnread() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        // Auto-created by tapping Message and never used — `lastActivityAt`
        // still answers with `createdAt`, which sits after a nil `lastReadAt`.
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)

        #expect(!chat.hasUnread)
        #expect(chat.lastRealActivityAt == nil)
    }

    /// The bug: `SendToFriendsView.send()` appends my clip to the chat and
    /// never marks it read, so sending a log to a friend lit that friend's
    /// unread dot with no friend involved at all. The dot is for what arrived.
    @Test func myOwnSendDoesNotLightTheUnreadDot() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)
        chat.lastReadAt = Date(timeIntervalSinceNow: -300)

        // My log, sent to them — the exact shape `SendToFriendsView` writes.
        let mine = Clip(author: me, chat: chat, capturedAt: .now,
                        kind: .vibe, label: "mine", emoji: "✨",
                        hueA: 0, hueB: 0.1)
        context.insert(mine)
        chat.clips.append(mine)
        // My text, on the Stream path.
        chat.noteOutgoingMessage(at: .now)

        // Pulse still floats the thread — that ordering is any-party on
        // purpose — but nothing has *arrived*, so the dot stays dark.
        #expect(chat.lastActivityAt >= mine.capturedAt)
        #expect(!chat.hasUnread)

        // Their reply is what lights it, and opening clears it.
        chat.noteIncomingMessage(at: .now)
        #expect(chat.hasUnread)
        chat.markRead()
        #expect(!chat.hasUnread)
    }

    /// A friend's *log* counts as arrival too, not just their text — the log
    /// feed is the main way things land in a thread.
    @Test func aFriendsLogLightsTheUnreadDot() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal])
        context.insert(chat)
        chat.lastReadAt = Date(timeIntervalSinceNow: -300)

        let theirs = Clip(author: pal, chat: chat, capturedAt: .now,
                          kind: .vibe, label: "theirs", emoji: "✨",
                          hueA: 0, hueB: 0.1)
        context.insert(theirs)
        chat.clips.append(theirs)

        #expect(chat.hasUnread)
    }

    /// Incoming and outgoing are separate high-water marks: a reply of mine
    /// must not overwrite when the friend last wrote, or the two stamps would
    /// race and whichever landed last would win.
    @Test func incomingAndOutgoingStampsAreIndependent() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let chat = Chat(isGroup: false, members: [me])
        // Backdated, because `lastActivityAt` floors at `createdAt` — a chat
        // made this instant would out-rank both stamps below and the max would
        // be testing nothing.
        chat.createdAt = Date(timeIntervalSinceNow: -600)
        context.insert(chat)

        let theirs = Date(timeIntervalSinceNow: -120)
        let mine = Date(timeIntervalSinceNow: -60)
        chat.noteIncomingMessage(at: theirs)
        chat.noteOutgoingMessage(at: mine)

        #expect(chat.lastIncomingMessageAt == theirs)
        #expect(chat.lastOutgoingMessageAt == mine)
        #expect(chat.lastActivityAt == mine)

        // Replayed history must not walk either stamp backwards.
        chat.noteIncomingMessage(at: Date(timeIntervalSinceNow: -9000))
        #expect(chat.lastIncomingMessageAt == theirs)
    }

    // MARK: - Places feed pruning

    /// Builds a public-log payload row. Only the fields the prune reads
    /// actually matter; the rest are filler so the struct can be made.
    private func publicLog(id: String, spotId: String, capturedAt: Date) -> LogSync.RemotePublicLog {
        LogSync.RemotePublicLog(
            id: id, authorUid: "uid", authorName: "Author", authorHandle: "@author",
            authorAvatarEmoji: "🙂", authorAvatarURL: "", spotId: spotId, spotName: "Spot",
            kind: "video", mediaURL: "", caption: "", emoji: "✨", hueA: 0, hueB: 0.1,
            capturedAt: capturedAt.timeIntervalSince1970 * 1000,
            likeCount: nil, commentCount: nil, viewCount: nil, likedByMe: nil
        )
    }

    private func spotClip(id: String, spot: Spot?, capturedAt: Date,
                          in context: ModelContext) -> SpotClip {
        let clip = SpotClip(spot: spot, authorName: "Author", label: "", emoji: "✨",
                            hueA: 0, hueB: 0.1, capturedAt: capturedAt)
        clip.remoteID = id
        context.insert(clip)
        return clip
    }

    /// The delete bug: the server stops returning a deleted log, but the local
    /// `SpotClip` used to survive every sync and keep rendering in Places.
    @Test func pruneDropsRowsTheServerNoLongerReturns() throws {
        let context = try makeContext()
        let sync = LogSync()
        let kept = spotClip(id: "kept", spot: nil, capturedAt: Date(timeIntervalSinceNow: -60),
                            in: context)
        let deleted = spotClip(id: "deleted", spot: nil, capturedAt: Date(timeIntervalSinceNow: -120),
                               in: context)

        // A short page: the server ran out of rows, so "absent" means gone.
        sync.prunePublic([publicLog(id: "kept", spotId: "spot-1",
                                    capturedAt: Date(timeIntervalSinceNow: -60))],
                         spotID: nil, pageLimit: 80, into: context)

        let remaining = try context.fetch(FetchDescriptor<SpotClip>()).map(\.remoteID)
        #expect(remaining == ["kept"])
        _ = (kept, deleted)
    }

    /// A *full* page proves nothing about what fell off the end of it, so the
    /// prune is confined to the window the page actually spans. Without this
    /// rule, a feed with more than one page of clips would delete its own
    /// backlog on every sync.
    @Test func pruneLeavesRowsOlderThanAFullPage() throws {
        let context = try makeContext()
        let sync = LogSync()
        let windowStart = Date(timeIntervalSinceNow: -3600)
        _ = spotClip(id: "older", spot: nil, capturedAt: Date(timeIntervalSinceNow: -86_400),
                     in: context)
        _ = spotClip(id: "inWindow", spot: nil, capturedAt: Date(timeIntervalSinceNow: -1800),
                     in: context)

        // Exactly `pageLimit` rows back = the page was capped.
        let page = (0..<3).map {
            publicLog(id: "server-\($0)", spotId: "spot-1",
                      capturedAt: windowStart.addingTimeInterval(Double($0) * 60))
        }
        sync.prunePublic(page, spotID: nil, pageLimit: 3, into: context)

        let remaining = Set(try context.fetch(FetchDescriptor<SpotClip>()).map(\.remoteID))
        // Inside the window and absent → genuinely deleted.
        #expect(!remaining.contains("inWindow"))
        // Older than the window → simply off the end of the page.
        #expect(remaining.contains("older"))
    }

    /// A spot-scoped sync only speaks for that spot. Pruning everything else
    /// would empty the Places feed every time a single place was opened.
    @Test func spotScopedPruneLeavesOtherPlacesAlone() throws {
        let context = try makeContext()
        let sync = LogSync()
        let here = Spot(name: "Here", category: "", summary: "", aiInsight: "",
                        distanceMiles: 0, emoji: "📍", hueA: 0, hueB: 0.1)
        here.remoteID = "spot-here"
        let elsewhere = Spot(name: "Elsewhere", category: "", summary: "", aiInsight: "",
                             distanceMiles: 0, emoji: "🗺️", hueA: 0, hueB: 0.1)
        elsewhere.remoteID = "spot-elsewhere"
        context.insert(here)
        context.insert(elsewhere)

        _ = spotClip(id: "gone-here", spot: here, capturedAt: .now, in: context)
        _ = spotClip(id: "still-elsewhere", spot: elsewhere, capturedAt: .now, in: context)

        // The server says this spot now has nothing public at all.
        sync.prunePublic([], spotID: "spot-here", pageLimit: 80, into: context)

        let remaining = Set(try context.fetch(FetchDescriptor<SpotClip>()).map(\.remoteID))
        #expect(remaining == ["still-elsewhere"])
    }

    /// A row that has never been published has no server id to be missing
    /// from the payload — including the mirror written the instant you post,
    /// before the upload has come back with its id.
    @Test func pruneLeavesUnpublishedLocalRows() throws {
        let context = try makeContext()
        let sync = LogSync()
        let local = SpotClip(spot: nil, authorName: "Me", label: "just posted", emoji: "✨",
                             hueA: 0, hueB: 0.1, capturedAt: .now)
        context.insert(local)

        sync.prunePublic([], spotID: nil, pageLimit: 80, into: context)

        #expect(try context.fetch(FetchDescriptor<SpotClip>()).count == 1)
    }

    // MARK: - Beacon start time

    @Test func beaconStartLabelNamesTodayAndTomorrow() throws {
        let spot = Spot(name: "Pier", category: "park", summary: "", aiInsight: "",
                        distanceMiles: 1, emoji: "🌊", hueA: 0, hueB: 0.1)
        let today = Beacon(spot: spot, host: nil, note: "",
                           startsAt: Calendar.current.date(bySettingHour: 15, minute: 0, second: 0,
                                                           of: .now)!,
                           capacity: 4)
        #expect(today.startsAtLabel.hasPrefix("Today · "))

        let tomorrow = Beacon(spot: spot, host: nil, note: "",
                              startsAt: Calendar.current.date(byAdding: .day, value: 1, to: .now)!,
                              capacity: 4)
        #expect(tomorrow.startsAtLabel.hasPrefix("Tomorrow · "))

        // Anything further out is dated, since the weekday alone is ambiguous.
        let later = Beacon(spot: spot, host: nil, note: "",
                           startsAt: Calendar.current.date(byAdding: .day, value: 5, to: .now)!,
                           capacity: 4)
        #expect(!later.startsAtLabel.hasPrefix("Today"))
        #expect(!later.startsAtLabel.hasPrefix("Tomorrow"))
        #expect(later.startsAtLabel.contains(" · "))
    }

}
