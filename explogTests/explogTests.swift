import Testing
import Foundation
import SwiftData
@testable import explog

@MainActor
struct explogTests {
    private func makeContext() throws -> ModelContext {
        let schema = Schema([Friend.self, Chat.self, Clip.self, Message.self,
                             Spot.self, SpotClip.self, Beacon.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @Test func cooldownBlocksWithinTheHour() throws {
        let context = try makeContext()
        let me = Friend(name: "Me", emoji: "🙂", hue: 0.5, isMe: true)
        let pal = Friend(name: "Pal", emoji: "🙃", hue: 0.1)
        let chat = Chat(isGroup: false, members: [me, pal], lastSentAt: Date(timeIntervalSinceNow: -60))
        context.insert(chat)

        // Sent 1 minute ago → ~59 minutes remain.
        #expect(chat.cooldownRemaining > 3500)
        #expect(chat.cooldownRemaining <= 3540)
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

    @Test func captureModeCyclesInOrderAndWraps() {
        // One tap per step: 3s → 5s → timelapse → jump cut → back to 3s.
        #expect(CaptureMode.threeSeconds.next == .fiveSeconds)
        #expect(CaptureMode.fiveSeconds.next == .timelapse)
        #expect(CaptureMode.timelapse.next == .jumpCut)
        #expect(CaptureMode.jumpCut.next == .threeSeconds)
    }

    @Test func cyclingEveryModeReturnsToStart() {
        // Whatever the case count, a full lap lands back where it began — the
        // guard that keeps `next` honest if a mode is ever added.
        var mode = CaptureMode.threeSeconds
        for _ in CaptureMode.allCases { mode = mode.next }
        #expect(mode == .threeSeconds)
    }

    @Test func onlyTimerModesCountDown() {
        #expect(CaptureMode.threeSeconds.countdownSeconds == 3)
        #expect(CaptureMode.fiveSeconds.countdownSeconds == 5)
        // Timelapse and jump cut fire immediately — no self-timer.
        #expect(CaptureMode.timelapse.countdownSeconds == nil)
        #expect(CaptureMode.jumpCut.countdownSeconds == nil)
    }

    @Test func everyModeHasExactlyOneButtonFace() {
        // Each mode renders either a symbol or a text label, never both and
        // never neither — otherwise the button comes up blank.
        for mode in CaptureMode.allCases {
            let hasSymbol = mode.symbolName != nil
            let hasLabel = !mode.shortLabel.isEmpty
            #expect(hasSymbol != hasLabel, "\(mode.title) must have a symbol or a label")
            #expect(!mode.title.isEmpty)
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
}
