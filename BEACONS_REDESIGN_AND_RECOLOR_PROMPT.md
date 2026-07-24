# Build Prompt: Recolor to Coral + Redesign Beacons (Ralli)

Two changes in one pass:
1. **Swap the app's primary accent from the current blue/iris to Coral**, everywhere.
2. **Redesign the Beacons screen** (`BeaconsFeedView.swift`), which currently looks dated and unrefined.

Follow `RALLI_DESIGN_SYSTEM.md` (the accent section is already updated to Coral). Warm-neutral canvas, soft rounded geometry, one confident accent, restraint. Verify on the simulator with screenshots before marking done.

---

## Part 1 — Global recolor: blue/iris → coral

Replace the primary accent app-wide. This is a find-and-replace of the *semantic* accent, not a per-screen tweak.

- In `Theme.swift`, set the primary accent tokens to Coral (dual-mode):
  - `coral` `#FF5A5F` (light) / `#FF7B7F` (dark)
  - `coral-press` `#E64A50` / `#F0656A`
  - `coral-wash` `#FFECEC` / `rgba(255,90,95,0.16)`
  - keep `mint` for online/success, `rose` `#FF7D90` for likes/reactions, `amber` for warnings only.
- Migrate **every** reference to the old iris/blue accent (primary buttons, active tab, links, selected filter chips, avatar "new" rings, progress bars, the center capture button, "Going" buttons, countdown text, focus rings) to `coral`. After this pass, `grep` for the old blue/iris hex and token in view code must return nothing.
- Coral must read as warm coral (red-pink), never orange/gold. Check contrast: white text on coral in light mode, near-black on the lighter coral in dark mode.
- Keep everything else in the system intact — only the hue of the accent changes.

**Acceptance:** no blue/iris left anywhere; the capture button, active tab, primary buttons, and chips are all coral; contrast passes in both modes.

---

## Part 2 — Redesign Beacons

Beacons is the "who's heading out / join me" feed. The current cards feel boxy, the countdown is a weak colored-dot-plus-text, the attendee area is cramped, and hierarchy is flat. Rebuild it to feel modern, warm, and alive.

### Header
- Large "Beacons" title, warm ink. Keep the montage/film icon and the create (`+`) button top-right, but restyle both as clean circular controls — the `+` as a solid **coral** circle (primary create action).
- **Friends / Public** as a proper segmented control (pill), active segment coral-washed with coral text and the count in a small coral pill; inactive in `sunken` neutral.

### Beacon card — new structure (top to bottom)
1. **Host row:** host avatar (circular, coral "new" ring only if unseen) or a coral-wash group icon for community events, then host name + a soft subtitle ("is heading out" / "open to everyone"). On the right, a **countdown chip** — a glass/`sunken` pill with a small live dot and "4 hr 15 min", not bare colored text. If the beacon starts very soon (<~30 min) or is live, the dot pulses and the chip goes coral.
2. **Place block:** give the place image real presence — either a larger rounded hero thumbnail (56–64pt) or a slim banner. Place name in headline weight, then `category · distance` in secondary. Make the imagery feel intentional, not a tiny clipped icon.
3. **Note:** the host's message line, comfortable size, secondary-ink.
4. **Footer:** an **overlapping avatar stack** of attendees + `x/capacity`, with a subtle **capacity progress** shown as a thin rounded bar *or* a small ring around the count (pick one, keep it quiet). Then **Details** (secondary/ghost) and **Going** (primary coral, with a clear toggled/confirmed state — filled coral when going, outline when not).

### Feel & polish
- Cards: `surface`, radius 16–20, soft warm shadow, no hard borders, generous internal padding, more air between cards.
- Clear type hierarchy: place name is the anchor, host and meta step down in size/weight.
- **Live/soon states:** beacons starting soon get a gentle coral accent (pulsing dot, coral countdown) so the feed feels time-sensitive and active.
- **Empty state:** if no beacons in a filter, a warm friendly empty state — soft illustration or avatar cluster, one line ("No beacons yet — start one"), and a coral create button.
- Motion: springy press on Going (scale ~0.97) with a satisfying confirm; countdown updates smoothly.

**Acceptance:** Beacons reads as a modern, warm, lively feed — segmented Friends/Public control, refined cards with a real place image, a proper countdown chip, an overlapping attendee stack with capacity progress, and a clear coral Going toggle. No boxy/dated look, no blue.

---

## Part 3 — Persistent chat access on Pulse + Snapchat-grade messaging

Messaging should feel like a first-class, always-reachable part of the app, and the thread experience should be as rich and playful as Snapchat. Chat runs on Stream (`StreamThreadView` / `MessageThreadView`, `ChatDetailView`, `ChatDrawerView`); build on that.

### Always-present chat button on Pulse
- Add a **persistent chat button in the Pulse header** (`PulseFeedView`) — always visible, top-right, opening the conversation list. It's the fixed home for messaging, not something you have to dig for.
- Style it as a clean circular control with an **unread badge** (coral pill with white count) when there are unread messages. The badge count reflects real Stream unread state.
- It stays put as the feed scrolls (pinned header), so chat is one tap from anywhere on Pulse.

### Conversation list (Snapchat-style)
- Rows: `GlassOrbAvatar`/circular avatar, name, and a **status line** that shows the real state — "New message", "Delivered", "Opened", typing ("…"), or a media indicator (a small icon for photo/video logs).
- **Unread** rows get emphasis: bolder name, a coral `GlowDot`, brighter text; read rows relax to secondary.
- **Streaks:** show the flame + day count (you already track `Chat.streak`) in rose/coral, with the "about to expire" hourglass when the window is closing.
- Presence: a **mint online dot** on avatars for friends currently active (Stream presence).
- Swipe actions on a row: quick camera reply, mute, pin.

### Thread experience (rich + playful)
- **Real-time niceties from Stream, surfaced visibly:** typing indicators, read receipts ("Opened"/"Delivered" states), and presence at the top of the thread. These exist in the SDK — display them.
- **Reactions:** keep and restyle the existing tapback emojis; long-press a bubble for a coral-accented reaction tray, plus copy/reply/save.
- **Quick camera-to-chat:** a camera affordance in the input bar to send a photo/video log straight into the thread (ties into the redesigned capture screen).
- **Media messages:** inline rounded photo/video bubbles with a tap-to-expand viewer; play button overlay for video logs.
- **Voice notes:** hold-to-record an audio message with a coral waveform (optional but on-brand).
- **Save / disappearing:** let a message be saved (persists) vs. ephemeral by default, Snapchat-style — visually distinguish saved messages (subtle highlight) from ones that clear.
- **Input bar:** soft `sunken` pill field, coral send button, camera + emoji affordances, grows with multi-line text; keep it reachable above the floating nav.
- **Bubbles:** mine in coral (white text), theirs in `surface`/`sunken` (ink text), radius ~18, tight vertical rhythm, timestamps in caption size, delivery state under the last sent bubble.

### Feel
- Springy send animation (bubble scales in), smooth scroll-to-latest, haptic on send and on receiving a reaction.
- Everything coral-accented per the design system; no blue anywhere.

**Acceptance:** Pulse always shows a chat button with a live unread badge; the conversation list reads like a modern messenger with presence, streaks, typing, and unread emphasis; threads support reactions, media, quick camera replies, read receipts, and save/ephemeral messages — all in the warm coral aesthetic.

---

## Verification

- Match `RALLI_DESIGN_SYSTEM.md` exactly (Coral accent, warm neutrals, soft glass, consistent radii).
- `grep` confirms the old blue/iris accent is gone from view code.
- Build to the simulator, drive to Beacons (`EXPLOG_AUTO_OPEN=beacons`), Pulse (with the chat button + conversation list + a thread open), and one or two other screens to confirm the global recolor took, screenshot each, and save them. Don't mark done without the screenshots.
