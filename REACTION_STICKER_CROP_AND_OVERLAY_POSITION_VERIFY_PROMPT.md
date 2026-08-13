# Fix prompt: reaction chat image is cropped and clunky; verify the emoji/drawing position-mismatch bug is actually still present; swipe-day navigation should keep the hour you were on; All Friends row borders are oversized

Four items. The first is a real, confirmed bug with a clear fix, not yet applied. The second was diagnosed as already fixed everywhere it was checked — but the user has since confirmed on a fresh build that it's still visibly broken, so a real fix (sticker padding) has now been applied directly, plus diagnostic logging to catch anything beyond that. The third is unrelated to overlays — a navigation-feel change for the swipe-between-days gesture. The fourth is a sizing fix specific to the All Friends tab.

---

## 1 — Reaction chat image: crops the log instead of showing it in full, and the emoji sits on a clunky badge

Confirmed: `StreamThreadPoster.postReaction` (`StreamThreadView.swift:626-676`) already does the right *kind* of thing — it composites a real image (via `ReactionSticker.makeImageFile`) and sends it as an attachment, not plain text. The problem is specifically in how that image is built.

**The crop.** `ReactionSticker.composite(clip:emoji:)` (`ReactionSticker.swift:50-91`) explicitly uses `.fill` + `.clipped()` to force the frame into a fixed 540×960 portrait canvas:
```swift
Image(uiImage: frame)
    .resizable()
    // `.fill` for the same reason the feeds use it: a landscape
    // capture in a portrait card is cropped, not letterboxed
    // into two black bars.
    .aspectRatio(contentMode: .fill)
    .frame(width: renderSize.width, height: renderSize.height)
    .clipped()
```
This comment is now stale — every other surface in the app (`ClipView`, `StackedClipPane`, and all their call sites: Pulse, the stacked feeds, profile, Daily Recap, chat drawer, insights) has since been switched to `.fit` as part of a "never crop video" pass. `ReactionSticker` was missed in that sweep and is now the one place in the app that still hard-crops a log instead of showing it in full — which is very likely exactly what reads as "clunky" here, since a landscape capture gets forced into a cropped portrait square that doesn't match how the log looks anywhere else in the app.

**Fix:** switch `ReactionSticker.composite` to `.fit` (letterboxed, full frame, matching every other surface), dropping `.clipped()`. Since the canvas (`renderSize`, line 23) is currently a fixed portrait 540×960, consider whether the canvas itself should become landscape-shaped (matching the log's actual aspect ratio) rather than staying portrait with letterbox bars — a portrait canvas holding a `.fit` landscape video will have visible bars top and bottom, which may look better sized closer to the actual clip's shape instead. Match whatever the rest of the app now does for "a landscape log inside a differently-shaped card" (the All Friends row and friend-pairing screen both size their containers to the clip's real aspect ratio rather than force-fitting into a fixed shape — use the same approach here if practical).

**The emoji placement.** Currently a fixed 108pt emoji in a fixed 26pt-padded dark circular badge, bottom-left (`ReactionSticker.swift:71-84`):
```swift
Text(emoji)
    .font(.system(size: 108))
    .padding(26)
    .background(Circle().fill(.black.opacity(0.55)))
    .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 3))
```
Since `renderSize` is a fixed constant today, this at least has a consistent ratio to the frame — but worth deliberately polishing regardless of the crop fix: consider a softer/larger backing blur (`.ultraThinMaterial` instead of flat black, matching the app's existing glass-surface treatments used elsewhere), and re-evaluate the emoji's size/position once the canvas shape changes to match the clip's real aspect ratio rather than always assuming a fixed portrait frame.

## 2 — Emoji/drawing ends up in a different position and size after sending — two real bugs found and fixed directly, confirmed against an actual before/after screenshot

This was previously diagnosed as a mismatch between the post-capture editor (which always previewed the full, uncropped frame via `.fit`) and playback surfaces that used `.fill` and cropped. That diagnosis turned out to be stale — every `ClipView`/`StackedClipPane` call site across the app already passes `.fit`. The user then confirmed on a genuinely fresh build that stickers were still visibly moving, and sent an actual before-editing / after-sending screenshot pair, which is what pinned the second, real cause down precisely.

**Bug 1, fixed:** `PostCaptureReview.swift`'s `staticOverlays` — the ZStack that `renderOverlayLayer()` snapshots to produce the burned-in overlay — was missing the `.padding(6)` that `MovableOverlay` (the live, draggable/pinchable view you actually interact with while editing) applies *before* its own `.scaleEffect`. Padding gets scaled up along with everything else in the live view but was absent entirely from the static render, so a sticker pinched larger during editing burned in noticeably smaller than what was actually placed. Fixed by adding the matching `.padding(6)` to `staticOverlays`.

**Bug 2, the actual cause of the position shift, fixed:** every sibling in `PostCaptureReview.body`'s ZStack that a sticker's position has to visually agree with — `ClipView` (the media itself), `strokeCanvas` (drawings) — explicitly calls `.ignoresSafeArea()`. The call to `overlayLayer(in:)` (which lays out every sticker via `MovableOverlay`) did not. That's not cosmetic: a view that doesn't ignore the safe area is laid out in a frame inset from the true screen edges by the status bar / Dynamic Island height, so a sticker dragged to a given on-screen point had its `position` recorded relative to *that* smaller, inset frame. `renderOverlayLayer()` then bakes `item.position` into an offscreen canvas sized to the full `UIScreen.main.bounds` — which, being offscreen, has no safe area of its own to account for — so every sticker landed that same inset amount higher than where it was actually placed. Confirmed against the screenshot pair: the emoji was roughly centered vertically on the shot in the editor and jumped up to hug the top edge in the sent log, exactly the direction and rough magnitude a missing top-safe-area inset (~55-90pt depending on device) would produce once the crop-and-stretch in `OverlayBurnIn` scales that fixed offset up against the media's much shorter displayed height.

**Fix:** added `.ignoresSafeArea()` to the `overlayLayer(in: geo.size)` call site (`PostCaptureReview.swift`, in `body`), matching `strokeCanvas` and `drawingSurface`, which already had it. This makes every layer in the ZStack agree on one coordinate space — the true full screen bounds — so a sticker's recorded position means the same thing whether it's being read live or baked into the burned-in file.

**What this doesn't explain:** the user's original report was that *both* stickers and drawings move. Drawings (`strokeCanvas`/`drawingSurface`) already had `.ignoresSafeArea()` on both the live capture surface and the live display, so they shouldn't have this specific bug — the screenshot evidence obtained so far is specifically about the emoji. If a drawing is still confirmed to shift after this fix, that's a separate, not-yet-found bug and needs its own fresh repro.

**Diagnostic logging remains in place** (not removed) in `OverlayBurnIn.swift` and `PostCaptureReview.swift`, under the `os.Logger` `"com.ej.explog"` / `overlay` category — `fittedRect`, `cropToMedia`, `burnVideo`'s first-frame `sourceImage.extent`, `renderOverlayLayer`'s screen size and sticker positions, and `PostCaptureReview.body`'s one-time `geo.size` vs. `UIScreen.main.bounds.size` check — useful if anything still doesn't line up after this fix, particularly for video (the screenshot repro so far looks like a photo) or for drawings specifically.

### Update — a second screenshot pair (this time a video, via TestFlight) shows the same shift, plus what looks like a size change too. Before writing more code, confirm this build actually contains Bug 1 + Bug 2's fixes.

A second before/after pair was sent — editor vs. the "Send log" preview, this time on a video capture (speaker/mute icon visible in the editor, confirming it exercises `burnVideo`, not `burnPhoto`) — via a **TestFlight** build. Measured against both screenshots: the emoji's horizontal position is preserved, but it shifts from roughly the vertical middle of the shot in the editor to hugging the top edge in the sent preview — the same direction and rough shape as Bug 2 above, not a new failure mode. There also appears to be a modest size reduction (the emoji reads as somewhat smaller relative to the video's own width in the sent version), which lines up with what Bug 1 (the missing `.padding(6)`) would produce, and/or is simply an artifact of comparing two screenshots where the video itself is displayed at two very different absolute sizes (full-bleed in the editor vs. a small preview card on the send screen) — a size comparison is only meaningful as *emoji width ÷ video width* in each shot, not raw pixel size, and that ratio is harder to eyeball precisely from a screenshot than position is.

**Before treating this as evidence Bug 1/Bug 2 didn't work: confirm the TestFlight build being tested was actually compiled *after* both fixes landed.** TestFlight builds are archived, uploaded, and processed by Apple separately from a local Xcode run — there is no guarantee the build on the device reflects the latest local source, and this project has a specific, repeated history of a fix being correct in code but tested against a build that predates it. Check the build number / upload timestamp in App Store Connect against when `PostCaptureReview.swift`'s two fixes were made, and if the TestFlight build is older, ship a fresh build and re-test before concluding anything further is broken.

**If a build confirmed to contain both fixes still shows this on video specifically:** the video path (`OverlayBurnIn.burnVideo`) has one piece of geometry photo doesn't: the Core Image composition in `burnVideo` (`OverlayBurnIn.swift`) relies on `request.sourceImage.extent` matching `displaySize` in orientation (documented in the file's own comments as "empirically verified", not just reasoned about) — the `burnVideo:` and `fittedRect:` log lines already in place will show directly whether that assumption is holding for this specific capture. Pull those from the console on a rebuilt, confirmed-fresh test rather than guessing further from screenshots alone.

---

## 3 — Swipe between days should keep the hour you were viewing, not jump to midnight

Unrelated to the overlay work above — a request for how the swipe-to-adjacent-day gesture feels on the hour/day navigation screens (`FriendPairFeedView`, `AllFriendsFeedView`, `DailyVlogView`). If an earlier pass implemented swipe as "jump straight to 00:00 of the adjacent day," that's being superseded here: **swipe should land on the same hour you were on, just on the previous/next day** — swipe forward from 3 PM Tuesday and you land on 3 PM Wednesday, not midnight.

**`HourFeedState.swift`** (shared by `FriendPairFeedView`/`AllFriendsFeedView`): if a `stepToStartOfDay(_ delta:)` method already exists from an earlier pass (jumps to `calendar.startOfDay(for:)` of the target day, discarding hour-of-day), replace its body — or replace the method entirely — with an hour-preserving version:
```swift
/// Jumps a whole day forward/back while keeping the hour-of-day exactly
/// where it was — swipe forward from 3 PM lands on 3 PM the next day, not
/// midnight. Distinct from `jump(toDay:)`, which goes to an arbitrary
/// specific day rather than stepping relative to the current one, and from
/// `step(_:)`'s hour-by-hour tap stepping, which is unrelated and unchanged.
func stepDay(_ delta: Int) {
    guard let target = calendar.date(byAdding: .day, value: delta, to: selectedHour) else { return }
    selectedHour = min(target, Self.floorToHour(.now, calendar: calendar))
}
```
The `min(...)` clamp matters for the same reason it does in `jump(toDay:)`: swiping forward from an hour later than the current time-of-day (e.g. viewing 9 PM yesterday and swiping forward) would otherwise land on a not-yet-happened hour today. Keep whatever `EdgeStepZones`/`onSwipeBack`/`onSwipeForward` wiring already exists — this only changes what the swipe closures call, not how the gesture itself is detected.

**`DailyVlogView.swift`**: if `swipeDay(_:)`/`onStepDay` currently resets `clipIndex = 0` on a day swipe, change it to land on the clip nearest the hour-of-day you were previously viewing instead — capture that hour before switching days, then after the new day's `hourGroups` load, pick the group closest to it (nearest match, since the target day won't necessarily have a clip at that exact hour) rather than always defaulting to the first clip of the day.

---

## 4 — All Friends tab: each row's box is bigger than the log inside it, leaving black borders around every clip

Root cause is in `AllFriendsFeedView.row(for:width:height:)` (`StackedClipViews.swift:1038-1093`) and where its `height` comes from. Each row is forced into a fixed `width × height` box — `width` is the available screen width, but `height` is a flat quarter of the *screen's* height (`rowHeight = proxy.size.height / Self.rowsPerScreen`, line 984), with no relationship at all to the actual shape of the video inside it. Every real capture in this app is landscape (the camera is landscape-only), so a landscape clip `.fit` into a box whose proportions were picked to fit four rows on screen — not to match 16:9 — leaves visible gaps on whichever axis doesn't match, and `StackedClipPane`'s `Color.black` backdrop (`StackedClipViews.swift:105`) fills those gaps. That's the black border the user is seeing around every single row, every hour, whether or not that friend actually logged.

The code comment at lines 1042-1049 explains *why* a uniform box was chosen over sizing each row to its own clip (avoiding a "ragged column of differently-sized cards" when friends' clips aren't all the same shape) — that reasoning is sound, but it's solving a problem that mostly doesn't exist here: since every real log is landscape, sizing the uniform box to *the landscape aspect ratio itself* (instead of an arbitrary screen-height fraction) keeps every row identically shaped **and** removes the border, without reintroducing raggedness.

**Fix:** derive `rowHeight` from `rowWidth` using the capture aspect ratio, instead of dividing the screen height into four fixed slices. Concretely, in `body` (`StackedClipViews.swift:983-987`):
```swift
let rowWidth = (proxy.size.width - 24).safeDimension
// Landscape capture ratio — matches what `.fit` actually shows, so the box
// *is* the clip's shape and there's nothing left for the black backdrop to
// show through as a border.
let rowHeight = (rowWidth * 9.0 / 16.0).safeDimension
```
(Use whichever landscape ratio the camera actually records at — check `CameraCaptureView`'s configured dimensions/`AVCaptureSession` preset rather than assuming 16:9 if it differs.) Drop the now-unused `Self.rowsPerScreen` sizing role, or repurpose it purely for scroll-estimation if it's used elsewhere.

**Empty slots must use the exact same computed size.** `row(for:width:height:)` already applies the same `width`/`height` to both the populated (`StackedClipPane`) and empty (`emptySlot`) branches (lines 1070, 1073) — once `height` itself is aspect-locked rather than a screen fraction, this requirement is satisfied automatically for both, which is exactly the "even if there is no log sent that hour, I want the size the same as if there were one" requirement: a quiet hour's row is the identical box shape as a populated one, just showing `emptySlot`'s surface instead of a clip, with no separate sizing path to keep in sync.

Also check `GroupClipFeedView`(`StackedClipViews.swift:428,474,856`) and `FriendPairFeedView` for the same "fixed-fraction-of-screen-height row" pattern — if either shares it, apply the identical aspect-locked-height fix there for consistency, but only if this prompt's reported issue ("in the all friends tab") is confirmed present on those screens too; don't change a screen that wasn't reported broken without checking it visually first.

---

## Verification

- **1:** react to a friend's landscape log with an emoji and confirm the resulting chat image shows the entire frame (letterboxed if needed, not cropped), with the emoji sitting cleanly on a legible backing rather than looking clunky against the frame's edge.
- **2:** place a sticker and a drawing near the edge of a photo and a video during capture, send both, and confirm they appear in the exact same position and size everywhere the log is viewed (editor, Pulse, profile, the stacked feeds). If a mismatch remains, capture the console output described above before writing another fix.
- **3:** on all three screens, note the hour you're viewing, swipe to the next or previous day, and confirm you land on that same hour on the new day rather than midnight — including when the new day has no log at that exact hour (should land on the nearest one).
- **4:** open the All Friends tab at an hour where several friends have logs and confirm each row's box hugs the clip with no visible black band around it. Scrub to an hour with a mix of populated and empty rows and confirm every row — logged or not — is the exact same size, with no jump in row height as you scrub past hours where different friends did or didn't post.
