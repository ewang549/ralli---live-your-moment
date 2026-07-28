# Fix prompt: live camera preview is vertical and mirrored, even though the recorded file is correct

This detail — the *output* is correctly oriented but the *live preview* isn't — narrows this down precisely. It rules out the rotation math itself (already proven correct, since the file that math produces is right) and points at the preview layer's connection specifically: either it never gets the rotation/mirroring applied at all, or it gets it applied once, too early, and never again.

---

## Root cause

`CameraCaptureView.swift`'s rotation system (`RotationCoordinator`-driven, `startTrackingRotation(for:)`) correctly pushes `videoRotationAngle` onto `movieOutput` and `photoOutput` from `apply(rotationAngle:)`, and that function only runs *after* `configure()` finishes committing the session (inside the `Task { @MainActor in ... }` block that follows `session.commitConfiguration()`). That's why the recorded file is always right — its connections are only ever touched once they're known to exist.

The **preview layer is handled by a completely separate, unsynchronized path**: `CameraPreview.PreviewView.applyRotation(_:)`, called from SwiftUI's `makeUIView`/`updateUIView`. There is no guarantee `previewLayer.connection` actually exists yet when `makeUIView` first calls it — the connection is only created once the session has a live input/output graph, which happens on `configure()`'s own timeline on the background `sessionQueue`, not SwiftUI's view-lifecycle timeline. If the very first `applyRotation` call lands before that connection exists, it silently no-ops (the `guard let connection = previewLayer.connection ... else { continue }` pattern just skips), and **nothing ever retries it** unless `rotationAngle` happens to change again later — which it won't if the phone is just held steady in landscape the whole time, since the `RotationCoordinator` only fires on an actual orientation change. That leaves the preview permanently on whatever the raw, unconfigured connection defaults to: unrotated (reads as "vertical") and, since mirroring is never explicitly set on this connection at all (unlike the outputs, which explicitly pin `isVideoMirrored = false`), possibly mirrored by AVFoundation's default too.

## Fix — two parts

**1. Make the preview layer's rotation/mirroring self-healing, not one-shot.** Don't rely solely on `rotationAngle` changing to trigger a re-application. Add a retry that fires once the connection is actually guaranteed to exist — `layoutSubviews()` is called by UIKit repeatedly as the view settles (including once the session's graph is live), so use it as a catch-all safety net alongside the existing calls:

```swift
final class PreviewView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var pendingAngle: CGFloat = 0
    private var pendingMirrored = false

    func applyRotation(_ angle: CGFloat, mirrored: Bool) {
        pendingAngle = angle
        pendingMirrored = mirrored
        push()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Catches the case where the connection didn't exist yet the first
        // time `applyRotation` was called — this fires again as the session's
        // graph comes up, so the pending values eventually land instead of
        // being silently dropped on a one-shot attempt.
        push()
    }

    private func push() {
        guard let connection = previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(pendingAngle),
           connection.videoRotationAngle != pendingAngle {
            connection.videoRotationAngle = pendingAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirrored != pendingMirrored {
                connection.isVideoMirrored = pendingMirrored
            }
        }
    }
}
```

**2. Pin the preview's mirroring explicitly instead of leaving it on AVFoundation's default**, matching what already correctly happens for the recorded outputs (`applyMirroring()`, which pins `isVideoMirrored = false` on `movieOutput`/`photoOutput` unconditionally). The live preview *should* stay mirrored for the front camera (the expected "look in a mirror" framing feel) and un-mirrored for the back camera — but that decision needs to be explicit here too, not inherited from a connection that may or may not have settled into the right default:

```swift
// CameraPreview (SwiftUI wrapper):
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var rotationAngle: CGFloat
    var isFrontCamera: Bool   // new — plumb `camera.currentPosition == .front` through

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.applyRotation(rotationAngle, mirrored: isFrontCamera)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.applyRotation(rotationAngle, mirrored: isFrontCamera)
    }
    ...
}
```

Update the call site (`CameraCaptureView.swift` ~line 440) to pass `isFrontCamera: camera.currentPosition == .front` alongside the existing `rotationAngle: camera.rotationAngle`.

---

## Verification

- Open the camera holding the phone steady in landscape from the very start (not rotating into position) — confirm the live preview shows upright and correctly oriented immediately, not just the recorded file afterward.
- Confirm the back-camera preview is never mirrored, and the front-camera preview is mirrored (the intentional "look in a mirror" feel) — both while holding still and immediately after flipping cameras.
- Flip the camera repeatedly and confirm the preview's rotation/mirroring both update correctly every time, with no stale frame left over from before the flip.
- Confirm the recorded file's orientation and mirroring are unaffected by this change — this fix only touches the preview layer's connection, not `movieOutput`/`photoOutput`.
