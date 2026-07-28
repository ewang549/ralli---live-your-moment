# Fix prompt: place-video delete doesn't clear the feed, friend-pairing layout regression, All Friends borders

Four items. One of them (Pulse ordering) turns out to already be fixed — noted so it doesn't get re-touched for no reason.

---

## 1 — Deleting a Place video removes it from your profile but not from the Places feed

This isn't a missing backend — the server-side delete is real and already works correctly. The bug is a client-side sync gap.

`UserProfileView.delete(_:)` (`UserProfileView.swift:395-408`) does call the real backend delete for a published clip (`FirestoreService.deleteLog(id:)` → the `deleteLog` callable, `functions/index.js:2108-2128`, which correctly verifies ownership, deletes the storage object, and recursively deletes the `logs/{id}` doc). `listSpotLogs`/`listPublicLogs` (`functions/index.js:1630-1638`, `1566-1605`) query the live `logs` collection directly, so once `deleteLog` runs, the server correctly stops returning it to anyone, including you.

**The actual gap:** the Places feed on-device is backed by a separate local SwiftData model, `SpotClip`, populated by `LogSync.materialisePublic` (`LogSync.swift:342-423`). That function only ever *creates or updates* `SpotClip` rows from each sync response — it never removes a local `SpotClip` whose remote log has since disappeared from the server (no diff/prune step). And `UserProfileView.delete(_:)` only touches the `Clip` model — it never looks up or deletes the corresponding `SpotClip` row at all. So after a successful server-side delete, the orphaned local `SpotClip` just sits in the store and keeps rendering in Places/Niche/Bookmarked views indefinitely.

**Fix — two complementary parts:**

1. In `UserProfileView.delete(_:)`, after the server delete succeeds, also look up and delete the matching local `SpotClip` (matched by `remoteID == clip.remoteID`) so it disappears immediately rather than waiting for the next sync.
2. In `LogSync.materialisePublic`, add a prune step: after processing a sync response, delete any local `SpotClip` for that spot whose `remoteID` is no longer present in the fresh server payload. This is the real fix — it also covers deletions that happen from other devices/sessions, not just the one that triggered the delete.

## 2 — Friend-pairing screen layout regressed after the recent aspect-ratio border fix

The earlier fix that sized `StackedClipPane`'s container to the clip's real aspect ratio (to eliminate letterbox borders) is working as intended for the video itself, but it exposed three layout bugs riding on top of the old fixed-square assumption. Reference: image 1 is current (broken), image 2 is the target layout — **take only the two-videos-stacked layout and the react/reply button placement from image 2, nothing else** (not its color scheme, header, or other chrome).

**(a) Remove the redundant time badge.** `StackedClipPane.header` (`StackedClipViews.swift:207-221`) renders a small `Capsule` pill showing the hour in the top-right, separate from the large burned-in `HourOverlay` time text. Since the big time stamp is already burned into the video, this small duplicate pill is redundant — remove it entirely from `header`.

**(b) Fix reaction/reply button placement.** `FriendLogActions` (lines 537-645) is attached via `.overlay(alignment: .bottomTrailing)` directly on the now aspect-fitted, dynamically-sized box — at three call sites: `pairPage` (lines 410-416, `.padding(16)`), `groupCard` (798-807, `.padding(14)`), and `row(for:height:)` (986-994, `.padding(12)`). Since the pane's outer frame now shrinks to match the clip's actual shape instead of a fixed square, the overlay tracks that new, smaller box exactly — for a landscape clip, its corner sits much higher/more compressed than users expect, since it used to anchor to a larger fixed container. Per image 2's reference layout, re-anchor `FriendLogActions` so it sits at a consistent position relative to each video card regardless of the card's own aspect ratio — positioned along the right edge, vertically centered or evenly spaced between the reaction and reply icons as shown in image 2, not pinned to the bottom corner of a box that now changes size per clip.

**(c) Fix the caption reverting to the bottom-left corner.** In `StackedClipPane.body` (`StackedClipViews.swift:126-144`), the caption is rendered inside a `VStack` with a `Spacer()` pushing it down:
```swift
VStack(alignment: .leading, spacing: 8) {
    header
        .padding(.top, headerTopPadding)
    Spacer()
    if let caption = clip?.label, !caption.isEmpty {
        captionOverlay(caption)
            .allowsHitTesting(false)
    }
    ...
}
```
This bottom-pins the caption, disconnected from the large `HourOverlay(date:)` burned-in time text (a separate `ZStack` layer, lines 114-116). This is exactly why the caption shows correctly under the time in the post-capture preview but reverts to the bottom-left once actually viewed here. `PostCaptureReview.swift:144-147` already does this correctly — the caption sits in the same small `VStack` directly beneath the time overlay:
```swift
VStack(spacing: 6) {
    LiveHourOverlay()
    captionField
}
```
(comment there: "The caption rides directly beneath it, a size down, so the two read as one stamp block.") **Restructure `StackedClipPane` to match this** — move the caption out of the bottom-anchored `VStack` and into the same layer/position as `HourOverlay`, directly beneath it, at a smaller font size, so playback matches what the post-capture preview already showed the user.

## 3 — Pulse ordering should move a friend to the top in BOTH directions — when you send to them, and when they send to you

The earlier fix only covers outgoing activity. `Chat.lastSentByMeAt` (`Models.swift:285-291`) and `PulseEntry.byOutreach` (`PulseHomeView.swift:433-446`) currently sort Pulse primarily by who *you* most recently sent a log or message to — a friend who texts or sends you a log without you replying does **not** currently move up at all.

The reason: `Chat.lastActivityAt` (`Models.swift:271-275`) was meant to be the any-party signal, and it correctly is for logs (clips sync in regardless of author), but it is **not** currently bidirectional for text — it only reads the legacy local `Message` model, and real Stream messages never become local `Message` rows (per the comment at `Models.swift:191-198`). There's a `lastOutgoingMessageAt` mechanism (`Models.swift:293-299`, fed by `OutgoingMessageObserver` in `StreamThreadView.swift:519-543`) that patches in *your* outgoing Stream sends specifically, but there is no counterpart recording when a Stream message *arrives* from a friend. So today, a friend texting you (with no video log attached) updates nothing Pulse's sort or unread logic looks at.

**Fix — three parts:**

1. Add an incoming counterpart to the existing outgoing recorder: a `lastIncomingMessageAt: Date?` field on `Chat` (next to `lastOutgoingMessageAt`, `Models.swift:293-299`), stamped by a small analog of `OutgoingMessageObserver` (`StreamThreadView.swift:519-543`) that captures message inserts where `!message.isSentByCurrentUser` instead of `message.isSentByCurrentUser` (the existing filter at line 538) — same mechanism, opposite direction.
2. Fold `lastIncomingMessageAt` into `Chat.lastActivityAt`'s `max(...)` (`Models.swift:271-275`) alongside clips/messages/createdAt, so it becomes genuinely any-party for both logs and Stream text, not just logs.
3. In `PulseEntry.byOutreach` (`PulseHomeView.swift:433-446`), switch the primary sort key from `sentByMeAt` to `activityAt` (now correctly any-party after step 2) so a friend who sends you something also bumps to the top, not just friends you've reached out to. This intentionally reverses the reasoning documented in the comments at `Models.swift:281-284` and `PulseHomeView.swift:422-431` — update/remove those comments since they currently justify the outgoing-only behavior this fix is replacing.

This also fixes half of item 4 below (the unread indicator) as a side effect, since both currently depend on the same incomplete `lastActivityAt` signal — do this fix first, since item 4 builds directly on it.

## 4 — Unread message indicator never lights up for incoming text messages

`Chat.hasUnread` (`Models.swift:310-313`) is `lastActivityAt > (lastReadAt ?? .distantPast)`, stamped via `Chat.markRead()` on chat-open (`ChatDrawerView.swift:135-138,198-201`). This logic itself is sound and precise — it's driven purely by real timestamps, not by unrelated data churn, sync completions, or app-opens, so it doesn't false-positive on reactions or your own sent messages (`OutgoingMessageObserver` already filters those out). Stream's own `channel.unreadCount`/read-state isn't used at all here; this is entirely custom-built off `lastActivityAt`.

The bug is under-firing, not over-firing, and it's the same root cause as item 3: since `lastActivityAt` currently never sees incoming Stream messages, **a friend's text message never lights the unread dot at all** — the indicator only ever fires off a new video clip today. Once item 3's fix lands (`lastIncomingMessageAt` folded into `lastActivityAt`), `hasUnread`/`markRead` (`Models.swift:310-319`) need no further changes — they'll correctly extend to cover incoming Stream DMs automatically, since they already key off `lastActivityAt` generically. **Implement item 3 first; this item is verification that it also fixes the unread indicator, not a separate code change** — but call this out explicitly if it doesn't resolve on its own, since it's worth confirming rather than assuming.

## 5 — All Friends feed: thin black borders on left/right of each video

Same root issue as item 2 used to have, but in a screen that never got the aspect-ratio fix applied. `AllFriendsFeedView.row(for:height:)` (`StackedClipViews.swift:951-995`) sets only a fixed row height (`rowHeight = proxy.size.height / Self.rowsPerScreen`, line 900) and takes the full available width — no `.aspectRatio(_:contentMode:)` at all, unlike `pairPage`/`groupCard`, which now correctly size to the clip's shape. `StackedClipPane` is passed `contentMode: .fit`, so the video letterboxes inside this fixed-formula box, and `Color.black` fills the leftover space whenever the clip's true aspect ratio doesn't exactly match `width / rowHeight` — producing the thin side bars from image 3.

**Fix:** apply the same aspect-ratio-matched sizing already used in `pairPage`/`groupCard` to this row, using the clip's real aspect ratio (via whatever mechanism those two screens now use — if that was implemented as a stored `videoAspectRatio` on `Clip`, reuse the same field here) instead of the fixed `width / rowHeight` formula. Match image 3's reference — no visible black bars, the video fills its row edge-to-edge on the sides.

## 6 — Log screens force dark background even in light mode

Not a single global switch to flip — dark appearance is applied per-screen via `.preferredColorScheme(.dark)` on 18 separate full-screen covers/sheets, including all four log-viewing feeds in `StackedClipViews.swift` (`FriendPairFeedView` line 355, `EmojiReactionPicker` line 687, `GroupClipFeedView` line 762, `AllFriendsFeedView` line 932), plus `CameraCaptureView.swift:486`, `PostCaptureReview.swift:163`, `LogPlayerView.swift:50`, `DailyVlogView.swift:96`, `MontageView.swift:108`, `UserProfileView.swift:1119`, four spots in `NichePlacesView.swift`, `BookmarkedPlacesView.swift:43`, `AvatarCropView.swift:53`, and `PulseFeedView.swift:54,554`.

It's compounded by hardcoded raw colors layered on top, independent of the forced scheme — `StackedClipViews.swift` line 87 (`Color.black` backdrop in `StackedClipPane`), lines 108-109 (`.black.opacity(...)` legibility gradient), line 1006 (`Color.black` in `emptySlot`), and `.foregroundStyle(.white)` / `.black.opacity()` chip/badge backgrounds scattered through lines 164-232 and 492-493, instead of `Theme`'s adaptive tokens.

**The infrastructure to fix this already exists** — `Theme.swift` has a full light/dark adaptive system: a `Color(light:dark:)` initializer (lines 11-25) and adaptive tokens already defined (`Theme.base`, `Theme.baseElevated`, `Theme.textPrimary`/`textSecondary`/`textTertiary`, `Theme.hairline`, the `Theme.accent` family, `Theme.mint`/`amber`, `Theme.glassTint`/`glassRimTop`/`glassRimBottom`). None of it is used in the log-viewing panes today.

**Fix:** remove `.preferredColorScheme(.dark)` from the four log-viewing feed screens listed above (leave it in place on screens where it's deliberate — e.g. the camera/capture flow may legitimately want to always stay dark for exposure/legibility reasons; use judgment per screen rather than a blanket removal across all 18 sites, but the four log-viewing feeds are the ones this request is specifically about). Then swap the hardcoded `Color.black`/`.white`/`.black.opacity(...)` backgrounds and chrome in those screens for the matching `Theme` tokens, so the UI actually follows system appearance. Note: the video content itself sitting on a black letterbox stage is fine to keep black regardless of appearance mode (that's normal for video playback, matching how Photos/most video apps behave) — this fix is about the surrounding chrome/background, not forcing video letterboxing to go white in light mode.

## 7 — Audio overlap: a log's audio keeps playing after navigating to a different one

Root cause: `StackedClipPane` (`StackedClipViews.swift:90`) hardcodes `ClipView(clip: clip, isActive: true, ...)` — every pane it renders is always "active," with no real signal for whether it's the one actually on screen. This is true across all three feeds (`FriendPairFeedView`, `GroupClipFeedView`, `AllFriendsFeedView`).

Two of the three feeds (`GroupClipFeedView` lines 732-751, `AllFriendsFeedView` lines 906-917) show several cards on screen simultaneously in a `LazyVStack` with no paging — multiple videos playing/audible at once may be intentional there. The real bug is in `FriendPairFeedView`'s paged scroll (lines 313-337): each page is a distinct SwiftUI identity (`.id(clip.id)`, line 102), so swiping to a new friend doesn't reuse the previous `PlayerContainerView` — it mounts a *new* view for the new clip while the old pane's `PlayerContainerView` stays alive in the lazy stack's render buffer, its player never told to pause. `PlayerContainerView.configure(...)` (`ClipView.swift:262-296`) only tears down a player when the *same* view instance is reused for a new URL (lines 278-280) — that path never fires here, since paging creates a new view rather than reusing one. There's no `onDisappear`-based pause scoped to an individual pane anywhere; the only `onDisappear` calls stop the shared `ClipSyncClock` for the whole screen (lines 354, 761, 931), which doesn't reach panes that fell out of the current index but are still resident in the lazy stack.

**Fix:** thread a real "is this the pane currently on screen" signal into `StackedClipPane`/`ClipView` — comparing against the current scroll index/id, replacing the literal `true` at `StackedClipViews.swift:90` — and call `PlayerContainerView.setPlaying(false)` (lines 338-341) when a pane loses that state, not just on full-screen teardown. This is a targeted lifecycle fix, not a rebuild — `setPlaying`/`setMuted` already exist and work correctly; they're just never told to fire per-pane today.

## 8 — Double-tap to flip camera, and continue recording across a flip mid-video

**Double-tap gesture:** doesn't exist yet. The viewfinder currently has exactly one tap gesture — a single tap for focus (`CameraCaptureView.swift:541`, `.onTapGesture { location in focus(at: location, in: geo.size) }`). Adding `.onTapGesture(count: 2)` naively will collide with this — SwiftUI doesn't automatically disambiguate a single-tap gesture from a double-tap on the same view. Use `.onTapGesture(count: 2, ...)` combined with a timing-based exclusivity approach (e.g. `ExclusiveGesture`, or delaying the single-tap focus action briefly to see if a second tap follows) so a double-tap triggers the flip without also firing a spurious focus-tap first.

**Flip mid-recording:** confirmed — `CameraModel.flip()` (`CameraCaptureView.swift:1835-1848`) has zero recording-state awareness today; nothing calls `stopVideo()`/`stopRecording()` as part of it, and it isn't needed to add that guard, because the underlying mechanics already support what you want. `flip()` reconfigures the session (`session.beginConfiguration()`/removes and re-adds device inputs, lines 1691-1706) but leaves `movieOutput` attached throughout — it's only re-added if not already present. So the movie file output keeps writing to the same file across the input swap already; recording doesn't currently stop because of an explicit "stop" call, so the actual reported symptom ("the video just ends") is more likely either a UI-side issue (the recording *indicator*/timer resetting or the app treating a flip as implicitly ending the session) or a runtime interruption during the brief `beginConfiguration()`/`commitConfiguration()` window rather than a fundamental architecture gap.

**Fix:** wire the double-tap gesture to `camera.flip()` (same action as the existing `flipButton`, lines 757-765) with the disambiguation described above. For the recording-continues-across-flip behavior, since `movieOutput` already survives the reconfiguration, focus verification on: confirming no UI state elsewhere (e.g. `isRecording`/`recordClip` state) is being reset or treated as "recording ended" purely because `flip()` was called, and testing for `AVCaptureSessionWasInterrupted`/runtime error notifications firing during an active recording's flip — if a brief interruption is naturally occurring during the input swap, that's the actual fix target (handling the interruption gracefully / minimizing its duration), not a bigger rebuild of the recording pipeline.

---

## Verification

- **1:** delete a Place video from your profile, confirm it also disappears from the Places feed and Niche/Bookmarked views immediately, without needing to reinstall or clear local data.
- **2:** view the friend-pairing screen with two stacked logs — confirm no small redundant time badge, confirm the reaction and reply buttons sit correctly on the video matching image 2's layout, and confirm the caption appears directly under the time stamp both in the post-capture preview and after the log is actually sent and viewed.
- **3:** have a friend send you a log or a message without you replying, and confirm they jump to the top of Pulse; confirm sending to a friend still bumps them to the top too (both directions work).
- **4:** have a friend send you a message, confirm the unread indicator lights up for that chat; open it, confirm the indicator clears.
- **5:** open All Friends and confirm no visible black bars on the sides of any video.
- **6:** switch the phone to light mode and confirm the log-viewing screens' background/chrome turns light, not just the video stage; confirm dark mode still looks correct too.
- **7:** page through several friends in a row quickly on the friend-pairing screen and confirm only the currently-viewed video's audio is ever audible — no lingering audio from a previous pane.
- **8:** double-tap the camera preview and confirm it flips cameras without also triggering a stray focus tap; start recording, flip mid-recording, and confirm the recording continues on the new camera instead of ending.
