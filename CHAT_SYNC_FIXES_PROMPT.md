# Fix prompt: friends can't be messaged/sent to after accepting

Three related bugs, all traced to actual code (not guesses — read the files named below before changing anything). Root cause in all three cases is the same design gap: **a local `Chat` row is created lazily, on demand, the first time you interact with a friend somewhere in the UI — but `SendLogView` never does that, and nothing cleans up a `Chat` when a friend is removed.**

Do not touch anything outside what's described here. Do not touch camera, Beacons, Places, or the design system.

---

## Bug A — "I can't send to anyone but me" (SendLogView)

`SendLogView.swift`'s friend picker is built from:

```swift
@Query(sort: \Chat.createdAt) private var chats: [Chat]
```

This is a raw list of whatever local `Chat` rows already happen to exist. There is no fallback that creates a `Chat` for a `Friend` who doesn't have one yet.

Compare this to every other messaging entry point in the app, which all correctly get-or-create:

- `PulseHomeView.swift` — `chat(orCreateWith:)`
- `UserProfileView.swift` — `chatWithThem()` (line ~1040, explicitly comments "Mirrors `PulseHomeView.chat(orCreateWith:)`")
- `BeaconsFeedView.swift` — `openHostChat(_:)`

A friend you just accepted gets a real local `Friend` row immediately (`FriendGraph.sync()` upserts this correctly and reactively — verified, not the problem). But they get **zero** `Chat` row until you happen to open their Pulse row or their profile first. Until then, `SendLogView` has nothing to show for them — only whatever `Chat` rows already existed (demo rows, "the crew", anyone you'd already messaged before). This is exactly the "duplicated Just me / can't send to anyone" screenshot.

**Fix:** Change `SendLogView`'s friends destination list to iterate the `friends` array (already queried in the file: `@Query private var friends: [Friend]`) rather than raw `chats`, and use the same get-or-create pattern as the other three views above — either by reusing/extracting a shared helper, or by adding an equivalent `chat(orCreateWith:)` local to `SendLogView`. Every accepted friend should be sendable immediately, with no prior visit to their Pulse row or profile required.

Ideally, extract the get-or-create logic (currently duplicated near-identically three times) into one shared helper — e.g. a `Chat` static/extension method `Chat.dm(with friend: Friend, me: Friend, context: ModelContext) -> Chat` — and have all four call sites (Pulse, Profile, Beacons, and the new Send Log usage) call the same function. This closes off the possibility of a fifth call site ever repeating this bug.

## Bug B — duplicate "Just me" rows

`Chat.displayName` (`Models.swift`):

```swift
var displayName: String {
    if let title, !title.isEmpty { return title }
    let others = members.filter { !$0.isMe }.map(\.name)
    return others.isEmpty ? "Just me" : others.joined(separator: ", ")
}
```

No code path ever intentionally creates a solo `members: [me]` chat — confirmed by checking every `Chat(...)` construction site. So a "Just me" row is a **1-on-1 chat whose other member got removed after the chat was created.**

That happens here, in `FriendGraph.swift`'s `sync(_:into:)`:

```swift
for (uid, friend) in byUID where !liveUIDs.contains(uid) {
    context.delete(friend)
}
```

This runs on every refresh (including right after any friend-graph change) and deletes the local `Friend` row for anyone no longer a live friend. `Chat.members` has no cascade delete rule (only `clips` and `messages` do), so deleting a `Friend` who is a chat member doesn't delete the `Chat` — it just drops out of that chat's `members` array, silently. The `Chat` survives, orphaned, and permanently renders as "Just me." Every unfriend (including ones from testing) leaves one of these behind, which is why there are multiple.

**Fix:** in `sync(_:into:)`, right before (or right after) deleting an orphaned `Friend`, also find and delete any 1-on-1 `Chat` whose only member besides "me" was that friend:

```swift
for (uid, friend) in byUID where !liveUIDs.contains(uid) {
    let orphanedChats = (try? context.fetch(FetchDescriptor<Chat>()))?.filter {
        !$0.isGroup && $0.members.contains { $0.id == friend.id }
    } ?? []
    for chat in orphanedChats {
        context.delete(chat)
    }
    context.delete(friend)
}
```

(Adjust to match actual local variable/type names in the file — this is illustrative, not a literal patch.) Also run a one-time cleanup pass for chats that are *already* orphaned on existing installs (any non-group `Chat` where, after filtering `isMe`, `members` is empty and it isn't a legitimately-solo chat — there are none of those by design, so any such row found at app launch can be safely deleted).

## Bug C — "texts aren't going through"

Checked the backend and channel-ID mapping directly — both look correct:

- `acceptFriendRequest` (functions/index.js) calls `ensureDmChannel(uid, fromUid)`, which creates a Stream channel at id `dm-{sorted uids}` and adds both members.
- The client computes the same id in `StreamThreadView.swift`'s `Chat.streamChannelId` (`dm-` + sorted `streamUserId` values), which is a documented match.

So this is very likely **not a separate backend bug** — it's the same root cause as Bug A viewed from a different screen: with no local `Chat` row for a freshly-accepted friend, there's nothing to open into `StreamThreadView` at all, so "can't message them" and "can't send them a log" are the same missing-row problem.

**After fixing Bug A**, re-test messaging specifically:
1. Accept a new friend request on Device B.
2. Confirm they now appear in `SendLogView`'s friend list immediately (Bug A fix).
3. Open a chat with them from Pulse and send an actual text message both directions.

If messaging **still** fails once a real `Chat`/channel exists, that's a genuinely separate bug — capture the exact failure (error shown, whether the message appears locally but not on the other device, whether `StreamThreadView` shows a connection error) and report back rather than guessing further; don't spend time rebuilding the Stream wiring speculatively, since the channel-creation code on both ends is already correct.

---

## Acceptance

- Accept a friend request on one account; on the other account, immediately open Send Log and confirm the new friend appears as a destination with no prior navigation to their profile or Pulse row.
- No new "Just me" rows appear from normal use; existing orphaned ones are cleaned up on next launch.
- Sending a text and a log to a newly-accepted friend both work in both directions.
- Unfriending someone removes both their `Friend` row and any 1-on-1 `Chat` that only contained them — verify no "Just me" reappears afterward.
- Nothing else changes: Pulse, profile message button, and Beacon host chat continue to work exactly as before (they were already correct — don't rewrite them, just extract/share their logic if you choose to).
