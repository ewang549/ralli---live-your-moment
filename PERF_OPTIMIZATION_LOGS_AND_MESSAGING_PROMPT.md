# Fix prompt: logs load slowly, messages take a long time to send — beta-readiness performance pass

Grounded in the current code, in priority order (highest perceived-latency impact first). This isn't a rewrite — every item below is a targeted fix at a named location.

---

## Part A — Why messages take a long time to send

**The actual text-composer send path (type → hit send, inside an already-open thread) is fine.** It goes through Stream's stock `ChatChannelController.createNewMessage`, which is already optimistic client-side. The real latency is concentrated in two places that sit *in front of* sending, and one of them re-runs on every single reaction send, not just once per session.

### A1 — Every reaction-as-message re-does a full channel-join round trip before sending

`StreamThreadView.swift:337-357`, `postReaction`:

```swift
static func postReaction(_ emoji: String, to clip: Clip, in chat: Chat) async {
    ...
    try await StreamTokenProvider.joinChannel(channelId: channelId,
                                               otherMemberIds: chat.streamMemberIds,
                                               name: chat.displayName)
    ...
    controller.createNewMessage(text: "\(emoji) reacted to your log", ...)
```

`joinChannel` (`StreamTokenProvider.swift:43-59`) does a Firebase ID-token fetch (`user.getIDToken()`) followed by a full HTTPS call to the `joinStreamChannel` Cloud Function — **on every reaction**, even for a channel the user already joined and has open. This is the dominant cause of "sending feels slow": a token mint + network round trip + (see A3) a cold-start-prone function, all serialized in front of what should be an instant send.

**Fix:** only call `joinChannel` the first time a given channel is joined, not on every send. Track membership locally — e.g. a `Set<String>` of already-joined channel IDs kept on `StreamTokenProvider` (or persisted alongside `Chat` once joined server-side), and skip straight to `createNewMessage` when the channel is already known-joined:

```swift
static func postReaction(_ emoji: String, to clip: Clip, in chat: Chat) async {
    ...
    if !StreamTokenProvider.hasJoined(channelId) {
        try await StreamTokenProvider.joinChannel(channelId: channelId,
                                                   otherMemberIds: chat.streamMemberIds,
                                                   name: chat.displayName)
    }
    ...
    controller.createNewMessage(text: "\(emoji) reacted to your log", ...)
```

### A2 — Opening a thread blocks the composer on the same join round trip

`StreamThreadView.swift:122-165`, `makeController`: `.task { await makeController() }` (line 119) runs the same `joinChannel` call (line 131) before `channelController(createChannelWithId:)` + `synchronize()` (lines 138-159), and the composer/`ProgressView` state isn't cleared until that whole chain resolves. Since threads get re-opened often in a chat app, this reproduces the same stacked latency (token fetch + Cloud Function + Stream sync) every time a thread is opened, not just the first time.

**Fix:** same as A1 — skip `joinChannel` on re-open if the channel is already known-joined for this session/user. If server-side idempotency is a concern (rejoining is harmless but still costs a round trip), gate it client-side with the same "already joined" tracking from A1, so the very first open per channel still joins correctly but subsequent opens go straight to `synchronize()`.

### A3 — `joinStreamChannel` and `getStreamToken` have no `minInstances`, and both sit directly on this path

`functions/index.js:2614` (`getStreamToken`) and `2658` (`joinStreamChannel`) both declare `{ secrets: [streamApiSecret] }` with no `minInstances` configured anywhere in the file (confirmed zero matches for `minInstances`). Secret-bound callables typically pay extra cold-start cost fetching the secret from Secret Manager on a cold instance, and both of these functions are invoked repeatedly during a normal chat session (once per thread open, once per reaction, per A1/A2) — so a cold instance directly stalls perceived send/open time, intermittently and unpredictably.

**Fix:** set `minInstances: 1` (or a small positive number matching expected beta concurrency) on both `getStreamToken` and `joinStreamChannel` in their function config, so they stay warm during the beta test window. This has a small standing cost but is the standard fix for "occasionally slow, hard to reproduce" cold-start latency, and combined with A1/A2 removes most of the recurring per-send overhead — with A1/A2 in place these functions are called far less often anyway (once per channel instead of once per send/open), so the standing cost of keeping them warm is small.

### A4 — `joinStreamChannel` does two sequential Stream API calls that could be one

`functions/index.js:2676-2678`:

```js
await channel.create();
await channel.addMembers([auth.uid]);
```

Two sequential network round trips to Stream's own servers on every join. Stream's channel `create()` accepts a `members` array directly — pass the joining member in at creation instead of as a separate follow-up call:

```js
await channel.create({ members: [auth.uid] });
```

Confirm this doesn't break the case where the channel already exists with other members already present (Stream's `create()` is idempotent and additive for members in this SDK — verify against the installed `stream-chat` server SDK version before removing `addMembers` entirely; if there's any doubt, keep `addMembers` as a fallback only when `create()` reports the member wasn't already present, rather than always).

### A5 — `getStreamToken` does two sequential round trips per session (lower priority — runs once per launch, not per message)

`functions/index.js:2633-2636`: a Firestore profile read followed by `serverClient.upsertUser(...)`, awaited sequentially. Since this only runs once at sign-in/launch (confirmed: called only from `AuthGateView.connectStream` and `explogApp.connectStreamUser`, not per-message), this isn't part of the recurring send-latency problem — flagging only because it adds to time-to-first-send right after login, worth a `Promise.all` if the Firestore read and `upsertUser` don't actually depend on each other's result, but not urgent relative to A1-A4.

---

## Part B — Why logs don't load fast enough

### B1 — `syncDown` re-fetches the newest 80 logs from scratch on every call, with no cursor, and runs on every Pulse appearance

`LogSync.swift:233-257`: `syncDown` always requests a flat `"limit": 80` with no `since`/cursor parameter — every call re-downloads and re-materializes the same page from zero, even if nothing changed since the last sync seconds ago. It's invoked from **two** places on a normal session: `MainTabView.swift:161` (once per launch) and `PulseHomeView.swift:147` (a `.task`, which re-runs every time `PulseHomeView`'s `NavigationStack` reappears — e.g. returning from any full-screen cover, not just cold launch).

**Fix:**
1. Track a `lastSyncedAt` timestamp (or the latest `capturedAt`/log id seen) and pass it to `listFriendLogs` so the server can return only what's new since last sync, rather than always re-fetching the full 80.
2. Guard `PulseHomeView`'s `.task` with a staleness check (e.g. skip re-running `syncDown` if the last sync completed within the last N seconds) instead of running unconditionally on every appearance.

### B2 — `materialise`/`materialisePublic` pull every `Friend`/`Clip`/`Spot`/`SpotClip` row in the local store into memory, on the main actor, on every sync

`LogSync.swift:20` marks the whole class `@MainActor`. `materialise` (lines 372-416) does:

```swift
let friends = (try? context.fetch(FetchDescriptor<Friend>())) ?? []   // line 375
let existing = (try? context.fetch(FetchDescriptor<Clip>())) ?? []    // line 381
```

This fetches **every** `Friend` and **every** `Clip` in the entire local database just to build lookup dictionaries, before touching the ≤80 incoming logs from B1 — and it does this on the main thread, blocking UI, every single sync. `materialisePublic` (lines 290-365) does the equivalent for `Spot`/`SpotClip`. This cost grows unboundedly as a user's local history grows, which is exactly the kind of thing that gets worse specifically during a beta test as real usage accumulates.

**Fix:** this needs a background execution context, not a full rewrite. Move `materialise`/`materialisePublic`'s heavy fetch-and-diff work off the main actor — either a `ModelActor`-backed background context that does the fetch/diff/merge and hands back only the changes to apply on the main actor, or at minimum scope the `FetchDescriptor<Clip>` fetch with a predicate (e.g. only clips from the friends actually present in the incoming batch, or only clips from the last N days) instead of unconditionally loading the entire table. Do this one first if only one fix from B is feasible before beta — it's the one that gets worse over time as users accumulate history, and it blocks the main thread on every sync.

### B3 — Videos have no caching layer at all; photos do

`ClipMediaView.swift:105`'s photo branch uses `CachedImage`, backed by an `NSCache` (`CachedImage.swift:18`) — a photo clip won't re-decode or re-download on reappearance. The video branch (`ClipMediaView.swift:91-99` → `LoopingVideoView` → `PlayerContainerView.configure`, line 244) builds a fresh `AVURLAsset(url:)` and streams directly from Firebase Storage every time a pane is configured for a URL it doesn't already have loaded — scrolling away from a friend's video and back re-streams it from the network every time. Given logs are primarily video, **this is very likely the single biggest contributor to "logs don't load fast enough."**

**Fix:** add a local disk cache for video assets keyed by URL (e.g. `URLCache` configured with a reasonable disk capacity, or a simple "download once to a local temp file, play from disk" wrapper around `AVURLAsset`) so a clip already seen once in this session doesn't re-stream from Storage on every reappearance. The existing player-reuse/seek logic (`PlayerContainerView`, lines 197-311) is already well-built to avoid destroying/rebuilding `AVPlayer` unnecessarily — this fix slots in at the asset-loading step specifically, not a rework of the player itself.

### B4 — No prefetching of adjacent clips in a feed

In `AllFriendsFeedView`/`GroupClipFeedView`, a video only starts loading when its `StackedClipPane` actually scrolls into view in the `LazyVStack` — each new row pays full cold remote-asset-load latency (`asset.load(.duration, .tracks)`, `LoopingVideoView.swift:264`). Once B3's caching exists, add a light prefetch: when a pane becomes active, kick off `configure`/asset-loading for the next 1-2 rows in the same feed direction, so scrolling forward usually finds the next video already loading or cached rather than starting cold.

### B5 — Repeated unmemoized full-relationship scans on every render

Several places do an O(clips-in-relationship) scan on every SwiftUI render, none of it push-down to SQLite (SwiftData can't translate `Calendar.current.isDate`-style predicates into a store-level query):

- `Friend.clip(forHourContaining:)` (`HourAxis.swift:22-26`) — called once per friend per render in `AllFriendsFeedView.row(for:height:)` (`StackedClipViews.swift:900`).
- `Friend.latestClip` (`Models.swift:125-127`) — used by `PulseHomeView.postedThisHour` (lines 49-52) and `Friend.isOnline` (`Models.swift:132-134`), both read on every Pulse row render.
- `Chat.sortedClips` (`Models.swift:215-217`) — re-sorts the entire relationship on every access; `GroupClipFeedView.entries` (`StackedClipViews.swift:689-694`) calls it once per member per render, and `Chat.myClip(forHourContaining:)` (`HourAxis.swift:42-47`) does its own separate full scan on top of that.

None of this is wrong, just uncached — as clip history grows (which it will, specifically during a beta test), these scans get linearly slower on every scroll-driven re-render. **Fix, lowest-effort first:** memoize the "latest clip per friend for the current hour" as a dictionary built once per hour-change (not recomputed per render) in the views that already track `viewingHour`/similar state, rather than re-scanning `clips` per friend per render. If load lets you go further, a denormalized "latest clip" field maintained at sync time (updated once when `materialise` runs, per B2) removes the need for any of these ad-hoc scans entirely — but the memoization fix alone removes most of the redundant work without touching the sync layer.

### B6 — `listFriendLogs`'s friend-count fan-out (lower priority, backend-side, not obviously fixable without a bigger redesign)

`functions/index.js:1607-1653`: Firestore's `in`-clause 30-item cap forces `listFriendLogs` to chunk a large friend list into groups of 30, run one query per chunk (each capped at up to 200 docs), then re-sort and truncate in JS. For a user with, say, 90+ friends, this can read and ship far more documents than actually get returned. This is inherent to Firestore's query limits rather than a simple bug — flagging for awareness, not urgent for beta unless early testers have unusually large friend graphs. If it becomes a real issue post-beta, the standard fix is a fan-out write pattern (writing each log's id into a per-friend "inbox" subcollection at publish time) instead of a fan-in read, trading write cost for read cost — that's a bigger structural change, not a quick fix, so it's listed last deliberately.

---

## Suggested order of operations for beta

1. **A1 + A2** (skip redundant `joinChannel` calls) — biggest message-send win, smallest change.
2. **A3** (`minInstances` on the two Stream callables) — cheap, directly addresses intermittent cold-start slowness.
3. **B3** (video caching) — biggest log-load win, most likely to be user-visible immediately.
4. **B1** (sync cursor + guard the Pulse `.task`) — stops redundant re-fetching.
5. **B2** (move `materialise` off the main actor / scope its fetch) — prevents this from getting worse as beta testers accumulate history.
6. **A4, B4, B5** — smaller, compounding wins.
7. **A5, B6** — deferred; not urgent for beta, noted for later.

---

## Verification

- **A1/A2:** open a thread, send several reactions in a row, and confirm each additional reaction is near-instant (no repeated network stall); close and reopen the same thread and confirm the composer becomes interactive quickly on the second open.
- **A3:** send messages after the app has been idle for a while (past typical Cloud Functions idle-scale-down time) and confirm no more first-message delay than usual.
- **B1/B2:** background the app and return to Pulse repeatedly; confirm it doesn't visibly stall/re-load every time, and that this stays fast after accumulating a large local history (test with a seeded account that has months of clips, not just a fresh one).
- **B3/B4:** scroll through a friend's video feed, scroll away, and scroll back — confirm a previously-viewed video plays instantly the second time instead of re-buffering from the network.
- **B5:** scroll rapidly through All Friends / a group chat with a friend who has a long clip history and confirm no visible frame stutter tied to relationship-scan cost.
