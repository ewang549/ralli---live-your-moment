# Fix prompt: rotating to landscape doesn't open/rotate the camera when the phone's rotation lock is on

Traced the full chain end to end — detection works correctly, the failure is specifically in forcing the interface to actually rotate once the phone's turn is detected.

## What already works (don't touch)

`OrientationObserver.swift` reads `UIDevice.current.orientation` directly (lines 24, 30) — the physical accelerometer signal, not the interface/UI orientation. This keeps updating regardless of Control Center's rotation lock; lock only suppresses automatic UI-follows-device behavior, it doesn't gate the sensor. `MainTabView.swift`'s `.onChange(of: orientation.isLandscape)` (lines 125-143) correctly fires off this signal and presents `CameraCaptureView` via `fullScreenCover` even with hardware lock engaged. So the phone-turn is detected correctly and the camera screen genuinely gets presented and starts running — the bug isn't in noticing you turned the phone.

## The actual bug: two compounding problems in forcing the interface to rotate

`CameraCaptureView.swift:424` calls `InterfaceOrientationLock.lockLandscape()` as soon as the screen appears, which calls `apply(.landscape)` in `explogApp.swift:31-56`.

**1. The requested mask is ambiguous.** `lockLandscape()` requests `.landscape` — the OR of `.landscapeLeft` and `.landscapeRight` together, not one specific orientation. Apple's rotation-lock override only works reliably when an app supports exactly one orientation: the system is then forced to present that single orientation regardless of lock, because there's no ambiguity to resolve. When two orientations are both technically permitted, choosing between them requires the same automatic-rotation machinery that Control Center's lock disables — so under hardware lock, the system has no sanctioned way to pick landscapeLeft vs. landscapeRight and can simply leave the interface in portrait instead.

**2. The failure is silently swallowed.** `explogApp.swift:44`:
```swift
scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { _ in }
```
The completion handler discards whatever error the system returns when it can't/won't honor the request. If the geometry update gets denied because of the ambiguous-mask issue above, nothing surfaces it anywhere — no log, no fallback, no retry — so the failure is completely invisible and looks exactly like "nothing happened" from the outside, even though the camera screen is actually up and running underneath, just stuck in portrait.

## Fix

**1. Pin `lockLandscape()` to a single fixed edge instead of both.** Change the requested mask from `.landscape` to one specific orientation — `.landscapeRight` (confirm this matches whichever edge the camera UI is actually designed for; check the shutter button/control layout in `CameraCaptureView.swift` to confirm which edge is "up" when landscape, since picking the wrong one would show the UI upside down):

```swift
static func lockLandscape() {
    apply(.landscapeRight)   // single fixed orientation, not .landscape (both edges)
}
```

**2. Stop swallowing the geometry-update error**, so this is diagnosable if it regresses again:

```swift
scene.requestGeometryUpdate(.iOS(interfaceOrientations: newMask)) { error in
    if let error {
        logger.error("requestGeometryUpdate failed: \(error.localizedDescription)")
    }
}
```

(Match whatever logging pattern the rest of `explogApp.swift`/the app already uses — `os.Logger` if that's the established convention.)

Both changes are in `explogApp.swift`'s `InterfaceOrientationLock` — no changes needed to `OrientationObserver.swift`, `MainTabView.swift`, or the trigger logic in general, since detection was already confirmed correct.

## Verification

- Enable the physical/Control-Center rotation lock, then turn the phone to landscape from the Pulse home screen — confirm the camera opens **and the interface actually rotates to landscape**, not just that the screen presents while stuck in portrait.
- Turn the phone back to portrait with lock still engaged — confirm the camera closes/returns correctly.
- Repeat with rotation lock off, confirm no regression to the existing (already-working) behavior.
- If it still fails after the fixed-edge change, the new error logging from fix #2 should surface exactly why — check for that log output before re-investigating from scratch.
