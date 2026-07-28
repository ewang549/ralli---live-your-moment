# Fix prompt: Pulse list should surface the friend you most recently sent a log or message *to*

## What's already there vs. what's actually missing

Pulse is already sorted by recent activity — this isn't a from-scratch feature, it's a scoping fix. `PulseHomeView.allEntries` (`PulseHomeView.swift:61-72`) sorts descending by `PulseEntry.activityAt`, which comes from `chat?.lastActivityAt ?? friend.latestClip?.capturedAt` (`PulseHomeView.swift:403`). `Chat.lastActivityAt` (`Models.swift:261-265`) is:

```swift
max(sortedClips.first?.capturedAt ?? .distantPast,
    messages.map(\.sentAt).max() ?? .distantPast,
    createdAt)
```

This already combines "last log in this chat" and "last message in this chat" into one timestamp — but it counts activity from **either party**, not specifically activity *you* initiated. If your friend messages you, that also bumps them to the top, even if you haven't sent them anything. That's almost certainly why this doesn't feel like it's working the way you described — the ask is specifically "the last person **I sent** something to," not "the last person who did anything in our chat."

## Fix

Add an author-scoped variant of `lastActivityAt` to `Chat` (`Models.swift`, right next to the existing computed property at line 261-265):

```swift
/// Like `lastActivityAt`, but only counts logs/messages *I* sent — used to surface
/// "who did I last reach out to" on Pulse, as distinct from "who's been active."
var lastSentByMeAt: Date? {
    let lastClip = sortedClips.first { $0.author?.isMe == true }?.capturedAt
    let lastMessage = messages.filter { $0.author?.isMe == true }.map(\.sentAt).max()
    let candidates = [lastClip, lastMessage].compactMap { $0 }
    return candidates.max()
}
```

Wire it into `PulseEntry.init` (`PulseHomeView.swift:395-407`) as the primary sort key, falling back to the existing `activityAt` for entries with no outgoing activity at all (so friends you've never messaged/logged still show up, just not pinned to the top):

```swift
let sentByMeAt = chat?.lastSentByMeAt
activityAt = chat?.lastActivityAt ?? friend.latestClip?.capturedAt
```

And in `allEntries`'s sort (`PulseHomeView.swift:61-72`), sort primarily on `sentByMeAt` (nils last), with the existing `activityAt`-based ordering as the tiebreaker/fallback for everyone you haven't personally sent anything to recently:

```swift
allEntries = entries.sorted { lhs, rhs in
    switch (lhs.sentByMeAt, rhs.sentByMeAt) {
    case let (l?, r?): return l > r
    case (.some, nil): return true
    case (nil, .some): return false
    case (nil, nil): return lhs.activityAt > rhs.activityAt   // existing fallback behavior, unchanged
    }
}
```

(Adjust the exact tuple/property names to match `PulseEntry`'s real shape once you're in the file — the point is: sort by "did I send them something, and when" first, then fall back to the current any-party `activityAt` ordering for the rest of the list, so nothing regresses for friends with no outgoing activity.)

## One thing to verify while implementing, not a known bug yet

Confirm every log-send path actually attaches the sent `Clip` to the correct `Chat` (via the clip's `chat` relationship) at send time — `sortedClips`/the new `lastSentByMeAt` both depend on `Chat.clips` being populated correctly. This almost certainly already works (it's how the friend-pairing screen's own-clip lookup already functions elsewhere), but worth a quick sanity check across the actual send call sites while you're in this code, since a clip that isn't correctly attached to its chat would silently fail to bump that friend to the top.

---

## Verification

- Send a log to a friend who's currently buried in the middle of your Pulse list; confirm they immediately jump to the top.
- Send a chat message (not a log) to a different friend; confirm that one also jumps to the top, above the friend from the previous step.
- Have a friend message or send *you* a log without you responding; confirm they do **not** jump to the top of your list purely from their own activity — only your own outgoing sends should do that.
- Confirm friends you've never sent anything to still appear in the list, just below anyone you've recently reached out to (no regression to the existing fallback ordering).
