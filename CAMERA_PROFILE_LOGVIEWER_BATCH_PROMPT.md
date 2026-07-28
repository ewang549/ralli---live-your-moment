# Fix prompt: profile photo crop, log-viewer sizing, caption flow, fonts, stickers, place nav, landscape lock, screen flash

Twelve items, grounded in the current code. Read item 6 (overlay mismatch) carefully before starting — the actual cause isn't what it looks like from the outside, and the fix scope depends on understanding it correctly.

---

## 1 — Profile picture: no cropping exists at all

`ProfilePhotoPicker.swift`'s `AvatarPhotoButton` (lines 29-71) goes straight from the photo picker callback to `AvatarPhotoStore.save(image)` (line 9) with zero crop step. Display then applies a blind center-crop: `GlassOrbAvatar` (`GlassKit.swift:145-156`) renders with `.scaledToFill()` inside a circular clip — whatever's in the center of the original photo survives, with no way for the user to reframe an off-center face.

**Fix:** insert a crop step between picker selection and `AvatarPhotoStore.save`. `PHPickerViewController`/`PhotosPicker` don't include built-in cropping, so add a simple crop view (drag-to-reposition + pinch-to-zoom over a circular mask, matching what `GlassOrbAvatar` will ultimately show) between selection and save — this is a standard, self-contained addition; a `UIViewControllerRepresentable` wrapping `PHPickerViewController` combined with a basic custom crop overlay (or a lightweight crop library if the team wants to avoid building the gesture math from scratch) both work.

**Note on quality — not actually a bug:** resolution is fine as-is; `AvatarPhotoStore.save` (`ProfilePhotoPicker.swift:7-19`) uploads the full picked resolution at `0.85` JPEG quality, no forced downscale. If avatars still look soft in the app, it's almost certainly the missing crop (users end up with an unintentionally bad frame, not genuinely low resolution) rather than a compression problem. No change needed here beyond the crop step — don't "fix" quality separately, there's nothing to fix.

## 2 — Log-viewer square container causes letterbox borders

Real prerequisite gap: `Clip` (`Models.swift:377-436`) stores no aspect-ratio/dimension field, and `AVAsset`'s natural size is only known once the asset loads — after layout has already happened. So sizing the container to match the video's true shape needs one of two approaches:

- **(a) Persist aspect ratio at capture time.** Add a `videoAspectRatio: Double` (or width/height) field to `Clip`, populated once at capture/save time (the app already knows the recording resolution right after `AVCaptureSession` finishes), then use that stored value to size the container ahead of render — no async wait, no pop-in.
- **(b) Defer container sizing until the player reports `naturalSize`,** then resize/animate the frame. Simpler to wire but causes a visible frame-size pop-in as the video loads — worse UX than (a).

**Recommend (a).** Once the aspect ratio is available, update the two square-ish containers to size themselves from it instead of dividing available space evenly:

- `FriendPairFeedView.pairPage(for:height:)` (`StackedClipViews.swift:359-427`) — currently splits `usable` height in half regardless of clip shape (lines 362-370).
- `GroupClipFeedView.groupCard(entry:width:height:)` (`StackedClipViews.swift:764-788`) — same pattern (lines 712-715).

Both already correctly pass `contentMode: .fit` — this fix is about the container's frame math, not the content mode.

## 3 — Remove the draggable Text tool from the post-capture editor

In `PostCaptureReview.swift`, delete: the `TextItem` struct (lines 689-696), `@State private var texts` (line 40), `editingText` (49), `@FocusState textFieldFocused` (68), the "Text" rail button (line 303) and its `addText()` handler (578-586), `textEditor(for:)` (510-558) and its helpers (`commitText()` 609-617, `bindingForText`, `currentTextColor`), and the two `ForEach($texts...)` blocks that render it (`overlayLayer` 216-227, `staticOverlays` 654-661). Strip the now-unused `texts` references out of `hasOverlays` (78-82) and `deleteSelected()` (603-607). Stickers and drawing are untouched — only the Text tool and its rail icon go away.

## 4 — Caption moves to right after capture; `SendToFriendsView` becomes a read-only preview with a back-to-edit button

Add a fixed (non-draggable) caption field to `PostCaptureReview.swift`: `@State private var caption: String = ""`, shown as a `TextField` positioned directly under `LiveHourOverlay()` (near line 108-109), auto-focused on appear. This is a fixed-position field, not a movable overlay item — no drag/pinch/rotate, unlike the old Text tool. This is the **only** place the caption gets typed or edited.

Thread the final value through as `initialLabel` into `SendToFriendsView`/`PublicPlacePostView` at the call site around lines 151-152 (a prior round deliberately decoupled captions from this hand-off — the comment at lines 139-145 explains captions used to *not* seed from here; that decoupling gets reversed by this change, which is intentional here). This keeps the caption as `Clip.label`, populated earlier in the flow.

**`SendToFriendsView` (`ShareLogViews.swift`) loses its editable caption `TextField` (lines 80-86) entirely.** Replace it with a **read-only preview** of the log exactly as it will be sent — the video/photo with the time stamp and caption overlaid on top (reuse `LogPreviewCard`, lines 475-502, which already renders this preview; just remove whatever there currently lets `label` be edited inline and render `caption` as static text instead). Add a back button on this screen that returns to `PostCaptureReview` with the current caption/media state intact, so the user can adjust the caption (or stickers/drawing) and come forward again — this needs the caption (and any overlay state) to survive the round-trip rather than resetting, so keep it in whatever state container already threads `media`/`caption` between these two views rather than treating `PostCaptureReview` as a one-way handoff.

## 5 — Consistent font for time text and captions

The on-video hour stamp is already consistent everywhere it's burned/shown live — one shared `HourOverlay`/`LiveHourOverlay` component (`HourOverlay.swift:14-29`, `.system(size: 34, weight: .heavy, design: .rounded).monospacedDigit()`) drives the camera viewfinder, post-capture review, and the stacked-feed playback pane. No change needed there — it already matches the reference image's look (bold, rounded, monospaced digits).

The caption font is the inconsistent one — six different call sites currently pick their own size/weight for `clip.label` (`UserProfileView.swift:1053`, `MontageView.swift:67`, `PulseFeedView.swift:446`, `LogPlayerView.swift:182`, `NichePlacesView.swift:429`, `NichePlacesView.swift:824`). Standardize all of them on `.system(size: 17, weight: .semibold, design: .rounded)` — matching `PulseFeedView.swift:446`, the closest existing match to `HourOverlay`'s rounded design — and use that same style for the new caption field from item 4, sized down as requested (e.g. `size: 15` instead of `17`, still `.semibold, design: .rounded`) so it visually reads as "part of the same family" as the time stamp, just smaller and secondary.

Also worth tidying while in this area (lower priority, same root inconsistency): the smaller ad-hoc hour readouts at `StackedClipViews.swift:208-209`, `PulseFeedView.swift:334-335`, and `MontageView.swift:70` each use their own size/weight for the same clock data — not urgent, but flag for consistency if time allows.

## 6 — MAJOR, DECIDED: the video must never be cropped anywhere in the app — only ever shown smaller, never cut

Product decision, not optional: **every surface that shows a log — Pulse, the stacked feed, profile, All Friends, Daily Recap, everywhere — must show the entire frame, always.** A surface is allowed to display the video smaller than another surface, but never allowed to crop it. And wherever a surface is smaller than the video's natural shape and has to letterbox, the letterbox/border must exactly match the video's own shape — no mismatched black bars that don't line up with the video's actual edges (that's what item 2 already fixes: containers sized to the clip's real aspect ratio instead of an arbitrary square/box).

This resolves the ambiguity from the original investigation: the mechanism was `ClipView`'s default `contentMode: .fill` (`ClipView.swift:16`) being used by most playback surfaces (Pulse, feed, profile) while the editor uses `.fit` — meaning most of the app was cropping the video and its burned-in overlay together, which is exactly what's forbidden now.

**Fix — apply option (b) from the original investigation, now decided as the direction:**

1. **Switch every `ClipView(clip:)` call site that currently relies on the `.fill` default to `contentMode: .fit` explicitly.** This is a real find-and-fix pass — grep every call site of `ClipView(clip:` across `PulseFeedView.swift`, `StackedClipViews.swift`, `UserProfileView.swift`, `NichePlacesView.swift`, and anywhere else a clip renders, and confirm each one passes `.fit` (or already does, like `DailyVlogView.swift:268` and the `AllFriendsFeedView` row from an earlier fix). Leave `ClipView`'s own default as-is if other non-log use cases still want `.fill` — this is about auditing and fixing call sites, not changing the shared default and hoping nothing else was relying on it.
2. **Every container that now shows the full frame must be sized to the clip's actual aspect ratio** (this is item 2's fix, and it now applies universally, not just to the two screens originally called out) — use the same `videoAspectRatio` field on `Clip` from item 2 to size every log-viewing container, so that wherever letterboxing is unavoidable (because the surface's natural shape doesn't match the video), the border reads as a deliberate, evenly-matched frame rather than an arbitrary crop-box mismatch.
3. **Confirm overlay burn-in stays correct under this change.** `OverlayBurnIn.swift`'s `burnVideo` (lines 212-252) already bakes stickers/drawing directly into the video's pixels, scaled and positioned against the video's true native dimensions — once every playback surface displays the *entire* frame (uniformly scaled, never cropped), the baked-in overlay pixels will scale and reposition together with the video correctly by construction, since they're part of the same flattened image. The "sticker ends up bigger and shifted" symptom was a byproduct of different surfaces cropping different parts of the same frame post-burn-in — once cropping is eliminated everywhere (step 1) and containers are properly aspect-matched (step 2), this resolves as a consequence rather than needing a separate overlay-specific fix.

## 7 — Mute audio option for video logs (video only, not photos)

Every video clip currently records audio unconditionally — a mic input is always added at capture time (`CameraCaptureView.swift`, `configure(position:maxDuration:)`, the movie output records both video and audio tracks together with no existing toggle).

**Add a `Clip.isMuted: Bool` field (default `false`) and a playback-time mute, not a re-encode.** This is the simplest, fully reversible approach — no export pass, no touching the recorded file:

- Add `isMuted: Bool = false` to `Clip` (`Models.swift`).
- In `ClipView.swift`'s `install(asset:videoGravity:)` (~line 280), change the unconditional `player.isMuted = false` to `player.isMuted = clip.isMuted`.
- Add a mute toggle button to `PostCaptureReview.swift`, gated to video only (mirror the existing `if media.kind != .video { ... }` pattern used to hide "Save to Photos" for video at line 275 — this is the inverse: `if media.kind == .video { ... }`), placed in the top controls row or creative rail near the other icon buttons (lines 264-312). Toggling it sets the in-progress `Clip`'s `isMuted` before send.

Don't route this through `OverlayBurnIn`'s export pass — that only runs conditionally when overlays exist, and forcing an export just to strip audio on overlay-free clips would add unnecessary latency for no benefit over a simple playback flag.

## 8 — Full emoji range for stickers

`PostCaptureReview.swift:73` hardcodes a 14-emoji array (`emojiTray`) rendered in a 7-column grid (lines 477-506). There's no bundled emoji-picker library in the project (`Package.resolved` only has Firebase/Ads/Stream), and iOS has no public API to invoke the system emoji keyboard as a standalone picker — this needs a custom-built full-Unicode-emoji grid (categories + optionally search), built from scratch or via a small third-party Swift emoji-picker package if the team wants to avoid hand-rolling the Unicode emoji dataset and category grouping. Replace the `stickerTray`'s data source with that new component; `dropSticker(_:)` (lines 594-600) doesn't need to change, since it already accepts an arbitrary emoji string.

## 9 — Tap a place's video in its highlights → open it in the Places tab

`SpotDetailView` (`NichePlacesView.swift:770-865`) has a horizontal clip strip ("VISITOR NOTES," lines 810-835) that's explicitly non-interactive today — the code comment at 818-820 says thumbnails intentionally stay paused since they're "not the focus of this sheet." No tap handler exists. Two things need to change:

1. Wrap each `ClipMediaView` in the strip with a tap handler.
2. `SpotDetailView` is currently `.sheet`-presented (from line 324), not hosted inside the Places tab's own navigation — so a tap needs to dismiss the sheet and drive the Places tab's navigation state to focus that specific clip, not just open another sheet on top. Check how `UserProfileView`'s `openHighlight` (from an earlier round) handles the equivalent "jump to Places tab focused on a clip" navigation — it already does this via `router.focusedPlaceClipId`; reuse that same router mechanism here rather than building a second path.

This also directly supports the shared-place flow from an earlier prompt (`PLACE_SHARE_TEXT_OVERLAY_REACTIONS_SWIPE_NOTIFS_PROMPT.md`) — once a friend receives a shared place and opens its detail sheet, this fix is what makes the videos there actually tappable into the real Places tab.

## 10 — Camera should open in landscape even with system rotation lock on

The app already has a mechanism specifically built to force landscape regardless of the app's own portrait-only default — `InterfaceOrientationLock` (`explogApp.swift:18-64`), invoked from `CameraCaptureView.swift:417,449`. What's unconfirmed: whether `mask` is actually being set to `.landscape` (excluding portrait) rather than a union that still includes portrait, and whether the call happens early enough. Per Apple's own documented behavior, `requestGeometryUpdate(.iOS(interfaceOrientations:))` combined with `setNeedsUpdateOfSupportedInterfaceOrientations()` (already present at `explogApp.swift:38,48`) is the sanctioned way to override the hardware rotation lock for a specific presentation — so the right mechanism may already be in place and just needs verification/tightening rather than a rebuild:

1. Confirm `InterfaceOrientationLock.lockLandscape()`'s `mask` value excludes `.portrait`/`.portraitUpsideDown` entirely (not just adds landscape alongside it).
2. Test specifically with the physical rotation-lock switch enabled (not just the in-app orientation logic) — this is the one condition the current code has never been verified against.
3. If it still doesn't override the hardware lock after confirming (1), this is a known constrained area of iOS (there's no public API to detect or force past the hardware switch beyond the `requestGeometryUpdate` pattern already in use) — worth reporting back rather than searching for a nonexistent stronger API.

## 11 — Front-camera "screen flash" (white ring with brightness/thickness control)

Confirmed: no screen-flash concept exists anywhere. Today, tapping flash while on the front camera is a near-total no-op — `applyTorch()` (`CameraCaptureView.swift:1805-1810`) guards on `device.hasTorch`, which front cameras don't have, and the front photo output typically doesn't support flash modes either, so the button does effectively nothing visible.

**Build from scratch:**
1. A new overlay view — a ring or full-white glow at the screen edges — composited above the camera preview.
2. State to drive it: gate visibility on `camera.isFrontCamera && camera.flashMode != .off` (both already exist — `isFrontCamera` at line 1572/1672, `flashMode` at 1522).
3. New `@Published` properties for brightness and ring thickness (0-1 range each is fine), with a `Slider` surfaced near the flash button (`flashButton`, lines 752-769) — only shown while the front camera + screen-flash mode is active.
4. Brightness can drive either the overlay's opacity or `UIScreen.main.brightness` directly (opacity is simpler and reversible; driving system brightness affects the whole device and needs to be restored on exit — opacity is the safer default unless a genuinely brighter light output is needed).

## 12 — Remove visible hour-navigation arrows, add swipe alongside tap

`EdgeStepZones` (`HourAxis.swift:76-141`) renders actual SF Symbol chevrons (`chevron.left`/`chevron.right`, lines 94-108, drawn at lines 118-125) inside quarter-screen tap zones, dim at rest (18% opacity) and flashing brighter on tap. No `DragGesture` exists anywhere for hour navigation (confirmed zero matches in `HourAxis.swift`/`StackedClipViews.swift`).

**Fix:** remove the `Image(systemName: chevron)` rendering (the visual glyph, part of lines 118-125) while keeping the tappable zones and `onTapGesture` handling exactly as-is — navigation still works by tap, just without the visible arrow icons. Add a `DragGesture` (as a sibling modifier on the pane, or wrapping `EdgeStepZones`) that calls the same `onBack`/`onForward` closures based on horizontal `translation.width` sign and a reasonable distance threshold (e.g. >60pt), so swipe works everywhere tap already does — `StackedClipViews.swift:120-123`, `StackedClipViews.swift:988`, and `DailyVlogView.swift:274` all use this same shared component, so the fix applies everywhere at once.

## 13 — Remove the Boomerang capture mode

Confirmed: Boomerang is unimplemented dead labeling, not a real feature — it's fully aliased to Video everywhere in the code, with no actual forward-then-reverse loop or burst capture logic anywhere in the repo. Safe to remove cleanly, all in `CameraCaptureView.swift`:

1. Delete `case boomerang` from the `CaptureMode` enum (line 54) and its `.title` case (line 61) — update the doc comment at line 51, which incorrectly claims boomerang "fires a short looping burst."
2. `modeStrip` (lines 924-960) iterates `CaptureMode.allCases`, so the Photo/Boomerang/Video pill row updates automatically once the case is gone — no separate UI change needed there.
3. Drop `.boomerang` from the `case .video, .boomerang:` match in the shutter gesture handling (line 1243), leaving just `.video`.
4. Update the doc comments at lines 983/1222 that reference boomerang alongside video.

Nothing else in the recording or playback path branches on `captureMode` beyond checking `== .photo`, so no other code changes are needed.

---

## Verification

- **1:** pick an off-center photo for your profile picture, confirm you can crop/reposition it before it saves.
- **2:** view a landscape log on the friend-pairing and group screens; confirm the card itself is shaped like the video with no black bars, not just the video letterboxed inside a square card.
- **3/4:** capture a video, confirm there's no more draggable Text tool, and confirm a caption field appears immediately, positioned smaller and directly under the time stamp. Advance to the send screen and confirm the caption field there is gone, replaced by a read-only preview showing the time + caption overlaid on the media; confirm the back button returns to the post-capture screen with your caption and any stickers/drawing still intact, editable, and that coming forward again reflects your edits in the preview.
- **5:** compare the time stamp and caption font across Pulse, profile, and the stacked feed — confirm they now visually match.
- **6:** place a sticker or draw near the edge of the frame, send it, and view it on every major screen (Pulse, stacked feed, profile, All Friends, Daily Recap) — confirm the full video is visible everywhere with nothing cropped, confirm the sticker/drawing is in the same relative position and scale as the original recording on every screen, and confirm any letterbox borders exactly match the video's own edges rather than looking like a mismatched box.
- **7:** record a video log, confirm a mute toggle is visible only for video (not for a photo log); mute it, send it, and confirm it plays back silently for the recipient; confirm an unmuted video still plays with audio as before.
- **8:** open the sticker tray and confirm the full emoji range is available, not just the original 14.
- **9:** receive a shared place from a friend, open its detail sheet, tap a video in the highlights strip, and confirm it opens that exact video inside the real Places tab.
- **10:** enable the physical rotation-lock switch, open the camera, and confirm it still opens in landscape.
- **11:** switch to the front camera, enable flash, confirm a ring/glow appears with a working brightness/thickness slider.
- **12:** confirm no arrow icons are visible on log-viewing screens, and confirm both tapping the edges and swiping left/right navigate between hours.
- **13:** open the camera and confirm the mode strip only shows Photo and Video — no Boomerang option anywhere.
