# Build Prompt: Per-row message buttons on Pulse + consistent Ralli logo across tabs

Two targeted fixes. Follow `RALLI_DESIGN_SYSTEM.md` (coral accent, warm neutrals). Verify on the simulator with screenshots.

---

## 1. Put a message button on the RIGHT of every chat row (not a separate messages tab)

Right now the header chat icon opens a **separate messages tab/list screen**, which is not what we want. Messaging should live inline with the Pulse rows.

- On **every friend/chat row in the Pulse list** (`PulseFeedView` / `PulseHomeView` rows), add a **message button on the right side of the row**. Tapping it opens **that specific conversation directly** (push the existing `ChatDetailView` / `StreamThreadView` for that chat), not a general list.
- Style it Snapchat-like: a small coral-tinted chat/message icon (circular, quiet), right-aligned in the row, with an **unread indicator** on the row (coral dot/badge) when that conversation has unread messages.
- The row itself still opens the log/clip view as before — only the right-side button goes to the chat. Keep the two tap targets clearly separate.
- **Remove the behavior where messaging opens a disconnected new tab.** Chat is reached per-row from Pulse. (Keep the always-present header entry point only if it makes sense as a quick "all conversations" shortcut, but the primary path is the per-row button; if the header button currently just spawns the separate tab, repoint it or remove it so it isn't confusing.)

**Acceptance:** every Pulse row has a right-aligned message button that opens that exact conversation directly; unread rows show a coral indicator; there is no separate messages tab being spawned.

---

## 2. Make the "ralli" logo identical size across tabs

When switching from Pulse to Places, the "ralli" wordmark **changes size**, so it looks like a different logo and jumps. It must look like the exact same logo in the exact same place on every tab.

- Use the **single shared wordmark component** (`RalliWordmark`) with the **same font size, weight, color, and position** in every tab header — `PulseFeedView`, `NichePlacesView`, and any other top-level tab that shows it.
- Right now Pulse and Places render it at different sizes. Pick one canonical size/placement (match Pulse) and use it everywhere. Do not let any screen set its own wordmark size.
- Ideal result: switching tabs, the logo appears to stay perfectly still and identical — same baseline, same size, no resize or reflow.

**Acceptance:** the "ralli" wordmark is pixel-identical in size, weight, and position on Pulse and Places (and any other tab showing it); switching tabs shows no jump or size change.

---

## Verification

- Screenshot Pulse (showing per-row message buttons) and Places on the simulator; overlay/compare the logo position and size across the two — they must match. Save the screenshots.
- Coral accent throughout, no blue.
