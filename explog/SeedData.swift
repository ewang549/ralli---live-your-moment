import Foundation
import SwiftData
import FirebaseAuth

/// Seeds a rich demo dataset so every surface has content while developing.
///
/// This is DEBUG-only and never runs for a real account: once someone signs in
/// with Firebase they get the real social graph, which starts empty until they
/// add friends. Set `SIMCTL_CHILD_EXPLOG_SEED_DEMO=1` to force demo data even
/// while signed in (screenshots, UI tests).
enum SeedData {
    /// Seeds only when auth is **resolved** and nobody is signed in.
    ///
    /// Taking `session` rather than reading `Auth.auth().currentUser` is the
    /// whole point: on a cold start Firebase restores the user asynchronously,
    /// so a synchronous check reports "signed out" for a moment and would seed
    /// demo friends into a real account's store. See `AuthSession`.
    @MainActor
    static func seedIfNeeded(context: ModelContext, session: AuthSession) {
#if DEBUG
        let forced = ProcessInfo.processInfo.environment["EXPLOG_SEED_DEMO"] == "1"
        guard forced || session.isConfirmedSignedOut else { return }
        seed(context: context)
#endif
    }

#if DEBUG
    /// True when the demo roster is already loaded.
    @MainActor
    static func isDemoDataLoaded(context: ModelContext) -> Bool {
        let descriptor = FetchDescriptor<Friend>(predicate: #Predicate { $0.isDemo })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Loads the demo roster, chats, clips, spots and beacons.
    ///
    /// Safe to call while signed in to a real account: it reuses the existing
    /// "me" row rather than creating a second `isMe` profile, so your real
    /// handle/profile survives and the fake friends are layered around it.
    /// Every row it creates is marked `isDemo` so it can be cleared again.
    @MainActor
    static func seed(context: ModelContext) {
        guard !isDemoDataLoaded(context: context) else { return }

        let allFriends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []

        // Reuse the signed-in account's profile when there is one.
        let me: Friend
        if let realMe = allFriends.first(where: { $0.isMe }) {
            me = realMe
            if me.city.isEmpty { me.city = "San Francisco" }
            if me.bio.isEmpty { me.bio = "building explog, logging every hour of it" }
            if me.interests.isEmpty { me.interests = ["code", "hike", "food"] }
        } else {
            let demoMe = Friend(name: "Ethan", emoji: "🧑‍💻", hue: 0.58, isMe: true)
            demoMe.email = "ethan@businessrate.com"
            demoMe.phone = "(415) 555-0132"
            demoMe.city = "San Francisco"
            demoMe.age = 24
            demoMe.bio = "building explog, logging every hour of it"
            demoMe.interests = ["code", "hike", "food"]
            demoMe.isDemo = true
            context.insert(demoMe)
            me = demoMe
        }

        let jordan = Friend(name: "Jordan", emoji: "🏄", hue: 0.08)
        jordan.city = "San Francisco"; jordan.age = 25
        jordan.bio = "dawn patrol or it didn't happen"; jordan.interests = ["surf", "food"]

        let jonny = Friend(name: "Jonny", emoji: "🎸", hue: 0.32)
        jonny.city = "Oakland"; jonny.age = 26
        jonny.bio = "guitars + garage shows"; jonny.interests = ["music"]

        let taylor = Friend(name: "Taylor", emoji: "📷", hue: 0.78)
        taylor.city = "San Francisco"; taylor.age = 23
        taylor.bio = "golden hour hunter"; taylor.interests = ["photo", "hike"]
        taylor.isPrivate = true // demo: a private profile in the roster

        let maya = Friend(name: "Maya", emoji: "🧗", hue: 0.92)
        maya.city = "Berkeley"; maya.age = 27
        maya.bio = "v7 project in progress"; maya.interests = ["climb", "hike"]

        let sam = Friend(name: "Sam", emoji: "☕️", hue: 0.13)
        sam.city = "San Francisco"; sam.age = 28
        sam.bio = "roasting since 2019"; sam.interests = ["food", "music"]

        // `me` is intentionally not re-inserted: it may already be the real,
        // signed-in account's row.
        let demoFriends = [jordan, jonny, taylor, maya, sam]
        demoFriends.forEach {
            $0.isDemo = true
            context.insert($0)
        }

        let now = Date.now
        func hoursAgo(_ h: Double) -> Date { now.addingTimeInterval(-3600 * h) }

        // MARK: 1-on-1 chats
        let jordanChat = Chat(isGroup: false, members: [me, jordan], streak: 5,
                              lastSentAt: now.addingTimeInterval(-59)) // ~59:01 left, like the sketch
        let mayaChat = Chat(isGroup: false, members: [me, maya], streak: 12)
        let samChat = Chat(isGroup: false, members: [me, sam], streak: 2)

        // MARK: Group chat
        let crew = Chat(title: "the crew", isGroup: true,
                        members: [me, jordan, jonny, taylor, maya, sam], streak: 23)

        [jordanChat, mayaChat, samChat, crew].forEach { context.insert($0) }

        // MARK: Clips (stylized demo clips; real captures produce video/photo)
        struct Seed { let author: Friend; let hoursAgo: Double; let label: String; let emoji: String; let hueA: Double; let hueB: Double }

        let jordanClips = [
            Seed(author: jordan, hoursAgo: 0.3, label: "dawn patrol, ocean beach", emoji: "🌊", hueA: 0.55, hueB: 0.62),
            Seed(author: jordan, hoursAgo: 1.4, label: "waxing the board", emoji: "🏄", hueA: 0.08, hueB: 0.13),
            Seed(author: jordan, hoursAgo: 2.6, label: "burrito refuel", emoji: "🌯", hueA: 0.10, hueB: 0.05),
            Seed(author: me, hoursAgo: 0.02, label: "shipping the app", emoji: "💻", hueA: 0.58, hueB: 0.66),
            Seed(author: me, hoursAgo: 1.8, label: "coffee #3", emoji: "☕️", hueA: 0.09, hueB: 0.04),
        ]
        let mayaClips = [
            Seed(author: maya, hoursAgo: 0.8, label: "top of the v6 🎉", emoji: "🧗", hueA: 0.92, hueB: 0.85),
            Seed(author: maya, hoursAgo: 2.1, label: "chalk everywhere", emoji: "🖐️", hueA: 0.88, hueB: 0.95),
            Seed(author: me, hoursAgo: 3.0, label: "morning walk", emoji: "🌳", hueA: 0.33, hueB: 0.40),
        ]
        let samClips = [
            Seed(author: sam, hoursAgo: 1.1, label: "latte art attempt #47", emoji: "☕️", hueA: 0.11, hueB: 0.07),
        ]
        let crewClips = [
            Seed(author: jonny, hoursAgo: 0.4, label: "band practice", emoji: "🎸", hueA: 0.32, hueB: 0.40),
            Seed(author: jordan, hoursAgo: 0.6, label: "post-surf glow", emoji: "🌅", hueA: 0.07, hueB: 0.98),
            Seed(author: taylor, hoursAgo: 0.9, label: "golden hour shoot", emoji: "📷", hueA: 0.78, hueB: 0.70),
            Seed(author: maya, hoursAgo: 1.2, label: "gym session", emoji: "🧗", hueA: 0.90, hueB: 0.84),
            Seed(author: sam, hoursAgo: 1.6, label: "roasting a new batch", emoji: "🔥", hueA: 0.05, hueB: 0.10),
            Seed(author: me, hoursAgo: 0.1, label: "heads down coding", emoji: "💻", hueA: 0.58, hueB: 0.52),
            Seed(author: jonny, hoursAgo: 3.2, label: "string shopping", emoji: "🎶", hueA: 0.35, hueB: 0.30),
            Seed(author: taylor, hoursAgo: 4.5, label: "editing yesterday's reel", emoji: "🎞️", hueA: 0.75, hueB: 0.82),
        ]

        func insert(_ seeds: [Seed], into chat: Chat, reactions: Bool = true) {
            for (index, seed) in seeds.enumerated() {
                let clip = Clip(author: seed.author, chat: chat, capturedAt: hoursAgo(seed.hoursAgo),
                                kind: .vibe, label: seed.label, emoji: seed.emoji,
                                hueA: seed.hueA, hueB: seed.hueB)
                if reactions && index == 0 && !seed.author.isMe {
                    clip.reactions = [Reaction(emoji: "❤️", authorName: "Ethan")]
                }
                context.insert(clip)
            }
        }
        insert(jordanClips, into: jordanChat)
        insert(mayaClips, into: mayaChat)
        insert(samClips, into: samChat)
        insert(crewClips, into: crew)

        context.insert(Message(chat: jordanChat, author: jordan, text: "waves are firing today 🔥", sentAt: hoursAgo(0.5)))
        context.insert(Message(chat: jordanChat, author: me, text: "haha saw the clip, unreal", sentAt: hoursAgo(0.4)))
        context.insert(Message(chat: crew, author: taylor, text: "who's around this weekend?", sentAt: hoursAgo(2.0)))

        // MARK: Discovery spots
        let tam = Spot(name: "Mount Tamalpais", category: "Sunrise hike",
                       summary: "East Peak trail with fog-line views over the whole bay.",
                       aiInsight: "Most visitors tag this spot between 6–8am — the marine layer usually sits below the peak until ~9. Parking fills by 7:30 on weekends; the Fern Creek route is the quiet way up. Recent clips show clear skies 4 of the last 5 mornings.",
                       distanceMiles: 12.4, emoji: "⛰️", hueA: 0.33, hueB: 0.55)
        let pinball = Spot(name: "Free Gold Watch", category: "Hidden arcade",
                           summary: "Print shop up front, 90+ pinball machines in the back.",
                           aiInsight: "Crowd peaks after 9pm; weekday afternoons are nearly empty. Visitors mention the Godzilla and Medieval Madness machines most. Cash-only token machine — bring small bills.",
                           distanceMiles: 1.8, emoji: "🕹️", hueA: 0.85, hueB: 0.95)
        let nightMarket = Spot(name: "Outer Sunset Night Market", category: "Pop-up food",
                               summary: "Rotating street-food vendors every Friday by the dunes.",
                               aiInsight: "The garlic noodle stall sells out by 8pm in most recent clips. Fog rolls in hard after sunset — visitors consistently recommend a jacket even in July.",
                               distanceMiles: 3.2, emoji: "🏮", hueA: 0.02, hueB: 0.08)
        let sutro = Spot(name: "Sutro Baths at Low Tide", category: "Tidepools",
                         summary: "Ruins + tidepools; sea stars visible at negative tides.",
                         aiInsight: "Clips cluster around low tide (check tide tables — negative tides expose the best pools). The cave echoes at high tide; several visitors flag slippery rocks near the north wall.",
                         distanceMiles: 4.1, emoji: "🌊", hueA: 0.52, hueB: 0.60)
        tam.address = "E Ridgecrest Blvd, Mill Valley, CA"
        pinball.address = "1767 Waller St, San Francisco, CA"
        nightMarket.address = "Great Hwy & Judah St, San Francisco, CA"
        sutro.address = "1004 Point Lobos Ave, San Francisco, CA"
        [tam, pinball, nightMarket, sutro].forEach { context.insert($0) }

        // A shared-location card in a DM — tapping it opens the same spot detail
        // sheet the Places feed uses (sharedSpot carries the real model along).
        let sharedSpotMsg = Message(chat: jordanChat, author: jordan,
                                    text: "found this — we should go 👀",
                                    sentAt: hoursAgo(0.35), sharedSpotName: sutro.name)
        sharedSpotMsg.sharedSpot = sutro
        context.insert(sharedSpotMsg)

        let perspectives: [(Spot, String, String, String, Double, Double, Double)] = [
            (tam, "Aria", "above the fog line", "☁️", 0.55, 0.60, 5),
            (tam, "Ben", "east peak lookout", "🌄", 0.08, 0.12, 26),
            (tam, "Cleo", "trail runners' turn", "🏃‍♀️", 0.33, 0.38, 49),
            (pinball, "Dex", "medieval madness!!", "🎯", 0.85, 0.90, 12),
            (pinball, "Ivy", "back row is empty rn", "🕹️", 0.92, 0.80, 3),
            (nightMarket, "Kai", "garlic noodle line", "🍜", 0.05, 0.10, 20),
            (nightMarket, "Lena", "sunset behind the stalls", "🌇", 0.02, 0.95, 44),
            (sutro, "Milo", "sea stars out today", "⭐️", 0.52, 0.47, 7),
            (sutro, "Nia", "inside the cave", "🕳️", 0.58, 0.63, 30),
        ]
        for (index, (spot, author, label, emoji, hueA, hueB, hrs)) in perspectives.enumerated() {
            let clip = SpotClip(spot: spot, authorName: author, label: label, emoji: emoji,
                                hueA: hueA, hueB: hueB, capturedAt: hoursAgo(hrs))
            clip.likeCount = [284, 41, 12, 96, 7, 153, 88, 33, 19][index % 9]
            if index.isMultiple(of: 3) {
                clip.comments = [
                    ClipComment(authorName: "Ravi", text: "was just here, unreal", sentAt: hoursAgo(hrs - 1)),
                    ClipComment(authorName: "Priya", text: "adding this to the list 🔖", sentAt: hoursAgo(max(hrs - 2, 0.5))),
                ]
            }
            context.insert(clip)
        }

        // MARK: Beacons — the sketch's public "Join 5/15" card + a friend broadcast
        let hike = Beacon(spot: tam, host: nil, note: "Community sunrise hike — all welcome",
                          startsAt: now.addingTimeInterval(3600 * 14), capacity: 15,
                          joined: [jordan, jonny, taylor, maya, sam])
        hike.isPublic = true
        context.insert(hike)
        context.insert(Beacon(spot: nightMarket, host: jordan, note: "heading over around 7, come thru",
                              startsAt: now.addingTimeInterval(3600 * 2), capacity: 8,
                              joined: [taylor]))
        let tidepools = Beacon(spot: sutro, host: maya, note: "negative tide at 6:40pm, sea stars guaranteed",
                               startsAt: now.addingTimeInterval(3600 * 27), capacity: 12,
                               joined: [sam, jonny])
        tidepools.isPublic = true
        context.insert(tidepools)

        // Activity group-chat starter messages (scoped by activityId).
        let hikeMsg1 = Message(chat: nil, author: jordan, text: "carpooling from the city, 2 seats open", sentAt: hoursAgo(3))
        hikeMsg1.activityId = hike.activityKey
        let hikeMsg2 = Message(chat: nil, author: maya, text: "bringing an extra headlamp if anyone needs", sentAt: hoursAgo(1.5))
        hikeMsg2.activityId = hike.activityKey
        [hikeMsg1, hikeMsg2].forEach { context.insert($0) }

        try? context.save()
    }
#endif
}
