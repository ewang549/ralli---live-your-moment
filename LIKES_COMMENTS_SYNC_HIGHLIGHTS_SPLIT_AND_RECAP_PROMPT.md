# Fix prompt: likes/comments aren't synced, Highlights shows the wrong content, Daily Recap orientation/tap, view counts

Four issues, grounded in the current code.

---

## 1 — Likes and comments are local-only; nobody else ever sees them

Confirmed: there is no backend for either at all. `functions/index.js` has zero like/comment-related code. `NichePlacesView.swift`'s `toggleLike()` (~line 470) does exactly this and nothing else:

```swift
private func toggleLike() {
    clip.likedByMe.toggle()
    clip.likeCount += clip.likedByMe ? 1 : -1
}
```

Pure local SwiftData mutation — nothing is ever sent to the server. Same story for comments: `ClipComment` (`Models.swift` ~line 542) is a plain `Codable` struct with no `authorUID`, stored directly as an array property on `SpotClip`, and `CommentsSheet` (`NichePlacesView.swift` ~line 479) only ever appends to that local array. This matches exactly what you're seeing: a like/comment only ever exists on the device that made it.

**Fix — real backend, then wire the client to it. This mirrors the pattern already used for follows/beacons/friend logs in this codebase, so build it the same way rather than inventing a new shape:**

**Backend (`functions/index.js`):**
- `toggleLikeLog({ logId })` — auth required. Store likes as `logs/{logId}/likes/{uid}` docs (existence = liked) rather than an array field, so concurrent likes never race each other. Return `{ liked: bool, likeCount: number }` (a `likeCount` counter field on the parent `logs/{id}` doc, updated via `FieldValue.increment`, the same pattern `publishLog`'s spot-clip-count increment already uses).
- `addComment({ logId, text })` — auth required, `cleanText`-sanitized (reuse the existing helper), stores `logs/{logId}/comments/{commentId}` with `authorUid`, `authorName`, `text`, `sentAt: FieldValue.serverTimestamp()`. Denormalize `authorName`/`authorAvatarEmoji`/`authorAvatarURL` from the caller's profile at write time — same reasoning `publishLog` already documents for why a public post's author fields are denormalized rather than resolved per-read.
- `listComments({ logId, limit })` — returns comments for a log, newest or oldest first (match whatever `CommentsSheet` already sorts by — oldest-first, per its current `.sorted { $0.sentAt < $1.sentAt }`).
- Add Firestore rules for the new `likes`/`comments` subcollections following the existing default-deny-plus-callable-only pattern in `firestore.rules` — no direct client writes.

**Client:**
- Give `SpotClip` (and if likes/comments should also apply to friends-only `Clip`s, that too — decide based on whether "the reels feed" in the existing comment on `ClipComment` was ever meant to be public-only; the current code and copy ("Reels-feed engagement state") suggest this is scoped to public Places posts specifically, so start there and only extend to private `Clip`s if that's actually wanted) a real sync path: a small addition to `LogSync` (or a new `EngagementSync`, matching the size of `BeaconSync`) with `toggleLike(_:)` calling `toggleLikeLog`, and `loadComments(for:)`/`addComment(_:to:)` calling the new callables.
- Add `authorUID: String` to `ClipComment` so a comment can actually be attributed to a real account (needed for any future moderation/block-filtering, matching every other content type in this app).
- Wire `toggleLike()` and `CommentsSheet`'s submit action to call the sync methods instead of mutating local state directly — keep the optimistic local update for responsiveness (flip `likedByMe`/append the comment immediately), but reconcile with the server's real response the same way `FollowGraph`/`toggleFollow` already do (roll back on failure).
- Sync comments/likes down alongside the existing `syncPublicDown` pass in `LogSync`, so opening Places picks up other people's likes/comments on already-synced content, not just your own.

## 2 — Video view counts don't exist anywhere; add real tracking

Confirmed there is genuinely nothing to build on here — `LogInsightsView.swift`'s own header comment already says it plainly: *"Views and saves aren't tracked anywhere for either model."* That screen currently only reports delivery/reach (upload state, who it was addressed to, where it was posted) specifically because there was no honest number to show for views — don't let this land as another placeholder zero.

There's a directly reusable pattern already in the codebase for exactly this shape of feature: `lookupUser`/`publicProfileFor` (`functions/index.js` ~line 510) increments a profile's `viewerCount` fire-and-forget on each view from another account, then reflects the increment immediately in its own response rather than making the viewer wait on a re-read. Build video view counts the same way:

**Backend:**
- Add a `viewCount` field to the `logs/{id}` doc (defaults to 0, same as `likeCount` from §1).
- Add a `viewLog({ logId })` callable: auth required, looks up the log, and if `log.authorUid !== uid` (never count the author's own views — matching the self-exclusion reasoning already used for `viewerCount` on profiles), increments `viewCount` fire-and-forget the same way, returning the updated count immediately.

**Client:**
- Call `viewLog` when a video log actually becomes the visible/active clip in a feed — every relevant view already threads an `isActive: Bool` through (`ClipView`, `StackedClipPane`, `ClipMediaView`), so hook the count there rather than adding new plumbing. Guard against re-counting the same log repeatedly as someone scrolls back and forth over one app session — keep an in-memory `Set` of already-counted log ids for the session and skip a repeat call rather than firing on every single scroll pass.
- Apply this to both public Places posts (`SpotClip`) and friends-only logs (`Clip`) — a view is a view regardless of audience, unlike likes/comments in §1 where scoping to public content specifically was a judgment call worth making explicit.
- Sync `viewCount` down the same way `likeCount` does in §1, and update `LogInsightsView` to show it as a real number once it exists — remove or revise the comment there that currently explains why views aren't shown, since that explanation stops being true once this lands.

## 3 — Profile Highlights shows all your videos; it should only show public location posts

`UserProfileView.swift`'s own-profile Highlights (`highlights(for me:)`, ~line 261) currently is:

```swift
private func highlights(for me: Friend) -> [Clip] {
    me.clips
        .filter { $0.kind == .video || $0.kind == .photo }
        .sorted { $0.capturedAt > $1.capturedAt }
}
```

This includes every video/photo you've ever captured — friends-only hourly logs included — which is why your daily logs are showing up there. What actually distinguishes "posted publicly to a place" is `Clip.intendedSpotID`: it's set only by `PublicPlacePostView.post()` when a log is posted publicly (empty for every friends-only send). Filter on that instead:

```swift
private func highlights(for me: Friend) -> [Clip] {
    me.clips
        .filter { !$0.intendedSpotID.isEmpty }
        .sorted { $0.capturedAt > $1.capturedAt }
}
```

Update the empty-state copy in `highlightsSection(for:)` (~line 276) to match the new scope — "Nothing filmed yet" / "Your logs land here as you post them" currently implies any capture counts; change to something like "Nothing posted publicly yet" / "Posts to a place will show up here," since a friends-only log will no longer appear here at all, by design.

Leave the *other* Highlights implementation in this same file (`highlights: [SpotClip]` ~line 571, used by `PublicProfileSheet` when viewing someone else's profile) untouched — that one already correctly shows only public place clips (`SpotClip`), matched to the viewed person. The bug was specific to your *own* profile's grid using the wrong source (`Clip`, unfiltered) instead of the same public-posts-only concept the rest of the app already gets right.

## 3 — Daily Recap: show the video horizontally, and lock the status button

**Orientation.** `DailyVlogView.swift`'s per-clip player (~line 264):

```swift
ClipView(clip: clip, isActive: true)
    .id(clip.id)
    .ignoresSafeArea()
```

No `contentMode` is passed, so it defaults to `.fill` — the landscape recording gets cropped to fill the vertical screen instead of showing at its true aspect. Add `contentMode: .fit`:

```swift
ClipView(clip: clip, isActive: true, contentMode: .fit)
    .id(clip.id)
    .ignoresSafeArea()
```

The surrounding `ZStack`'s `Color.black` base (~line 258) already provides the letterbox backing, so this is the only change needed here.

**Lock the status button.** `PulseChrome.swift`'s `HourlyCadenceBanner` currently has the status readout wired to open the hourly wall:

```swift
HStack(spacing: 14) {
    statusIcon
    Text(title)...
    Spacer(minLength: 0)
}
.contentShape(Rectangle())
.onTapGesture(perform: onOpenHour)
.accessibilityElement(children: .ignore)
.accessibilityAddTraits(.isButton)
.accessibilityLabel(title)
.accessibilityHint("Opens the hourly wall")

recapButton
```

Remove the tap entirely from the status side — no gesture, and drop the now-inapplicable `.isButton` accessibility trait (it becomes plain status text, so `.accessibilityElement(children: .ignore)` plus a label without the button trait/hint is enough):

```swift
HStack(spacing: 14) {
    statusIcon
    Text(title)...
    Spacer(minLength: 0)
}
.accessibilityElement(children: .ignore)
.accessibilityLabel(title)

recapButton
```

`onOpenHour` becomes unused inside `HourlyCadenceBanner` once this lands — remove the parameter and update its one call site in `PulseHomeView.swift` (`HourlyCadenceBanner(postedThisHour: postedThisHour) { destination = .hourlyWall }` → drop the trailing closure and the parameter from the initializer). This doesn't remove access to the hourly wall from Pulse entirely — `allFriendsCard` (the separate "All Friends" card already sitting below the banner) is still its own independent entry point into that same feed.

---

## Verification

- **1:** like a public post from one account, confirm it shows as liked (and the count is up) on a second account viewing the same post; add a comment from one account and confirm it appears when the other account opens that post's comments.
- **2:** watch a log from a second account and confirm the view count goes up exactly once per session, not once per scroll pass; confirm the author's own views of their own log never increment it.
- **3:** confirm your own profile's Highlights shows only posts made through the public-location flow, and that a friends-only hourly log never appears there, even though it still shows correctly everywhere it's supposed to (Pulse, the friend-pairing screen, All Friends, Daily Recap).
- **4:** open Daily Recap and confirm the video shows letterboxed/horizontal, not cropped vertical; confirm tapping the "Logged for this hour" status text/icon does nothing, and only the recap button on the right opens anything.
