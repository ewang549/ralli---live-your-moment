# Fix prompt: profile photos, media flicker/staleness, review-screen orientation, Beacons sync

Four issues, each traced to real code below. Do not touch anything outside what's described here — camera rotation plumbing, Stream messaging config, and the Pulse presentation-modifier consolidation from recent prompts are all correct now; leave them alone.

---

## 1 — Profile pictures only show on the profile screen, never in Pulse

`AvatarView` (`ClipView.swift`, ~line 133) is what renders every avatar in Pulse, chat rows, etc.:

```swift
if let url = friend.avatarPhotoURL, let uiImage = UIImage(contentsOfFile: url.path) {
    Image(uiImage: uiImage).resizable().scaledToFill()
} else {
    Circle().fill(...) ; Text(friend.emoji)...
}
```

`friend.avatarPhotoURL` (`Models.swift` ~line 140) resolves `avatarPhotoFileName` to a path in the **local device's Documents directory**. That field is only ever set when a photo is picked *on this device* (`ProfileSetupView`, or your own `UserProfileView` edit flow) — it is never set for a friend synced from the server. `FriendGraph.sync()` upserts `name`, `emoji`, `city`, `bio`, `isPrivate`, `handle` etc. from `RemoteProfile` but never touches an avatar field, because `Friend` has no remote-avatar field to sync into.

Meanwhile `UserProfileView`/`PublicProfileSheet` render photos correctly because they read `remote?.avatarURL` directly off a freshly-fetched `RemoteProfile` (confirmed at `UserProfileView.swift:597`) via its own `AsyncImage`/similar — a completely separate path from `AvatarView`, and the only reason a photo shows up anywhere.

**Fix:**

1. Add a synced field to `Friend`: `var avatarURL: String = ""` (a remote download URL string, same shape as `Clip.remoteURLString`).
2. In `FriendGraph.sync(_:into:)` (`FriendGraph.swift`), copy `profile.avatarURL` into `friend.avatarURL` alongside the other soft fields it already updates.
3. Update `AvatarView` to a three-tier fallback, mirroring the pattern `ClipView` already uses for photo clips (local file → remote URL → placeholder):

```swift
if let url = friend.avatarPhotoURL, let uiImage = UIImage(contentsOfFile: url.path) {
    Image(uiImage: uiImage).resizable().scaledToFill()
} else if let remote = URL(string: friend.avatarURL), !friend.avatarURL.isEmpty {
    AsyncImage(url: remote) { $0.resizable().scaledToFill() } placeholder: { placeholderOrb }
} else {
    placeholderOrb  // existing emoji-orb view, extracted so both branches can use it
}
```

This makes every friend's real photo show up everywhere in the app the moment their `Friend` row syncs, not just when you happen to open their profile.

## 2 — Sent media flickers to the emoji placeholder, and sometimes shows stale content

Two separate causes in `StackedClipViews.swift` and `ClipView.swift`, both real:

**2a — Unconditional clock-keyed remount.** `StackedClipPane` does:

```swift
ClipView(clip: clip, isActive: true)
    .id("\(clip.id)-\(clock.cycle)")
```

`clock.cycle` (`ClipSyncClock.swift`) increments every `clipDuration` seconds for *every* pane on screen, to keep looping videos restarting in lockstep. That's correct for video. But this `.id()` is applied regardless of `clip.kind`, so a **photo** — which has nothing to restart — gets its entire view torn down and rebuilt every cycle too. For a photo backed by `clip.assetURL` (local file) this is at least instant; for one backed by `clip.remoteURL` (the `AsyncImage` branch in `ClipView`), every rebuild re-fetches over the network and shows `vibeBody` (the emoji placeholder) as its `AsyncImage` placeholder while it reloads — that's the exact "flicker with the default emoji picture" you're seeing.

**Fix:** only key on `clock.cycle` when the clip actually loops:

```swift
.id(clip.kind == .video ? "\(clip.id)-\(clock.cycle)" : "\(clip.id)")
```

**2b — `LoopingVideoView` never reconfigures on a changed URL.** In `ClipView.swift`:

```swift
func updateUIView(_ uiView: PlayerContainerView, context: Context) {
    uiView.setPlaying(isPlaying)
}
```

This only toggles play/pause — it never checks whether `url` changed and never calls `configure(url:)` again if it did. Anywhere this view gets reused for a different clip without SwiftUI treating it as a new identity (any spot using `ClipView` without a clip-keyed `.id()`, now or added later), the player keeps showing whatever it loaded first. Fix defensively regardless of where it bites:

```swift
final class PlayerContainerView: UIView {
    private var currentURL: URL?
    ...
    func configure(url: URL) {
        currentURL = url
        ...
    }
}

// in LoopingVideoView.updateUIView:
func updateUIView(_ uiView: PlayerContainerView, context: Context) {
    if uiView.currentURL != url {
        uiView.configure(url: url)
    }
    uiView.setPlaying(isPlaying)
}
```

(`currentURL` needs to be readable from `LoopingVideoView` — expose via an internal var or a small getter.) This makes the video view self-correcting instead of relying entirely on the call site always supplying a perfectly-keyed `.id()`.

## 3 — Post-capture/send screen forces the photo vertical instead of letterboxing

`PostCaptureReview.swift` renders the shot via:

```swift
ClipView(clip: previewClip)
    .applyLook(look)
    .ignoresSafeArea()
```

`ClipView`'s photo branch always does `.aspectRatio(contentMode: .fill).frame(width: proxy.size.width, height: proxy.size.height).clipped()` — full-bleed fill, cropping to whatever shape the container is. Since capture is landscape-only, the photo's native aspect is landscape; filling a portrait screen with `.fill` crops/stretches it to look like a vertical image with the framing wrong, instead of showing the actual landscape photo.

Desired behavior (per your description): the **screen** (device chrome, controls) can stay in its normal portrait layout — only the **media itself** should render at its true landscape aspect ratio, centered, with letterboxing (black bars) above and below, exactly like watching a landscape video on a portrait phone.

**Fix — do not change `ClipView` globally** (the full-bleed fill look is presumably intentional for the main feeds/stacked views). Instead, give `ClipView` an explicit content-mode option, defaulting to today's `.fill` behavior everywhere else, and use `.fit` specifically on the post-capture review screen:

```swift
struct ClipView: View {
    let clip: Clip
    var isActive: Bool = true
    var contentMode: ContentMode = .fill   // new, defaults to existing behavior everywhere

    // photo branch:
    Image(uiImage: image)
        .resizable()
        .aspectRatio(contentMode: contentMode)
        .frame(width: proxy.size.width, height: proxy.size.height)
        .clipped()   // harmless no-op in .fit once the image is already contained
```

Apply the same `contentMode` passthrough to the video branch's `LoopingVideoView` (its `videoGravity` should switch from `.resizeAspectFill` to `.resizeAspect` when `contentMode == .fit`, so a landscape video letterboxes the same way a photo does).

In `PostCaptureReview.swift`, pass `.fit`:

```swift
ClipView(clip: previewClip, contentMode: .fit)
    .applyLook(look)
    .background(Color.black.ignoresSafeArea())   // fills the letterbox bars
    .ignoresSafeArea()
```

Confirm this doesn't change how clips render in the main feeds, chat threads, or anywhere else — every other call site should be left with no `contentMode` argument (defaulting to `.fill`, today's behavior) unless you're deliberately extending the same treatment elsewhere later.

## 4 — A video/photo posted to Places shows the emoji placeholder, never the real media

`SpotClip` (`Models.swift` ~line 517) — the model backing every Places feed card — has **no `kind` field at all**, unlike `Clip`, which distinguishes `.photo`/`.video`/`.vibe` via `kindRaw`. It does carry `remoteURLString` (the real uploaded media's download URL), but nothing downstream ever reads it.

`NichePlacesView.swift`'s card body renders the backdrop unconditionally:

```swift
var body: some View {
    ZStack(alignment: .bottom) {
        // The media is the backdrop; every control below floats over it.
        VibeClipView(emoji: clip.emoji, label: clip.label,
                     hueA: clip.hueA, hueB: clip.hueB, animate: isActive)
            .ignoresSafeArea()
```

That comment ("the media is the backdrop") describes the intent, but the code never checks `clip.remoteURLString` — it always shows the stylized emoji/gradient placeholder, real upload or not. The same pattern repeats at the other `VibeClipView(emoji: clip.emoji, ...)` call site further down the file (~line 711).

Compounding it: even where the data *is* available, it gets dropped along the way. `LogSync.swift`'s `RemotePublicLog` struct already carries `let kind: String` from the server, but `materialisePublic(_:into:)` builds each `SpotClip` without ever passing it through:

```swift
clip = SpotClip(spot: spot, authorName: log.authorName, authorUID: log.authorUid,
                label: log.caption, emoji: log.emoji, hueA: log.hueA, hueB: log.hueB,
                capturedAt: ...)   // log.kind is right there and never used
```

And `SendLogView.sendPublic()` constructs its own local `SpotClip` the same way, with no kind either.

**Fix, three parts, all needed together:**

1. Add `var kindRaw: String = ClipKind.vibe.rawValue` to `SpotClip` (mirroring `Clip`'s convention), with a computed `kind: ClipKind` accessor same as `Clip` already has.
2. Thread the kind through both write paths: `SendLogView.sendPublic()` should pass `kind: media.kind` into the local `SpotClip` it creates, and `LogSync.materialisePublic()` should set `clip.kindRaw = log.kind` (or the equivalent typed assignment) when creating/updating a `SpotClip` from a `RemotePublicLog`.
3. Fix the two card-rendering call sites in `NichePlacesView.swift` to actually branch on it, the same three-tier logic `ClipView` already uses for a real `Clip` (local file → remote URL → vibe placeholder) — reuse `ClipView`'s photo/video rendering rather than duplicating it if practical (e.g., by giving `ClipView` a lightweight second initializer that accepts a `SpotClip`'s fields directly, or by extracting the local/remote media-resolution logic into a shared helper both models can use). At minimum, each `VibeClipView(...)` call site should become:

```swift
if clip.kind == .video, let remote = clip.remoteURL {
    LoopingVideoView(url: remote, isPlaying: isActive)
} else if clip.kind == .photo, let remote = clip.remoteURL {
    AsyncImage(url: remote) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: {
        VibeClipView(emoji: clip.emoji, label: clip.label, hueA: clip.hueA, hueB: clip.hueB, animate: isActive)
    }
} else {
    VibeClipView(emoji: clip.emoji, label: clip.label, hueA: clip.hueA, hueB: clip.hueB, animate: isActive)
}
```

Existing rows already published to the server before this fix will have no `kind` recorded — they'll fall back to `.vibe` (today's behavior) until re-synced, which is fine; nothing needs a backfill.

## 5 — Beacons are entirely local; no other account ever sees them

Checked both sides. `functions/index.js` has **no Beacon-related code at all** — no collection, no callable, nothing. `BeaconsFeedView.swift` sources its list purely from `@Query private var beacons: [Beacon]`, and creating one (`startCreate` → `Beacon(spot: selectedSpot, host: me, note:, startsAt:, capacity:)`) just inserts a local SwiftData row. There is no server round-trip anywhere in the Beacon flow — a beacon you create exists only on your device, which is exactly why nobody else ever sees it, friend or public.

This is a real backend + sync gap, the same shape as the logs pipeline (`LogSync` + `publishLog`/`listFriendLogs`/`listPublicLogs`) already built for video/photo logs — follow that exact pattern rather than inventing a new one:

**Backend (`functions/index.js`):**

- A `beacons/{beaconId}` Firestore collection. Fields: `hostUid`, `spotId` (nullable — a beacon needn't be tied to a real `Spot` doc, but if it is, reuse the same `spots` collection convention `publishLog`'s public-audience path already established), `note`, `startsAt`, `capacity`, `isPublic`, `joinedUids: string[]`, `createdAt`.
- `createBeacon({ spotId, note, startsAt, capacity, isPublic })` — validates auth, writes the doc, `hostUid = auth.uid`.
- `joinBeacon({ beaconId })` / `leaveBeacon({ beaconId })` — adds/removes `auth.uid` from `joinedUids`, enforcing `capacity` and the existing "public beacon requires a public profile" guard that already exists client-side (`me.isPrivate` check in `BeaconsFeedView`) — enforce it server-side too, since a client check alone isn't real enforcement.
- `listFriendBeacons()` — same shape as `listFriendLogs`: fetch the caller's friend list, chunked `in` query against `beacons` where `hostUid` is a friend (or the caller themself) and `isPublic == false`, excluding anything already ended.
- `listPublicBeacons()` — all `isPublic == true` beacons not yet ended, same unauthenticated-to-relationship shape as `listPublicLogs`.
- Add matching Firestore rules: `beacons/{id}` readable by signed-in users (same reasoning `storage.rules` already documents for logs — the real gate is which `list*` callable hands out which rows), writes only through these callables (default-deny direct client writes, matching every other collection's pattern in `firestore.rules`).

**Client — new `BeaconSync` (mirror `LogSync.swift`'s shape exactly):**

- `publish(_ beacon: Beacon) async` — calls `createBeacon`, stamps the local row with a `remoteID` (add this field to the `Beacon` model, same convention as `Clip.remoteID`).
- `syncDown(context:)` — calls `listFriendBeacons`, materialises into local `Beacon` rows keyed by `remoteID` (same upsert-by-remoteID pattern `LogSync.materialise` already uses for logs), resolving `hostUid`/`joinedUids` against local `Friend` rows the same way `materialise` resolves `authorUid`.
- `syncPublicDown(context:)` — calls `listPublicBeacons`, same idea, for the public feed segment.
- `join(_ beacon: Beacon) async` / `leave(_ beacon: Beacon) async` — call `joinBeacon`/`leaveBeacon`, then re-sync or optimistically update `joined` locally the way `FriendGraph`'s actions do.

**Wire it in:** `startCreate()`'s beacon insert in `BeaconsFeedView.swift` should call `beaconSync.publish(beacon)` right after the local insert (fire-and-forget background task, same "local first, sync in background" shape `SendLogView.send()` already uses — don't block the create UI on the network). Add a `.task` to `BeaconsFeedView` that calls `syncDown`/`syncPublicDown` on appear, same as `PulseHomeView`'s existing `.task { await friendGraph.refresh(...); await logSync.syncDown(...) }`.

This is the biggest piece of this prompt — treat it as its own phase and get it working end-to-end (create on device A, see it on device B, both friends-only and public) before considering it done.

---

## Verification

- **1:** two accounts, friend each other, confirm each other's real profile photo shows in Pulse rows immediately after the friend sync completes — not just when opening their profile.
- **2:** send a photo and a video into a chat; watch the row/feed through at least two `clock.cycle` ticks and confirm no flicker to the emoji placeholder, and that scrolling through a stack never leaves a previous clip's video frozen on screen under a new caption/author.
- **3:** take a landscape photo, confirm the send/review screen shows it at its correct aspect with black letterboxing, not stretched/cropped to fill vertically. Confirm the main Pulse feed and chat thread views still show clips full-bleed as before (unaffected).
- **4:** post a real photo and a real video to a place from Send Log's public flow; confirm the Places feed card shows the actual media, not the emoji placeholder, both right after posting and after a fresh sync (`syncPublicDown`) on a second device.
- **5:** create a beacon on Device A as friends-only, confirm it appears on Device B (a real friend) within a normal refresh; create a public one and confirm it shows in Device B's public feed even without a friendship; confirm capacity and the private-profile join guard are enforced by the server, not just hidden client-side.
