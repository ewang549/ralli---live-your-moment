# Fix prompt: App Review rejections — ATT tracking label and iPad camera freeze

Two separate App Review rejections, both already resolved. This doc records what was wrong and what changed, so the reasoning survives past this session and the fixes can be verified before resubmission.

---

## 1 — App Privacy label claimed tracking the app doesn't do

**Rejection:** "The app privacy information provided in App Store Connect indicates the app collects data in order to track the user. However, the app does not use App Tracking Transparency to request the user's permission before tracking their activity."

**Root cause:** App Store Connect's App Privacy declaration had one or more "Data Used to Track You" entries checked, but nothing in Ralli actually does Apple's definition of tracking (linking user data with a third party's data for ads/attribution, or sharing with a data broker) — no ad SDK, no cross-app attribution. The label didn't match the app's actual behavior, so App Review correctly flagged the mismatch: a "tracks" label with no `AppTrackingTransparency` prompt anywhere in the binary.

**Fix:** Updated the App Privacy declaration in App Store Connect (App Store Connect → Ralli → App Privacy → "Data Used to Track You") to reflect no tracking. No code changes — there was nothing to gate behind `ATTrackingManager.requestTrackingAuthorization`, since nothing qualifies as tracking under Apple's definition.

**Before resubmitting:**
- [ ] Re-check every third-party SDK in the app (Firebase, Stream Chat, any analytics) for tracking-adjacent settings (ad attribution, IDFA collection) that could silently re-trip this — if one is ever added, either turn its ad features off or implement ATT for it.
- [ ] Confirm the App Privacy label in App Store Connect is saved and reflects "does not track" before the next build is submitted.
- [ ] Optional: reply in Resolution Center noting the label was corrected — not required if the label alone is what App Review re-checks, but can speed things along.

## 2 — Camera screen reads as an unresponsive splash screen on iPad

**Rejection:** "The app exhibited one or more bugs that would negatively impact users. Bug description: tapped on camera / the app displayed an unresponsive splash screen." Reviewed on iPad Air 11-inch (M3), iPadOS 26.5.2.

**Root cause:** `CameraCaptureView.swift` forces the interface into landscape via `InterfaceOrientationLock.lockLandscape()` (`explogApp.swift`, `scene.requestGeometryUpdate`) the moment the screen opens, and gates the *entire* control layer — close button, shutter, everything — behind `isLandscapeReady`, which only flips true once `RotationSettleReporter` hears a real UIKit rotation transition complete.

On iPhone the app is portrait-only (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone = Portrait`), so forcing a single landscape orientation is unambiguous and the system reliably honors it. On iPad the project supports all four orientations by default (`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad` includes portrait, upside-down, and both landscapes), and iPadOS — especially under Stage Manager / windowed multitasking, which the reviewer's iPad Air (M3) supports — is far less willing to honor a forced single-orientation `requestGeometryUpdate`. When the request is silently declined, the rotation transition coordinator never fires, `isLandscapeReady` never becomes true, and the entire chrome — including the one button that closes the screen — stays permanently invisible and non-interactive. The live camera feed is still running underneath; there's just nothing on screen to tap. That's what read as a frozen splash screen.

**Fix (`CameraCaptureView.swift`):**

1. **Close button is no longer gated behind rotation readiness.** Pulled `closeButton` out from under the `ControlsReady(ready: isLandscapeReady)` modifier in `topBand` so it's always visible and tappable the instant the screen appears, regardless of whether the forced rotation ever completes:

```swift
private var topBand: some View {
    HStack(alignment: .center) {
        closeButton   // always visible — the one way out can't wait on rotation
        Spacer(minLength: 12)
        HStack(spacing: 0) {
            gridButton
            selfTimerButton
            looksButton
            durationPill
        }
        .modifier(ControlsReady(ready: isLandscapeReady))   // only the utility row waits
    }
    .frame(height: topBandHeight)
}
```

2. **Hard backstop timeout forces the rest of the chrome to appear.** Added a `force` parameter to `revealControls()` that skips the `isLandscapeLayout` gate, and a 1.2s timer fired from `.task` right after requesting the lock:

```swift
private func revealControls(force: Bool = false) {
    guard !isLandscapeReady, force || isLandscapeLayout else { return }
    safeArea = Self.windowSafeArea()
    camera.reapplyRotation()
    withAnimation(.easeOut(duration: 0.22)) { isLandscapeReady = true }
}

.task {
    maxVideoDuration = VideoDuration(clamping: context.maxClipDuration)
    camera.startIfAvailable(maxDuration: maxDuration)
    InterfaceOrientationLock.lockLandscape()
    Task {
        try? await Task.sleep(for: .milliseconds(1200))
        revealControls(force: true)
    }
    ...
}
```

Together: the close button never depends on rotation succeeding, and even if the rotation silently fails (the iPad case), the shutter/flip/flash/mode-strip controls still appear within 1.2 seconds — the screen is never stuck with a live feed and nothing to interact with.

**Before resubmitting:**
- [ ] Test on an iPad simulator/device specifically, opening the camera from both a portrait and landscape starting orientation.
- [ ] Confirm the close button is tappable immediately on open, before any rotation animation would normally finish.
- [ ] Confirm the full control layer (shutter, flip, flash, grid, self-timer, looks, duration pill) appears within ~1.2s even if the interface visibly stays in portrait.
- [ ] Re-test the existing iPhone landscape-lock behavior (rotate-to-camera, rotation lock on/off) to confirm no regression — this fix only changes what happens when the rotation *doesn't* complete; it shouldn't change anything when it does.
- [ ] In Review Notes on resubmission, flag that the fix was specifically validated on iPad given how the original bug was reported.

---

## Verification summary

- **1:** App Privacy label in App Store Connect shows no "Data Used to Track You" entries; next binary submitted with no ATT-related rejection.
- **2:** On iPad, tapping the camera tab always yields a screen where the close button works immediately and the rest of the controls appear within ~1.2s, even if the interface never visibly rotates to landscape.
