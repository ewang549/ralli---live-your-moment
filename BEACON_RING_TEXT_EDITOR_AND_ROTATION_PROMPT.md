# Fix prompt: host ring clipped on Beacons, post-capture text/sticker/draw editing, choppy rotation animation

Three grounded fixes.

---

## 1 — Host's avatar ring is clipped on the Beacon participants list

`GlassKit.swift`'s `GlassOrbAvatar` (lines 118-168) draws the "host" ring as an overlay with **negative padding**, deliberately painting it *outside* the avatar's own declared frame:

```swift
.frame(width: size, height: size)
.clipShape(Circle())
.overlay {
    if isActive {
        Circle()
            .strokeBorder(Theme.accent, lineWidth: max(1.5, size * 0.05))
            .padding(-size * 0.08)
    }
}
```

The view still only reports `size x size` to its parent for layout — the ring's actual paint area extends past that, but nothing reserves the extra space. Both call sites feed this straight into containers that clip to exactly that reported size:

- `BeaconsFeedView.swift:459-460` (header host avatar, `size: 40`)
- `BeaconsFeedView.swift:685-702` (attendee roster inside a horizontal `ScrollView`, `size: 52`)

`ScrollView` clips its content to the bounds it computes from the laid-out subview sizes (52×52 / 40×40 — not the ring's overflow), so the top/leading edge of the ring gets cut off by the scroll container edge. There's no explicit `.clipped()` causing this — it's `ScrollView`'s implicit bounds clipping colliding with a ring that was drawn outside its own layout box.

**Fix:** reserve room for the ring at both call sites, rather than changing `GlassOrbAvatar` itself (other non-host avatars elsewhere may rely on its current sizing). Wrap the call in a padding that matches the ring's overflow:

```swift
GlassOrbAvatar(friend: host, size: 40, isActive: true)
    .padding(40 * 0.08)   // reserves the ring's negative-padding overflow

GlassOrbAvatar(friend: friend, size: 52, isActive: friend.id == beacon.host?.id)
    .padding(friend.id == beacon.host?.id ? 52 * 0.08 : 0)
```

(Only pad when `isActive`/host, so non-host avatars in the roster don't gain unnecessary spacing.) Confirm the surrounding `HStack`/`VStack` spacing still looks right once this padding is added — nudge `spacing` down slightly if the roster now looks too loose.

## 2 — Post-capture Text tool: color picker works, but you can't actually type; no tap-out for Sticker/Draw

All in `PostCaptureReview.swift`.

**(a) Text — never actually focuses the keyboard.** `addText()` (lines 457-465) sets `editingText = item` to bring up the text editor (lines 397-406), but there is **no `@FocusState` anywhere in this file** and no `.focused()` modifier on the `TextField`. SwiftUI doesn't auto-focus a `TextField` just because it appears — without an explicit focus binding, the keyboard never comes up and nothing you type registers, which is exactly the "pick a color, then can't type" symptom.

Fix:

```swift
@FocusState private var textFieldFocused: Bool
```

```swift
TextField("", text: bindingForText(item.id)?.text ?? .constant(""), axis: .vertical)
    .focused($textFieldFocused)
    .font(.system(size: 30, weight: .bold, design: .rounded))
    ...
```

Set `textFieldFocused = true` at both places that start a text edit: `addText()` (line ~460) and the double-tap-to-re-edit path (line ~177, `onDoubleTap: { editingText = item }`). Dismissal is already correctly implemented for text — background tap (line 400, `onTapGesture { commitText() }`) and the "Done" button (lines 428-433) both already call `commitText()`. Just add `textFieldFocused = false` there too so the keyboard reliably drops when the editor closes.

**(b) Draw mode — no way to tap out.** `drawingSurface` (lines 187-205) is a full-screen `Color.clear` whose only gesture is the drag-to-draw `DragGesture` — there is no tap gesture on it, so the only way out of draw mode right now is re-tapping the "Draw" rail icon itself. Add a tap gesture alongside the existing drag gesture that exits draw mode:

```swift
private var drawingSurface: some View {
    Color.clear
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { ... }
                .onEnded { ... }
        )
        .simultaneousGesture(
            TapGesture().onEnded { tool = .none }
        )
}
```

Use `simultaneousGesture` (not a plain `.onTapGesture`) so a quick tap-without-drag exits, while an actual drawing stroke (which starts as a drag) isn't swallowed or misread as a tap.

**Sticker/selection — the tray itself already dismisses correctly** (`stickerTray`, lines 388-391, background tap already sets `showStickerTray = false`). What's actually missing: once a sticker or text item is placed, it's auto-selected (`selectedID` gets set), and there's no way to tap elsewhere on the canvas to clear that selection — the delete-trash icon (lines 218-221, `if selectedID != nil`) just stays up. Add a background tap catcher beneath the overlay layer that clears selection:

```swift
Color.clear
    .contentShape(Rectangle())
    .onTapGesture { selectedID = nil }
```

positioned below `overlayLayer` (lines 164-185) in the z-stack so it only catches taps that miss an actual sticker/text item (which have their own tap-to-select handling and should take priority).

## 3 — Choppy portrait/landscape rotation animation

`CameraCaptureView.swift`, inside the root `GeometryReader` (line 280):

```swift
.onChange(of: screen.size) { _, newSize in
    safeArea = Self.windowSafeArea()
    camera.reapplyRotation()
    let landscape = newSize.width > newSize.height
    guard landscape != isLandscapeReady else { return }
    withAnimation(.easeOut(duration: 0.22)) { isLandscapeReady = landscape }
}
```

This drives the chrome fade-in (`ControlsReady`, lines 608-615 — `.opacity(ready ? 1 : 0)` on `topBand`/`bottomBand`/`shutterColumn`). The existing code comment (lines 248-254) explains this was already an attempt to fix an earlier flicker by keying off "real layout geometry," on the theory that `screen.size` is the one signal that tracks when rotation is done. It isn't, quite: `GeometryReader`'s `screen.size` updates as soon as the interface's *logical* bounds change, which UIKit reports early in the rotation transition — well before the system's own rotation transform/crossfade animation (which runs roughly 0.3–0.4s) has actually finished playing on screen. So the `0.22`s opacity fade fires immediately and runs **concurrently with** the system's own rotation animation instead of after it — two animations stacking on top of each other in the same window, which is what reads as choppy (icons fading in mid-spin rather than only once the phone has visually finished rotating).

**Fix:** stop keying the chrome-reveal animation off `GeometryReader` size changes directly. Gate it on a signal that only flips once the system's rotation transition has actually completed:

```swift
// explogApp.swift ~line 38 — currently a discarded no-op completion:
scene.requestGeometryUpdate(...) { _ in }
```

Wire that completion handler to flip a shared flag (e.g. publish it through the same object that already exposes `screen.size`/`OrientationObserver`, or a simple `@State`/`@Published var rotationSettled = false` passed down) once the geometry update actually finishes, and drive `isLandscapeReady`'s `withAnimation` off *that* instead of off the raw `onChange(of: screen.size)`. If wiring the real completion handler through turns out to be awkward given how `CameraCaptureView` is structured, a pragmatic fallback is a short fixed delay before starting the fade (tuned to roughly the system rotation duration, ~0.35s) via `DispatchQueue.main.asyncAfter` or `Task { try? await Task.sleep(...) }` — less precise than the real completion signal, but still strictly avoids the two animations overlapping. Apply the same reasoning symmetrically for landscape→portrait, not just portrait→landscape, since `isLandscapeReady` already toggles both directions through this same code path.

---

## Verification

- **1:** open a Beacon's detail sheet and the feed card; confirm the host's colored ring is fully visible with no clipped edge, in both the header avatar and the attendee roster.
- **2:** capture a log, tap Text, pick a color, and confirm the keyboard appears and typing actually works; confirm tapping the background or "Done" dismisses it and drops the keyboard. Enter draw mode, draw a stroke, then tap (without dragging) on empty canvas and confirm it exits draw mode. Place a sticker or text item, confirm it's selected (trash icon visible), then tap empty canvas and confirm the selection clears and the trash icon disappears.
- **3:** rotate the phone from portrait to landscape inside the camera screen and confirm the controls only fade in once the phone has visually finished rotating, not while it's still mid-rotation; confirm the same going back to portrait.
