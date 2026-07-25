# Build Prompt: Camera orientation, friend requests, Follow system, content sync, Places/Beacon location, profile photo

I read through the actual codebase before writing this, so the items below are grounded in what's really there, not guesses — file names, line numbers, and root causes are called out precisely. **Read each "Root cause" before touching code.** Several things that looked broken are actually already correctly built (the Follow backend, the friend-request backend, the push notification system) — don't rebuild those, only fix the specific gap named. Other things (content sync, Spot/location) have real, sizeable architecture gaps that need real building, not a small patch. Work through the phases in order; each is independently testable.

---

## 0. DO NOT BREAK — protected, already-working behavior

Re-verify all of these after your work, via simulator screenshots:

- **Coral theme** (`Theme.accent`) everywhere — no blue/purple/gold anywhere.
- **Landscape-only camera** — stays landscape-only; you are ONLY fixing the video orientation bug in Phase 1, not the layout, not the landscape lock itself.
- **Per-row message button on Pulse** — every row keeps its right-aligned message icon opening that exact conversation.
- **Hourly countdown on Pulse** — keeps working.
- **Logout doesn't crash** — `AuthGateView`'s auth-change handler must keep unmounting data-bound views *before* `LocalStore.claim`/`wipe` runs. Do not reintroduce an early wipe.
- **Per-account cache scoping** (`LocalStore.claim`/`wipe`) — new synced data (Phase 5) must also be wiped on account change, same as everything else.
- **`PublicProfileSheet` stays the single shared profile component** — it is already correctly used from `AddFriendView`, `BeaconsFeedView`, `ChatDrawerView`, `FriendRequestsView`, `NichePlacesView`, `PulseHomeView`, and `StackedClipViews`. Fix its bugs (Phase 3) in place — do not fork it or create a second profile view.

---

## Phase 1 — Camera captures/previews in the wrong (portrait) orientation

**Root cause, confirmed by reading `CameraCaptureView.swift`:** the app correctly locks the *interface* to landscape (`InterfaceOrientationLock.lockLandscape()`), but nowhere does it set `videoRotationAngle` (or the equivalent) on the `AVCaptureConnection` for either the preview layer (`AVCaptureVideoPreviewLayer`, around line 1591–1600) or the movie output (`AVCaptureMovieFileOutput`, around line 1399). AVFoundation's capture connections default to the sensor's native orientation and never automatically follow a UI-level orientation lock — so the live feed and recorded video stay portrait-oriented underneath a landscape-locked interface.

**Fix:**
- On session/connection setup, and again whenever the effective interface orientation changes, set the correct `videoRotationAngle` (iOS 17+ API — use this over the deprecated `videoOrientation`) on:
  - The preview layer's connection, so what's shown on screen is correctly oriented.
  - The movie output's connection, so recorded video is actually landscape, not portrait video inside a landscape UI.
  - Do the same for the photo output if one exists, so captured photos aren't rotated either.
- Since the app forces one fixed landscape orientation via `InterfaceOrientationLock`, the correct rotation angle can likely be a fixed constant matching that specific locked orientation (landscape-left vs. landscape-right — check which `InterfaceOrientationLock.lockLandscape()` actually forces) rather than something that needs to track live device rotation. Confirm which landscape orientation is locked and set the angle to match it exactly.
- Verify on a **physical device** if at all possible — the simulator's camera behavior for orientation bugs is not always representative.

**Acceptance:** recording a video or taking a photo in the landscape-locked camera produces landscape-oriented media that matches what was shown in the live preview — no unexpected rotation in the saved/sent result.

---

## Phase 2 — Friend requests: audit and harden, don't rebuild

**Important finding from the audit: the backend and client code for friend requests are already fully and correctly built.** `sendFriendRequest`, `acceptFriendRequest`, `declineFriendRequest`, `listRequests` (all in `functions/index.js`), the `FriendGraph` client class, `FriendRequestsView`'s `.task` refresh and pull-to-refresh, and the `onFriendRequest` push trigger (which correctly fires on the target's `incomingRequests` doc creation and calls `notify()`) are all present, correct, and consistent with each other. **Do not rewrite this pipeline.**

The push delivery chain (`PushNotifications.swift`) is also fully built: token registration on mint, re-sync after sign-in, deletion on sign-out, and the `notify()` server helper reads real device tokens from `users/{uid}/devices`. This is not a stub.

**Given all of that is correct, "they don't receive it" most likely has one of these causes — investigate in this order before writing any new code:**

1. **The Push Notifications entitlement was only just fixed** (in this very development cycle — the App ID capability and provisioning profile issues that took a long signing saga to resolve, ending in a successful TestFlight upload). Any test done before that fix would show exactly this symptom (no push arrives) even though the code is correct, because APNs delivery was structurally broken at the platform level, not the app level. **Retest with the current TestFlight build now that the entitlement is confirmed fixed.**
2. **Push permission was never granted on the recipient's test device.** `PushNotifications.shouldPrime` only shows the priming explainer once per install and only if a decision hasn't been made yet — if it was dismissed, denied, or the onboarding flow that calls `requestAuthorization()` was skipped, no token is ever registered and `notify()` silently has nothing to send to (it returns early when `tokens.length` is 0). Check Settings → Notifications → Ralli on the recipient's device to confirm permission is actually granted, and check `users/{uid}/devices` in Firestore to confirm a token document actually exists for that account.
3. **The in-app fallback (no push required) may not be prominent enough.** Even with push working, a user should be able to discover a pending request just by opening the app — check how visible the `pendingCount` badge (in `FriendHubView`, surfaced via `PulseHomeView`) actually is. If it's easy to miss, make it more prominent as a defensive measure: a `GlowDot`/badge that's genuinely hard to overlook near wherever the friend-request entry point sits on Pulse, since push permission can never be guaranteed for every user.

**Do this:** retest live with two real accounts/devices on the current build first. Only write code changes for whatever the live test actually reveals as broken (most likely nothing in the backend — possibly just the badge visibility from point 3). Do not "fix" `sendFriendRequest`, `listRequests`, or the push trigger unless the live test proves one of them is actually failing.

**Acceptance:** Account A sends a request to Account B on the current build. Confirm the Firestore write exists (`users/{B}/incomingRequests/{A}`). Confirm B either receives a push (if permission was granted) or can find the pending request within a few seconds of opening the app via the badge.

---

## Phase 3 — Follow system: three precise, surgical fixes

The Follow backend (`followUser`/`unfollowUser`, transactional `followerCount`, `FollowGraph.swift`, `listFollowing`) and most of `PublicProfileSheet`'s follow UI are **already correctly built** — follower count displays, the follow button calls the real backend, optimistic updates and rollback work. Do not rebuild any of this. Three specific things are actually broken:

### 3a. The Places clip-card Follow chip is still local-only
**Root cause, confirmed:** `NichePlacesView.swift`, in the clip attribution row, has:
```swift
AccentChip(title: isFollowing ? "Following" : "Follow", ...) {
    isFollowing.toggle()
}
```
This is a plain local `@State` toggle with no backend call at all — it never touches `FollowGraph`.

**Fix:** wire this chip to the same `FollowGraph.follow(_:)`/`unfollow(_:)` calls `PublicProfileSheet.toggleFollow()` uses (same environment object, `@Environment(FollowGraph.self)`), with the same optimistic-update-then-reconcile pattern. The chip's state must reflect `followGraph.isFollowing(uid)`, not a local toggle. **This requires a real uid for the clip's author — see 3b, since today the clip only carries a name.**

### 3b. Clips from non-friend authors can't be followed at all — no uid available
**Root cause, confirmed:** `SpotClip` (the place-clip model) only carries `authorName: String`, never an author uid. `NichePlacesView` resolves a `matchedFriend` by case-insensitive name match against the local roster; when there's no match (the author isn't already a friend), it falls back to `PublicProfileSheet(uid: "", name: clip.authorName, emoji: clip.emoji)` — an **empty uid**. Since `PublicProfileSheet.isRemote` is `!uid.isEmpty`, an empty uid means `isRemote == false`, which hides the entire `actionRow` (no Follow button, no Add Friend, no follower count) for exactly the case where following would matter most — someone you don't already know.

**Fix:** this depends on Phase 5's content-sync work giving place clips a real `authorUid` (public logs will carry one once posted through the real pipeline — see Phase 5). Once clips carry a real author uid:
- Pass the real uid into `PublicProfileSheet` instead of `uid: ""`.
- Remove or de-prioritize the name-matching fallback once uid-based lookup is available — it's a reasonable stopgap for legacy/seed data, not something new public content should depend on.
- Until Phase 5 lands, at minimum make sure the empty-uid case fails gracefully (no follow button shown, no crash) rather than silently showing a broken/non-functional Follow control.

### 3c. Two stacked filled-coral pills
**Root cause, confirmed:** in `UserProfileView.swift`, `followButton`'s not-following state uses `Capsule().fill(Theme.accentGradient)` — the exact same filled treatment `primaryButton` (used for "Add friend") uses. Stacked together, both read as equally primary.

**Fix:** in `followButton`, swap the **not-following** state from a filled `accentGradient` capsule to the **outlined** treatment (the same `Capsule().fill(Theme.accentWash).overlay(strokeBorder(Theme.accent))` style already used for the *following* state). Leave the *following* state's current outlined-with-checkmark look as-is, or, if you want an explicit "confirmed" moment, make *following* the filled state instead and *not-following* the outline — either way, **only one of Follow/Add Friend may be filled in its default state**, and that one is Add Friend (`primaryButton` stays untouched).

**Acceptance:** the Places clip-card Follow chip actually follows/unfollows via the real backend and is reflected in `FollowGraph`; `PublicProfileSheet` opened from any entry point with a real uid shows follower count and a working Follow button; the profile sheet never shows two filled coral pills at once.

---

## Phase 4 — Onboarding profile photo isn't actually synced to the server

**Root cause, confirmed:** `ProfileSetupView` already has a working photo-picker (`AvatarPhotoButton`), and on submit, if a photo was picked, it does this:
```swift
me?.avatarPhotoFileName = avatarPhotoFileName
try? modelContext.save()
```
That writes the picked photo's **local filename to the local SwiftData `Friend` row only**. It is never uploaded to Firebase Storage, and `RemoteProfile.avatarURL` (which exists server-side specifically for this) is never set. So the photo is invisible to every other user, doesn't survive a reinstall, and doesn't appear on a second device — the picker works, but the photo never actually becomes part of the account.

**Fix:**
- On submit, if a photo was picked, upload it to Firebase Storage under a path scoped to the new user's uid (follow the same convention `publishLog`'s `storagePath.startsWith('logs/${uid}/')` check uses for media — something like `avatars/{uid}/profile.jpg`).
- Get the resulting download URL and either pass it into `createProfile` (extend that callable to accept an optional `avatarURL`) or call a small follow-up callable (e.g. `setAvatarURL({ url })`) right after `createProfile` succeeds.
- Update `RemoteProfile.avatarURL` accordingly so it's returned on every future profile fetch, and confirm `PublicProfileSheet`/`GlassOrbAvatar` actually render `avatarURL` when present (falling back to the emoji avatar when it's empty, matching the existing fallback pattern).
- Also make sure the existing **edit-profile photo flow** (if `UserProfileView` lets you change your photo later, not just at onboarding) uses the same real upload path, not another local-only shortcut.

**Acceptance:** set a profile photo during onboarding on Account A, sign in as Account B, open A's profile — the real photo shows, not the emoji fallback. Confirm the same works after reinstalling the app on A's device (proves it's server-synced, not local).

---

## Phase 5 — Captured content never syncs to the server at all (the real root of "post videos publicly")

**This is the biggest, most important gap found in the audit, and it's bigger than "add a public option."** `functions/index.js` already contains a complete, well-built content-sync backend — `publishLog` (uploads a log doc with `authorUid`, media, caption, capture time, hour-bucket), `listFriendLogs` (fans out friends' recent logs), `deleteLog` — but **nothing on the client calls any of them.** There is no `FirestoreService` wrapper for `publishLog`/`listFriendLogs` at all, and nothing in `CameraCaptureView`, `PostCaptureReview`, or `SendLogView` references them. Captured clips are still 100% local `SwiftData` `Clip` objects, exactly as they were before any of this backend existed — meaning **friends don't see each other's logs today either**, let alone the public/Places case.

Also confirmed: `publishLog` hardcodes `audience: "friends"` server-side — there is currently no "public" audience option, and no way to associate a published log with a `Spot`/place at all.

Build this in two parts — part A is the prerequisite for part B:

### 5a. Wire up real friends-only sync (the existing backend)
- Add `FirestoreService.publishLog(...)` and `FirestoreService.listFriendLogs(...)` wrappers, following the existing pattern other callables use in that file.
- In the capture → review flow (`PostCaptureReview`, wherever the user currently confirms/sends a captured clip), after a successful capture: upload the media to Firebase Storage under `logs/{uid}/...` (matching what `publishLog` already validates against), then call `publishLog` with the resulting `storagePath`/`mediaURL`.
- Have Pulse pull recent friends' logs via `listFriendLogs` and merge them with local/just-captured content for instant feedback, same general approach used elsewhere in the app for optimistic UI.
- Respect existing block relationships (already handled server-side in `listFriendLogs`).

### 5b. Add the public/Places posting path (net-new)
- Extend `publishLog` to accept an `audience` field (`"friends"` | `"public"`), and when `"public"`, a target Spot reference (id, or enough info to create one — ties into Phase 6's real Spot model).
- Add a new callable (e.g. `listSpotLogs({ spotId })` or `listPublicLogs({ limit })`) that Places queries for public content, replacing the current local-only `SpotClip` seed data as the real data source once this exists.
- In the capture/review flow, add a way to choose audience — post to friends (default, matches today's behavior once 5a lands) vs. **post publicly to a place** — and when public is chosen, require picking/confirming a Spot (using Phase 6's real location search).
- Published public logs must carry a real `authorUid`, which is what unblocks Phase 3b (Follow/profile working correctly from Places clips authored by non-friends).

**Acceptance:** capturing a log and sending it to friends actually appears in a friend's Pulse feed (real cross-device test, not local-only). Posting publicly with a chosen spot makes it appear in that spot's clips on the Places tab, with a real author uid such that tapping the author opens a full profile with working Follow and an accurate follower count.

---

## Phase 6 — Beacon "Pick a spot" is empty; build real location search

**Root cause, confirmed:** `BeaconsFeedView.swift` backs the spot picker with `@Query(sort: \Spot.distanceMiles) private var spots: [Spot]` — a **local SwiftData query only**. There is no MapKit search, no `CLLocationManager`, and no Firestore-backed spot collection anywhere in the app. `Spot` is populated exclusively by `SeedData` (DEBUG-only demo data) — a real signed-in account has zero `Spot` rows, so the picker is correctly empty; there's no bug in the picker itself, the underlying data source just doesn't exist for real users.

**Fix, per the explicit request — replace the dropdown with real location search:**
- Add a location search field using `MKLocalSearchCompleter`/`MKLocalSearch` (optionally biased with `CLLocationManager` for the user's current area) — type a place name, see live suggestions.
- On selecting a suggestion, show a small MapKit map confirming the pinned location (matches the "type it and locate it on the map" request).
- Confirming a location should create-or-reuse a **Firestore-backed** `Spot` (new `spots` collection — `Spot` currently has zero backend presence) rather than a local-only SwiftData row, so a place created by one user is discoverable/shared, not trapped on one device.
- This same Firestore-backed Spot search/creation should be reused for the "pick a spot" step in Phase 5b's public-posting flow — one real Spot system serving both Beacons and Places public posts, not two separate implementations.
- Keep local `Spot`/`SpotClip` SwiftData as a cache of what's been fetched/created, same caching pattern used elsewhere in the app (Firestore as source of truth, SwiftData as local mirror).

**Acceptance:** creating a Beacon, typing a real place name shows live search suggestions, selecting one shows it pinned on a small map, confirming creates a real spot usable immediately. A second account can find/select that same spot (proves it's server-backed, not local-only).

---

## Verification (required for every phase)

- Re-confirm every item in §0 still holds — screenshot Pulse, the landscape camera, a public profile, Places, and Beacons.
- Phases 1, 4, 5, and 6 need a **physical device** and, where noted, **two real accounts** to actually prove the fix (orientation, cross-account content sync, cross-device photo sync, shared spot search). Simulator-only testing will not catch these.
- Don't mark any phase done on "the code looks right" alone — this exact standard was set because the Follow feature was reported broken twice already after being marked complete. Prove each acceptance criterion with a live test and a screenshot before moving on.
