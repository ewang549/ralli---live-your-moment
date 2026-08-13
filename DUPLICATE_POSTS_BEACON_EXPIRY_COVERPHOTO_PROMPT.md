# Fix prompt: duplicate Places posts, beacon auto-expiry, beacon cover photo, All Friends empty-slot sizing

Four items, one of which turns out to already be correctly implemented — but read item 0 first, since it's very likely the reason item 4 (and possibly others) still look broken on a real device despite the code being correct.

---

## 0 — Do this first: confirm you're building from the branch the fixes actually live on

Checked directly: the "All Friends empty-slot sizing" fix (item 4 below) — along with the pairing-gap, unread-scoping, and mid-take-flip fixes from the previous round — is genuinely committed and pushed to GitHub. `git log` shows it in commit `9056299` ("Fix pairing gap, unread scoping, mid-take flip, and All Friends row sizing"), fully in sync with `origin`. Re-reading the code directly confirms it's correct: the populated-card and empty-slot branches in `AllFriendsFeedView.row(for:width:height:)` both receive the exact same `width`/`height` values, so they cannot render at different sizes as written.

**But that commit only exists on the `social-graph-phase-1` branch.** `git branch -a` shows `main` (both local and on `origin`) still only has the original two initial commits — none of this work is on it. If the local checkout Xcode is actually archiving from has `main` checked out (rather than `social-graph-phase-1`), it will never see any of these fixes, no matter how many times it's clean-built or re-archived, because the code genuinely isn't present on that branch.

**Before re-testing anything below:**
1. In the exact folder Xcode builds from, run `git branch --show-current`.
2. If it says anything other than `social-graph-phase-1`, that's the problem: `git checkout social-graph-phase-1`.
3. Once confirmed working from the right branch, merge it into `main` and push (`git checkout main && git merge social-graph-phase-1 && git push`), so `main` stops being stuck on the initial commit and future builds/branches default to the current state instead of silently reverting to it.
4. Clean Build Folder in Xcode, then rebuild/re-archive, before judging any of the items below as fixed or not.

## 1 — Posting to Places sometimes creates 2-3 duplicate videos

Two independent client-side triggers, both made visible as real duplicates because the server has zero deduplication.

**Trigger A — no in-flight guard on the Post button.** `PublicPlacePostView`'s post button (`ShareLogViews.swift:364-374`) is only disabled by `canPost`, which just checks that a spot is selected — it has no `isSending`/in-flight state. `post()` (lines 443-501) creates a brand-new `Clip` and `SpotClip` and fires `logSync.publish(...)` **without awaiting it** (line 490-497), then immediately calls `dismiss()`. Since the view doesn't actually leave the hierarchy until SwiftUI processes that dismissal on a later runloop tick, a fast double-tap can invoke `post()` twice before the button disappears — creating two entirely separate `Clip`/`SpotClip` pairs, each with its own `publish()` call.

**Trigger B — the retry sweep re-sends a clip that already succeeded.** `LogSync.publish()`'s success path (`LogSync.swift:150-154`) persists the server's returned `remoteID` via `try? context.save()` — a `try?` that silently swallows a save failure. If the app backgrounds/crashes between the server successfully creating the post and that save landing, the clip still looks locally unpublished (`remoteID == ""`). The next launch's `publishPending()` sweep (lines 190-228, matching on `remoteID == "" && !isRemote`) will resend it — a genuine duplicate from the server's perspective, since it has no idea this is a retry.

**Root cause that turns both triggers into visible duplicates: `publishLog` has no idempotency at all.** `functions/index.js:1432`: `const ref = db.collection("logs").doc();` — every single invocation unconditionally creates a brand-new auto-ID document, with no client-supplied idempotency key and no check for an existing doc before writing. For a public post this also double-increments `spots/{spotId}.clipCount` (lines 1464-1469).

**Fix — do the server-side dedup first, it neutralizes both triggers at once:**
1. Have the client generate a stable UUID for each capture (once, at capture time — not regenerated on retry) and pass it to `publishLog` as a `clientRequestId`.
2. In `publishLog`, before creating a new doc, check for an existing `logs` doc with that `clientRequestId` (e.g. a Firestore query, or use it directly as the doc ID instead of `db.collection("logs").doc()`'s auto-ID) — if one already exists, return its existing data instead of creating a second one.
3. Additionally, harden the client: add an `@State private var isSending = false` guard to `PublicPlacePostView`'s post button (disable it the instant `post()` starts, not just on `canPost`), and make the success-path `Clip.remoteID` persistence in `LogSync.publish()` more robust than a silently-swallowed `try?` — at minimum log a failure there so a broken save is diagnosable instead of invisible.

## 2 — Beacons should be automatically removed once their date is past

The server already has a definition of "expired" — `functions/index.js:2152`, `BEACON_LIFETIME_MS = 6 * 60 * 60 * 1000` (6 hours past `startsAt`), and both `listFriendBeacons`/`listPublicBeacons` (lines 2399, 2445) already filter query results using that cutoff. So fresh syncs correctly stop returning expired beacons.

**The gap: nothing ever removes a beacon once it's already synced onto the device.** `BeaconSync.materialise()` (`BeaconSync.swift:215-291`) is a pure upsert — it creates/updates local `Beacon` rows from each response but never deletes a local row that's fallen out of the response. And `BeaconsFeedView.filtered` (`BeaconsFeedView.swift:33-36`) only filters by segment (public vs. hosted), with no time check at all. So once a beacon syncs into SwiftData, it stays visible locally forever, even after it ages past the server's 6-hour cutoff and stops appearing in fresh responses.

Separately, the underlying Firestore documents also live forever server-side — the query filter hides them from list results, but nothing ever deletes the docs themselves.

**Fix — three parts:**
1. Add a client-side time filter to `BeaconsFeedView.filtered`, checking `startsAt.addingTimeInterval(6 * 3600) > .now` (mirroring the server's `BEACON_LIFETIME_MS`), so already-cached expired rows stop rendering immediately regardless of sync timing — this is the fix that actually makes beacons "disappear" reliably from the user's perspective.
2. Have `BeaconSync.materialise()` prune local `Beacon` rows whose `remoteID` no longer appears in a fresh full sync response, so stale rows don't just pile up silently in the local store.
3. Optionally, add a scheduled Cloud Function that deletes `beacons` docs some time after they expire — model it on the existing `streakReminder` (`functions/index.js:2725`, an `onSchedule(...)` function), so Firestore storage is actually reclaimed server-side. This isn't required for correct display (the query filter already handles that), but worth doing since documents currently accumulate forever with no cleanup at all.

## 3 — Beacon creation should support a cover photo (upload, or auto-fetched from the location)

Confirmed: beacon creation has no image field at all today. The composer (`BeaconsFeedView.swift`, ~lines 985-1099) only collects location, note, capacity, public/private, and start time; `Beacon` (`Models.swift:847-878`) has no photo/image property, only a denormalized `hostAvatarURL`.

**What already exists to build on:**
- A working photo-upload pattern: `ProfilePhotoPicker.swift` uses SwiftUI's `PhotosPicker` with no extra permission dance needed, and `LogSync.publish()` (`LogSync.swift:103-115`) shows the Storage-upload pattern (`Storage.storage().reference(withPath:)`, `putFileAsync`, `downloadURL()`) — both are directly reusable templates for a manual cover-photo upload.
- Location search already runs through MapKit (`SpotSearchView.swift`, `MKLocalSearchCompleter`/`MKLocalSearch`) — but **MapKit has no place-photo API**. Apple doesn't expose anything comparable to Google's Place Photos for a searched location.

**What genuinely doesn't exist and would need real new setup:** there is no Google Places/Maps API key or SDK anywhere in this codebase (confirmed via grep — only Firebase's unrelated `GoogleService-Info.plist` and Stream's own API key turned up). Auto-fetching a photo for a location is not a small addition; it requires provisioning a Google Places API key and either a client SDK integration or (preferable, to avoid embedding a key client-side) a new Cloud Function proxy callable that calls Google's Place Photos endpoint server-side and returns a URL.

**Recommended approach given that gap:** ship manual upload first (it's the small, self-contained half of this request), and treat auto-fetch-from-location as a separate follow-up requiring real infrastructure decisions (API key provisioning/billing, whether to proxy through a Cloud Function) rather than bundling both into one pass:

1. Add `coverImageURL: String` to `Beacon` (client) and the `beacons` Firestore doc/`createBeacon` payload (`functions/index.js:2157`, `beaconPayload` at line 2211).
2. Add a `PhotosPicker`-based step to the beacon composer, mirroring `ProfilePhotoPicker`, uploading to a new `beacons/{uid}/...` Storage path before calling `createBeacon`, then passing the resulting URL along.
3. If/when auto-fetch is greenlit as a separate task: provision a Google Places API key, add a server-side callable that looks up a photo for the beacon's `MKMapItem`/coordinates and returns a URL, and use it as a fallback default when the host doesn't upload their own photo.

## 4 — All Friends empty-slot cards vs. video cards — already correctly unified, no fix needed here

Checked fresh: `AllFriendsFeedView.row(for:width:height:)` (`StackedClipViews.swift:999-1053`) already guarantees both branches match. The populated branch and the empty-slot branch are both children of one `Group` and both receive their frame from the exact same `width`/`height` parameters (lines 1030, 1033) — sourced from a single `GeometryReader`-derived `rowWidth`/`rowHeight` computed once per screen layout (lines 945, 948) and passed identically to every row regardless of whether that friend has a clip. Both branches also share the same corner-radius/border treatment applied outside the `Group` (lines 1036-1040). There's no separate hardcoded size or independently-computed dimension anywhere in the empty-slot path to drift out of sync — if the row's target size changes in the future (e.g. `rowsPerScreen` or padding constants), both branches automatically pick up the new value together, since they're driven by the same local variables.

**If this still looks visually off in a real build, it's almost certainly item 0 above** (building from `main` instead of `social-graph-phase-1`) rather than a genuine code gap — confirm the branch before assuming this needs further work.

---

## Verification

- **1:** rapidly double-tap the Places post button and confirm only one post appears; force-quit the app immediately after a successful post and relaunch, confirm the retry sweep doesn't create a second copy.
- **2:** confirm a beacon whose time has passed (plus the 6-hour window) disappears from the feed on a device that already had it cached locally, not just on a fresh install.
- **3:** create a beacon with an uploaded cover photo and confirm it displays correctly in the feed and detail view.
- **4:** no action needed — if empty-slot vs. video-card sizing still looks mismatched after confirming a fresh build, report back with specifics, since the code itself is already correct.
