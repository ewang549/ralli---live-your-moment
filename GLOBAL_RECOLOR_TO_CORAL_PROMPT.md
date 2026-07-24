# Build Prompt: Recolor the ENTIRE app to Coral (not just the camera)

The accent was only changed on the camera screen. It must be changed **everywhere** — every screen, every control, every tab. The likely reason it didn't cascade: the accent is hardcoded per view instead of coming from one shared token. Fix the root cause, then sweep every surface.

Accent target (from `RALLI_DESIGN_SYSTEM.md`): **Coral** `#FF5A5F` light / `#FF7B7F` dark, press `#E64A50` / `#F0656A`, wash `#FFECEC` / `rgba(255,90,95,0.16)`. Coral is warm red-pink — never orange/gold/purple.

---

## 1. Fix the root cause — one source of truth

- In `Theme.swift`, define the accent **once** as semantic tokens (`Theme.accent`, `Theme.accentPressed`, `Theme.accentWash`) set to the Coral values above, dual-mode (light/dark).
- Every view must reference `Theme.accent` — **no view may hardcode a color for the accent.** If a screen uses a literal purple/iris/blue (`Color(red:...)`, a hex, `.purple`, `.blue`, `.indigo`, or an old `Theme.iris`/gold token), replace it with `Theme.accent`.
- After this, changing the token in one place recolors the whole app. That's the test that it's wired right.

## 2. Sweep every screen (nothing skipped)

Audit and convert **all** of these, not just the camera:
- `MainTabView` — active tab tint, the center capture button, any selected state.
- `PulseFeedView` / `PulseHomeView` — headers, badges, "new" rings, the chat button + unread badge, filter chips.
- `NichePlacesView` (Places) — action rail, follow chip, active states, scrubber.
- `BeaconsFeedView` — segmented Friends/Public, countdown, "Going" buttons, `+` create.
- `UserProfileView` / `ProfileSetupView` — toggles, accents, buttons.
- `ChatDrawerView` / `MessageThreadView` / `StreamThreadView` / `ChatDetailView` — my-message bubbles, send button, tapback tray, links.
- `AuthGateView` / onboarding — primary buttons, links, field focus rings.
- `CameraCaptureView` — already coral; confirm it uses `Theme.accent`, not a local literal.
- `GlassKit.swift`, `LogPlayerView`, `MontageView`, `DailyVlogView`, `ClipView`, `SendLogView`, and any component with an accent — convert too.

## 3. Verify (this is where it failed last time)

- `grep` the whole `explog/` view code for old accent values and names: the old purple/iris hex, `Theme.iris`, `.purple`, `.indigo`, `.blue` used as accent, and any gold token. **Result must be empty** (except genuinely non-accent uses like a system blue link you intend to keep — there shouldn't be any).
- Build to the simulator and screenshot **at least five different screens** — Pulse, Places, Beacons, Profile, and a chat thread — using the `EXPLOG_AUTO_OPEN` hooks. Every accent element in every shot must be coral. Save the screenshots.
- Do not report done based on one screen. The whole point of this task is that the previous change only touched one screen.

**Acceptance:** the accent is defined once in `Theme` and referenced everywhere; a `grep` for old purple/iris/blue/gold accent values in view code returns nothing; five+ screenshots across different tabs all show coral; changing the single `Theme.accent` token visibly recolors the entire app.

---

## Note on the camera (minor polish)

The camera is close. Two small things while you're here: the shutter's coral inner fill can be slightly more saturated for punch, and confirm the top-bar controls (`#`, timer) and side cluster all pull from `Theme.accent` so they match the rest of the app after the sweep.
