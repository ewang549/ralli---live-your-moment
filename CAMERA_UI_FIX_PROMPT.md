# Build Prompt: Redesign the Camera / Capture screen (Ralli)

Redesign `CameraCaptureView.swift` — the full-screen capture surface Ralli raises for logging. It currently looks unfinished: the capture button sits on the **left**, the flash and duration controls float awkwardly, and the layout doesn't feel like a real camera. Rebuild it to be beautiful, ergonomic, and Snapchat-grade, using the Ralli "Warm Modern" design system (see `RALLI_DESIGN_SYSTEM.md`). Keep the existing capture logic and `CaptureContext` duration caps; this is a UI/UX and interaction rebuild, not a backend change.

Follow the design system: **Coral `#FF5A5F` accent** (the app is now coral, not the old purple/iris — recolor this screen too), warm dark base (not pure black), soft rounded geometry, glass only where it earns it. Retire any leftover orange/gold/purple. Verify on the simulator with screenshots before marking done.

---

## 0. Vision — this is a social camera, not the iOS camera app

**The most important thing:** right now the capture screen looks like Apple's stock camera — a preview with a plain shutter and a few utility buttons. That is not the goal. Ralli's camera is the heart of a social app, and it should feel like **Snapchat, TikTok, and Instagram's camera**: playful, tactile, delightful, and packed with creative tools, while still being dead-simple to point and shoot.

Aim for:
- **Fun and expressive**, not utilitarian. Capturing a moment should feel like play — creative tools within thumb's reach, satisfying animations, personality in every interaction.
- **Effortless for the 1-tap case, deep for the rest.** A first-timer can just tap and post; a power user can add a filter, a caption, a sticker, and pick a mode. Complexity is layered, never in the way.
- **Beautiful and modern** — soft glass controls, coral accents, smooth springy motion, nothing that reads as a system default.
- **Ownable.** It should look like *Ralli's* camera the moment you see it, not a reskinned iOS camera.

The features in §3 are not optional garnish — the creative tools are what make this a social camera instead of a utility. Prioritize making it feel alive.

---

## 1. Fix the core layout — the camera preview must fill the screen

The current layout is fundamentally wrong on sizing: the camera/preview sits in a small floating card in the middle with controls scattered around empty black space, and there's a stray empty square floating near the top. Fix this first.

- **The camera preview is the screen.** It fills the entire surface, edge to edge, full-bleed, as the background layer. It is the majority of the view — everything else is an overlay on top of it. No small centered card, no large empty black margins.
- **Controls float over the preview**, not beside it in dead space. Group them tightly against the edges with safe-area padding: capture button and its cluster on the right (landscape) / bottom (portrait), utility controls in a top bar. The middle stays clear for framing.
- **Remove the stray/empty floating element** (the loose outlined square near the top). Every control must be intentional, labeled, and part of a group — nothing orphaned.
- **Move the capture button to the right side.** In landscape it belongs under the right thumb; in portrait it belongs bottom-center. Support both orientations properly (the app raises capture on landscape rotation) — controls reflow, they don't just rotate.
- **Portrait (primary):** preview full-bleed, capture button bottom-center, secondary controls flanking it, top row for close + settings. **Landscape:** preview full-bleed, capture button pinned to the **right edge**, vertically centered, secondary controls stacked beside it, close button top-left.
- Give every control a consistent hit target (≥44pt), even spacing, and safe-area padding. Nothing should feel floated or accidental.

---

## 2. The capture button (Snapchat-style)

- Large circular button: a clean white ring with a Coral-tinted inner fill; pressed state scales slightly and brightens.
- **Tap = photo. Press-and-hold = video**, with the ring filling as a Coral progress arc that completes at the `CaptureContext.maxClipDuration` cap (2s pulse / 5s place). Release early stops and keeps the clip; reaching the cap auto-stops.
- Subtle haptic on start and on stop. A soft Coral glow while recording. Remove the current flat purple disc look in favor of this ring + progress treatment.

---

## 3. Features — the creative tools that make it a social camera

These are what separate a social camera from the stock one. Build the core set well; the creative set is what gives it personality.

### Core capture (table stakes, but polished)
- **Flip camera** — front/back toggle with a quick flip animation.
- **Flash / torch** — off / on / auto cycle, clear icon state.
- **Pinch to zoom** with a thin zoom indicator; drag-up-from-shutter-to-zoom during a hold (Snapchat/TikTok gesture).
- **Tap to focus / expose** — a small focus reticle animates where you tap.
- **Timer / duration chip** — restyle the `2s` indicator into a clean glass pill; let it toggle the cap where allowed.
- **Gallery / last-capture thumbnail** — a rounded thumbnail to pull the most recent shot or open the picker.
- **Grid toggle** (rule-of-thirds).
- **Self-timer / countdown** (3s/10s) for hands-free shots.

### Creative tools (this is what makes it Ralli's camera)
- **Filters / looks** — a swipeable strip or carousel of tasteful color grades and effects (swipe left/right on the preview to change look, like Snapchat/Instagram). Live preview, coral-accented selected state. Keep the default set curated and beautiful, not gimmicky.
- **AR lenses / face effects** — support fun face and world effects (even a starter set). This is the single most "social camera" feature; make room for it in the UI even if the effect library grows later.
- **Text tool** — tap to add captions/text over a capture, with a few clean fonts, colors (coral in the palette), and drag-to-position.
- **Stickers & emoji** — drop, scale, rotate stickers and emoji onto a shot; optionally pin a sticker to a spot in video.
- **Draw / doodle** — finger-draw over a capture with a coral-forward color set and adjustable brush.
- **Music / sound** — attach a short audio/music clip to a video log (even a simple picker to start).
- **Capture modes** — a mode selector (like TikTok/Snap): Photo, Video, and at least one playful mode such as **Boomerang/loop** or **dual camera** (front+back at once, BeReal-style) which fits Ralli's "capture the real moment" ethos perfectly.
- **Multi-snap / burst** — optionally chain a few quick clips into one log.

### Post-capture (review & send)
- After capturing, land on a clean **review screen**: the shot full-bleed, creative tools (text, stickers, draw, filters) along one edge, and a prominent coral **Send / Next** action plus save-to-gallery and retake. This is where captions and stickers get added before posting — mirrors Snap/Instagram's flow.

Layer these so the base capture stays one-tap-simple: creative tools live in a tidy rail and on the post-capture review screen, never cluttering the framing view.

---

## 4. Controls styling

- **Top row:** close (`x`) top-trailing in portrait / top-leading in landscape as a soft glass circular button; grid and any settings as matching glass circles.
- **Secondary buttons** (flip, flash, gallery): circular, translucent dark glass, white line icons, Coral active tint. Even sizing, even rhythm around the shutter.
- **Duration/timer pill:** glass pill, Coral ring accent, tabular figures.
- Use the design system's line icons (~1.75px stroke, rounded), never filled except for active state.

---

## 5. Simulator / no-camera state

- The simulator has no camera, so the placeholder stands in for the live preview — it must therefore **fill the whole screen too**, exactly where the real camera feed would be, not sit as a small centered card. Make it a **full-bleed soft time-of-day gradient** (coral-tinted, warm) with the hour centered and the copy quiet and small so it reads as a graceful fallback, not an error. All the real controls (shutter on the right, flip, flash, timer, gallery) render on top of it, laid out exactly as they would over a real feed, so the screenshot looks like a finished camera.

---

## 6. Motion & polish

- Springy, quick (200–300ms). Shutter press scales to ~0.96; recording ring animates smoothly to the cap.
- Control appear/disappear cross-fades; focus reticle pulses once and fades.
- Respect reduce-motion.

---

## Constraints & verification

- Keep capture logic, `CaptureContext`, and duration caps intact — restyle and add interactions around them.
- Match `RALLI_DESIGN_SYSTEM.md` exactly: Coral accent, warm dark base, soft glass, no orange/gold/purple, consistent radii.
- **Prove it:** build to the simulator, capture screenshots in both portrait and landscape (reuse the `EXPLOG_AUTO_OPEN=capture` hook), and confirm the shutter is on the right in landscape, controls are evenly laid out, and the look matches the design system. Save the screenshots.

**Acceptance:** the screen reads unmistakably as a **modern social camera** (Snapchat/TikTok/Instagram), not the iOS camera app — playful, beautiful, and full of creative tools, while staying one-tap-simple. The preview fills the screen full-bleed as the majority of the view with controls overlaid (no small centered card, no stray floating elements); capture button is right-aligned in landscape / bottom-center in portrait; tap-photo / hold-video with a Coral progress ring works; core tools (flip, flash, zoom, tap-to-focus, timer, gallery) and creative tools (filters/looks, lenses, text, stickers, draw, capture modes) are present; a post-capture review screen with a coral Send action exists; all in the Ralli coral aesthetic.
