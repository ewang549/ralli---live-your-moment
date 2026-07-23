# Build Prompt: Real Social Graph for Explog

You are working in the **explog** iOS app repo. Implement a real, server-backed social layer to replace the current local-only demo graph. Follow the existing architecture and conventions exactly. Ship in the phases below, in order. Do not skip the App Store compliance phase.

---

## Context: current state of the codebase

**Stack**
- SwiftUI + SwiftData (`@Model` classes in `explog/Models.swift`).
- Firebase Auth (email/password) — `AuthGateView.swift`. Project id `explog-723b7`, region `us-central1`.
- Firebase Cloud Functions v2, callable style (`onCall`) — `functions/index.js`. Already deploys `getStreamToken` and `joinStreamChannel`, both gated on `request.auth`. Server Stream secret is a Functions secret (`STREAM_API_SECRET`), key `msdyxmxmqf53`.
- Stream Chat (iOS SDK + server SDK) for messaging. Client connects via `StreamTokenProvider.fetchToken` after Firebase sign-in (`explogApp.swift`, `AuthGateView.swift`).
- **Firestore is NOT set up yet.** There is no `users` collection, no security rules, no persistent server data. Add it.

**Key files**
- `explog/Models.swift` — SwiftData models: `Friend` (aliased `UserProfile`), `Chat`, `Clip`, `Message`, `Spot`, `SpotClip`, `Beacon`.
- `explog/SeedData.swift` — seeds fake friends/chats/clips on first launch. This is demo-only data.
- `explog/AuthGateView.swift` — sign up / log in, then `connectStream`.
- `explog/StreamTokenProvider.swift` — pattern for calling callable Cloud Functions from Swift (build the URLRequest, `Bearer <idToken>`, `{"data": {...}}` body, decode `{"result": ...}`). **Reuse this exact pattern for every new callable.**
- `explog/UserProfileView.swift` — renders only the current user (`friends.first { $0.isMe }`). No concept of viewing another user.
- `functions/index.js` — add new callables here.

**The core problem**
`Friend` objects are seeded locally and never leave the device. Two real accounts cannot discover or reach each other. Everything below fixes that. All new persistent, cross-user state lives in **Firestore**; ephemeral chat stays in **Stream**; local caches stay in **SwiftData**.

**Design decision (default — keep unless told otherwise): mutual friends, Snap-style.** A friendship requires a request and an accept. Not a follow model. Data model and UI below assume this.

---

## Global conventions to follow

- Every new server call is a **callable Cloud Function** in `functions/index.js`, authed via `request.auth`, mirrored by a Swift method that copies the `StreamTokenProvider` URLRequest pattern. Do not call Firestore directly from the client for writes that need validation (friend requests, handle claims) — go through Functions so rules stay simple and abuse is controlled.
- Keep the existing dark theme (`Theme.swift`) and visual language. New screens must match the existing rounded, dark aesthetic.
- Add a thin `FirestoreService` (Swift) and use `firebase-admin` Firestore in Functions.
- Write Firestore **security rules** for every collection. Default deny.
- Keep `SeedData` behind a DEBUG flag so demo data never ships to real users. Real accounts start with an empty graph.
- Add unit/UI test hooks consistent with the existing `EXPLOG_AUTO_*` env-var pattern in `AuthGateView`/`MainTabView`.

---

## Visual style — "Liquid Glass" (applies to every new screen)

All new UI must match this aesthetic. This describes the **style/material language only** — not layout, spacing, or where buttons go. Keep the existing `Theme.swift` tokens as the base and extend them; do not restyle existing screens unless asked.

- **Base:** deep near-black background with a subtle warm undertone (charcoal, not pure black), low-key and moody so glass and glow read clearly. Prefer a very dark vertical gradient over a flat fill.
- **Liquid glass surfaces:** cards, sheets, bars, and containers are **translucent frosted glass** — real background blur (`.ultraThinMaterial` / `.regularMaterial`, or iOS 26 Liquid Glass effects where available), not flat opaque panels. Each glass surface has a soft inner sheen, a faint bright top edge (specular highlight), and a thin darker bottom edge so it reads as a physical pane of glass catching light. Gentle, soft shadows underneath for float/depth.
- **Glossy 3D orbs:** avatars and status/story rings render as **glassy spheres** — a rounded, dimensional bubble with a bright specular hotspot near the top-left, a smooth glass falloff, and a thin luminous rim. Think polished liquid-glass marble, not a flat circle crop.
- **Warm gold accent + glow:** the accent is a warm amber/gold. Active states (unread, live, "now") are small **glowing gold orbs** with a soft bloom/halo around them, as if lit from within. Use glow sparingly as the one source of warmth against the cool dark glass.
- **Wordmark/type:** the "Explog" wordmark uses an elegant serif with a **metallic gold sheen/gradient**. Body text stays clean and legible (keep current font choices); primary text near-white, secondary text muted grey — never pure white on pure black.
- **Materials & finish:** everything feels wet/polished — soft highlights, gentle gradients, rounded generous corners, subtle depth layering (foreground glass floats above background glass). Avoid hard flat fills, harsh borders, high-contrast slabs, or opaque solid cards.
- **Motion (where cheap):** light refractive/parallax feel — glass can subtly brighten on press, glows can breathe slowly. Keep it tasteful, never busy.
- **Do NOT** copy the mockup's specific layout, tab arrangement, or button placement — only its material and lighting language. Reuse Explog's existing information architecture.

Add reusable SwiftUI components for this: a `GlassCard` container, a `GlassBar`, a `GlowDot`, and a `GlassOrbAvatar`, all driven by extended `Theme` tokens (glass tint, rim highlight, gold accent, glow color). Every new screen composes these rather than restyling ad hoc.

---

## Phase 1 — User directory + handles (foundation)

**Goal:** every account has a Firestore profile and a unique `@handle`. This unblocks search, add-by-code, and viewing others.

**Firestore**
- `users/{uid}`: `{ uid, handle (lowercased, unique), handleDisplay, name, avatarEmoji, city, bio, createdAt, referredBy?, friendCode }`.
- `handles/{handle}`: `{ uid }` — a claim doc that enforces uniqueness (create is only allowed if it doesn't exist).
- `friendCode`: short unique code (e.g. 6 chars, unambiguous alphabet, no 0/O/1/I) generated at signup. Used for add-by-code and ambassador attribution.

**Cloud Functions**
- `createProfile({ handle, name, avatarEmoji, city })` — called right after Firebase signup. Validates handle format (`^[a-z0-9_]{3,20}$`), atomically claims `handles/{handle}` in a transaction (fail with `already-exists` if taken), generates a unique `friendCode`, writes `users/{uid}`. Idempotent if profile already exists.
- `checkHandleAvailable({ handle })` → `{ available: bool }` for live signup validation.
- `setFriendCode` not needed — generated server-side.

**Swift**
- New onboarding step after signup (before `MainTabView`): pick handle (live availability check), confirm name/avatar/city. Only proceed once `createProfile` succeeds.
- `FirestoreService.currentProfile()` loads `users/{uid}`; cache into the local `Friend` marked `isMe`.
- Extend `Friend` model with `handle: String`, `friendCode: String`, `remoteUID: String` (Firebase uid; today `Friend` has only a local `UUID`). Add `remoteUID` so local `Friend` rows map to real accounts.

**Security rules:** `users/{uid}` readable by any signed-in user (needed for profiles/search), writable only via Functions (client writes denied except maybe self bio/avatar). `handles/*` no client writes.

**Acceptance:** two fresh accounts each get a `users` doc with a unique handle and friendCode; duplicate handle is rejected; signup is blocked until a valid profile exists.

---

## Phase 2 — Adding friends (search, code/QR, contacts, suggestions)

**Firestore**
- `users/{uid}/friends/{friendUid}`: `{ since }` — an accepted friendship edge (written on both sides). Source of truth for "who are my friends."

**Cloud Functions**
- `searchUsers({ query })` — prefix match on `handle` (and optionally name). Return public fields only (uid, handle, name, avatarEmoji, city). Exclude self and existing friends; annotate request state (none/pending/friends).
- `resolveFriendCode({ code })` → the matching user's public profile (for add-by-code and QR).

**Swift — "Add friends" screen** (entry point: a person-badge-plus button on Profile and/or Pulse):
- **Search by @handle** — live results, each row has an Add button.
- **Add by code** — text field to type a `friendCode`; **QR** — show my code as a QR (encode `explog://add?code=XXXXXX`) and a scanner to read someone else's. Use AVFoundation for scan; a QR lib or `CIQRCodeGenerator` for display.
- **Invite from contacts** — request Contacts permission, hash emails/phones, match against `users` (store a hashed `emailHash`/`phoneHash` on the profile for matching; never upload raw contacts). Unmatched contacts get an invite share sheet with a referral deep link.
- **Suggested** ("people you may know") — v1 can be same-city or friends-of-friends; keep simple.

**Deep link / attribution:** register `explog://add?code=XXXXXX` and a universal link. When opened, prefill the add flow and record `referredBy` if the user is brand new — **this is the ambassador attribution hook.**

**Acceptance:** from account A I can find account B by handle, by code, and by QR, and send a request.

---

## Phase 3 — Friend requests (pending/accepted + inbox)

**Firestore**
- `users/{uid}/incomingRequests/{fromUid}`: `{ fromUid, at }`.
- `users/{uid}/outgoingRequests/{toUid}`: `{ toUid, at }`.

**Cloud Functions** (all authed, all validate the relationship state):
- `sendFriendRequest({ toUid })` — writes incoming (on target) + outgoing (on self); no-op if already friends or already pending; blocks if either side has blocked the other.
- `acceptFriendRequest({ fromUid })` — transaction: create both friend edges, delete both request docs, (optionally) create the Stream DM channel via the existing server client.
- `declineFriendRequest({ fromUid })` / `cancelFriendRequest({ toUid })` — clean up request docs.
- `removeFriend({ friendUid })` — delete both edges.

**Swift**
- **Requests inbox** (badge count on Profile/tab): incoming list with Accept/Decline, outgoing list with Cancel.
- Friend list view backed by `users/{uid}/friends`, replacing the seeded roster for real accounts.
- On accept, ensure a Stream DM channel exists (reuse `joinStreamChannel`).

**Acceptance:** full lifecycle works across two devices/simulators: send → appears in target's inbox → accept → both see each other as friends → chat channel exists.

---

## Phase 4 — View other people's profiles

**Swift**
- Refactor `UserProfileView` so the current-user editable form is one mode and a **read-only `PublicProfileView(uid:)`** is another. Today it hard-codes `friends.first { $0.isMe }`.
- `PublicProfileView` loads `users/{uid}` from Firestore, shows avatar/handle/name/city/bio, mutual-friend count, and a context-appropriate action button (Add / Requested / Friends / Message / Block).
- Make avatars/names tappable everywhere (Pulse, Beacons, chat headers, search results) → push `PublicProfileView`.
- Respect privacy: the existing `isPrivate` flag hides feed content; a private profile shows only minimal info to non-friends.

**Acceptance:** tapping any user anywhere opens their profile; my own profile stays editable; private accounts are limited to non-friends.

---

## Phase 5 — Push notifications (APNs + FCM)

**Goal:** re-engagement. This is existential for an hourly-log app.

- Add the Push Notifications + Background Modes capabilities; wire **Firebase Cloud Messaging**. Register for APNs, store the FCM token at `users/{uid}/devices/{token}`.
- Request notification permission during onboarding (prime it — explain value first, then trigger the system prompt).
- **Cloud Functions triggers** (Firestore-triggered, v2):
  - New incoming friend request → "X wants to be friends."
  - Friend request accepted → "You and X are now friends."
  - New Stream message → use Stream's webhook/push or a function to notify recipients ("X sent you a log/message").
  - **Streak about to break** — scheduled function checking `Chat.lastSentAt`/streak state; notify before the window closes.
- Deep-link each notification to the right screen.

**Acceptance:** all four notification types fire on a physical device and deep-link correctly.

---

## Phase 6 — Real content sync

**Goal:** posts actually reach friends. Today clips/beacons/messages are local SwiftData + seed only.

- Decide storage: **Firebase Storage** for media (clips/photos), **Firestore** for post metadata + beacons; keep chat in Stream.
- On capture (`CameraCaptureView`), upload the asset to Storage and write a post doc scoped to the author + audience (friends). Feeds (`PulseFeedView`, `BeaconsFeedView`) query friends' recent posts instead of seed data.
- Beacons become real Firestore docs with server-side RSVP; keep the `isPublic` gating and the private-profile guards.
- Migrate `SeedData` to DEBUG-only. Real users get an empty-state UI ("add friends to see their logs") instead of fake content.
- Handle offline: keep SwiftData as a local cache; sync up/down.

**Acceptance:** a clip posted on account A appears in account B's Pulse feed (B is A's friend); public beacons appear to eligible users.

---

## Phase 7 — App Store compliance (REQUIRED — do not ship without this)

Apple rejects UGC social apps missing these (Guidelines 1.2 and 5.1.1(v)).

- **Block & report**
  - `blockUser({ uid })` / `unblockUser`, stored at `users/{uid}/blocked/{blockedUid}`. Blocking removes friendship, cancels requests, hides all content both ways, and prevents new requests/messages. Enforce in search, feeds, requests, and Stream (mute/ban on the channel).
  - `reportUser` / `reportContent({ targetId, reason })` → writes to a `reports` collection an admin can review; provide a contact method.
- **In-app account deletion** — a Delete Account action in Profile that deletes the Firebase Auth user, the Firestore profile + subcollections + handle claim, the Stream user, and Storage media (Cloud Function doing the cascade). Also add a plain **Sign out** (currently missing).
- **Content moderation** — a filter for objectionable content (at minimum profanity filter + report-driven takedown), a published way to contact you about reports, and an EULA with zero-tolerance terms (Apple requires this exact language for UGC).

**Acceptance:** block/report reachable from every user and content surface; account deletion fully cascades; sign-out works.

---

## Phase 8 — Engagement layer (polish)

- **Onboarding flow**: profile setup (Phase 1) → find-your-friends (Phase 2) → notification priming (Phase 5), as a first-run sequence.
- **Search**: users by handle/name; extend to places if useful.
- **Stream niceties**: surface presence/online status, typing indicators, and read receipts — the Stream SDK already provides these; just display them in the chat views (`ChatDrawerView`, `StreamThreadView`).
- **Invite / deep links**: "Join me on Explog" share sheet using the referral deep link from Phase 2 — the ambassador loop.

---

## Deliverables & checkpoints

For each phase: Firestore schema + rules, Cloud Functions (with input validation and abuse guards), Swift service + screens matching the existing theme, and the acceptance test. Commit per phase. After Phase 1–3 the graph is functional; after Phase 7 it's shippable.

Start with **Phase 1** and confirm the `users` collection, handle uniqueness, and onboarding step work end-to-end before moving on.
