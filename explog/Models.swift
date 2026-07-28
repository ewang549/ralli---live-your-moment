import Foundation
import SwiftData

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

    /// Which push notifications this account wants, keyed by
    /// `NotificationCategory.rawValue`.
    ///
    /// Only meaningful on the `isMe` row — it's this user's own setting, and
    /// the copy the server actually checks lives on `users/{uid}`. A missing
    /// key means on, so an empty dictionary (which is what every row written
    /// before this existed has) is "notify me about everything", not silence.
    /// Defaulted, so this stays a lightweight SwiftData migration.
    var notificationPrefs: [String: Bool] = [:]

    /// A real profile photo, when one's been picked — takes over from the
    /// emoji/gradient orb everywhere an avatar renders. File name inside the
    /// app's Documents directory, same convention as `Clip.assetFileName`.
    /// Defaulted so this is a lightweight SwiftData migration for rows
    /// written before photo avatars existed.
    var avatarPhotoFileName: String? = nil

    /// The friend's uploaded profile photo (Storage download URL), synced from
    /// their `RemoteProfile`. `avatarPhotoFileName` only ever gets set for a
    /// photo picked *on this device*, so without this a friend's real photo
    /// existed nowhere in the local model and every avatar fell back to the
    /// emoji orb. Empty when they haven't set one.
    var avatarURL: String = ""

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

    /// Drives the green dot on the chat list. There is no presence service yet,
    /// so "online" is inferred from activity: they logged something inside the
    /// last quarter hour. Point this at real presence when Phase 2 lands.
    var isOnline: Bool {
        guard let capturedAt = latestClip?.capturedAt else { return false }
        return Date.now.timeIntervalSince(capturedAt) < 15 * 60
    }

    /// "@handle" when the account is real, otherwise the local lookup ID.
    var displayUserId: String {
        let value = userId.isEmpty ? handle : userId
        return value.isEmpty ? "" : "@\(value)"
    }

    /// On-device location of the picked profile photo, when there is one.
    ///
    /// Only ever set for a photo picked *on this device* — someone else's
    /// photo lives at `avatarRemotePhotoURL`. Anything rendering an avatar has
    /// to consult both, or a friend's real photo never appears.
    var avatarPhotoURL: URL? {
        guard let avatarPhotoFileName else { return nil }
        let url = URL.documentsDirectory.appending(path: avatarPhotoFileName)
        // A file name that no longer resolves (reinstall, or the app container
        // moving) would otherwise short-circuit the remote photo and pin the
        // avatar to the emoji orb for good.
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The uploaded photo on Storage, synced from this account's profile.
    var avatarRemotePhotoURL: URL? {
        avatarURL.isEmpty ? nil : URL(string: avatarURL)
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

    /// When the current user last opened this thread. Defaulted so this is a
    /// lightweight migration for chats written before the read cursor existed.
    /// Nil means "never opened" — everything in the chat still counts as new.
    var lastReadAt: Date? = nil

    /// When the current user last sent a *message* on this chat's Stream
    /// channel. Defaulted → lightweight migration for older stores.
    ///
    /// Stored rather than derived because a Stream message never becomes a
    /// local `Message` row: with real messaging on, `messages` only holds the
    /// legacy offline path, so `lastSentByMeAt` would be blind to every text
    /// you actually sent. `StreamThreadView`'s send recorder stamps this, and
    /// backfills it from channel history when a thread is opened.
    var lastOutgoingMessageAt: Date? = nil

    /// When a *friend* last sent a message on this chat's Stream channel.
    /// Defaulted → lightweight migration for older stores.
    ///
    /// The mirror image of `lastOutgoingMessageAt`, and stored for the same
    /// reason: an incoming Stream message never becomes a local `Message` row
    /// either, so nothing in the store used to record that a friend had texted
    /// you. That left `lastActivityAt` — the signal both Pulse's order and the
    /// unread dot read — able to see a friend's *log* but never their message.
    var lastIncomingMessageAt: Date? = nil

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
    ///
    /// Top-of-hour, not a rolling 60 minutes: one send per *clock* hour, and
    /// availability returns at the next `:00` rather than an hour after
    /// whenever you last sent. This is the same definition Pulse's hourly
    /// banner already used for `postedThisHour`, so the two mechanisms that
    /// used to disagree about "can I post now" are now one rule.
    var cooldownRemaining: TimeInterval {
        guard let lastSentAt,
              Calendar.current.isDate(lastSentAt, equalTo: .now, toGranularity: .hour) else { return 0 }
        let nextHour = Calendar.current.nextDate(after: .now,
                                                 matching: DateComponents(minute: 0, second: 0),
                                                 matchingPolicy: .nextTime) ?? .now
        return max(0, nextHour.timeIntervalSince(.now))
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

    // MARK: - Read state (Pulse chat-row unread dot)

    /// The most recent thing that happened here — a log, a message from either
    /// side, or (for a brand-new chat) just its creation. The single timestamp
    /// both the unread dot and the message-list ordering key off of, so they
    /// never disagree about what "most recent" means.
    ///
    /// Both Stream stamps are folded in, not just the outgoing one. Clips reach
    /// the store whoever filmed them, so this was always genuinely any-party
    /// for logs — but for text it could only ever see the legacy local `Message`
    /// rows plus my own Stream sends, which meant a friend texting you moved
    /// nothing at all. See `lastIncomingMessageAt`.
    var lastActivityAt: Date {
        max(sortedClips.first?.capturedAt ?? .distantPast,
            messages.map(\.sentAt).max() ?? .distantPast,
            lastIncomingMessageAt ?? .distantPast,
            lastOutgoingMessageAt ?? .distantPast,
            createdAt)
    }

    /// Like `lastActivityAt`, but only counting what *I* sent — the last log I
    /// posted here, the last message I wrote, whichever is newer. Nil when I've
    /// never reached out in this thread.
    ///
    /// Kept for the surfaces that genuinely mean "when did I last reach out",
    /// but Pulse's order no longer uses it: sorting on outgoing activity alone
    /// meant a friend who sent you a log or a message and got no reply never
    /// moved up the list. See `PulseEntry.byOutreach`.
    var lastSentByMeAt: Date? {
        [sortedClips.first { $0.author?.isMe == true }?.capturedAt,
         messages.filter { $0.author?.isMe == true }.map(\.sentAt).max(),
         lastOutgoingMessageAt]
            .compactMap { $0 }
            .max()
    }

    /// Records an outgoing Stream message at `sentAt`, keeping the newest.
    /// Never moves the stamp backwards — history replayed on thread open
    /// arrives out of order and must not undo a send that just happened.
    func noteOutgoingMessage(at sentAt: Date) {
        guard sentAt > (lastOutgoingMessageAt ?? .distantPast) else { return }
        lastOutgoingMessageAt = sentAt
    }

    /// Records a friend's message at `sentAt`, keeping the newest. Same
    /// monotonic rule as `noteOutgoingMessage`, and for the same reason:
    /// channel history arrives out of order and must not walk the stamp back
    /// over a message that landed a moment ago.
    func noteIncomingMessage(at sentAt: Date) {
        guard sentAt > (lastIncomingMessageAt ?? .distantPast) else { return }
        lastIncomingMessageAt = sentAt
    }

    /// The most recent thing *someone else* did here — their log, their
    /// message, whichever is newer. `.distantPast` when nothing has ever
    /// arrived from the other side.
    ///
    /// Deliberately not `lastActivityAt` with a filter bolted on: that one is
    /// any-party by design (see its comment) and floors at `createdAt`, both of
    /// which are right for ordering and wrong for unread. A thread I have only
    /// ever sent *into* has nothing to be unread, so this has no `createdAt`
    /// floor and no outgoing terms at all.
    var lastIncomingActivityAt: Date {
        max(sortedClips.first { $0.author?.isMe != true }?.capturedAt ?? .distantPast,
            messages.filter { $0.author?.isMe != true }.map(\.sentAt).max() ?? .distantPast,
            lastIncomingMessageAt ?? .distantPast)
    }

    /// True when something *arrived* here since the current user last opened
    /// the thread. This is the one source of truth for the row's unread dot —
    /// set `lastReadAt` when the thread is opened and it clears immediately,
    /// and stays cleared until a friend sends something new.
    ///
    /// Scoped to incoming activity rather than to `lastActivityAt`, because my
    /// own sends move that too: `SendToFriendsView.send()` appends my clip to
    /// the chat and never calls `markRead()`, so sending a log to a friend lit
    /// their unread dot with no friend involved at all. Scoping the signal
    /// fixes that everywhere at once — a future send path can't reintroduce the
    /// bug by forgetting to mark the thread read.
    ///
    /// Both Stream stamps and the local rows matter here. A friend's text
    /// writes neither a `Clip` nor a local `Message` — only
    /// `lastIncomingMessageAt` — so a signal built from rows alone stayed dark
    /// for the exact case the dot exists to announce.
    var hasUnread: Bool {
        lastIncomingActivityAt > (lastReadAt ?? .distantPast)
    }

    /// Whether anything has happened in this thread beyond it being created.
    var hasActivity: Bool {
        !clips.isEmpty || !messages.isEmpty
            || lastIncomingMessageAt != nil || lastOutgoingMessageAt != nil
    }

    /// `lastActivityAt` for ordering: nil when the thread has only ever been
    /// created and nothing has happened in it.
    ///
    /// `lastActivityAt` floors at `createdAt` so it can always answer with a
    /// date, which is right for "how recent is this" but wrong as a sort key.
    /// Threads get auto-created just by tapping a friend's message button, and
    /// once the order leads on activity rather than on my own sends, that bare
    /// creation timestamp would rank an empty thread opened by accident above
    /// a friend you actually spoke to last week.
    var lastRealActivityAt: Date? {
        hasActivity ? lastActivityAt : nil
    }

    /// Call when the user opens this thread. Idempotent enough to call from
    /// `onAppear` — repeatedly stamping "now" while already caught up is harmless.
    func markRead() {
        lastReadAt = .now
    }
}

// MARK: - DM lookup

extension Chat {
    /// The 1-on-1 chat with `friend`, created if this is the first time anyone
    /// asked for it.
    ///
    /// Every entry point into a DM — Pulse rows, a profile's Message button, a
    /// beacon host, the Send Log audience list — goes through here. A local
    /// `Chat` is what makes someone reachable at all, and it used to be created
    /// ad hoc by whichever screen you happened to open first: a friend you'd
    /// just accepted but never visited had no row, so Send Log had nothing to
    /// list and there was nothing to open a thread from. One shared get-or-create
    /// means a friendship is enough, and every caller lands on the same row —
    /// and so the same deterministic Stream channel.
    static func dm(with friend: Friend, me: Friend, in context: ModelContext) -> Chat {
        let existing = (try? context.fetch(FetchDescriptor<Chat>()))?.first { chat in
            !chat.isGroup && chat.members.contains { $0.id == friend.id }
        }
        if let existing { return existing }

        let chat = Chat(isGroup: false, members: [me, friend])
        context.insert(chat)
        try? context.save()
        return chat
    }

    /// Deletes 1-on-1 chats that have lost the person they were with.
    ///
    /// `Chat.members` has no cascade rule, so deleting a `Friend` row (which is
    /// what un-friending does) silently drops them out of the members array and
    /// leaves the chat behind with only "me" in it — a row that renders forever
    /// as "Just me". Nothing ever intentionally creates a solo chat, so any
    /// non-group chat with no other member is one of these leftovers and is safe
    /// to remove. Run at launch to clear ones that predate the fix; `FriendGraph`
    /// prevents new ones at the point the friend is deleted.
    static func pruneOrphanedDMs(in context: ModelContext) {
        let orphaned = ((try? context.fetch(FetchDescriptor<Chat>())) ?? []).filter { chat in
            !chat.isGroup && !chat.members.contains { !$0.isMe }
        }
        guard !orphaned.isEmpty else { return }
        for chat in orphaned { context.delete(chat) }
        try? context.save()
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

    // MARK: Sync (Phase 2: content sync)
    //
    // A clip starts life local-only and becomes shared once its media is in
    // Storage and a `logs/{id}` doc exists. Defaulted so this is a lightweight
    // SwiftData migration for stores written before logs synced.

    /// `logs/{remoteID}` in Firestore. Empty until published.
    var remoteID: String = ""
    /// Storage download URL for the media. Empty for local-only and vibe clips.
    var remoteURLString: String = ""
    /// Author's Firebase uid. Set on both published and downloaded clips, so a
    /// synced clip still knows who made it even before its `Friend` row exists.
    var authorUID: String = ""
    /// True for a clip pulled down from a friend rather than captured here.
    var isRemote: Bool = false
    /// The spot this clip was meant to be posted publicly to, when it was.
    ///
    /// Kept on the clip rather than only passed to `publish` so a retry knows
    /// the intended audience: without it, a public post whose first upload
    /// failed would be silently re-published to friends instead.
    var intendedSpotID: String = ""

    /// The friends this clip was actually addressed to, for the same reason
    /// `intendedSpotID` is kept here: a send that failed and is retried later
    /// must reach the same people, not the whole roster. Empty means "everyone
    /// you're friends with", which is what an unaddressed log has always meant.
    var intendedRecipientUIDs: [String] = []

    /// True once an upload attempt has actually failed, as opposed to not
    /// having happened yet.
    ///
    /// `remoteID.isEmpty` alone can't tell "still on its way up" from "gave
    /// up" — and that distinction is the whole difference between a send the
    /// user should wait on and one they need to know about. Cleared when a
    /// retry starts, so the banner reflects the current attempt rather than an
    /// old one.
    var publishFailed: Bool = false

    /// How many accounts other than the author have watched this log.
    ///
    /// A cache of `logs/{remoteID}.viewCount`. Unlike likes and comments, which
    /// are scoped to public place posts, this is tracked for friends-only logs
    /// too — a view is a view regardless of who it was addressed to, and this
    /// is the number `LogInsightsView` reports back to the author.
    var viewCount: Int = 0

    /// Whether this log's audio is silenced on playback.
    ///
    /// A playback flag rather than a property of the file: the recording keeps
    /// its audio track, so muting stays reversible and costs no export pass.
    /// Only meaningful for `.video` — a photo has no audio to silence.
    var isMuted: Bool = false

    /// The media's displayed width ÷ height, measured once when the log was
    /// created and stored so every surface can size its container to the real
    /// shape of the shot *before* the asset loads.
    ///
    /// `AVAsset` only reports a natural size asynchronously, long after layout
    /// has run, so resolving this at playback time would mean laying out
    /// against a guess and popping to the right shape once the video arrived.
    /// 0 means "unknown" — logs written before this field existed, and clips
    /// synced from a friend on an older build — and every reader falls back to
    /// its own default shape rather than dividing by zero.
    var videoAspectRatio: Double = 0

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

    /// On-device media. Nil for clips that only exist on the server.
    var assetURL: URL? {
        guard let assetFileName else { return nil }
        return URL.documentsDirectory.appending(path: assetFileName)
    }

    /// Media in Storage, once published or downloaded.
    var remoteURL: URL? {
        remoteURLString.isEmpty ? nil : URL(string: remoteURLString)
    }

    /// What a player should actually load: the local file when it's really on
    /// disk, otherwise the uploaded copy. Keeping the local file first means
    /// your own just-captured log plays instantly instead of round-tripping
    /// through Storage.
    var playbackURL: URL? {
        if let assetURL, FileManager.default.fileExists(atPath: assetURL.path) {
            return assetURL
        }
        return remoteURL
    }

    /// The shape a container should be laid out in to show this log whole.
    ///
    /// `videoAspectRatio` when it was measured, and the landscape capture
    /// shape otherwise. The fallback matters as much as the measurement: a
    /// clip from an older build, or one synced from a friend still running
    /// one, has no stored ratio, and a container sized from 0 would collapse.
    /// Capture is landscape-only at the `.high` preset, so 16:9 is what those
    /// clips almost certainly are.
    var displayAspectRatio: Double {
        videoAspectRatio > 0 ? videoAspectRatio : Clip.defaultAspectRatio
    }

    /// See `displayAspectRatio` — the shape assumed for an unmeasured clip.
    static let defaultAspectRatio: Double = 16.0 / 9.0

    /// Whether this clip's media has reached the server.
    var isPublished: Bool { !remoteID.isEmpty }

    /// How far this capture got on its way to the recipient.
    ///
    /// `.pending` and `.failed` look identical in the store apart from
    /// `publishFailed`, and conflating them is what made a dead send
    /// indistinguishable from a slow one. Read by the UI; the fetch predicates
    /// in `LogSync` match on the stored fields directly, since `#Predicate`
    /// can't call a computed property.
    enum SendState {
        /// Captured, not yet acknowledged by the server — still on its way.
        case pending
        /// The server has it; recipients can see it.
        case published
        /// An upload attempt failed. Local-only until a retry succeeds.
        case failed
    }

    var sendState: SendState {
        if isPublished { return .published }
        return publishFailed ? .failed : .pending
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
    /// The actual spot behind a shared-location card, so tapping it in the
    /// thread can open the very same detail sheet the Places feed uses.
    /// Optional to-one; nil on legacy messages and plain text.
    var sharedSpot: Spot?
    /// iMessage-style tapback reaction (single emoji), nil when none.
    var tapback: String? = nil
    /// Set when the message belongs to an activity group chat instead of a
    /// direct chat (ActivityChatView) — the Beacon's id string.
    var activityId: String? = nil
    /// When this message is a reaction *broadcast* onto a friend's video log,
    /// the emoji that was tapped. The bubble then renders the reacted clip's
    /// preview with this emoji overlaid instead of plain text. nil for normal
    /// messages. Defaulted → lightweight SwiftData migration for old stores.
    var reactionEmoji: String? = nil
    /// The clip a reaction message targets, so the thread can show a live
    /// preview of the exact log that was reacted to. Optional to-one; nil on
    /// plain messages. No explicit inverse — a clip doesn't need to know which
    /// messages reference it.
    var reactedClip: Clip? = nil

    init(chat: Chat?, author: Friend?, text: String, sentAt: Date = .now, sharedSpotName: String? = nil) {
        self.id = UUID()
        self.chat = chat
        self.author = author
        self.text = text
        self.sentAt = sentAt
        self.sharedSpotName = sharedSpotName
    }

    /// A reaction broadcast: the friend's clip preview stamped with `emoji`,
    /// posted into the thread so a reaction shows up as chat context too.
    static func reaction(_ emoji: String, to clip: Clip, from author: Friend?, in chat: Chat?) -> Message {
        let message = Message(chat: chat, author: author, text: "")
        message.reactionEmoji = emoji
        message.reactedClip = clip
        return message
    }

    /// True when this message is a reaction broadcast rather than plain text.
    var isReaction: Bool { reactionEmoji != nil }
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
    /// `spots/{id}` on the server. Empty for seed rows, which never left the
    /// device; every spot created through location search carries one, which is
    /// what lets a second account find the same place.
    var remoteID: String = ""
    /// Coordinates from the location search that created this spot. Both zero
    /// when unknown (seed data), which `hasCoordinate` distinguishes from a
    /// genuine null-island fix.
    var latitude: Double = 0
    var longitude: Double = 0
    var hasCoordinate: Bool = false
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
///
/// Mirrors `logs/{logId}/comments/{id}` on the server. It carries the author's
/// real account uid and denormalised identity, which is what makes a comment
/// attributable at all — before there was a backend for this, a comment was an
/// unattributed string that existed only on the device that typed it.
struct ClipComment: Codable, Hashable {
    /// `logs/{logId}/comments/{id}`. Empty for a comment still in flight, which
    /// is how the optimistic insert is told apart from the server's copy.
    var remoteID: String = ""
    /// The commenter's account uid. Empty only for rows written before this
    /// existed. Needed for any blocking or moderation decision downstream.
    var authorUID: String = ""
    var authorName: String
    var authorAvatarEmoji: String = ""
    var authorAvatarURL: String = ""
    var text: String
    var sentAt: Date

    init(remoteID: String = "",
         authorUID: String = "",
         authorName: String,
         authorAvatarEmoji: String = "",
         authorAvatarURL: String = "",
         text: String,
         sentAt: Date) {
        self.remoteID = remoteID
        self.authorUID = authorUID
        self.authorName = authorName
        self.authorAvatarEmoji = authorAvatarEmoji
        self.authorAvatarURL = authorAvatarURL
        self.text = text
        self.sentAt = sentAt
    }

    /// Decoded field by field rather than by the synthesized initialiser.
    ///
    /// A synthesized `init(from:)` throws on a missing key *even when the
    /// property has a default value*, so adding a field to this struct would
    /// fail to decode every comment already stored — and because these live as
    /// an encoded array on `SpotClip`, one bad row loses the whole thread.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        remoteID = try container.decodeIfPresent(String.self, forKey: .remoteID) ?? ""
        authorUID = try container.decodeIfPresent(String.self, forKey: .authorUID) ?? ""
        authorName = try container.decodeIfPresent(String.self, forKey: .authorName) ?? ""
        authorAvatarEmoji = try container.decodeIfPresent(String.self, forKey: .authorAvatarEmoji) ?? ""
        authorAvatarURL = try container.decodeIfPresent(String.self, forKey: .authorAvatarURL) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        sentAt = try container.decodeIfPresent(Date.self, forKey: .sentAt) ?? .now
    }
}

/// A 3-second ambient tag someone recorded at a spot.
@Model
final class SpotClip {
    @Attribute(.unique) var id: UUID
    var spot: Spot?
    var authorName: String
    /// The author's account uid. Empty for legacy/seed clips, which predate
    /// public posting and have no real account behind them — every screen that
    /// acts on the author (Follow, profile sheet) must tolerate that.
    var authorUID: String = ""
    /// The author's uploaded profile photo (Storage download URL).
    ///
    /// The Places feed shows content from people the viewer has no local
    /// `Friend` row for, so there is nowhere else to read an avatar from. The
    /// server has always denormalised this onto a public log (`authorAvatarURL`)
    /// and `RemotePublicLog` has always decoded it — but there was no field to
    /// put it in, so every Places card drew the placeholder no matter how many
    /// of those authors had a real photo. Defaulted, so this is a lightweight
    /// SwiftData migration.
    var authorAvatarURL: String = ""
    /// The author's avatar emoji, for the placeholder. Distinct from `emoji`,
    /// which is the *clip's* vibe emoji — the orb used to render that, so even
    /// the fallback wasn't the person's.
    var authorAvatarEmoji: String = ""
    /// `logs/{id}` on the server, for clips pulled from the public feed. Empty
    /// for clips that only exist locally.
    var remoteID: String = ""
    /// Download URL of the clip's media, when it has any.
    var remoteURLString: String = ""
    /// What kind of media this is, same convention as `Clip.kindRaw`. Places
    /// rows carried a media URL but nothing said whether it was a photo or a
    /// video, so every card rendered the vibe placeholder. Defaults to `.vibe`,
    /// which is both a lightweight SwiftData migration and exactly the old
    /// behavior for rows published before the kind was recorded.
    var kindRaw: String = ClipKind.vibe.rawValue
    /// File name inside the app's Documents directory, for a clip captured on
    /// this device — so your own post shows its real media immediately rather
    /// than waiting on the upload to come back.
    var assetFileName: String? = nil
    var label: String
    var emoji: String
    var hueA: Double
    var hueB: Double
    var capturedAt: Date
    /// The media's displayed width ÷ height. Mirrors `Clip.videoAspectRatio`
    /// for the Places feed — the same "show the whole frame, never crop it"
    /// rule applies here, and a place card needs the shape for the same
    /// reason a log card does. 0 means unknown; see `displayAspectRatio`.
    var videoAspectRatio: Double = 0
    // Reels-feed engagement state. Server-owned since likes and comments got a
    // backend: these are a cache of `logs/{remoteID}`'s counters, not the truth.
    var likeCount: Int = 0
    var likedByMe: Bool = false
    /// How many accounts other than the author have watched this. Defaulted, so
    /// this is a lightweight SwiftData migration.
    var viewCount: Int = 0
    /// Bookmarked from the Places rail. Defaulted, so this is a lightweight
    /// SwiftData migration for stores written before the rail existed.
    var savedByMe: Bool = false
    var comments: [ClipComment] = []

    init(spot: Spot?, authorName: String, authorUID: String = "",
         label: String, emoji: String,
         hueA: Double, hueB: Double, capturedAt: Date,
         kind: ClipKind = .vibe, assetFileName: String? = nil) {
        self.id = UUID()
        self.spot = spot
        self.authorName = authorName
        self.authorUID = authorUID
        self.label = label
        self.emoji = emoji
        self.hueA = hueA
        self.hueB = hueB
        self.capturedAt = capturedAt
        self.kindRaw = kind.rawValue
        self.assetFileName = assetFileName
    }

    var kind: ClipKind { ClipKind(rawValue: kindRaw) ?? .vibe }

    /// On-device media. Nil for clips that only exist on the server.
    var assetURL: URL? {
        guard let assetFileName else { return nil }
        return URL.documentsDirectory.appending(path: assetFileName)
    }

    /// Media in Storage, once published or downloaded.
    var remoteURL: URL? {
        remoteURLString.isEmpty ? nil : URL(string: remoteURLString)
    }

    /// The shape a container should be laid out in to show this clip whole.
    /// See `Clip.displayAspectRatio` — same rule, same fallback.
    var displayAspectRatio: Double {
        videoAspectRatio > 0 ? videoAspectRatio : Clip.defaultAspectRatio
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

    // MARK: Sync
    //
    // A beacon starts local and becomes shared once `beacons/{remoteID}` exists.
    // All defaulted, so this is a lightweight SwiftData migration for stores
    // written while beacons were device-only.

    /// `beacons/{remoteID}` in Firestore. Empty until published, and on seeded
    /// demo rows, which never leave the device.
    var remoteID: String = ""

    /// Host identity, denormalised.
    ///
    /// `host` is a local `Friend`, and a public beacon's host is usually someone
    /// the viewer has no relationship with — so there is no row to hang it off.
    /// These carry enough to draw the card either way.
    var hostUID: String = ""
    var hostName: String = ""
    var hostEmoji: String = ""
    var hostAvatarURL: String = ""

    /// Everyone who has RSVP'd, as account uids — the roster of record.
    ///
    /// `joined` can only hold attendees this device has a `Friend` row for, so
    /// on a public beacon it is usually a subset. Counting off that would show
    /// "1/8" on an activity the server considers full.
    var joinedUIDs: [String] = []

    init(spot: Spot?, host: Friend?, note: String, startsAt: Date, capacity: Int, joined: [Friend] = []) {
        self.id = UUID()
        self.spot = spot
        self.host = host
        self.note = note
        self.startsAt = startsAt
        self.capacity = capacity
        self.joined = joined
    }

    /// How many people are in, counting attendees this device has no `Friend`
    /// row for. Local-only beacons (seed data) carry no uids and fall back to
    /// the relationship, which is all they ever had.
    var attendeeCount: Int { max(joinedUIDs.count, joined.count) }

    var isFull: Bool { attendeeCount >= capacity }

    /// Everyone in the activity we can actually draw: host first, then RSVPs.
    /// Attendees without a local `Friend` row are counted by `attendeeCount`
    /// but have no avatar to show.
    var attendees: [Friend] {
        var roster: [Friend] = []
        if let host { roster.append(host) }
        roster.append(contentsOf: joined.filter { $0.id != host?.id })
        return roster
    }

    /// Group-chat scoping key (ChatMessage.activityId).
    var activityKey: String { id.uuidString }

    func hasJoined(_ friend: Friend) -> Bool {
        if !friend.remoteUID.isEmpty && joinedUIDs.contains(friend.remoteUID) { return true }
        return joined.contains { $0.id == friend.id }
    }

    func isAttending(_ friend: Friend) -> Bool {
        if !friend.remoteUID.isEmpty && hostUID == friend.remoteUID { return true }
        return hasJoined(friend) || host?.id == friend.id
    }
}
