# Build Prompt: Ralli UI Redesign (gold-forward, glass, rebrand)

You are working in the iOS app repo formerly called **Explog** — the app is now named **Ralli**. This prompt redesigns the visual language across the app using two reference screens as inspiration, kills the old orange-on-black palette, and makes **warm gold on rich dark** the signature look everywhere.

**Reference the existing code, don't rebuild from scratch.** Keep the information architecture and the `GlassKit.swift` component kit; restyle and extend. Verify every screen on the simulator with screenshots before calling it done.

---

## 0. Rebrand: Explog → Ralli

- Change every **user-facing** occurrence of "Explog" to **"Ralli"**: the wordmark, onboarding copy, empty states, notification strings, `Info.plist` display name, launch screen. Rename `ExplogWordmark` → `RalliWordmark` (elegant serif, metallic **gold** sheen).
- **Do not** rename internal identifiers that would break the backend: bundle id, Firebase project `explog-723b7`, Cloud Function names, Stream app/keys, file/type names like `StreamConfig`, env hooks `EXPLOG_AUTO_*`. Rebrand is cosmetic/user-facing only. Leave a short code comment where an internal name still says "explog" so it's clearly intentional.

---

## 1. Global color system — no more orange, no more flat black

Replace the palette in `Theme.swift`. Retire `Theme.accent` (orange) entirely — migrate every reference to gold as you touch each screen; do not leave a split orange/gold palette anywhere.

- **Base:** rich warm near-black / deep charcoal with a faint warm undertone (not pure `#000`). Use a subtle dark vertical gradient as the app background so glass and gold read against depth.
- **Accent (signature):** warm **gold** with two tiers — a bright polished gold for highlights/active states and a softer amber for glows. Gold is used deliberately and sparingly against the dark so it always feels premium, never neon.
- **Text:** near-white primary, muted warm-grey secondary. Never pure white on pure black.
- **Surfaces:** translucent frosted glass (`GlassCard` / `GlassBar`) with a bright top specular edge, darker bottom edge, and soft float shadow. Content sits *behind* glass so it actually refracts.
- Define reusable tokens: `Theme.gold`, `Theme.goldSoft`, `Theme.goldGlow`, `Theme.base`, `Theme.baseElevated`, `Theme.glassTint`, `Theme.textPrimary`, `Theme.textSecondary`. Every new/updated view pulls from these — no hardcoded colors.

---

## 2. Places — full-bleed vertical feed + floating slider (Reference: Image 1)

Redesign `NichePlacesView` into an immersive, scroll-snapping vertical media feed inspired by the reels layout, **gold-accented and aesthetic**.

- **Full-bleed media:** each place/spot clip fills the screen edge to edge; vertical paging that **snaps** one item per swipe. Content (the clip/photo) is the backdrop — everything else floats over it as glass/gold overlays.
- **Right-side action rail:** a vertical stack of glass-backed icon buttons with counts — like, comment, share, save/bookmark — styled with **gold** icons/tints and a soft gold bloom on the active (liked/saved) state. Counts in clean light type beneath each. Reuse `GlowDot` language for "live/now."
- **Bottom-left attribution:** creator avatar as a `GlassOrbAvatar` with a **gold gradient ring**, handle (`@handle`), a one-line context/caption, and a gold-outlined **Follow / Add** chip. A "See more" caption expander.
- **Sequence scrubber:** the horizontal dotted progress/sequence indicator from the reference, rendered as thin gold-tinted segments showing position in the place's clip set.
- **Floating slider / nav pill:** adopt the reference's floating **glass pill** as the app-wide bottom nav (see §5) — translucent, rounded, with the active tab in bright gold. It floats above the media, not docked to a bar.
- Emphasize gold throughout this screen — rail, ring, follow chip, scrubber, active nav — so Places feels like the gold showcase.

**Acceptance:** Places is a snapping full-screen vertical feed; the gold action rail, gold-ring orb avatar, follow chip, and floating glass nav pill all read clearly over real media.

---

## 3. Pulse — activity/conversation list (Reference: Image 2)

Redesign `PulseFeedView` as a rich, scannable list of friends' hourly logs / activity, inspired by the chat-list layout — translated to Ralli's gold-on-dark glass.

- **Header:** `RalliWordmark` (or "Pulse" title), a search affordance, a notifications bell (with gold badge), and a prominent **add-friend button** rendered in gold (this is the entry to the Phase-2 add-friend flow).
- **Filter chips row:** horizontal segmented chips (e.g. Unread / Today / Streaks / Groups), active chip in gold, unread counts in small gold pills.
- **List rows:** each row is a friend with a `GlassOrbAvatar`, their name, and a **status/activity line** ("Busy coding", "Hiking the Rockies", "New log", "2 new") in muted type. Right side shows timestamp and state.
  - **Unread/new** gets emphasis: brighter name, a **gold `GlowDot`**, bolder weight.
  - **Streaks** shown with a flame + count in gold, matching your existing `Chat.streak` model.
  - Row action affordance on the right (camera/quick-log or open-thread), gold-tinted.
- Rows sit on the dark base with subtle glass separation; no orange anywhere (retire any orange "Restore"-style buttons → gold).

**Acceptance:** Pulse reads as a premium activity list — orb avatars, status lines, gold glow for new/unread, gold streak flames, gold filter chips, gold add-friend button.

---

## 4. Everything else matches

Apply the same gold-on-dark glass language to the rest so the app feels unified — **no orange, no flat black anywhere**:

- **Beacons** (`BeaconsFeedView`): glass cards, gold accents for "live/join", orb avatars for attendees, gold capacity/RSVP states.
- **Profile** (`UserProfileView` + `ProfileSetupView`): glass sections, gold toggles/accents, orb avatar, `RalliWordmark`.
- **Chat** (`ChatDrawerView` / `StreamThreadView`): gold send button and sender accents (replace the old orange), glass input bar, tapback styling in gold-neutral tones.
- **Onboarding**: gold buttons, glass fields; since backgrounds are empty, add a subtle gold-tinted gradient/grain behind the panes so glass still reads.
- **Camera / capture** and any remaining surface: audit for `Theme.accent` orange and convert to gold.

---

## 5. Global bottom navigation — floating glass pill

Replace the current tab bar with a floating **glass pill** nav (inspired by Image 1's bottom bar): translucent, rounded, floats above content with a soft shadow. Icons in muted tone, the **active tab in bright gold** with a subtle gold glow. Keep Ralli's existing tabs/center-camera action — restyle only, don't change what the tabs do.

---

## Constraints & verification

- Keep `GlassKit` components; extend them (e.g. gold-ring variant of `GlassOrbAvatar`, gold action-rail button, sequence scrubber) rather than styling ad hoc.
- One palette: after this pass, `grep` for the old orange accent should return nothing in view code.
- Glass needs content behind it — ensure media/gradients sit under panes so the effect is visible (this was the earlier miss).
- **Prove it:** build to the simulator, drive to Places, Pulse, Beacons, Profile, and Chat (reuse the `EXPLOG_AUTO_OPEN` hooks), screenshot each, and confirm the gold-on-dark glass look is actually visible over real content. Save the screenshots. Don't mark done without them.

**Acceptance (whole task):** the app is rebranded to Ralli, uses one cohesive warm-gold-on-dark glass aesthetic with zero orange/flat-black, Places is the immersive gold vertical feed with a floating glass slider, and Pulse is the gold activity list — verified by simulator screenshots.
