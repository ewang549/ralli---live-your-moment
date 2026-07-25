# Build Prompt: Four targeted fixes (Pulse glitch, Profile photo, Follow system, Camera buttons)

You will not be shown screenshots for this task — everything you need is described in text below. Work through these four items **only**. Do not touch, restyle, or refactor anything else in the app. Follow `RALLI_DESIGN_SYSTEM.md` (coral accent, warm neutrals, soft glass) for any new UI. Verify each fix on the simulator with a screenshot before marking it done.

---

## 1. Fix the duplicated avatar-stack glitch on group chat rows (Pulse)

**Bug:** On the Pulse feed (`PulseFeedView` / `PulseHomeView`), any **group chat row** (e.g. "the crew") renders its overlapping-avatar-stack **twice, side by side**, before the chat name text. A 1-on-1 row (e.g. "Jordan") correctly shows a single circular avatar — only group rows are affected. Visually it looks like two identical clusters of overlapping member avatars sitting next to each other, then the group name/streak/preview text starts after both.

**Fix:** Find wherever the row builds its leading avatar view for a `Chat` with `isGroup == true` — it is very likely rendering the avatar-stack component **twice** in the row's HStack (e.g. once directly and once again inside a container/background view that also draws it, or a duplicate view modifier/duplicate call left in from a previous edit). Remove the duplicate so exactly **one** overlapping-avatar-stack renders per group row, matching the visual weight of a single avatar on 1-on-1 rows. Do not change the avatar-stack component's own visual design (overlap style, sizing) — only remove the duplicate render call.

**Acceptance:** every group chat row on Pulse (e.g. "the crew") shows exactly one avatar cluster before the name/text, with no repeated/doubled graphic. 1-on-1 rows are unaffected.

---

## 2. Center the profile photo and remove the emoji avatar picker

**Current state:** `UserProfileView`'s photo section shows the user's profile photo on the **left** (circular, with a small coral camera badge for editing) followed by a **horizontal scrollable strip of emoji options** to its right (a picker of ~10 emoji avatars, one highlighted as "selected").

**Why this needs to change:** Ralli now uses **real profile photos only** — the emoji-avatar system is legacy and no longer applies. Remove the emoji picker entirely.

**Fix:**
- Delete the horizontal emoji-picker strip (the `ScrollView` of emoji option buttons) from the profile photo section.
- **Center the profile photo** on the screen horizontally, larger than its current size (it no longer needs to share the row with the picker — give it real presence, e.g. ~100–120pt).
- Keep the small coral camera/edit badge in the bottom-right corner of the photo circle — tapping it should open the photo picker to change the profile photo (wire this to the actual image picker / upload flow if not already connected; if a photo upload pipeline doesn't exist yet, use Firebase Storage following the same pattern as other backend calls in `FirestoreService.swift`, uploading to a path scoped to the user's uid and storing the resulting URL on their profile).
- Remove the `emoji` / `avatarEmoji` selection UI from this screen. (Do not delete the underlying `Friend.emoji` model field if other parts of the app still reference it for seed/demo data — just stop exposing the picker in this UI. If `avatarEmoji` is still used as a fallback display when no photo is set, that's fine to keep as a fallback, just not as a user-facing picker here.)

**Acceptance:** Profile screen shows one large, centered profile photo with an edit badge; no emoji picker strip anywhere on the screen.

---

## 3. Add Follow to public profiles, with a follower counter and a Following tab under Places

**Current state:** Tapping into someone's public profile (the sheet shown for e.g. beacon attendees — `PublicProfileSheet` or equivalent) shows their avatar, name, and a "Highlights" section with their clips. There is no way to follow them, no follower count, and nothing surfaces their content elsewhere.

**This is a new lightweight "Follow" relationship, separate from the existing mutual friend system.** Following is one-directional and doesn't require acceptance — think Instagram/Twitter follow, not a friend request. Build it as follows.

### Backend (Firestore + Cloud Functions, following the existing pattern in `functions/index.js` and `FirestoreService.swift`)
- `users/{uid}/followers/{followerUid}`: `{ since }`
- `users/{uid}/following/{followingUid}`: `{ since }`
- Add a `followerCount` (and optionally `followingCount`) field on the `users/{uid}` document, maintained via a counter increment/decrement inside the follow/unfollow transaction (not a client-side read-count-and-write, to avoid race conditions).
- Callable: `followUser({ uid })` — authed, writes both sides (`following` on self, `followers` on target) in a transaction, increments `followerCount` on the target. No-op if already following. Block if either side has blocked the other (respect the existing block system if built; otherwise just guard against following yourself).
- Callable: `unfollowUser({ uid })` — removes both sides, decrements `followerCount`.
- Extend the public-profile fetch (`FirestoreService.profile(uid:)` or equivalent) to also return `followerCount` and whether the current user is following this profile, so the UI can render the right button state without an extra round trip.
- Firestore rules: owner can read their own `followers`/`following` subcollections; both subcollections are otherwise write-protected (writes only via the callables).

### UI — Public profile sheet
- Add a **follower count** near the name (e.g. "128 followers"), pulling from `followerCount`.
- Add a **Follow / Following button**: coral filled pill reading "Follow" when not following; when tapped, calls `followUser` and flips to an outlined "Following" state (tap again to `unfollowUser`). Optimistic UI update with rollback on failure, consistent with how other actions in the app handle async state.
- Keep the existing avatar, name, and Highlights section unchanged in position — just add the follower count + Follow button near the top (below name, above or beside Highlights).

### UI — Places tab gets a "Following" tab
- Add a **Following** tab/segment to `NichePlacesView` (alongside however Places currently segments content — e.g. add it as a new top-level filter/tab).
- This tab shows a feed built from the **Highlights of everyone the current user follows** — pull each followed user's highlight clips (same data source as what renders in their public-profile "Highlights" section) and compose them into a scrollable feed, newest first.
- Empty state if following nobody yet: friendly prompt, e.g. "Follow people to see their highlights here," with no crash/blank screen.

**Acceptance:** From any public profile, you can follow/unfollow with a live follower count; followed users' Highlights appear in the new Following tab under Places; unfollowing removes their content from that tab.

---

## 4. Clean up the camera's buttons (landscape only) — do NOT touch the camera view itself

**Scope is narrow: only the button/control styling and layout on the camera screen (`CameraCaptureView`), in **landscape orientation only** (this screen is landscape-only, as established). Do not change the camera preview area, the "no camera / vibe clip" placeholder, capture logic, or any of the existing creative features (filters, modes, timer duration, etc.) — restyle and clean up the chrome around them only.

Current landscape layout has these specific problems to fix:

- **A stray, unintentional floating rounded-square outline** appears near the top-center of the screen, overlapping the "6 PM" placeholder text. This is a visual glitch/orphaned element with no label or function — remove it entirely.
- **The duration/mode pill (e.g. "5s" with a video-camera icon) in the top-right is clipped/cut off at the screen edge** — it's rendering partially outside the safe area near the device bezel. Move it fully inside the safe area with proper padding so it's never clipped.
- **The bottom mode selector (Boomerang / Photo / Video) is off-center and also clipped at the right edge**, running past the visible screen boundary. **Center it properly** on screen as a clean, fully-visible pill, matching how it should look centered per the earlier camera design work.
- **General button cleanup, Snapchat-style:** the top-row icons (grid, timer, effects/lens) and the right-side stack (flip camera, flash, gallery thumbnail) should be **smaller, more tightly and evenly spaced, and visually quieter** than they currently are — clean small glass circles that frame the preview rather than compete with it. The shutter button remains the one visually prominent element.
- Keep everything coral-accented, soft glass, consistent radii, per the design system. No stray elements, nothing clipped by the screen edge, nothing overlapping text or other controls.

**Acceptance:** Landscape camera screen has no stray floating elements, no controls clipped at the screen edge, a centered bottom mode selector, and cleaner/smaller/evenly-spaced top and side buttons — while the camera preview area, placeholder, and all existing capture functionality are completely unchanged.

---

## Constraints (apply to all four)

- Change only what's described above. Do not restyle, refactor, or "improve" any other screen, component, or file while working on these.
- Reuse existing patterns: `Theme.accent` (coral) for all styling, the existing callable-function + `FirestoreService` pattern for backend work, `GlassKit` components for any new glass surfaces.
- Since no screenshots were provided to you for this task, **you must build to the simulator and screenshot each of the four fixes yourself** to verify before calling anything done: Pulse (group row + 1-on-1 row for comparison), Profile (centered photo, no emoji strip), a public profile sheet (follower count + Follow button) plus the new Following tab under Places, and the landscape camera screen (no clipping, no stray element, centered bottom pill).
