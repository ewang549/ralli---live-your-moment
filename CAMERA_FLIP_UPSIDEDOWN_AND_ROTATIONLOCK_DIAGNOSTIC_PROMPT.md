# Fix prompt: flipping mid-recording turns the video upside-down, and rotation-lock camera auto-open still not working

Two items. Both now have precise, confirmed root causes and fixes already applied — this file is a record of what was wrong and what changed, not a set of open questions.

---

## 1 — Flipping the camera mid-recording makes the video upside-down after the flip point

Root cause confirmed precisely, in `CameraCaptureView.swift`. This is not a bug in *whether* orientation gets communicated per-frame — the recording pipeline already does that correctly, via `videoRotationAngle` set on the capture connection (`CameraModel.pushRotation(_:)`, line 1873-1879), which is fed to the sample-buffer delegate before `ClipRecorder.append` ever sees a frame. That's the right mechanism, and it's capable of tracking a camera flip.

**The actual bug: `flip()` deliberately reuses the *old* camera's rotation angle on the *new* camera, instead of asking the new camera for its own correct angle.**

- `apply(rotationAngle:)` (line 1858-1866) intentionally refuses to push a new angle while `isRecording` is true — correct, this prevents splicing two orientations into one file mid-frame.
- `flip()` (line 1919-1937) captures `lockedAngle = isRecording ? rotationAngle : nil` (line 1927) — this is the **old camera's** angle at the moment of the flip.
- `configure(position:lockedAngle:)` then force-pushes that **same, stale angle** onto the **new** camera's freshly-attached connection (line 1772, and again at lines 1795-1799), explicitly skipping `reapplyRotation()` — which is the method that would correctly ask the (already-rebuilt, per-device) `rotationCoordinator` for the *new* camera's own correct angle. The comment block at lines 1922-1926 explains the reasoning: reusing the same numeric angle was meant to avoid a frame-shape glitch mid-recording. It does succeed at that — but front and back cameras are physically mounted with different sensor orientations, so the "correct" angle for a given phone posture is not the same number for both cameras, most commonly off by exactly 180°. Reusing the old camera's angle on the new camera doesn't affect frame *dimensions* (so the recording doesn't glitch or truncate — that part was already solved correctly), but it does flip the image vertically for every frame captured after the swap. That matches the reported symptom precisely: recording continues cleanly through the flip, and only the picture orientation is wrong from that point on.
- Mirroring is not involved — `pinOutputMirroring()` (line 1897-1904) unconditionally pins `isVideoMirrored = false` on both outputs regardless of which camera is active, so it can't produce an upside-down (as opposed to left-right flipped) result.
- The correct angle only gets restored *after* the fact, for the next clip — `recordClip`'s completion handler calls `reapplyRotation()` at line 2006, too late to help the clip that was actually flipped mid-recording.

**Fix:** when flipping mid-recording, don't reuse the old camera's angle — ask the new camera's own `rotationCoordinator` for its correct angle (the same thing `reapplyRotation()` already knows how to do) and push *that* instead. The frame-shape-glitch concern that motivated reusing the old angle can be addressed differently: if there's a real risk that querying the new coordinator's angle produces a different value than the old camera's (which is expected and exactly the point — that's what makes the video right-side-up), the actual fix is to push the *new, correct* angle for the new camera, not to preserve continuity by reusing a wrong one. Concretely: remove the `lockedAngle` reuse path in `configure()` (lines 1772, 1795-1799) for the mid-recording-flip case, and call `reapplyRotation()` (or equivalent per-device angle lookup) immediately once the new device's `rotationCoordinator` is rebuilt (already happening at line 1783), before the next frame is captured — so the correct angle for whichever camera is now active gets applied starting from the very next frame after the flip, not just at the next `recordClip()` call.

## 2 — Rotation-lock camera auto-open: root cause found via on-device diagnostics, fixed

The static read in the earlier pass of this file was correct as far as it went — `InterfaceOrientationLock`, the `requestGeometryUpdate` error logging, `OrientationObserver`'s physical-sensor detection, and `MainTabView`'s trigger logic were all individually sound. The bug wasn't in any one of those pieces; it was in a race between them that only showed up on-device, under an actual hardware rotation lock, which is exactly why the earlier static pass couldn't find it.

**What the device console showed.** Diagnostic logging was added to `OrientationObserver.swift`, `MainTabView.swift`, and `explogApp.swift`'s `InterfaceOrientationLock.apply(_:)`, then reproduced on a real device with Control Center's rotation lock engaged. The relevant excerpt:

```
apply(mask: 8) device=0
requestGeometryUpdate(mask: 8) failed: ... Requested: landscapeRight; Supported: portrait
apply(mask: 2) device=0
requestGeometryUpdate(mask: 2) failed: ... Requested: portrait; Supported: landscapeRight
settled interface=1 for mask=8
settled interface=1 for mask=2
```

`apply(mask: 8)` (landscape) and `apply(mask: 2)` (portrait) fired back-to-back, within the same instant, and both ultimately settled at `interface=1` (portrait) — neither ever won. A companion log line, `"A new orientation transaction token is being requested while a valid one already exists... reason=Fullscreen transition (dismissing)"`, confirmed the camera's `fullScreenCover` was being presented and torn down in that same instant, not just the lock request being contested.

**Root cause:** `MainTabView`'s `.onChange(of: orientation.isLandscape)` (lines 133-156) reacts to every raw change in `OrientationObserver.isLandscape` immediately, with no debouncing. Under a hardware rotation lock, `UIDevice.current.orientation` — while still physically/sensor-driven and correctly independent of interface orientation, as the earlier pass established — was observed to bounce (landscape → briefly something else → landscape again) within the same fraction of a second the phone was turned. Each bounce round-tripped through `OrientationObserver.update(for:)`, flipping `isLandscape` true, then false, then true again. `MainTabView` opened the camera on the first flip, closed it on the second, and reopened it on the third, all within roughly the time it takes SwiftUI to animate one `fullScreenCover` transition — which is why it looked like "the camera doesn't open at all" rather than a visible flicker: the open/close/open happened faster than the presentation animation could complete any single step.

**Fix applied**, in `OrientationObserver.swift`: raw orientation notifications no longer call `update(for:)` synchronously. Each new raw value cancels any pending update and schedules one 220ms out; if another raw value arrives before that fires, the previous scheduled update is cancelled and replaced. Only a raw orientation that holds stable for 220ms gets committed to `isLandscape`/`landscapeEdge`, which is what `MainTabView` and everything downstream actually observes. A `debounceTask` (separate from the existing `monitorTask`) tracks this, and is cancelled alongside it in `stop()`.

No changes were needed in `MainTabView.swift`, `explogApp.swift`, or `InterfaceOrientationLock` — the bounce was happening upstream of all of them, in the raw signal itself.

---

## Verification

- **1:** start recording, flip the camera mid-recording, and confirm the video stays right-side-up for its entire duration, including everything captured after the flip — not just that recording continues without truncating.
- **2:** enable rotation lock, open the camera by turning the phone sideways, and confirm it opens cleanly on the first turn — no flash-open-and-close, no needing to turn the phone twice. Repeat a few times in a row, since the bounce was intermittent/timing-dependent rather than deterministic.
