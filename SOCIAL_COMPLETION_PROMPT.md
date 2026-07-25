# Build Prompt: Complete Ralli's social layer (without breaking what works)

The UI is ahead of the backend. This prompt fills the missing social plumbing — real friendships, content sync, push, safety, account deletion — and hardens a few gaps. Work in the phase order below. **The most important rule: do not regress anything already working.**

Follow `RALLI_DESIGN_SYSTEM.md` (coral accent, warm neutrals, soft glass). Backend follows the existing pattern: callable Cloud Functions in `functions/index.js` (authed via `request.auth`), mirrored by Swift methods in `FirestoreService.swift` that copy the existing `call(...)` pattern. Every new Firestore collection needs security rules. Verify on the simulator with screenshots after each phase.

---

## 0. DO NOT BREAK — protected, already-working behavior

Before changing anything, treat these as invariants. If a change would alter them, find another way. Re-verify each after your work:

- **Coral theme.** The app accent is coral (`Theme.accent`). Do not reintroduce blue/iris/purple/gold. New UI uses `Theme.accent`, never a hardcoded color.
- **Landscape camera.** `CameraCaptureView` works in landscape with the shutter on the right, full-bleed preview, centered mode selector, flip/flash/gallery/timer, and the creative tools. Don't disturb its layout or orientation handling.
- **Per-row message icon on Pulse.** Every Pulse row has a right-aligned message button that opens *that* conversation directly. This must remain on every row, always.
- **Hourly countdown on Pulse.** The "next log in mm:ss" countdown stays and keeps working.
- **Logout no longer crashes.** `AuthGateView.session.onChange` flips `stage` away from data-bound views *before* `LocalStore.claim`/`wipe` runs (deferred a runloop). Keep this ordering — reintroducing an early wipe brings back the `Friend.interests` detached-context crash. Any new logout/delete path must follow the same "unmount data views, then touch the store" ordering.
- **Per-account cache scoping.** `LocalStore.claim/wipe` scopes the SwiftData cache to the signed-in uid so accounts never inherit each other's data, and seed/demo data never reaches a real account. Preserve this. New synced data must also be wiped on account change.
- **Consistent wordmark.** `RalliWordmark` renders at the same size/position across tabs. Don't fork it.
- **Auth resolution.** `AuthSession.isResolved` gating (don't treat a cold-start `nil` as signed-out) must stay intact.

When done, re-screenshot Pulse (message icons + countdown), the landscape camera, Beacons, and Profile to confirm none of the above changed.

---

## Phase 1 — Real friendships (highest priority)

Today `AddFriendView` can look a user up by handle/code but there is **no way to actually add them** — no request, no accept, no stored friendship. Build the full lifecycle.

**Firestore**
- `users/{uid}/friends/{friendUid}`: `{ since }` — accepted edge, written on both sides.
- `users/{uid}/incomingRequests/{fromUid}`: `{ at }`
- `users/{uid}/outgoingRequests/{toUid}`: `{ at }`

**Cloud Functions** (authed; validate state; block if either side has blocked the other):
- `sendFriendRequest({ toUid })` — writes incoming (target) + outgoing (self); no-op if already friends/pending.
- `acceptFriendRequest({ fromUid })` — transaction: create both friend edges, delete both request docs, then ensure a Stream DM channel exists (reuse the server client / `joinStreamChannel` path).
- `declineFriendRequest({ fromUid })` / `cancelFriendRequest({ toUid })` / `removeFriend({ friendUid })`.
- `listFriends` / `listRequests` (or client reads with rules allowing the owner to read their own subcollections).

**Swift (`FirestoreService` + UI)**
- Add matching methods following the existing `call(...)` pattern.
- `AddFriendView`: add an **Add** button on the result card that calls `sendFriendRequest`, with states (Add → Requested → Friends). This is the missing piece.
- Add a **requests inbox** (incoming: Accept/Decline; outgoing: Cancel), reachable from Pulse (a badge near the add-friend control).
- Back the friend list / Pulse roster from real friend edges for real accounts (demo roster stays DEBUG-only).
- On accept, ensure the Stream DM channel exists so the existing per-row message button works immediately.

**Rules:** owner can read their own `friends`/`incomingRequests`/`outgoingRequests`; all writes go through Functions.

**Acceptance:** from account A, find B, tap Add → B sees it in their inbox → accept → both are friends → the per-row message button opens a working DM. No regressions from §0.

---

## Phase 2 — Content sync (so friends actually see each other's logs)

Clips are local-only (`clip.assetURL` is on-device). Nothing reaches other users. Make logs sync.

- **Storage:** upload captured photo/video to **Firebase Storage** under the author's uid; store returned URL.
- **Firestore:** write a post/log doc (`logs/{id}` or `users/{uid}/logs/{id}`) with author uid, media URL, caption, hour/timestamp, audience (friends).
- **Feeds:** `PulseFeedView` / `PulseHomeView` show friends' recent logs from the server (merged with the local just-captured one for instant feedback). Keep SwiftData as a local cache; sync down.
- Respect the hourly model and existing `HourFeedState`.
- Keep demo/seed data DEBUG-only; real accounts get a warm empty state until friends post.
- New synced rows must be covered by `LocalStore.wipe` on account change.

**Acceptance:** a log posted on A appears in B's Pulse feed (B is A's friend); offline still shows cached content; account switch clears it.

---

## Phase 3 — Push notifications

FirebaseMessaging initializes but nothing is wired.

- Add Push + Background Modes capabilities; register for APNs; save the **FCM token** to `users/{uid}/devices/{token}`. Remove stale tokens on logout.
- Prime the notification permission during onboarding (explain value, then request).
- **Firestore-triggered functions:** new incoming friend request; request accepted; new Stream message (via Stream push/webhook) → "X sent you a log/message"; **streak about to break** (scheduled) using existing streak state.
- Deep-link each notification to the right screen (thread, requests inbox, capture).

**Acceptance:** all four notification types fire on a physical device and deep-link correctly; token cleared on logout.

---

## Phase 4 — Block & report (App Store required — Guideline 1.2)

- `blockUser({ uid })` / `unblockUser` at `users/{uid}/blocked/{blockedUid}`. Blocking removes friendship, cancels requests, hides content both ways, prevents new requests/messages, and mutes/bans on the Stream channel.
- `reportUser` / `reportContent({ targetId, reason })` → `reports` collection for review; provide a contact method.
- Enforce blocks in search (`lookupUser`), friend requests, feeds, and chat.
- UI: Block/Report reachable from a user's profile and from a message/log (long-press or overflow).

**Acceptance:** block/report reachable everywhere a user or their content appears; blocked users disappear from search, feed, requests, and chat.

---

## Phase 5 — In-app account deletion (App Store required — Guideline 5.1.1(v))

- A **Delete account** action in Profile (below Log out) with a confirm step.
- `deleteAccount` Cloud Function cascades: Firebase Auth user, `users/{uid}` + all subcollections + handle/friendCode claims, Stream user, and Storage media.
- Client: after the cascade, sign out and return to Welcome. **Use the same safe ordering as logout** (§0) — unmount data views before wiping the local store — so deletion doesn't reintroduce the detached-context crash.

**Acceptance:** deleting an account removes it everywhere and lands cleanly on Welcome with no crash.

---

## Phase 6 — Fuller profiles + discovery + chat niceties

- **Public profile view:** from search results and anywhere an avatar appears, open a profile showing handle/name/city/bio/mutuals with a context action (Add / Requested / Friends / Message / Block). Extend the existing `PublicProfileSheet` rather than forking it.
- **Discovery:** improve `lookupUser` to also match names (prefix), and add a lightweight "people you may know" (same city / friends-of-friends). Optional: contacts matching via hashed email/phone (never upload raw contacts).
- **Stream niceties:** surface presence (online dot), typing indicators, and read receipts in `ChatDrawerView` / `StreamThreadView` — the SDK already provides them; display them. Don't alter the per-row message entry point.

**Acceptance:** tapping any user opens a profile with the right action; search finds people by handle and name; chat shows presence/typing/read state.

---

## Verification (every phase)

- Backend: each callable authed, input-validated, abuse-guarded; every new collection has default-deny rules with server-only writes where validation matters.
- Client: matches `RALLI_DESIGN_SYSTEM.md`, coral only, no blue.
- **Regression pass (required):** after each phase, build to the simulator and confirm §0 invariants still hold — screenshot Pulse (per-row message icons + hourly countdown), the landscape camera, Beacons, and Profile, and confirm logout still doesn't crash. Save screenshots. Do not mark a phase done if any protected behavior changed.
