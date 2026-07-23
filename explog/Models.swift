import Foundation
import SwiftData

/// How long a sender must wait between logs to the same chat.
let logCooldown: TimeInterval = 3600

/// Where a capture was started from. The surface decides how long you get to
/// record: a pulse check-in is a glance, a place is worth a few extra seconds.
enum CaptureContext {
    /// Hourly pulse / micro check-in.
    case pulse
    /// Places & experiences (niche spots, beacons).
    case place

    var maxClipDuration: TimeInterval {
        switch self {
        case .pulse: 2
        case .place: 5
        }
    }

    /// Label for the capture mode picker, e.g. "2s Video".
    var videoModeLabel: String { "\(Int(maxClipDuration))s Video" }
}

/// Default clip length used for playback pacing (montage/story dwell time).
let clipDuration: TimeInterval = CaptureContext.pulse.maxClipDuration

// Spec-name parity: the design docs refer to these models by these names.
typealias UserProfile = Friend
typealias GroupChat = Chat
typealias ActivityItem = Beacon
typealias ChatMessage = Message

@Model
final class Friend {
    @Attribute(.unique) var id: UUID
    var name: String
    var emoji: String
    var hue: Double
    var isMe: Bool

    // MARK: Real-account identity (Phase 1: user directory)
    //
    // `id` stays a local UUID so seeded demo rows keep working; `remoteUID` is
    // the Firebase uid and is the key that maps this row to a real account.
    // Empty on demo/seeded friends.
    var remoteUID: String = ""
    /// Lowercased unique handle, e.g. "ethan_w". Empty until a profile exists.
    var handle: String = ""
    /// Handle as the user typed it, for display.
    var handleDisplay: String = ""
    /// Short shareable code (add-by-code / QR / ambassador attribution).
    var friendCode: String = ""
    /// Marks a row created by `SeedData` so demo content can be loaded and
    /// cleared independently of real accounts and real friends.
    var isDemo: Bool = false

    /// Unique, user-facing lookup ID — what you type into "Add friend".
    /// Mirrors the Firestore handle for real accounts; demo rows get a local one.
    var userId: String = ""

    // Profile metadata (UserProfileView).
    var email: String = ""
    var phone: String = ""
    var city: String = ""
    var age: Int = 0
    var bio: String = ""
    var interests: [String] = []
    /// Privacy control: private profiles are hidden from community feeds and
    /// cannot host or join public activities (enforced by guard clauses).
    var isPrivate: Bool = false

    // Explicit inverses — without these, SwiftData infers a to-one inverse and
    // silently drops a friend from a chat when they join a second one.
    var chats: [Chat]
    var clips: [Clip]
    var messages: [Message]
    var hostedBeacons: [Beacon]
    var joinedBeacons: [Beacon]

    init(name: String, emoji: String, hue: Double, isMe: Bool = false) {
        self.id = UUID()
        self.name = name
        self.emoji = emoji
        self.hue = hue
        self.isMe = isMe
        self.chats = []
        self.clips = []
        self.messages = []
        self.hostedBeacons = []
        self.joinedBeacons = []
    }

    // MARK: - Home-list display values
    //
    // Computed rather than stored so a row can never show a caption or streak
    // that a newer clip has already replaced.

    /// Caption from this person's most recent log — the status line under
    /// their name in the home list.
    var latestCaption: String {
        clips.max { $0.capturedAt < $1.capturedAt }?.label ?? ""
    }

    /// Streak for the 1-on-1 with this person. Deliberately *not* the max
    /// across their chats — that would paint every member of a hot group chat
    /// with the group's streak, which reads as a personal one.
    var streakCount: Int {
        chats.first { !$0.isGroup }?.streak ?? 0
    }

    /// Most recent clip, used by the stacked video feeds.
    var latestClip: Clip? {
        clips.max { $0.capturedAt < $1.capturedAt }
    }

    /// "@handle" when the account is real, otherwise the local lookup ID.
    var displayUserId: String {
        let value = userId.isEmpty ? handle : userId
        return value.isEmpty ? "" : "@\(value)"
    }
}

@Model
final class Chat {
    @Attribute(.unique) var id: UUID
    var title: String?
    var isGroup: Bool
    @Relationship(inverse: \Friend.chats) var members: [Friend]
    var streak: Int
    /// When the current user last sent a log to this chat (drives the 1-hour cooldown).
    var lastSentAt: Date?
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \Clip.chat) var clips: [Clip]
    @Relationship(deleteRule: .cascade, inverse: \Message.chat) var messages: [Message]

    init(title: String? = nil, isGroup: Bool, members: [Friend], streak: Int = 0, lastSentAt: Date? = nil) {
        self.id = UUID()
        self.title = title
        self.isGroup = isGroup
        self.members = members
        self.streak = streak
        self.lastSentAt = lastSentAt
        self.createdAt = .now
        self.clips = []
        self.messages = []
    }

    var displayName: String {
        if let title, !title.isEmpty { return title }
        let others = members.filter { !$0.isMe }.map(\.name)
        return others.isEmpty ? "Just me" : others.joined(separator: ", ")
    }

    /// Seconds until the current user may log to this chat again; 0 when ready.
    var cooldownRemaining: TimeInterval {
        guard let lastSentAt else { return 0 }
        return max(0, logCooldown - Date.now.timeIntervalSince(lastSentAt))
    }

    var sortedClips: [Clip] {
        clips.sorted { $0.capturedAt > $1.capturedAt }
    }

    // MARK: - GroupChat display values (spec parity)

    /// Stable unique ID for the group, used for routing and Stream channels.
    var userId: String { id.uuidString }

    /// Caption from the most recent log in this chat, shown under the name.
    var latestCaption: String {
        guard let latest = sortedClips.first else { return "" }
        let author = latest.author?.name ?? ""
        return author.isEmpty ? latest.label : "\(author): \(latest.label)"
    }

    /// Spec-named alias for `streak`.
    var streakCount: Int { streak }

    /// One current clip per member — the group's stacked video feed.
    var memberClips: [Clip] {
        members.compactMap { member in
            sortedClips.first { $0.author?.id == member.id }
        }
    }

    func latestClip(by friend: Friend) -> Clip? {
        sortedClips.first { $0.author?.id == friend.id }
    }
}

enum ClipKind: String, Codable {
    case video, photo, vibe // vibe = stylized placeholder (simulator / seeded demo content)
}

struct Reaction: Codable, Hashable {
    var emoji: String
    var authorName: String
}

@Model
final class Clip {
    @Attribute(.unique) var id: UUID
    @Relationship(inverse: \Friend.clips) var author: Friend?
    var chat: Chat?
    var capturedAt: Date
    var kindRaw: String
    /// File name inside the app's Documents directory for video/photo clips.
    var assetFileName: String?
    var label: String
    var emoji: String
    var hueA: Double
    var hueB: Double
    var reactions: [Reaction]

    init(author: Friend?, chat: Chat?, capturedAt: Date, kind: ClipKind,
         assetFileName: String? = nil, label: String, emoji: String,
         hueA: Double, hueB: Double, reactions: [Reaction] = []) {
        self.id = UUID()
        self.author = author
        self.chat = chat
        self.capturedAt = capturedAt
        self.kindRaw = kind.rawValue
        self.assetFileName = assetFileName
        self.label = label
        self.emoji = emoji
        self.hueA = hueA
        self.hueB = hueB
        self.reactions = reactions
    }

    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .vibe }

    var assetURL: URL? {
        guard let assetFileName else { return nil }
        return URL.documentsDirectory.appending(path: assetFileName)
    }
}

@Model
final class Message {
    @Attribute(.unique) var id: UUID
    var chat: Chat?
    @Relationship(inverse: \Friend.messages) var author: Friend?
    var text: String
    var sentAt: Date
    /// Set when the message shares a discovery spot into the chat.
    var sharedSpotName: String?
    /// iMessage-style tapback reaction (single emoji), nil when none.
    var tapback: String? = nil
    /// Set when the message belongs to an activity group chat instead of a
    /// direct chat (ActivityChatView) — the Beacon's id string.
    var activityId: String? = nil

    init(chat: Chat?, author: Friend?, text: String, sentAt: Date = .now, sharedSpotName: String? = nil) {
        self.id = UUID()
        self.chat = chat
        self.author = author
        self.text = text
        self.sentAt = sentAt
        self.sharedSpotName = sharedSpotName
    }
}

@Model
final class Spot {
    @Attribute(.unique) var id: UUID
    var name: String
    var category: String
    var summary: String
    var aiInsight: String
    var distanceMiles: Double
    /// Street address shown in activity detail sheets.
    var address: String = ""
    var emoji: String
    var hueA: Double
    var hueB: Double
    @Relationship(deleteRule: .cascade, inverse: \SpotClip.spot) var perspectives: [SpotClip]

    init(name: String, category: String, summary: String, aiInsight: String,
         distanceMiles: Double, emoji: String, hueA: Double, hueB: Double) {
        self.id = UUID()
        self.name = name
        self.category = category
        self.summary = summary
        self.aiInsight = aiInsight
        self.distanceMiles = distanceMiles
        self.emoji = emoji
        self.hueA = hueA
        self.hueB = hueB
        self.perspectives = []
    }
}

/// A comment left on a place clip in the reels feed.
struct ClipComment: Codable, Hashable {
    var authorName: String
    var text: String
    var sentAt: Date
}

/// A 3-second ambient tag someone recorded at a spot.
@Model
final class SpotClip {
    @Attribute(.unique) var id: UUID
    var spot: Spot?
    var authorName: String
    var label: String
    var emoji: String
    var hueA: Double
    var hueB: Double
    var capturedAt: Date
    // Reels-feed engagement state.
    var likeCount: Int = 0
    var likedByMe: Bool = false
    var comments: [ClipComment] = []

    init(spot: Spot?, authorName: String, label: String, emoji: String,
         hueA: Double, hueB: Double, capturedAt: Date) {
        self.id = UUID()
        self.spot = spot
        self.authorName = authorName
        self.label = label
        self.emoji = emoji
        self.hueA = hueA
        self.hueB = hueB
        self.capturedAt = capturedAt
    }
}

/// A live "Join me" broadcast tied to a spot.
@Model
final class Beacon {
    @Attribute(.unique) var id: UUID
    var spot: Spot?
    @Relationship(inverse: \Friend.hostedBeacons) var host: Friend?
    var note: String
    var startsAt: Date
    var capacity: Int
    @Relationship(inverse: \Friend.joinedBeacons) var joined: [Friend]
    /// Public activities appear in the community feed and require a public
    /// profile to host or join; false = shared with friends only.
    var isPublic: Bool = false

    init(spot: Spot?, host: Friend?, note: String, startsAt: Date, capacity: Int, joined: [Friend] = []) {
        self.id = UUID()
        self.spot = spot
        self.host = host
        self.note = note
        self.startsAt = startsAt
        self.capacity = capacity
        self.joined = joined
    }

    var isFull: Bool { joined.count >= capacity }

    /// Everyone in the activity: host first, then RSVPs.
    var attendees: [Friend] {
        var roster: [Friend] = []
        if let host { roster.append(host) }
        roster.append(contentsOf: joined.filter { $0.id != host?.id })
        return roster
    }

    /// Group-chat scoping key (ChatMessage.activityId).
    var activityKey: String { id.uuidString }

    func hasJoined(_ friend: Friend) -> Bool {
        joined.contains { $0.id == friend.id }
    }

    func isAttending(_ friend: Friend) -> Bool {
        hasJoined(friend) || host?.id == friend.id
    }
}
