# Build Prompt: Open Fixes for Explog

You are working in the **explog** iOS app repo (SwiftUI + SwiftData, Firebase Auth + Cloud Functions v2 in `functions/index.js`, Stream Chat, project `explog-723b7` / `us-central1`). A prior session landed the Phase 1 social graph and a Liquid Glass component kit. The items below are outstanding. Do them in order — #1 (security rotation) is urgent, #2 (UI) is the visible regression the user cares about most.

---

## 1. Rotate the leaked Stream secret (URGENT — security)

**Why:** `StreamConfig.userToken` previously held a long-lived Stream user JWT for `ethan` with **no `exp` claim**. It was committed at `c5b1ecc` and the signing secret sits in `.stream/creds.yaml`. Setting the token to empty (already done) stops *future* exposure but does **not** revoke the leaked token — it's valid forever until the signing secret changes. Treat the token and secret as compromised.

**Runbook (do in this order so you don't lock out live users):**
1. Rotate `STREAM_API_SECRET` in the Stream dashboard (generate a new secret).
2. `firebase functions:secrets:set STREAM_API_SECRET` → paste the new secret.
3. Update local `.stream/creds.yaml` to the new secret (this file is gitignored — keep it that way).
4. `firebase deploy --only functions` so `getStreamToken` / `joinStreamChannel` sign with the new secret.
5. Verify: run `functions/test-stream.js` (reads the secret from `.stream/creds.yaml`) and confirm a signed-in launch still connects to Stream.

**Blast radius:** rotation invalidates all tokens signed with the old secret, but `getStreamToken` re-mints on every launch, so live users get a fresh token on next foreground. No user-visible breakage expected. Confirm after deploy.

**Also:** scrub the token from git history. Nothing is pushed yet, so amend (if `c5b1ecc` is HEAD) or `git rebase -i` to strip the blob before the first push. This is hygiene, not the mitigation — rotation above is what actually revokes it. Do both.

**Acceptance:** old token fails against Stream; fresh signed-in launch connects; no leaked secret in the working tree or in to-be-pushed history.

---

## 2. Liquid Glass didn't visibly change the UI (visible regression — fix this)

**Symptom:** the user reports the UI looks the same. The Liquid Glass kit (`GlassKit.swift`: `GlassCard`, `GlassBar`, `GlowDot`, `GlassOrbAvatar`, `GlassField`, `GoldButton`, `ExplogWordmark`) was built but applied to **onboarding only**, and onboarding has near-empty backgrounds so the frosted panes read flat — there's nothing behind them to blur. Net effect: no perceptible change.

**Fix — actually apply the style to the screens the user sees:**
- Roll `GlassKit` across the real surfaces, not just onboarding: `PulseFeedView`, `BeaconsFeedView`, `NichePlacesView`, `UserProfileView`, `ChatDrawerView` / `StreamThreadView`, `MainTabView`'s tab bar, and the row/card containers in each. Replace flat opaque cards/bars with `GlassCard` / `GlassBar`, avatars with `GlassOrbAvatar`, unread/live indicators with `GlowDot`, and the wordmark with `ExplogWordmark`.
- The glass only reads as glass when there's content **behind** it. Ensure feed content, gradients, or imagery sits under the frosted panes so the blur has something to refract. On any genuinely empty background (onboarding), add a subtle static gradient or faint grain layer behind the panes so the material still reads.
- Keep the material language from the mockup: deep near-black warm-charcoal base, translucent frosted panels with a bright top specular edge + darker bottom edge + soft float shadow, glossy 3D orb avatars with a top-left hotspot and luminous rim, and warm **gold** glow accents (use `Theme.gold`, not the legacy `Theme.accent` orange) used sparingly for "now/live/unread."
- Migrate legacy surfaces from `Theme.accent` (orange) to `Theme.gold` as you convert each screen, so the app doesn't look half-old/half-new. Don't leave a split palette.

**Verify visually — don't claim done without proof:** build to the simulator, drive to each converted screen (reuse the `EXPLOG_AUTO_OPEN` env hooks), screenshot, and confirm the frosted/gloss/gold treatment is actually visible over real content. Attach or save the screenshots.

**Acceptance:** the main feed and profile visibly show frosted-glass cards, orb avatars, and gold glow over real content — a clear before/after change, not just onboarding.

---

## 3. Seed data leaking into real accounts + local store not scoped to auth

**Symptom (observed once):** on a messy first run, seeded demo friends appeared for a signed-in account. After erasing the simulator, two clean runs produced correctly empty graphs.

**Root cause (hypothesis to confirm):** `SeedData.seedIfNeeded` gates only on `Friend` count `== 0` and runs from `MainTabView`'s `.task`, independent of resolved auth state. On the messy run it likely won a race against auth resolving (or ran during a transient pre-`currentUser` / dev-token moment), wrote demo `Friend` rows to the **local** SwiftData store, and those rows then showed for the signed-in account because nothing ties local `Friend` objects to the Firebase uid. The local store persists across sessions, so seeded (or one account's) data can bleed into another account on the same install. Erasing cleared the store.

**Fixes:**
- Gate seeding on a **definitively resolved "no real signed-in account"** state, evaluated *after* the Firebase auth listener has fired — not just on row count, and never before auth resolves. Keep it DEBUG-only.
- **Scope/clear the local SwiftData store on auth transitions:** wipe (or namespace by uid) local `Friend`/`Chat`/`Clip`/`Message` data on logout and on login, so one account never sees another's (or the seed's) cached graph on a shared install.
- To confirm the race: log timestamps at seed time and at auth-resolved time, force the messy path, and check whether seed precedes auth-resolved.

**Acceptance:** a fresh real account always starts with an empty graph; logging out and into a different account shows no leftover data; seed appears only in DEBUG with no signed-in user.

---

## 4. Friend-code enumeration hardening (carry into Phase 2)

`createProfile` now uses `crypto.randomInt` (good) and codes stay 6 chars per spec. A 6-char unambiguous-alphabet code (~1e9 space) is only safe if guess velocity is capped:
- Add **per-caller rate limiting** on `resolveFriendCode`.
- Add a **max-attempts lockout** (temporary block after N failed lookups from the same caller).

**Acceptance:** rapid repeated `resolveFriendCode` calls from one caller are throttled/locked; normal use is unaffected.

---

## Notes / non-bugs (no action)

- Newly deployed 2nd-gen callables return 401 for a few minutes until the public-invoker IAM binding propagates; retry passes. Not a code bug.
- Do not restyle by guessing — build, screenshot, and verify each UI change on the simulator before marking it done.
