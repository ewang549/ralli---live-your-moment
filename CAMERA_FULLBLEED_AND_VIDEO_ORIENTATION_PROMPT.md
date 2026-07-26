# Fix prompt: camera should be full-bleed, and recorded video comes out upside down/mirrored

Two issues. The first is a direction change from the layout just shipped (the letterboxed 16:9 card) — that work isn't wrong, it's just not the look wanted once seen live. The second is a real correctness bug in the rotation math.

Do not touch anything outside what's described here.

---

## 1 — Camera should fill the whole screen, controls floating on top

**Current state** (`CameraCaptureView.swift`, from the last pass): the viewfinder is a bounded, aspect-locked 16:9 card (`viewfinderCard`, ~line 517) sitting inside a black-background screen, with the close button / grid / self-timer / looks / duration in a `topBand` above the card and the mode strip in a `bottomBand` below it — both bands living in the black letterbox margin, not over the live image.

Seen on an actual device (per your screenshot), this reads as a small floating card surrounded by a lot of dead black space, not like a real camera app. The direction now: **the live camera image should fill the entire screen edge-to-edge**, with the controls floating cleanly on top of it as an overlay — the way Snapchat/Instagram/TikTok camera screens actually work, and the way this screen worked before the 16:9-card pass, just with better-organized control spacing this time.

**Fix:**

1. Remove the `.aspectRatio(16.0/9.0, contentMode: .fit)` lock and the fixed sizing on `viewfinderCard` (~line 532) — let the viewfinder fill the full screen (`.ignoresSafeArea()`, `maxWidth: .infinity, maxHeight: .infinity` with no aspect constraint), same as `viewfinderLayer` did originally.
2. Fold `topBand`, `bottomBand`, and `shutterColumn` back into overlays on top of the full-bleed image instead of separate letterboxed regions — same `ZStack`-over-viewfinder approach the screen used before, but **keep the control grouping, spacing, and sizing exactly as it is now** (the close button top-left, grid/self-timer/looks/duration grouped top-trailing, flip/flash/gallery stacked left of the shutter, mode strip bottom-center) — that part already reads clean in the screenshot; it just needs to sit over the live image instead of in a black margin.
3. Since controls now float over a bright, moving image instead of solid black, restore/strengthen `edgeScrims` (the top/bottom darkening gradient already defined in this file) behind the top and bottom control clusters specifically, so the glass icons and mode strip stay legible over any footage rather than relying on a black backdrop that no longer exists.
4. Keep `LiveHourOverlay()` exactly as it is (already reads well per the screenshot) — just make sure it stays centered over the now-full-bleed image rather than the smaller card.
5. Leave `RuleOfThirdsGrid`, the focus reticle, and the rounded-corner clipping/rim as they are conceptually — they just now apply to the full screen bounds instead of the 16:9 card's bounds (a full-bleed viewfinder likely doesn't need the rounded-corner clip/rim treatment at all, since there's no card edge to visually round — drop `.clipShape(RoundedRectangle...)`/the `.strokeBorder` overlay on the viewfinder itself once it's full-screen, unless you want to keep a corner treatment for some other reason).

## 2 — Recorded video comes out upside down and possibly mirrored

Two separate, real gaps in the rotation code, `CameraCaptureView.swift`:

**2a — Likely 180°-inverted landscape mapping.** `interfaceRotationAngle()` (~line 1527):

```swift
switch orientation {
case .landscapeRight: return 0
case .landscapeLeft: return 180
case .portraitUpsideDown: return 270
default: return 90
}
```

This is exactly the kind of mapping that's notoriously easy to get backwards: `AVCaptureConnection`'s rotation values and `UIInterfaceOrientation`'s landscape values have a long, well-documented history of being inverted relative to each other on iOS (the old `AVCaptureVideoOrientation.landscapeLeft`/`.landscapeRight` pair was itself inverted relative to `UIInterfaceOrientation`'s same-named cases, and the same class of confusion carries over to the newer `videoRotationAngle` angle values). "Upside down" is precisely the symptom of a landscape mapping that's swapped: if `.landscapeRight` should actually map to `180` and `.landscapeLeft` to `0` (the reverse of what's written), every video recorded while holding the phone the "wrong" way — actually every video, if the whole pair is flipped — comes out rotated 180° from correct.

**Fix:** don't guess-fix the swap blind — verify empirically, since it's just as easy to flip it the wrong way a second time:

1. Record a short test video holding the phone with the volume/mute-switch edge on top (one physical landscape orientation), and again with it on the bottom (the other). Check both files.
2. Whichever one comes out upside down tells you which case is wrong: if only one landscape holding-direction is inverted, swap just that case's value (`0` ↔ `180`); if both are inverted, the whole mapping is shifted and needs the same correction applied to `.portraitUpsideDown`/default too.
3. Apply the same corrected mapping consistently — it's shared by `applyInterfaceRotation()` (movie + photo outputs) and `CameraPreview.PreviewView.applyRotation` (the live preview layer), so fixing the one function fixes both live preview and recorded output together, and confirms whether the preview itself already looks wrong (a fast way to check without even recording — if the *live preview* is upside down in one holding direction, you don't need to record a test file to find the bug, just rotate the phone both ways and watch the viewfinder).

**2b — No explicit front-camera mirroring handling.** There is no `isVideoMirrored` / `automaticallyAdjustsVideoMirroring` reference anywhere in this file — every capture connection (preview, photo output, movie output) is left on AVFoundation's default mirroring behavior. The default behavior auto-mirrors the **front camera** for both the live preview and, in many configurations, the recorded/captured output too. A mirrored live preview is normal and expected (it's the "look in a mirror while you frame the shot" behavior every camera app has) — but the **saved video/photo** coming out mirrored means any text, logos, or asymmetric detail in a front-camera log reads backwards to everyone who watches it, which is very likely what "maybe mirrored" is describing.

**Fix:** make mirroring explicit instead of relying on the default, for both outputs:

```swift
private func applyMirroring() {
    let mirrored = currentPosition == .front
    for output in [movieOutput as AVCaptureOutput, photoOutput] {
        guard let connection = output.connection(with: .video),
              connection.isVideoMirroringSupported else { continue }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
```

Call this alongside `applyInterfaceRotation()` — on `flip()` (~line 1566, since that's what changes `currentPosition`) and once at session setup. Leave the **preview layer's** connection on its default/automatic mirroring (or explicitly mirror it when `currentPosition == .front`) so the live viewfinder still shows the expected mirror-image framing experience — the fix is specifically about making sure the *saved* file's mirroring is a deliberate, known value rather than whatever AVFoundation defaults to, so this can actually be verified and isn't just an assumption.

---

## Verification

- **1:** open the camera, confirm the live image fills the entire screen with no black margins, and every control (close, grid/timer/looks/duration, flip/flash/gallery, shutter, mode strip, hour overlay) floats over the live image, legible against any footage.
- **2a:** record holding the phone both landscape ways; confirm both come out upright, not just one.
- **2b:** record a front-camera video containing readable text (write something on paper and hold it up) and confirm it reads correctly (not mirrored) in the saved file, while the live preview while filming still shows the natural "mirror" framing.
- Confirm nothing else changed — hour-only timestamps, top-of-hour cooldown, and the post-capture/Places letterboxing from the other open prompts are unrelated to this pass and should be untouched.
