# Camera & Feed Redesign — grounded in current code

Six items, in the order to build them (later ones depend on earlier ones). Every item below is checked against the actual current implementation — two of them (camera landscape lock, reactions) turned out to already be built further than the reference screenshots suggest, so read the "what's already true" notes before changing anything, to avoid duplicating or fighting existing correct code.

Do not touch anything outside what's described here — coral theme, the messaging fixes, the Beacons/media-sync work from the other open prompts are unrelated to this pass.

---

## 1 — Camera capture screen layout

**What's already true (read `CameraCaptureView.swift` before touching this):** the camera is *already* fully landscape-locked — `InterfaceOrientationLock.lockLandscape()` runs in `.task`, and `landscapeControls` lays out every control (close, grid, self-timer, looks, duration, shutter, mode strip) for a landscape screen exclusively; there is no portrait layout to remove. If your reference screenshot shows a tall vertical preview with icons floating on top of it, that's consistent with the *current* structure in one specific way — the icons genuinely are floating on top — but the screen itself, once rotated, already reports landscape dimensions. The actual gap is composition, not orientation-locking:

- `viewfinderLayer` (~line 400) is sized to fill essentially the whole safe area minus a small `viewfinderInset` margin — it isn't bounded to a true video aspect ratio (e.g. 16:9), it just fills whatever space is left.
- `landscapeControls` (~line 485) is one `ZStack` with the close button, utility row (grid/self-timer/looks/duration — the "hashtag, timer, filter icons" in your notes: the rule-of-thirds grid icon reads as a hashtag glyph), shutter cluster, and mode strip all layered *on top of* the viewfinder card as overlays, sharing the same screen region rather than living in their own space outside it.

**Fix:**

1. Give the viewfinder card an explicit, locked aspect ratio matching recorded video (16:9) via `.aspectRatio(16.0/9.0, contentMode: .fit)` inside its `.frame(...)`, rather than filling whatever space is left over. This makes it unambiguously a landscape rectangle, not however-the-screen-happens-to-measure.
2. Restructure `landscapeControls` from one overlapping `ZStack` into a real layout split: a letterbox/margin region that holds the close button, utility row, and mode strip, genuinely outside the viewfinder card's bounds (top/side margins, not floating over the live image) — shrink the viewfinder's height/available space so this margin has real room, rather than overlaying controls at a fixed inset on top of a nearly-full-bleed card.
3. Move `closeButton` so it sits in that true margin area at the screen's top-left corner, not layered over the edge of the viewfinder image.
4. Change the default: `@State private var captureMode: CaptureMode = .photo` (~line 216) → `.video`.
5. Add the hour overlay: a horizontal text banner across the viewfinder showing the current hour only (see §2 for the shared formatter), styled like your screenshot 3 reference (bold, centered horizontally across the frame). This is a new element — there's no existing hour overlay on the live camera screen to reuse; build it once here and reuse the same font/size/weight everywhere else this prompt calls for "the camera screen's hour overlay" (§4, §6).

## 2 — Global rule: hour-only timestamps

`Date.clockTime` (`Theme.swift` ~line 180) is the formatter used for every clip/log timestamp in the app, and it includes minutes (`formatted(date: .omitted, time: .shortened)` → "5:29 PM"). Current call sites showing a video log's timestamp: `StackedClipViews.swift:146` (author-row timestamp chip), `StackedClipViews.swift:338` (the stacked-feed's live timestamp banner), `MontageView.swift:70` (clip caption row). `ChatDrawerView.swift:291` also uses `clockTime`, but that's a **text message's** send time, not a video log — leave that one showing minutes, since the hour-only rule is specifically about video log timestamps per your spec.

**Fix:** add a new formatter next to `clockTime` in `Theme.swift`:

```swift
extension Date {
    /// Hour-only clock time for video logs — always shows :00, per the
    /// app's hourly cadence (a log is filmed once per hour, so the minute
    /// is never meaningful information).
    var hourOnlyClockTime: String {
        let zeroed = Calendar.current.date(bySettingHour: Calendar.current.component(.hour, from: self),
                                            minute: 0, second: 0, of: self) ?? self
        return zeroed.formatted(date: .omitted, time: .shortened)
    }
}
```

Replace `clockTime` with `hourOnlyClockTime` at the three video-log call sites above (`StackedClipViews.swift:146`, `StackedClipViews.swift:338`, `MontageView.swift:70`), plus every new hour overlay built elsewhere in this prompt (§1, §4, §6) — all of them should use this one formatter so the format never drifts between screens.

## 3 — Global rule: hourly posting cadence (top-of-hour, not rolling 60 minutes)

**What's already true:** two different "can I post now" mechanisms currently coexist, and they disagree:

- `Chat.cooldownRemaining` (`Models.swift` ~line 190): `max(0, logCooldown - Date.now.timeIntervalSince(lastSentAt))` — a **rolling** 60 minutes from whenever you last sent to that specific chat. This gates `SendLogView`'s per-chat send button and drives `PulseFeedView`'s countdown pill.
- `PulseHomeView.postedThisHour` (~line 44): `Calendar.current.isDate(at, equalTo: .now, toGranularity: .hour)` — this one **is** top-of-hour aligned already, and drives the hourly banner's "done for this hour" state.

Your spec wants everything on the top-of-hour model: one send per clock hour, countdown to the next `:00`, not 60 minutes from your last send.

**Fix:**

1. Replace `Chat.cooldownRemaining`'s logic with a top-of-hour calculation:

```swift
var cooldownRemaining: TimeInterval {
    guard let lastSentAt, Calendar.current.isDate(lastSentAt, equalTo: .now, toGranularity: .hour) else { return 0 }
    let nextHour = Calendar.current.nextDate(after: .now, matching: DateComponents(minute: 0, second: 0),
                                              matchingPolicy: .nextTime) ?? .now
    return max(0, nextHour.timeIntervalSince(.now))
}
```

This makes "can send" mean "haven't sent yet this clock hour" (matching `postedThisHour`'s definition) rather than "60 minutes haven't elapsed since I last sent" — the two mechanisms become one rule instead of two different ones.
2. `cooldownString(_:)` (`Theme.swift` ~line 204) already formats a `TimeInterval` as `MM:SS`, which works unchanged with the new top-of-hour remaining value — no change needed there.
3. Check every other reader of `cooldownRemaining` (`SendLogView.swift:288`, `SendLogView.swift:388`, `PulseFeedView.swift:613`) still behaves correctly with the new semantics — they should, since they only ever read the value/compare it to zero, not the old formula directly.

## 4 — Post-capture edit/caption screen

`PostCaptureReview.swift` currently renders the shot full-bleed and vertical:

```swift
ClipView(clip: previewClip)
    .applyLook(look)
    .ignoresSafeArea()
```

**Fix, three parts:**

1. **Horizontal embed.** Give `ClipView` a `contentMode: ContentMode = .fill` parameter (default preserves today's behavior everywhere else) and pass `.fit` here, same idea as Instagram Reels embedding a horizontal clip inside a vertical screen — video/photo shows at its true landscape aspect, letterboxed, rather than cropped to fill the vertical screen:

```swift
ClipView(clip: previewClip, contentMode: .fit)
    .applyLook(look)
    .background(Color.black.ignoresSafeArea())
    .ignoresSafeArea()
```
(For the video branch inside `ClipView`, switch `LoopingVideoView`'s `videoGravity` from `.resizeAspectFill` to `.resizeAspect` when `contentMode == .fit`.) Keep every existing editing tool (text, stickers, draw, filters/looks) exactly as they are — this is purely a preview-sizing change, not a redesign of the tool rail.
2. **Hour overlay.** Add the same horizontal hour banner built in §1, same font/size/weight, positioned over the video here too — reuse the actual view/component from §1 rather than rebuilding it a second time with matching-but-separate styling.
3. **Public location post branch.** Add a new option on this screen (e.g. a toggle or button near the caption field — match the existing control style, not Reels' icon set) that routes to a **new, separate screen** with three fields: name, location, and an audience choice (friends-only vs. public). Reuse what already exists rather than rebuilding it: `SendLogView.swift` already has a `.place` destination with a `Spot` picker (`SpotSearchView`, `showSpotSearch`) and a working `sendPublic()` that creates the local `Clip`/`SpotClip` and calls `logSync.publish(..., audience: .publicAt(spotID:))`. Extract that logic into its own dedicated view rather than leaving it behind `SendLogView`'s segmented `Destination` control, and wire the new toggle on `PostCaptureReview` to present it directly.
4. **Restructure the flow so the ordering matches your spec exactly:** from `PostCaptureReview`, *not* choosing the public-location option should go straight to a friends-only "who do you want to send this to" screen — essentially `SendLogView`'s existing `.friends` destination content (the `Audience` picker sourced from the friend roster, already correctly get-or-create'ing a `Chat` per friend — this part is already correct, don't touch its friend/chat resolution logic), trimmed down to remove the now-unnecessary `Destination` segmented control since the branch is decided one screen earlier now.

## 5 — Places/feed tab: horizontal video, everything else unchanged

Depends on the fix already queued in the other open prompt (`PROFILE_PHOTOS_MEDIA_FLICKER_ORIENTATION_BEACONS_PROMPT.md`, issue #4) that makes `SpotClip` cards render real media instead of always showing the `VibeClipView` placeholder — land that first, since there's nothing to reorient here until real video/photo actually shows in Places at all.

Once that's in: apply the same `.fit`-contentMode / letterbox treatment described in §4 above to `NichePlacesView.swift`'s clip card rendering specifically — the video/photo should show at its true landscape aspect with letterboxing, not full-bleed-cropped vertical. Everything else on this screen (caption, attribution row, like/comment/share controls, bookmarks) stays exactly as it is — this is purely the media container's orientation, matching the same principle as §4's fix, just applied to Places' cards instead of the post-capture review screen.

## 6 — Reactions on friends' videos

**What's already true — read this before writing any new reaction code:** the reaction system in `StackedClipViews.swift` already appears fully built and wired:

- `FriendLogActions` (~line 364) has a working emoji-reaction button (tap → full picker via `EmojiReactionPicker`, long-press → a 5-emoji quick tray), correctly instantiated with a real `chat` parameter at both of its two call sites (`StackedClipViews.swift:289` in the 1-on-1 stacked feed, `StackedClipViews.swift:589` in the all-friends feed).
- `react(with:)` toggles the reaction in `clip.reactions` (a real, persisted `[Reaction]` on the `Clip` model) and, on adding (not removing), constructs `Message.reaction(emoji, to: clip, from: me, in: chat)` and inserts it into the chat — meaning a reaction is already broadcast into the DM thread today.
- `StackedClipPane.reactionBadges(_:)` already renders de-duplicated reaction chips pinned to the bottom-left of the clip (`StackedClipViews.swift` ~line 88, called from the pane's body whenever `clip.reactions` is non-empty).
- `ChatDrawerView.swift`'s `MessageBubble` already has a `reactionCard(clip:emoji:)` branch that renders a reaction message as a small preview of the reacted clip with the emoji overlaid bottom-left, inside the DM thread — screenshot 6's "emoji overlaid on shared content" pattern already exists there.

Given all of this is already wired end-to-end per the code, **do not rebuild the reaction system from scratch.** Instead:

1. Test the actual live flow first: react to a friend's video from the stacked feed, confirm the bottom-left badge appears on the clip, and confirm the same reaction shows up as an overlaid-emoji message in that friend's DM thread. If this genuinely doesn't work on-device, find the specific break (a gesture conflict with the paging swipe consuming the tap before it reaches the button is the most likely candidate given `FriendLogActions` sits inside a `TabView`-style vertically-paging stack; also check whether `chat(with:)`'s lookup at the call site ever returns `nil` for a legitimately-existing chat, which would silently drop the broadcast-to-DM half while leaving the local badge working) — report what's actually broken rather than re-implementing working code.
2. The one genuinely new piece: add the horizontal hour overlay (same component built in §1, same font/size/weight) in the middle of each video in the stacked feed — this doesn't exist yet anywhere in `StackedClipPane`. Add it to `StackedClipPane`'s body (`StackedClipViews.swift` ~line 50), positioned centered over the clip, using `clip.capturedAt.hourOnlyClockTime` from §2's formatter.

---

## Verification

- **1:** open the camera, confirm the viewfinder is a bounded 16:9 landscape card with the close button, grid/timer/looks icons, and mode strip genuinely outside its bounds rather than overlaid on the live image; confirm Video is selected by default; confirm the hour banner shows the current hour with `:00`.
- **2/3:** send a log, confirm every timestamp shown for it anywhere in the app reads e.g. "5:00 PM" never "5:29 PM"; confirm the countdown pill counts down to the next top-of-hour boundary and resets availability at `:00`, not 60 minutes after your last send.
- **4:** capture → edit/caption screen shows the video letterboxed with the hour overlay; choosing "public location post" routes to the dedicated name/location/audience screen and posts correctly; not choosing it goes straight to a friends-only share screen.
- **5:** a video/photo posted to a place shows in the Places feed at its true landscape aspect, letterboxed — confirm nothing else on that screen changed.
- **6:** react to a friend's video; confirm the badge appears bottom-left on the clip *and* the reaction appears in that friend's DM thread overlaid on the shared clip; confirm the new hour overlay shows centered on every video in the stacked feed.
