# URGENT: Recolor the whole app to Coral, then refine the camera

Two tasks. Do #1 first and completely — it has been asked for repeatedly and is still not done.

---

## 1. THE APP IS STILL BLUE. MAKE THE ENTIRE APP CORAL. (do this first)

The main UI accent is **still the old blue/iris everywhere except the camera.** This is wrong. The app's signature color is **Coral `#FF5A5F`** (light) / `#FF7B7F` (dark). Every blue/purple/iris accent in the app must become coral. No exceptions.

Why it keeps failing: the accent is hardcoded per screen instead of coming from one shared token. Fix the root cause:

- In `Theme.swift`, define the accent **once** (`Theme.accent`, `Theme.accentPressed`, `Theme.accentWash`) as the Coral values above, dual-mode.
- Make **every** view reference `Theme.accent`. Replace every hardcoded blue/purple/iris literal (`.blue`, `.indigo`, `.purple`, any old iris hex, any `Theme.iris`) with `Theme.accent`.
- Sweep every screen: `MainTabView` (active tab + center capture button), `PulseFeedView`/`PulseHomeView`, `NichePlacesView`, `BeaconsFeedView`, `UserProfileView`, `ProfileSetupView`, `AddFriendView`, all chat views (`ChatDrawerView`, `MessageThreadView`, `StreamThreadView`, `ChatDetailView`), `AuthGateView`, `GlassKit`, `LogPlayerView`, `MontageView`, `DailyVlogView`, `ClipView`, `SendLogView`.

**Verification — non-negotiable:**
- `grep -rin "\.blue\|\.indigo\|\.purple\|iris\|5A4FF3\|8C82FF\|4B3FE4" explog/` returns **nothing** in accent usage.
- Screenshot **five different screens** (Pulse, Places, Beacons, Profile, a chat thread) on the simulator. Every accent element in every screenshot is coral. If even one screen is still blue, the task is not done.
- The proof it's wired right: changing the single `Theme.accent` token recolors the whole app at once.

---

## 2. Refine the camera layout (I like the features, the layout is off)

The features are good. The problem is the controls are **too big and take up too much of the screen**, and there's a stray connecting line/box glitch. The preview should dominate; controls should be minimal and tucked to the edges, like Snapchat/TikTok.

Specific changes:

- **Shrink the control buttons.** The right-side circular buttons (flip, flash, gallery) and the top-row buttons are oversized. Make them small and unobtrusive (roughly 40–44pt), with tighter, even spacing. They should frame the preview, not compete with it.
- **The capture button can stay the most prominent element, but slightly smaller**, and the other buttons much smaller than it so the hierarchy is clear.
- **Remove the stray connecting line / floating rounded-rectangle** tethering the top-right controls to the flip button. That's a visual bug — every control should be a clean standalone circle in an evenly spaced group, nothing connected by a line or box.
- **Top row:** lay the utility controls (grid, timer, effects, mode/duration) out as a **neat, evenly spaced horizontal row** pinned to the top edge — not a clustered blob. Even gaps, same size, aligned.
- **Center the bottom mode selector.** The Boomerang / Photo / Video segmented control must be **horizontally centered** on screen, as a compact pill, with the selected segment filled coral. Right now it's off-center and a touch large — tighten it.
- **Overall:** maximize the clear preview area. Controls hug the edges (top row, right cluster, centered bottom mode bar) and stay visually quiet so the shot is the hero. Nothing should feel oversized or floating.

Keep everything coral per task #1, warm dark base, soft glass, consistent radii, springy motion.

**Acceptance:** the whole app is coral (five screenshots prove it); the camera's controls are small and edge-hugging with no stray connecting line, the preview dominates, and the Boomerang/Photo/Video selector is centered as a compact coral segmented pill.
