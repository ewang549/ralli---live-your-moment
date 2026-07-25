# Build Prompt: Fix the Follow system end-to-end

The Follow feature was built in a prior pass but isn't working correctly. Two confirmed bugs, plus a styling fix and a hard requirement on what a public profile must always show. Fix root causes, don't patch symptoms — start by reading the existing implementation before changing anything.

---

## 0. First, audit what's actually there

Before fixing anything, locate and read:
- The follow backend in `functions/index.js` (`followUser`, `unfollowUser` callables, the `followers`/`following` subcollections, and however `followerCount` is being maintained — should be a transaction, not a client-side read-count-write).
- The client-side calls in `FirestoreService.swift` that hit those callables.
- Every place in the app that renders a Follow control or a public profile: the clip-card Follow chip in `NichePlacesView.swift` (around the follow chip flagged earlier, line ~281), the public profile sheet, and any other entry point into someone's profile (Beacon attendees, chat headers, search results, etc.).

Confirm whether the backend callables actually work when called directly (test with two accounts) before assuming the bug is server-side — given the symptoms described below, this is very likely a **client-side wiring gap**, not a broken backend.

---

## 1. Fix: following someone on the Places feed doesn't add them to Following

**Bug:** the Follow chip on Places clip cards (`NichePlacesView.swift:281`) is still backed by **local `@State`** — tapping it toggles local UI only and never calls the real follow backend. So the person never actually gets followed: no Firestore write happens, `followerCount` never increments, and they correctly don't show up in the Following tab, because nothing was ever persisted.

**Fix:** replace the local `@State` toggle with a real call to the same `followUser`/`unfollowUser` path used elsewhere (or should be used elsewhere — see §3). On tap:
- Call `followUser(uid:)` (or `unfollowUser` if already following) through `FirestoreService`, same pattern as other async actions in the app (optimistic UI update, rollback on failure).
- The chip's visual state must be driven by the **real "am I following this person" value**, not a local toggle that resets/forgets on next launch or is disconnected from truth.
- After a successful follow from this chip, the person's Highlights must appear in the Places → **Following** tab (built in the prior pass) — if that tab isn't pulling live from the `following` subcollection, fix that data source too.

**Acceptance:** follow someone from a Places clip card → open Places → Following tab → they appear. Unfollow → they disappear. Force-quit and relaunch → the chip still correctly shows "following" (proves it's reading real state, not local memory).

---

## 2. Fix: public profiles don't show a follower count

**Bug:** opening someone's profile doesn't display their follower count at all (or it's not reliable).

**Fix:** audit the profile-fetch path (`FirestoreService.profile(uid:)` or equivalent) — confirm it actually returns `followerCount` (and `isFollowing` for the current viewer) in its response, and confirm the profile UI actually binds to and renders that value. This may be a fetch-shape bug (field not included in the returned object) or a UI bug (field fetched but never displayed) — check both. If `followerCount` isn't being maintained correctly server-side either (e.g. the increment/decrement transaction from §0 isn't wired into both `followUser` and `unfollowUser`), fix that too.

**Acceptance:** every public profile shows an accurate, live follower count near the name (e.g. "128 followers"), correct immediately after a follow/unfollow (optimistic update) and correct again after a fresh fetch.

---

## 3. Requirement: a public profile must always show Highlights AND follower count, from every entry point

There should be **one** reusable public-profile view used everywhere a profile can be opened from (Places, Beacons attendees, search, chat, etc.) — not several different implementations that render inconsistently. Audit for duplicate/divergent profile sheet code; consolidate onto one component if there are multiple.

That single view must always render, regardless of entry point:
- Avatar/photo, name.
- **Follower count** (from §2).
- **Follow / Following button** (styling fixed in §4).
- **Highlights** — the user's public clips, same data source used elsewhere for their highlights. If the profile is private (`isPrivate == true`), keep the existing privacy behavior (hide highlights/details from non-friends) — the follower count and Follow button can still show, but respect the existing private-profile guard for content.

**Acceptance:** opening a profile from Places, from a Beacon, and from anywhere else all show the same layout with follower count and Highlights present and correct.

---

## 4. Styling fix: don't stack two filled coral pills

Currently the profile sheet shows **both** Follow and Add Friend as filled coral pills stacked together — too heavy, and conflicts with the design system's "one primary coral action per screen" rule.

**Fix:**
- **Add Friend stays the primary coral-filled pill** (it's the more consequential action — mutual friendship unlocks messaging and the real social graph).
- **Follow becomes a coral-outlined pill by default** (not filled) when the current user isn't following yet.
- Once the user **is** following, Follow can switch to a filled/confirmed coral state (same pattern as Beacons' "Going" button flipping to filled once confirmed) — the point is only that in the default, untapped state, just one pill (Add Friend) carries full coral weight.

**Acceptance:** on a profile where you're not yet following and haven't sent a friend request, Add Friend is the bold filled pill and Follow is a quieter coral outline. After following, Follow's pill fills in to confirm the state.

---

## Verification (end-to-end, required)

Using two test accounts:
1. Account A follows Account B from a **Places clip card** → confirm a real Firestore write happened (check `users/{B}/followers/{A}` and `users/{A}/following/{B}` exist).
2. Account A opens Places → Following tab → B's Highlights appear.
3. Account A opens B's profile from a **different entry point** (e.g. search or a Beacon) → same follower count, same Highlights, Follow shows correctly as active/filled.
4. Account A unfollows from the profile sheet → B disappears from Following tab, follower count decrements everywhere.
5. Screenshot the profile sheet showing both the outlined-vs-filled pill states (before and after following) and the Following tab with content in it. Don't mark this done without those screenshots and the two-account test above — this exact feature was reported broken twice already, so verify it actually works this time rather than trusting that the code looks right.
