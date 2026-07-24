# Ralli Design System — "Warm Modern"

A clean, soft, contemporary look for a social app people open many times a day. The feeling is warm, calm, and human: a paper-warm canvas, one confident accent with personality, generous rounded shapes, real whitespace, and restraint. No gold, no pure black, no heavy chrome.

---

## 1. Principles

- **Warm, not cold.** Neutrals carry a slight warm tint. Pure black and pure white feel clinical; we avoid both.
- **One accent, used sparingly.** Iris (violet) is the signature. Color earns attention because most of the screen is quiet.
- **Content is the hero.** Friends' faces and moments carry the color. The UI is a calm frame around them.
- **Soft geometry.** Rounded corners, pill controls, circular avatars. Nothing sharp or boxy.
- **Depth through softness, not lines.** Prefer gentle shadows and tonal layering over hard borders and dividers.
- **Light-first, beautiful in dark.** Browsing feels light and airy; immersive media (Places) leans dark.

---

## 2. Color

### Light mode (default)
| Token | Hex | Use |
|---|---|---|
| `canvas` | `#FAF8F4` | app background (warm chalk) |
| `surface` | `#FFFFFF` | cards, sheets, rows |
| `sunken` | `#F0EDE7` | inputs, wells, pressed rows |
| `ink` | `#1B1922` | primary text |
| `ink-2` | `#726C7A` | secondary text |
| `ink-3` | `#A8A2AE` | hints, disabled |
| `hairline` | `#E8E3DB` | subtle borders when needed |

### Dark mode
| Token | Hex | Use |
|---|---|---|
| `canvas` | `#131118` | app background (warm near-black) |
| `surface` | `#1C1A23` | cards, sheets, rows |
| `elevated` | `#262330` | raised surfaces, menus |
| `ink` | `#F5F2F8` | primary text |
| `ink-2` | `#A6A0B0` | secondary text |
| `ink-3` | `#6E6878` | hints, disabled |
| `hairline` | `rgba(255,255,255,0.08)` | subtle borders |

### Accent + functional
Primary accent is **Coral** (updated from Iris — the app's signature color is now a warm coral, not blue/violet).

| Token | Light | Dark | Use |
|---|---|---|---|
| `coral` (primary) | `#FF5A5F` | `#FF7B7F` | primary actions, active states, links, brand |
| `coral-press` | `#E64A50` | `#F0656A` | pressed/hover |
| `coral-wash` | `#FFECEC` | `rgba(255,90,95,0.16)` | tinted chip/badge backgrounds |
| `rose` (affective) | `#FF7D90` | `#FF90A2` | likes, reactions, streaks warmth |
| `mint` (positive) | `#24C2A0` | `#34D4B0` | online, success, confirmations |
| `amber` (caution) | `#F5A524` | `#F7B23B` | warnings only, never decorative |

**Accent rules**
- Coral is the only brand color. Rose and mint are *functional* moments (a like, an online dot, a streak), not decoration.
- On any screen, aim for one primary coral action. If everything is accented, nothing is.
- Text on coral is white (light) or near-black (dark, on the lighter `#FF7B7F`). Check contrast either way.
- Never place saturated accent as a large flat fill behind lots of text. Use `coral-wash` for tinted surfaces.
- Coral is warm but is not orange — keep it in the red-pink coral range, never drift toward the old orange/gold.

---

## 3. Typography

Modern geometric sans, tight tracking on large sizes, comfortable line height on body.

- **UI + body:** `General Sans` or `Satoshi` (fallback `Inter`, then system).
- **Wordmark / display:** a slightly characterful cut — `Clash Display` or `Satoshi` heavy. The "Ralli" wordmark is lowercase, tight tracking, medium-bold.
- **Numbers:** tabular figures for counts, timestamps, streaks.

### Scale (pt, sentence case everywhere)
| Role | Size / Weight | Notes |
|---|---|---|
| Display | 32 / 600 | screen heroes, wordmark moments |
| Title 1 | 24 / 600 | screen titles |
| Title 2 | 20 / 600 | section headers |
| Headline | 17 / 600 | row names, card titles |
| Body | 15 / 400 | default text |
| Callout | 14 / 400 | secondary lines, captions in rows |
| Caption | 12 / 500 | timestamps, metadata |
| Micro | 11 / 600 | badges, tiny labels |

Two to three weights only (400 / 500 / 600). Never 700+ in UI; it feels heavy against the soft palette. Line height ~1.4 body, ~1.15 headings. Letter-spacing slightly negative (−0.01 to −0.02em) at 20pt+.

---

## 4. Spacing, radius, layout

- **Spacing scale (4pt):** 4, 8, 12, 16, 20, 24, 32, 40. Screen side margins 20. Card padding 16. Row vertical padding 12–14.
- **Radius:** controls 12, cards 16, sheets/large 20–24, buttons and nav and chips fully pill (999), avatars circular. Consistency here does most of the "clean" work.
- **Density:** generous. One clear focus per screen, lots of breathing room, don't crowd edges.

---

## 5. Elevation

Soft, low, warm-tinted shadows. No hard 1px drop lines, no dark harsh shadows.

- Card (light): `0 1px 2px rgba(20,18,30,0.04), 0 8px 24px rgba(20,18,30,0.06)`.
- Floating (nav pill, FAB): `0 6px 24px rgba(20,18,30,0.12)`.
- Dark mode: lean on surface tone steps (`surface` → `elevated`) more than shadow; keep shadows faint.
- Borders are a last resort. Prefer a tonal step (canvas vs surface) to separate regions. Use `hairline` only when tone alone isn't enough.

---

## 6. Glass / blur — use sparingly

Frosted glass is a garnish, not the theme. Reserve it for:
- the floating bottom nav pill (translucent over content),
- overlays on immersive media (Places feed captions and action rail).

Everywhere else use solid `surface`. Glass over an empty light background just looks muddy; it only earns its place over photos or a scrolling feed.

---

## 7. Iconography

- Line icons, ~1.75px stroke, rounded caps and joins, consistent 24px grid. (SF Symbols rounded weight, or a set like Phosphor / Lucide.)
- Inactive icons `ink-2`; active icon `iris`. Filled variants only for the selected tab.
- Keep icons monochrome. Color lives in the accent states, not in multicolor icons.

---

## 8. Imagery & avatars

- **Avatars:** circular, no heavy rings by default. Show a thin `iris` ring only to signal "new / unseen" (story-style). Online = a small `mint` dot, bottom-right.
- **Media (logs, places):** rounded 16 corners, subtle inner shadow so photos sit into the surface. Let the photography be the color on the page.
- **Empty states:** warm and friendly — a soft illustration or large rounded avatar cluster, one line of copy, one iris action ("Add your first friend").

---

## 9. Components

- **Primary button:** pill, `iris` fill, white text, 15/600, height 48–52. Pressed → `iris-press`, slight scale 0.98.
- **Secondary button:** pill, `surface` fill with `hairline` border (light) or `elevated` fill (dark), `ink` text.
- **Ghost / tertiary:** text-only in `iris`.
- **Chips / filters:** pill, unselected `sunken` with `ink-2` text, selected `iris-wash` bg with `iris-press` text. Counts as tiny pills.
- **Cards / rows:** `surface`, radius 16, soft shadow, no divider lines between rows — use spacing.
- **Inputs:** `sunken` fill, no border, radius 12, `ink-3` placeholder, focus adds a 2px `iris` ring.
- **Badges / unread:** iris dot or small iris pill with white count. Streaks use `coral` with a flame.
- **Bottom nav:** floating pill, `surface` with light blur, active tab icon `iris` (filled) + label, inactive `ink-2`. Center capture button is a solid `iris` circle.
- **Sheets:** radius 24 top corners, grabber in `ink-3`, `surface` background.

---

## 10. Motion

- Springy but quick: 200–300ms, gentle spring (damping high, no bounce overshoot beyond ~3%).
- Press feedback: scale to 0.97–0.98 + slight opacity.
- Transitions: content fades/slides; the nav pill and FAB feel physical.
- Accent glows breathe slowly only for genuine "live" states, never idle decoration.
- Respect reduce-motion: cross-fade instead of movement.

---

## 11. Do / don't

**Do**
- Keep most of the screen quiet neutral; let one iris action lead.
- Use tonal layering and spacing to separate content.
- Let faces and photos supply the color.
- Round everything consistently.

**Don't**
- Use gold, or pure `#000` / `#FFF`.
- Put accent on large text-heavy fills.
- Add borders and dividers everywhere.
- Mix more than one brand accent (coral and mint stay functional).
- Blur every surface; reserve glass for nav and media overlays.

---

## 12. Accessibility

- Body text meets WCAG AA (≥4.5:1) against its surface; large text ≥3:1. `ink-2` on `surface` passes; don't drop below `ink-2` for anything readable.
- Never signal state by color alone — pair the online mint dot with position/label, streaks with the flame + number.
- Tap targets ≥44pt. Focus rings visible (2px iris). Support Dynamic Type by using the scale relatively, not fixed pixels.

---

## 13. Mapping to the app

- **Theme.swift:** replace the gold/orange tokens with the tables above (`iris`, `coral`, `mint`, warm neutrals) as semantic tokens, dual-mode. Retire `Theme.accent` entirely.
- **Pulse:** neutral canvas, `surface` rows, circular avatars with iris "new" ring, `coral` streaks, `mint` online, iris add-friend and filter chips.
- **Places:** dark immersive feed, media full-bleed, glass caption + action rail overlay, iris for follow/active, coral for likes.
- **Beacons / Profile / Chat / Onboarding:** neutral light surfaces, iris primary actions, soft cards, no orange anywhere.
- **Nav:** floating iris-accented glass pill; center capture is a solid iris circle.
- `grep` for the old orange/gold accent afterward should return nothing in view code.
