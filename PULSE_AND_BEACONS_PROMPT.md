# Build Prompt: Pulse message button + hourly countdown, and a more modern Beacons

Three changes. Follow `RALLI_DESIGN_SYSTEM.md` — coral accent, warm neutrals, soft rounded geometry. Verify on the simulator with screenshots before marking done.

---

## 1. Bring back the message button on Pulse — and ALWAYS keep it

The chat entry point on Pulse keeps disappearing. Add it back and make it permanent.

- Put a **message / chat button in the Pulse header** (`PulseFeedView`), top-right, opening the conversation list.
- **This button must ALWAYS be present on Pulse.** It is a permanent, non-removable part of the header. Do not gate it behind any state, feature flag, or condition. If it is ever missing from Pulse, that is a regression and a bug. Treat its presence as a hard requirement.
- Style: clean circular control, coral-tinted, with an **unread badge** (small coral pill, white count) reflecting real Stream unread state.
- It stays pinned as the feed scrolls, so chat is one tap from anywhere on Pulse.

**Acceptance:** the message button is visible in the Pulse header on every launch and every scroll position, with a live unread badge.

---

## 2. Add an hourly countdown on Pulse ("Life, on the hour")

Ralli's whole premise is posting a log every hour. Make that cadence visible and motivating with a **countdown to the next hour** on Pulse.

- Show a clear indicator on Pulse (near the top / under the header) counting down to the **top of the next hour**, which is the next window to post a log. Live-updating (mm:ss or "23 min").
- Frame it around the action: e.g. "Next log in 23:14" or "New hour in 23 min," not a bare timer. Pair it with the capture affordance so it's obvious what to do.
- Consider a **coral progress ring or bar** that fills as the hour elapses, so you can glance and feel the hour closing.
- **When the hour flips**, celebrate it: a brief coral pulse/animation and a nudge to capture ("It's a new hour — post your log"). If the user hasn't posted this hour, keep the indicator gently prompting; once they've posted, show a satisfied/"done for this hour" state.
- Wire it to the real clock (and the existing `HourFeedState` where relevant), not a fake value. Handle the app returning from background (recompute on foreground).

**Acceptance:** Pulse shows a live, coral countdown to the next hour that updates in real time, prompts capture when the hour flips, and reflects whether the user has already posted this hour.

---

## 3. Make Beacons look modern and social

Beacons still doesn't feel modern or social-media-grade (see the earlier screenshot: boxy cards, weak countdown, cramped attendees, flat hierarchy). Build on `BEACONS_REDESIGN_AND_RECOLOR_PROMPT.md` and push it further toward a polished social feed.

- **Cards with real presence:** give each beacon a prominent place image (hero thumbnail or slim banner), strong type hierarchy with the place name as the anchor, and generous padding with more air between cards. Kill the boxy, utility look.
- **Host row:** host avatar (coral "new" ring if unseen) or a coral-wash group icon for community events, name + soft subtitle ("is heading out" / "open to everyone").
- **Countdown as a chip, not bare text:** a `sunken`/glass pill with a small live dot and "4 hr 15 min." If it starts soon (<~30 min) or is live, the dot **pulses** and the chip goes coral — the feed should feel time-sensitive.
- **Attendees:** an overlapping avatar stack + `x/capacity`, with a quiet capacity progress (thin bar or ring). Social proof should read at a glance.
- **Actions:** Details (secondary/ghost) and **Going** (primary coral) with a clear confirmed/toggled state (filled coral when going) and a springy confirm.
- **Segmented Friends / Public** control (pill), active segment coral-washed with the count in a small coral pill.
- **Live/soon states** and a warm **empty state** ("No beacons yet — start one" + coral create button).
- Everything coral, soft shadows, no hard borders, rounded 16–20 cards, consistent with the design system.

**Acceptance:** Beacons reads as a modern, lively social feed — image-forward cards, pulsing countdown chips, overlapping attendee stacks with capacity progress, coral Going toggle, segmented Friends/Public, and live/empty states. No boxy, dated, or blue look.

---

## Verification

- Match `RALLI_DESIGN_SYSTEM.md` (coral accent, warm neutrals, soft glass, consistent radii). No blue/iris anywhere.
- Build to the simulator, screenshot Pulse (showing the message button + hourly countdown) and Beacons, and save them. The message button must be present in the Pulse screenshot. Don't mark done without the screenshots.
