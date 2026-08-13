import SwiftUI
import SwiftData
import AVFoundation
import Combine
import PhotosUI
import UIKit
import os

private let cameraLog = Logger(subsystem: "com.ej.explog", category: "camera")

/// Maximum length of a recorded video clip. The duration pill toggles between the
/// two values; the initial value is seeded from the launching context (2s for a
/// pulse check-in, 5s for a place/experience) so context still sets the default,
/// but the user can override it on the fly.
enum VideoDuration {
    case twoSeconds
    case fiveSeconds

    /// The hardware cap handed to AVFoundation and the record-ring animation.
    var seconds: TimeInterval {
        switch self {
        case .twoSeconds: 2
        case .fiveSeconds: 5
        }
    }

    /// Face shown on the toggle pill.
    var label: String {
        switch self {
        case .twoSeconds: "2s"
        case .fiveSeconds: "5s"
        }
    }

    /// The other value — one tap flips between the two.
    var toggled: VideoDuration {
        switch self {
        case .twoSeconds: .fiveSeconds
        case .fiveSeconds: .twoSeconds
        }
    }

    /// Nearest option to a raw duration, so the toggle can seed itself from the
    /// launching context's cap.
    init(clamping seconds: TimeInterval) {
        self = seconds <= 3 ? .twoSeconds : .fiveSeconds
    }
}

/// What the shutter does. Photo taps a still and holds for video (the unified
/// Snapchat gesture); Video makes a single tap toggle recording. Modes never
/// override the `CaptureContext` cap.
enum CaptureMode: String, CaseIterable, Identifiable {
    case photo, video

    var id: String { rawValue }

    /// Face on the mode strip, sentence-cased.
    var title: String {
        switch self {
        case .photo: "Photo"
        case .video: "Video"
        }
    }
}

/// Hands-free countdown before a capture fires. Off is the common case; 3s and
/// 10s cover a quick brace and a run-into-frame.
enum SelfTimer: CaseIterable {
    case off, three, ten

    /// One tap advances the cycle.
    var next: SelfTimer {
        switch self {
        case .off: .three
        case .three: .ten
        case .ten: .off
        }
    }

    /// Seconds counted down before firing; 0 when off.
    var seconds: Int {
        switch self {
        case .off: 0
        case .three: 3
        case .ten: 10
        }
    }

    /// Compact face on the pill ("3", "10"); the icon carries the "timer" meaning.
    var label: String { self == .off ? "" : "\(seconds)" }
    var isOn: Bool { self != .off }
}

/// A live "look": a color grade previewed over the viewfinder. A couple of
/// entries read as playful lenses (a coral bloom, a soft glow) rather than a flat
/// grade — that is the room the design system asks us to leave for a growing
/// face/AR effect library. `.normal` is the identity look. Kept curated, warm,
/// and coral-forward — never a gimmicky rainbow.
struct CameraLook: Identifiable, Equatable {
    let id: String
    let name: String
    var saturation: Double = 1
    var contrast: Double = 1
    var brightness: Double = 0
    /// A tint layer composited over the frame — always visible, even over a live
    /// camera feed where SwiftUI's render filters may not reach the AV layer.
    var tint: Color = .clear
    var tintOpacity: Double = 0
    var tintBlend: BlendMode = .normal
    /// Reads as an AR lens (sparkles marker) rather than a plain grade.
    var isLens: Bool = false
    /// Two-stop gradient for the round carousel swatch.
    var swatch: [Color]

    static let normal = CameraLook(
        id: "normal", name: "Normal",
        swatch: [Color(hex: 0xC9C4CC), Color(hex: 0x8E8A94)]
    )

    /// The curated strip. Order runs identity → warm → mono → cool → playful.
    static let all: [CameraLook] = [
        .normal,
        CameraLook(id: "warm", name: "Warm", saturation: 1.08, contrast: 1.02,
                   tint: Color(hex: 0xFF7B5A), tintOpacity: 0.14, tintBlend: .plusLighter,
                   swatch: [Color(hex: 0xFFB27A), Color(hex: 0xFF6B70)]),
        CameraLook(id: "peach", name: "Peach", saturation: 1.04, brightness: 0.03,
                   tint: Color(hex: 0xFF9EA6), tintOpacity: 0.16, tintBlend: .softLight,
                   swatch: [Color(hex: 0xFFC9B0), Color(hex: 0xFF8FA0)]),
        CameraLook(id: "fade", name: "Fade", saturation: 0.9, contrast: 0.86, brightness: 0.05,
                   tint: Color(hex: 0xF3E4DE), tintOpacity: 0.14, tintBlend: .softLight,
                   swatch: [Color(hex: 0xEAD9D2), Color(hex: 0xC9A9AE)]),
        CameraLook(id: "mono", name: "Mono", saturation: 0, contrast: 1.06,
                   swatch: [Color(hex: 0xD8D5DA), Color(hex: 0x6E6A74)]),
        CameraLook(id: "noir", name: "Noir", saturation: 0, contrast: 1.28, brightness: -0.04,
                   tint: .black, tintOpacity: 0.1, tintBlend: .multiply,
                   swatch: [Color(hex: 0x9A969E), Color(hex: 0x1E1C24)]),
        CameraLook(id: "cool", name: "Cool", saturation: 1.05, contrast: 1.03,
                   tint: Color(hex: 0x6FA6FF), tintOpacity: 0.12, tintBlend: .softLight,
                   swatch: [Color(hex: 0x9FD1FF), Color(hex: 0x5A6BC9)]),
        CameraLook(id: "vivid", name: "Vivid", saturation: 1.4, contrast: 1.1,
                   swatch: [Color(hex: 0xFF5A5F), Color(hex: 0xC1287E)]),
        CameraLook(id: "dream", name: "Dream", saturation: 1.16, brightness: 0.02,
                   tint: Color(hex: 0xFF5A5F), tintOpacity: 0.2, tintBlend: .plusLighter,
                   isLens: true,
                   swatch: [Color(hex: 0xFF8FB0), Color(hex: 0xFF5A5F)]),
        CameraLook(id: "glow", name: "Glow", saturation: 1.1, brightness: 0.05,
                   tint: Color(hex: 0xFF9EB0), tintOpacity: 0.18, tintBlend: .plusLighter,
                   isLens: true,
                   swatch: [Color(hex: 0xFFD1DA), Color(hex: 0xFF7D90)]),
    ]
}

/// Capture a log: a short video or a photo.
///
/// The maximum clip length comes from the surface that opened the camera —
/// 2s for a pulse check-in, 5s for a place/experience (see `CaptureContext`).
/// On simulator (no camera) it falls back to composing a stylized "vibe" clip.
///
/// The screen is a full-bleed viewfinder with a floating glass control layer that
/// **reflows** between orientations rather than merely rotating: in landscape the
/// shutter sits under the right thumb, in portrait it drops to bottom-centre. In
/// real use the app forces landscape (turning the phone sideways is what raises
/// the camera), but the layout is driven off the live geometry so it is correct
/// either way — and a debug hook keeps it portrait for screenshots.
struct CameraCaptureView: View {
    /// Which surface launched capture; drives the recording cap.
    var context: CaptureContext = .pulse

    /// Shared nav/orientation state. The camera reports capture-state changes
    /// here (`isPreviewActive`) so MainTabView's rotation handler knows whether
    /// a portrait rotation should exit (State 1) or be preserved (State 2), and
    /// so the tab we came from can be restored on close. Passed in explicitly
    /// rather than read from `@Environment` — a fullScreenCover's content does
    /// not reliably inherit an @Observable injected on the presenting view, and
    /// a missing lookup is a hard crash.
    let router: AppRouter
    /// Same reasoning as `router` above — carried through to `PostCaptureReview`
    /// and the share screens, all presented via further nested sheets/covers.
    let logSync: LogSync

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var camera = CameraModel()

    /// Max recording length, flipped by the duration pill. Seeded from the
    /// launching context's cap in `.task`.
    @State private var maxVideoDuration: VideoDuration = .twoSeconds
    @State private var captured: CapturedMedia?
    /// When the current recording began — drives the live duration readout.
    /// nil when idle.
    @State private var recordStartedAt: Date?

    // Viewfinder affordances.
    @State private var showGrid = false
    /// Where the last tap-to-focus landed, in the full-bleed viewfinder space.
    /// nil hides the reticle.
    @State private var focusPoint: CGPoint?
    @State private var focusPulse = false
    /// Base zoom captured at the start of a pinch, so the gesture is relative.
    @State private var zoomAnchor: CGFloat = 1
    /// Momentarily shown after a zoom change so the ×-indicator can fade out.
    @State private var showZoom = false
    @State private var flipSpin = false

    // Creative layer.
    /// The live look/lens applied over the viewfinder. Swipe the preview or tap
    /// the carousel to change it; carried into review.
    @State private var look: CameraLook = .normal
    /// Momentarily shown after a look change so its name can announce and fade.
    @State private var showLookName = false
    /// Whether the look carousel is expanded over the shutter row.
    @State private var showLooks = false
    /// Which gesture the shutter performs. Video is the default: a Ralli log is
    /// a short horizontal *video*, and photo is the exception you opt into.
    @State private var captureMode: CaptureMode = .video
    /// Hands-free countdown length.
    @State private var selfTimer: SelfTimer = .off
    /// Live countdown value while a self-timer runs; nil when idle.
    @State private var countdown: Int?

    // Gallery import.
    @State private var pickedItem: PhotosPickerItem?

    /// State 2 of the orientation state machine: media captured, Preview/Send
    /// screen up. Mirrored into the router so MainTabView can read it.
    private var hasCapturedMedia: Bool { captured != nil }

    private var maxDuration: TimeInterval { maxVideoDuration.seconds }

    // MARK: Control bands
    //
    // The live image runs edge-to-edge and every control floats on top of it,
    // the way a real camera app works. The bands below are no longer a layout
    // split carving space out of the viewfinder — they only group the chrome
    // into clusters and give the legibility scrims a height to be sized from.

    /// Cluster on the top edge, holding the close button and the utility row.
    /// Tall enough for a 44pt tap target plus a little air.
    private let topBandHeight: CGFloat = 52
    /// Cluster on the bottom edge, holding the capture-mode strip.
    private let bottomBandHeight: CGFloat = 52
    /// Trailing column holding the shutter cluster: the 74pt shutter, the 44pt
    /// flip/flash/gallery stack, and the gap between them.
    private let shutterColumnWidth: CGFloat = 128

    /// Orientation state machine, state 0: the interface has actually finished
    /// rotating to landscape, *animation included*. `.task` below only
    /// *requests* the rotation; revealing landscape-laid-out controls before the
    /// system has finished playing it is what caused the flicker (icons
    /// appearing over a still-portrait frame).
    ///
    /// This used to be driven off `GeometryReader` size changes, on the theory
    /// that geometry settling tracks the end of the rotation. It doesn't: the
    /// interface's *logical* bounds flip near the start of the transition, so
    /// the fade ran concurrently with the system's own rotation animation —
    /// two animations stacked in one window, which is what read as choppy. The
    /// reveal is now gated on `RotationSettleReporter` below, which reports from
    /// the rotation's own transition coordinator.
    @State private var isLandscapeReady = false

    /// Whether the interface's *layout* is landscape. Flips as soon as the
    /// geometry does — early in the transition — which is why it's separate
    /// from `isLandscapeReady`, the visibility gate.
    @State private var isLandscapeLayout = false

    /// The window's real safe-area insets.
    ///
    /// Read from UIKit rather than SwiftUI because the control layer lives
    /// inside a container that deliberately ignores the safe area (the
    /// viewfinder is meant to run under the bezel) — and `ignoresSafeArea`
    /// zeroes the inset environment for everything inside it. Without the real
    /// numbers the top-trailing pill and the shutter sit under the Dynamic
    /// Island, and the bottom strip under the home indicator, since in
    /// landscape the whole safe area lands on one short edge.
    @State private var safeArea = EdgeInsets()

    /// Current window insets, or zero before there's a window to ask.
    private static func windowSafeArea() -> EdgeInsets {
        let insets = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets ?? .zero
        return EdgeInsets(top: insets.top, leading: insets.left,
                          bottom: insets.bottom, trailing: insets.right)
    }

    /// Fade the chrome in, now that the interface has genuinely finished
    /// rotating. Idempotent: the coordinator callback and the backstop timer
    /// both land here, and whichever arrives second does nothing.
    ///
    /// `force` skips the `isLandscapeLayout` gate. It exists for the hard
    /// timeout scheduled in `.task` below: on iPad — where, unlike iPhone, the
    /// system supports every orientation out of the box and is far less
    /// willing to honor `InterfaceOrientationLock`'s forced single-orientation
    /// `requestGeometryUpdate` (especially under Stage Manager/windowed
    /// multitasking) — the interface can simply never rotate. Without a
    /// forced path here, `isLandscapeReady` stays false forever and the whole
    /// control layer (close button included, previously) stays invisible and
    /// non-interactive: exactly the "unresponsive screen" App Review reported
    /// tapping into the camera on an iPad Air.
    private func revealControls(force: Bool = false) {
        guard !isLandscapeReady, force || isLandscapeLayout else { return }
        // Insets are only final once the rotation is over, so re-read them
        // here rather than trusting the pair taken mid-transition.
        safeArea = Self.windowSafeArea()
        camera.reapplyRotation()
        withAnimation(.easeOut(duration: 0.22)) { isLandscapeReady = true }
    }

    var body: some View {
        GeometryReader { screen in
            ZStack {
                // Warm dark base behind everything (never pure black) — only
                // ever visible in the beat before the session delivers frames.
                Theme.base.ignoresSafeArea()

                // The live image, edge to edge under everything else.
                viewfinderStage

                // The camera is landscape-only (Ralli video is horizontal), so
                // this is laid out for landscape and never reflows to portrait.
                //
                // One symmetric side inset rather than per-edge safe areas: in
                // landscape the whole safe area lands on one short edge, and
                // padding the two sides differently is what used to drag the
                // mode strip visibly off the screen's centre. Taking the larger
                // of the two on both sides costs a little width on the flat
                // edge and keeps every band centred on the *screen*.
                let sideInset = max(safeArea.leading, safeArea.trailing) + 12

                // Chrome floats over the image. Spacers, not opaque bands, hold
                // the clusters apart, so the whole middle of the frame stays
                // available to the viewfinder's pinch / swipe / tap gestures.
                VStack(spacing: 0) {
                    topBand
                    HStack(spacing: 10) {
                        // Leading edge, opposite the shutter cluster: the
                        // sliders need real width, which the narrow trailing
                        // column next to the shutter doesn't have, and putting
                        // them on the far side keeps them clear of the thumb
                        // that is about to press record.
                        screenFlashControls
                            .modifier(ControlsReady(ready: isLandscapeReady))
                        Spacer(minLength: 0)
                        shutterColumn
                    }
                    .frame(maxHeight: .infinity)
                    bottomBand
                }
                .animation(.easeOut(duration: 0.2), value: camera.isScreenFlashActive)
                .padding(.horizontal, sideInset)
                .padding(.top, safeArea.top + 8)
                .padding(.bottom, safeArea.bottom + 10)

                // Transient readouts (record timer, zoom ×, look name) ride the
                // empty centre of the top band, between close and the utilities.
                topReadouts.padding(.top, safeArea.top + 8)

                // The creative strip rises over the image just above the mode
                // strip when opened — a transient tray, held clear of the
                // trailing shutter cluster.
                if showLooks {
                    VStack {
                        Spacer()
                        looksCarousel
                            .padding(.trailing, sideInset + shutterColumnWidth)
                    }
                    .padding(.bottom, safeArea.bottom + 10 + bottomBandHeight)
                }

                // Big self-timer countdown, above everything.
                countdownOverlay.allowsHitTesting(false)

                // Zero-sized, invisible: it exists only to hear the interface
                // rotation's transition coordinator finish. UIKit forwards size
                // transitions to child controllers regardless of their frame.
                RotationSettleReporter { revealControls() }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
            .onAppear {
                // No animation on first read: if the phone was already
                // physically landscape (rotate-to-open), there's no rotation
                // to wait out and the controls should just be there.
                isLandscapeLayout = screen.size.width > screen.size.height
                isLandscapeReady = isLandscapeLayout
                safeArea = Self.windowSafeArea()
                camera.reapplyRotation()
            }
            .onChange(of: screen.size) { _, newSize in
                // Geometry settling is the one signal that the *interface*
                // rotation is done, so it's when the window's insets are final.
                //
                // It is no longer what drives the capture rotation: a 180°
                // landscape flip never changes the screen's size, so this never
                // fired for it, which is exactly how recordings ended up upside
                // down. The rotation coordinator observes that turn directly
                // now; this is only a cheap re-push on top.
                safeArea = Self.windowSafeArea()
                camera.reapplyRotation()
                let landscape = newSize.width > newSize.height
                guard landscape != isLandscapeLayout else { return }
                isLandscapeLayout = landscape

                if !landscape {
                    // Leaving landscape: drop the chrome at once and *without*
                    // a fade. Same reasoning as the reveal — nothing of ours
                    // animates while the system spins the interface — but here
                    // there's nothing to wait for, since holding the controls
                    // on screen through the turn is the artefact, not the fix.
                    isLandscapeReady = false

                    // On iPad, hiding must not be permanent. Portrait is a
                    // supported orientation the interface can simply stay in —
                    // the forced landscape lock is routinely declined there —
                    // and nothing else would ever bring the chrome back, so
                    // the first turn of the device would strand the screen with
                    // a live viewfinder and a lone close button: the same
                    // complaint App Review filed, one rotation later. Re-arm
                    // the same backstop that covers the initial open.
                    //
                    // iPhone is portrait-only, so leaving landscape there means
                    // the camera is already on its way out; restoring chrome
                    // over a portrait layout is exactly what must not happen.
                    if UIDevice.current.userInterfaceIdiom == .pad {
                        Task {
                            try? await Task.sleep(for: .milliseconds(1200))
                            revealControls(force: true)
                        }
                    }
                    return
                }

                // Entering landscape: the reveal waits for the transition
                // coordinator (`revealControls`). This is only a backstop, in
                // case a geometry flip ever arrives without a transition to
                // report — otherwise the chrome would stay hidden for good.
                // It's a no-op once the coordinator has already fired.
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    revealControls()
                }
            }
        }
        // Seed the duration from the launching context, push its cap into the
        // session before the first recording, and force the interface into
        // landscape — the camera is landscape-only (Ralli video is horizontal).
        .task {
            maxVideoDuration = VideoDuration(clamping: context.maxClipDuration)
            camera.startIfAvailable(maxDuration: maxDuration)
            InterfaceOrientationLock.lockLandscape()
            // Backstop: guarantee the chrome appears even if the forced
            // rotation this just requested never actually completes — see
            // `revealControls(force:)` above. `RotationSettleReporter` only
            // ever fires from a real UIKit rotation transition, so a request
            // that gets silently declined (routine on iPad) would otherwise
            // leave this screen permanently stuck with no visible close
            // button or shutter.
            Task {
                try? await Task.sleep(for: .milliseconds(1200))
                revealControls(force: true)
            }
#if DEBUG
            // Screenshot hook: open the looks carousel and pre-select a look so a
            // static capture shows the full creative surface.
            if let name = ProcessInfo.processInfo.environment["EXPLOG_CAMERA_LOOK"] {
                showLooks = true
                if let match = CameraLook.all.first(where: { $0.id == name }) { look = match }
            }
            // Screenshot hook: jump straight to the post-capture review over a
            // composed vibe clip.
            if ProcessInfo.processInfo.environment["EXPLOG_CAMERA_REVIEW"] == "1" {
                captured = CapturedMedia(kind: .vibe, assetFileName: nil)
            }
#endif
        }
        .onChange(of: maxDuration) { _, newValue in camera.updateMaxDuration(newValue) }
        // Start/stop the on-screen duration readout with the recording itself.
        .onChange(of: camera.isRecording) { _, recording in
            recordStartedAt = recording ? .now : nil
        }
        // Keep the router's state-machine flag in lockstep with capture. Setting
        // it true the instant media exists is what makes a portrait rotation on
        // the Preview/Send screen *preserve* it (State 2) instead of exiting.
        .onChange(of: hasCapturedMedia) { _, hasMedia in
            router.isPreviewActive = hasMedia
            if hasMedia {
                // Moved to the Preview/Send flow — release the landscape lock and
                // stand the interface back up so the send UI is vertical.
                InterfaceOrientationLock.lockPortrait()
            } else {
                // Discarded the capture → back to the live viewfinder; re-assert
                // the landscape lock so the viewfinder is horizontal again.
                InterfaceOrientationLock.lockLandscape()
            }
        }
        .onChange(of: pickedItem) { _, item in importPickedPhoto(item) }
        .onDisappear {
            camera.stop()
            // Restore portrait for every close path (rotate-to-portrait, ✕, or
            // finishing a send) so the tab view we return to stands upright.
            InterfaceOrientationLock.lockPortrait()
            // Single cleanup point for every close path: clear the flag and
            // restore the tab we rose from. previousTab is nil when the camera
            // wasn't opened by a rotation, so this is a no-op there.
            router.isPreviewActive = false
            if let previous = router.previousTab {
                router.tab = previous
                router.previousTab = nil
            }
        }
        // Auto-transition: the instant capture completes, the full-bleed review
        // screen rises over the camera. Retake clears the capture (back to the
        // viewfinder); the coral Next inside carries the log to the send flow.
        .fullScreenCover(item: $captured) { media in
            PostCaptureReview(
                media: media,
                look: look,
                logSync: logSync,
                onRetake: { captured = nil },
                onSent: { dismiss() }
            )
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Viewfinder

    /// The live image (or, on a device without a camera, a full-bleed coral
    /// time-of-day gradient). Pinch anywhere to zoom; a single tap drops a
    /// focus reticle.
    private var viewfinderLayer: some View {
        GeometryReader { geo in
            Group {
                if camera.hasCamera {
                    CameraPreview(
                        session: camera.session,
                        rotationAngle: camera.rotationAngle,
                        isFrontCamera: camera.isFrontCamera
                    )
                } else {
                    TimeOfDayCard()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .modifier(LookGrade(look: look))
            // Above the grade, not under it: this is light being thrown at the
            // subject, not part of the image being graded.
            .overlay {
                if camera.isScreenFlashActive {
                    ScreenFlashOverlay(brightness: camera.screenFlashBrightness,
                                       thickness: camera.screenFlashThickness)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                MagnificationGesture()
                    .onChanged { scale in
                        camera.setZoom(zoomAnchor * scale)
                        showZoom = true
                    }
                    .onEnded { _ in
                        zoomAnchor = camera.zoomFactor
                        scheduleZoomHide()
                    }
            )
            // Horizontal swipe over the frame flips to the next / previous look,
            // the Snapchat/Instagram gesture. Runs alongside pinch-zoom; only a
            // decisively horizontal drag past the threshold counts.
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.3,
                              abs(value.translation.width) > 44 else { return }
                        cycleLook(forward: value.translation.width < 0)
                    }
            )
            // Double-tap flips the camera; a single tap still focuses.
            //
            // `ExclusiveGesture` rather than two `.onTapGesture` modifiers,
            // because the two readings of a tap here genuinely conflict and
            // something has to arbitrate: the first tap of a flip is
            // indistinguishable from a focus tap until the second either
            // arrives or doesn't. Exclusivity resolves that the only way it
            // can — the double-tap is offered first, and focus runs only once
            // that has failed. The cost is that a single tap now waits out the
            // double-tap window before the reticle drops, which is the price of
            // never firing a stray focus at the point you flipped from.
            .gesture(
                ExclusiveGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { _ in
                            Haptics.tap()
                            camera.flip()
                        },
                    SpatialTapGesture(count: 1)
                        .onEnded { value in focus(at: value.location, in: geo.size) }
                )
            )
        }
    }

    private struct LookGrade: ViewModifier {
        let look: CameraLook
        func body(content: Content) -> some View {
            content.applyLook(look, animated: true)
        }
    }

    /// Top/bottom darkening so the white glass icons and the mode strip stay
    /// legible over a bright, moving frame, without heavy chrome.
    ///
    /// Two short gradients sized to the control clusters rather than one wash
    /// across the whole screen: with the image running edge to edge there is no
    /// black margin doing this job any more, but a full-height gradient would
    /// also grey down the middle of the composition — the part the viewfinder
    /// exists to show. Each band covers its cluster plus that edge's safe area,
    /// and fades out just past it.
    private var edgeScrims: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.45), .black.opacity(0.18), .clear],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: safeArea.top + topBandHeight + 28)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.clear, .black.opacity(0.2), .black.opacity(0.5)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: safeArea.bottom + bottomBandHeight + 28)
        }
    }

    /// A single-shot pulsing reticle at the last tap location. Animates once and
    /// fades — never idle decoration.
    @ViewBuilder
    private var focusReticleLayer: some View {
        if let point = focusPoint {
            FocusReticle(pulse: focusPulse)
                .position(point)
                .transition(.opacity)
                .id(point.debugID)
        }
    }

    // MARK: - Control layer

    /// Top-centre stack of transient readouts: live recording time, the zoom ×,
    /// and the look name as it changes.
    private var topReadouts: some View {
        VStack(spacing: 8) {
            if camera.isRecording { recordingTimerPill }
            if showZoom { zoomIndicator }
            if showLookName { lookNameChip }
            Spacer()
        }
    }

    /// The viewfinder and everything burned into the frame with it: the scrims,
    /// the grid, the focus reticle and the hour banner.
    ///
    /// Full bleed. No aspect lock, no rounded clip, no rim — the image *is* the
    /// screen, so there is no card edge left to round and nothing to letterbox
    /// against. Every control floats on top of this stack instead of beside it.
    private var viewfinderStage: some View {
        ZStack {
            viewfinderLayer
            edgeScrims.allowsHitTesting(false)
            if showGrid { RuleOfThirdsGrid().allowsHitTesting(false) }
            focusReticleLayer.allowsHitTesting(false)
            // The hour banner, burned across the frame exactly as it will read
            // on the finished log. Live, so it rolls over at the top of the
            // hour instead of freezing at whatever hour the camera opened in.
            LiveHourOverlay()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// Top-edge cluster floating over the image: close at the screen's top-left
    /// corner, the utility group (grid, self-timer, looks, duration) on the
    /// trailing side.
    private var topBand: some View {
        HStack(alignment: .center) {
            // Deliberately *not* gated by `ControlsReady`: this is the one way
            // out of the camera screen, and it must never be hidden behind the
            // landscape-rotation reveal. If the forced rotation never
            // completes (see `revealControls(force:)`), everything else in
            // this band still recovers within the backstop timeout — but the
            // close button can't afford to wait even that long.
            closeButton
            Spacer(minLength: 12)
            // Zero spacing on purpose: every control carries a 44pt tap target
            // around a 34pt disc, so the 10pt of overhang *is* the gap — and
            // it's the same gap in the row and in the side stack below.
            HStack(spacing: 0) {
                gridButton
                selfTimerButton
                looksButton
                durationPill
            }
            .modifier(ControlsReady(ready: isLandscapeReady))
        }
        .frame(height: topBandHeight)
    }

    /// Bottom-edge cluster floating over the image, holding the capture-mode
    /// strip.
    private var bottomBand: some View {
        modeStrip
            .frame(maxWidth: .infinity)
            .frame(height: bottomBandHeight)
            .modifier(ControlsReady(ready: isLandscapeReady))
    }

    /// Trailing column floating over the image: the flip/flash/gallery circles
    /// stacked just left of the much larger shutter, vertically centred in the
    /// right-thumb zone so the hierarchy reads at a glance.
    private var shutterColumn: some View {
        HStack(spacing: 6) {
            VStack(spacing: 0) {
                flipButton
                flashButton
                galleryButton
            }
            shutter
        }
        .frame(width: shutterColumnWidth)
        .modifier(ControlsReady(ready: isLandscapeReady))
    }

    /// Holds the chrome invisible until the interface has actually finished
    /// rotating to landscape, then fades it in — see `isLandscapeReady`.
    ///
    /// Applied per cluster rather than to the whole stack, so the fade only
    /// ever touches chrome — the live image underneath is never dimmed by it.
    private struct ControlsReady: ViewModifier {
        let ready: Bool
        func body(content: Content) -> some View {
            content
                .opacity(ready ? 1 : 0)
                .allowsHitTesting(ready)
        }
    }

    // MARK: - Shutter

    private var shutter: some View {
        ShutterButton(
            mode: captureMode,
            maxDuration: maxDuration,
            isRecording: camera.isRecording,
            reduceMotion: reduceMotion,
            onPhoto: takePhoto,
            onVideoStart: startVideo,
            onVideoStop: stopVideo,
            onZoomDrag: { dy in
                // Drag up from the held shutter to zoom (Snapchat/TikTok gesture).
                camera.setZoom(zoomAnchor + dy / 90)
                showZoom = true
            },
            onGestureEnd: {
                zoomAnchor = camera.zoomFactor
                scheduleZoomHide()
            }
        )
    }

    // MARK: - Live readouts

    /// Live recording readout: a pulsing coral dot + elapsed seconds, shown only
    /// while recording. Elapsed is clamped to the current cap so it tracks the
    /// progress ring and never overruns the hardware limit.
    private var recordingTimerPill: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { context in
            let elapsed = recordStartedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? 0
            let shown = min(elapsed, maxDuration)
            HStack(spacing: 7) {
                Circle()
                    .fill(Theme.coral)
                    .frame(width: 8, height: 8)
                    .opacity(reduceMotion ? 1 :
                        (context.date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.35))
                Text(String(format: "%.1fs", shown))
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .glassPill()
        }
        .transition(.opacity)
    }

    /// Thin ×-magnification readout shown transiently while zooming.
    private var zoomIndicator: some View {
        Text(String(format: "%.1f×", camera.zoomFactor))
            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(.white)
            .glassPill()
            .transition(.opacity)
    }

    // MARK: - Buttons

    /// Dismiss.
    private var closeButton: some View {
        GlassIconButton(system: "xmark", action: { dismiss() })
            .accessibilityLabel("Close camera")
    }

    /// Rule-of-thirds grid toggle.
    private var gridButton: some View {
        GlassIconButton(system: "grid", isActive: showGrid) {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showGrid.toggle() }
        }
        .accessibilityLabel("Grid")
        .accessibilityValue(showGrid ? "On" : "Off")
    }

    /// Camera flip, with a quick spin.
    private var flipButton: some View {
        GlassIconButton(system: "arrow.triangle.2.circlepath.camera") {
            camera.flip()
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { flipSpin.toggle() }
        }
        .rotation3DEffect(.degrees(flipSpin ? 180 : 0), axis: (x: 0, y: 1, z: 0))
        .accessibilityLabel("Flip camera")
    }

    /// Flash / torch cycle: off → on → auto. Lit coral when armed.
    private var flashButton: some View {
        GlassIconButton(system: camera.flashMode.icon, isActive: camera.flashMode != .off) {
            camera.cycleFlash()
        }
        .overlay(alignment: .topTrailing) {
            if camera.flashMode == .auto {
                Text("A")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.onCoral)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Theme.coral))
                    .offset(x: 2, y: -2)
            }
        }
        .accessibilityLabel("Flash")
        .accessibilityValue(camera.flashMode.label)
    }

    /// The screen-flash sliders, shown only while the screen flash is the thing
    /// the flash button is actually controlling — i.e. on the front camera,
    /// with flash armed. On the back camera the button drives a real torch and
    /// there is nothing here to tune.
    @ViewBuilder
    private var screenFlashControls: some View {
        if camera.isScreenFlashActive {
            ScreenFlashControls(
                brightness: Binding(get: { camera.screenFlashBrightness },
                                    set: { camera.screenFlashBrightness = $0 }),
                thickness: Binding(get: { camera.screenFlashThickness },
                                   set: { camera.screenFlashThickness = $0 })
            )
        }
    }

    /// Gallery / last-capture thumbnail → opens the system photo picker to pull
    /// an existing shot into the send flow. A clean standalone glass circle, the
    /// same treatment as the flip/flash buttons above it, so the right cluster
    /// reads as one evenly spaced group — nothing tethered or floating.
    private var galleryButton: some View {
        PhotosPicker(selection: $pickedItem, matching: .images) {
            Image(systemName: "photo.on.rectangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: CameraChrome.controlSize, height: CameraChrome.controlSize)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(Theme.glassTint)
                }
                .overlay {
                    Circle().strokeBorder(Theme.glassRimTop, lineWidth: 0.75)
                }
                .contentShape(.rect)
                .frame(width: CameraChrome.tapTarget, height: CameraChrome.tapTarget)
        }
        .accessibilityLabel("Open gallery")
    }

    /// Toggles the maximum recording length between 2s and 5s. A glass pill with
    /// a coral ring marking it as the one stateful toggle in the top row.
    private var durationPill: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                maxVideoDuration = maxVideoDuration.toggled
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video")
                    .font(.system(size: 10, weight: .semibold))
                Text(maxVideoDuration.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .frame(height: CameraChrome.controlSize)
            .background {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(Theme.glassTint)
            }
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.coral, lineWidth: 1.5))
            .contentShape(.capsule)
            .frame(height: CameraChrome.tapTarget)
        }
        .accessibilityLabel("Maximum video length")
        .accessibilityValue(maxVideoDuration.label)
        .accessibilityHint("Toggles between 2 and 5 seconds")
    }

    /// Self-timer cycle: off → 3s → 10s. Lit coral when armed; the number rides
    /// the glyph when set.
    private var selfTimerButton: some View {
        GlassIconButton(system: "timer", isActive: selfTimer.isOn) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
                selfTimer = selfTimer.next
            }
        }
        .overlay(alignment: .topTrailing) {
            if selfTimer.isOn {
                Text(selfTimer.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.onCoral)
                    .frame(minWidth: 15, minHeight: 15)
                    .padding(.horizontal, 1)
                    .background(Capsule().fill(Theme.coral))
                    .offset(x: 3, y: -3)
            }
        }
        .accessibilityLabel("Self-timer")
        .accessibilityValue(selfTimer.isOn ? "\(selfTimer.seconds) seconds" : "Off")
    }

    /// Toggles the look carousel — the entry point to the creative filter/lens
    /// strip. Coral when the strip is open or a non-default look is active.
    private var looksButton: some View {
        GlassIconButton(system: "camera.filters", isActive: showLooks || look != .normal) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                showLooks.toggle()
            }
        }
        .accessibilityLabel("Looks and lenses")
        .accessibilityValue(look.name)
    }

    // MARK: - Creative readouts

    /// Transient look name, centred near the top after a change. Lens looks get a
    /// sparkles marker so they read as an effect, not just a grade.
    private var lookNameChip: some View {
        HStack(spacing: 6) {
            if look.isLens {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.coral)
            }
            Text(look.name)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
        }
        .glassPill()
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    /// Big centred countdown while a self-timer runs. Coral, springy, one number
    /// at a time. Sits above everything so it reads as the moment.
    @ViewBuilder
    private var countdownOverlay: some View {
        if let value = countdown {
            Text("\(value)")
                .font(.system(size: 120, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .shadow(color: Theme.coralGlow.opacity(0.7), radius: 24)
                .contentTransition(.numericText(countsDown: true))
                .transition(.scale.combined(with: .opacity))
                .id(value)
        }
    }

    // MARK: - Looks carousel

    /// The Snapchat-style creative strip: round look/lens swatches, the active
    /// one ringed coral and named. Scrolls, taps to select. Shown only when the
    /// looks button is toggled on, so the framing view stays clean by default.
    private var looksCarousel: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(CameraLook.all) { option in
                        LookSwatch(look: option, isSelected: option == look) {
                            selectLook(option)
                        }
                        .id(option.id)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 4)
            }
            .onChange(of: look) { _, new in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new.id, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(look.id, anchor: .center) }
        }
        .frame(height: 74)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Capture mode strip

    /// TikTok/Snap-style mode selector. The active mode is a coral pill; a tap
    /// (or the underlying swipe on the preview) moves between Photo and Video.
    /// Sits just under the shutter row.
    private var modeStrip: some View {
        HStack(spacing: 6) {
            ForEach(CaptureMode.allCases) { mode in
                let isSelected = mode == captureMode
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) {
                        captureMode = mode
                    }
                    Haptics.tap()
                } label: {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? Theme.onCoral : .white.opacity(0.85))
                        .padding(.horizontal, 14)
                        .frame(height: 30)
                        .background {
                            if isSelected {
                                Capsule().fill(Theme.coral)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 40)
        .background {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            Capsule(style: .continuous).fill(Theme.glassTint)
        }
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.glassRimTop, lineWidth: 0.75))
        .accessibilityLabel("Capture mode")
        .accessibilityValue(captureMode.title)
    }

    // MARK: - Capture

    /// Quick tap → still photo, after any armed self-timer countdown. Guards
    /// against a stray tap arriving mid-record.
    private func takePhoto() {
        guard !camera.isRecording, countdown == nil else { return }
        withCountdown { firePhoto() }
    }

    private func firePhoto() {
        guard camera.hasCamera else {
            captured = CapturedMedia(kind: .vibe, assetFileName: nil)
            return
        }
        Haptics.tap()
        camera.capturePhoto { fileName in
            if let fileName { captured = CapturedMedia(kind: .photo, assetFileName: fileName) }
        }
    }

    /// Begin recording. From a press-and-hold (Photo mode) it fires immediately;
    /// from a mode tap (Video) it runs any armed self-timer first. The
    /// hardware cap auto-stops at `maxVideoDuration`; releasing early keeps the clip.
    private func startVideo() {
        guard countdown == nil else { return }
        if captureMode == .photo {
            fireVideo()          // hold-to-record: no countdown, start now
        } else {
            withCountdown { fireVideo() }
        }
    }

    private func fireVideo() {
        guard camera.hasCamera else {
            captured = CapturedMedia(kind: .vibe, assetFileName: nil)
            return
        }
        Haptics.start()
        camera.recordClip { fileName in
            if let fileName { captured = CapturedMedia(kind: .video, assetFileName: fileName) }
        }
    }

    private func stopVideo() {
        guard camera.isRecording else { return }
        Haptics.stop()
        camera.stopRecording()
    }

    private func importPickedPhoto(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self) else { return }
            let fileName = "photo-\(UUID().uuidString).jpg"
            let url = URL.documentsDirectory.appending(path: fileName)
            try? data.write(to: url)
            await MainActor.run {
                captured = CapturedMedia(kind: .photo, assetFileName: fileName)
            }
        }
    }

    // MARK: - Focus

    /// Drops the focus reticle at `location` and best-effort tells the device to
    /// focus/expose there. The reticle pulses once, then fades.
    private func focus(at location: CGPoint, in size: CGSize) {
        withAnimation(.easeOut(duration: 0.15)) {
            focusPoint = location
            focusPulse = false
        }
        // Normalised point for the device (0…1 in each axis).
        camera.focus(atNormalized: CGPoint(x: location.x / max(size.width, 1),
                                           y: location.y / max(size.height, 1)))
        if !reduceMotion {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { focusPulse = true }
        }
        // Fade the reticle out shortly after.
        let target = location
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard focusPoint == target else { return }
            withAnimation(.easeInOut(duration: 0.3)) { focusPoint = nil }
        }
    }

    private func scheduleZoomHide() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.easeInOut(duration: 0.3)) { showZoom = false }
        }
    }

    // MARK: - Looks

    /// Steps to the adjacent look and announces its name.
    private func cycleLook(forward: Bool) {
        let all = CameraLook.all
        guard let idx = all.firstIndex(of: look) else { return }
        let next = (idx + (forward ? 1 : -1) + all.count) % all.count
        selectLook(all[next])
    }

    /// Selects a look, flashes its name, and gives a light tick of feedback.
    private func selectLook(_ new: CameraLook) {
        guard new != look else { return }
        Haptics.tap()
        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)) {
            look = new
        }
        announceLook()
    }

    /// Shows the look-name chip briefly, then fades it.
    private func announceLook() {
        withAnimation(.easeInOut(duration: 0.2)) { showLookName = true }
        let shown = look
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            guard look == shown else { return }
            withAnimation(.easeInOut(duration: 0.35)) { showLookName = false }
        }
    }

    // MARK: - Self-timer

    /// Runs the self-timer countdown (if armed) and then fires `fire`. With the
    /// timer off it fires immediately, so the shutter stays one-tap-simple.
    private func withCountdown(_ fire: @escaping () -> Void) {
        guard selfTimer.isOn, countdown == nil else { fire(); return }
        var remaining = selfTimer.seconds
        countdown = remaining
        Haptics.tap()
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                remaining -= 1
                if remaining <= 0 {
                    withAnimation(.easeOut(duration: 0.2)) { countdown = nil }
                    fire()
                } else {
                    Haptics.tap()
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { countdown = remaining }
                    tick()
                }
            }
        }
        tick()
    }
}

struct CapturedMedia: Identifiable {
    let id = UUID()
    let kind: ClipKind
    let assetFileName: String?
}

private extension CGPoint {
    /// Stable identity so the reticle re-triggers its pulse on each new tap.
    var debugID: String { "\(Int(x))-\(Int(y))" }
}

// MARK: - Rotation settling

/// Reports when the system's *interface rotation animation* has actually
/// finished playing — not merely when the new bounds were published.
///
/// SwiftUI has no signal for this. `GeometryReader` hands over the new size
/// near the *start* of the transition, so anything animated off it runs on top
/// of the system's own rotation animation instead of after it. UIKit does have
/// the signal: every size transition carries a transition coordinator whose
/// completion block fires when the rotation has finished on screen. A
/// zero-sized child controller is enough to hear it, since `UIViewController`
/// forwards `viewWillTransition(to:with:)` down to its children.
private struct RotationSettleReporter: UIViewControllerRepresentable {
    /// Called on the main actor once a rotation has fully finished.
    let onSettled: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onSettled = onSettled
        controller.view.isUserInteractionEnabled = false
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onSettled = onSettled
    }

    final class Controller: UIViewController {
        var onSettled: (() -> Void)?

        override func viewWillTransition(to size: CGSize,
                                         with coordinator: UIViewControllerTransitionCoordinator) {
            super.viewWillTransition(to: size, with: coordinator)
            // `alongsideTransition: nil` — nothing of ours should animate
            // *with* the rotation; the whole point is to wait it out.
            coordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.onSettled?()
            }
        }
    }
}

// MARK: - Shutter button (Snapchat-style ring + progress)

/// A clean white ring with a coral-tinted inner fill. Tap fires a photo;
/// press-and-hold records video while a coral arc fills to the cap. Dragging up
/// during a hold feeds a zoom delta. Pressed state scales down and brightens; a
/// soft coral glow breathes while recording (unless reduce-motion).
private struct ShutterButton: View {
    let mode: CaptureMode
    let maxDuration: TimeInterval
    let isRecording: Bool
    let reduceMotion: Bool
    var onPhoto: () -> Void
    var onVideoStart: () -> Void
    var onVideoStop: () -> Void
    var onZoomDrag: (CGFloat) -> Void
    var onGestureEnd: () -> Void

    private let size: CGFloat = 74

    @State private var progress: CGFloat = 0
    @State private var isPressed = false
    @State private var didStartVideo = false
    @State private var holdWork: DispatchWorkItem?
    @State private var pressStartY: CGFloat = 0
    @State private var glow = false

    var body: some View {
        ZStack {
            // Outer white ring.
            Circle()
                .stroke(.white, lineWidth: 4.5)
                .frame(width: size, height: size)

            // Coral progress arc, drawn over the ring while recording.
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.coral, style: StrokeStyle(lineWidth: 4.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.coralGlow.opacity(0.8), radius: 8)

            // Coral-tinted inner fill; shrinks while recording.
            Circle()
                .fill(Theme.coralGradient)
                .frame(width: isRecording ? 30 : 58, height: isRecording ? 30 : 58)
                .brightness(isPressed ? 0.08 : 0)
                .shadow(color: Theme.coralGlow.opacity(glow ? 0.75 : 0.4),
                        radius: glow ? 22 : 14)
        }
        .scaleEffect(isPressed ? 0.96 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: isRecording)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressed {
                        isPressed = true
                        pressStartY = value.startLocation.y
                        // Only Photo mode arms hold-to-record; Video is
                        // tap-to-toggle, so a hold there is just a long tap.
                        if mode == .photo { scheduleHold() }
                    }
                    if didStartVideo {
                        // Positive = dragged upward from the shutter.
                        onZoomDrag(max(0, pressStartY - value.location.y))
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    holdWork?.cancel()
                    holdWork = nil
                    if didStartVideo {
                        // Photo-mode hold ends → stop the clip.
                        didStartVideo = false
                        onVideoStop()
                    } else {
                        switch mode {
                        case .photo:
                            onPhoto()
                        case .video:
                            // Single tap toggles recording.
                            if isRecording { onVideoStop() } else { onVideoStart() }
                        }
                    }
                    onGestureEnd()
                }
        )
        .onChange(of: isRecording) { _, recording in
            if recording {
                progress = 0
                withAnimation(.linear(duration: maxDuration)) { progress = 1 }
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { glow = true }
                }
            } else {
                // Cap reached (auto-stop) or released early — reset ring + glow.
                withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                glow = false
            }
        }
        .accessibilityLabel("Shutter")
        .accessibilityHint("Tap for a photo, hold to record video")
    }

    /// After a short threshold the press becomes a video hold.
    private func scheduleHold() {
        let work = DispatchWorkItem {
            didStartVideo = true
            onVideoStart()
        }
        holdWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }
}

// MARK: - Glass controls

/// A translucent dark-glass circle with a white line icon. Turns coral when
/// active. The shared secondary-control treatment: small and quiet, so the
/// cluster frames the preview instead of competing with it and the shutter
/// stays the one prominent element. The disc is `CameraChrome.controlSize`;
/// an invisible 44pt tap target rides underneath so shrinking the visual
/// doesn't shrink what a thumb has to hit.
private struct GlassIconButton: View {
    let system: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? Theme.coral : .white)
                .frame(width: CameraChrome.controlSize, height: CameraChrome.controlSize)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(isActive ? Theme.coral.opacity(0.16) : Theme.glassTint)
                }
                .overlay {
                    Circle().strokeBorder(isActive ? Theme.coral.opacity(0.7) : Theme.glassRimTop,
                                          lineWidth: isActive ? 1.5 : 0.75)
                }
                .contentShape(.rect)
                .frame(width: CameraChrome.tapTarget, height: CameraChrome.tapTarget)
        }
        .buttonStyle(.plain)
    }
}

/// Shared metrics for the camera's secondary chrome, so the top row, the side
/// stack and the duration pill can't drift apart from each other.
enum CameraChrome {
    /// Visible diameter/height of a secondary control.
    static let controlSize: CGFloat = 34
    /// Hit area around it — never smaller than the 44pt minimum.
    static let tapTarget: CGFloat = 44
}

/// One round look/lens swatch in the creative carousel: a gradient chip that
/// grows and gains a coral ring when selected, its name beneath. Lens looks wear
/// a small sparkles marker.
private struct LookSwatch: View {
    let look: CameraLook
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 5) {
                Circle()
                    .fill(LinearGradient(colors: look.swatch,
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: isSelected ? 52 : 46, height: isSelected ? 52 : 46)
                    .overlay {
                        if look.isLens {
                            Image(systemName: "sparkles")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 3)
                        }
                    }
                    .overlay {
                        Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1)
                    }
                    .overlay {
                        if isSelected {
                            Circle().strokeBorder(Theme.coral, lineWidth: 2.5)
                                .padding(-4)
                                .shadow(color: Theme.coralGlow.opacity(0.6), radius: 6)
                        }
                    }
                Text(look.name)
                    .font(.system(size: 10, weight: isSelected ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(isSelected ? Theme.coral : .white.opacity(0.85))
                    .lineLimit(1)
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.name + (look.isLens ? " lens" : " look"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The rule-of-thirds guide: two thin lines each way, hairline-white.
private struct RuleOfThirdsGrid: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width, h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.28), lineWidth: 0.5)
        }
        .transition(.opacity)
    }
}

/// A single-shot focus reticle: a rounded square that pulses in and settles.
private struct FocusReticle: View {
    let pulse: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(Theme.coral, lineWidth: 1.75)
            .frame(width: 74, height: 74)
            .scaleEffect(pulse ? 1 : 1.35)
            .opacity(pulse ? 1 : 0.6)
            .shadow(color: Theme.coralGlow.opacity(0.5), radius: 6)
    }
}

// MARK: - Simulated viewfinder (simulator / no camera)

/// A full-bleed, coral-tinted time-of-day gradient standing in for a live frame
/// on hardware without a camera. It fills the whole viewfinder exactly where the
/// real feed would be — not a centred card — so the controls overlay on top read
/// as a finished camera. Reads as a graceful fallback, not an error: the current
/// hour, big and calm, with a quiet caption beneath. The warm palette deepens
/// through the day (bright coral at noon, ember over warm plum at night).
private struct TimeOfDayCard: View {
    @State private var shift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let palette = TimeOfDayCard.palette(for: context.date)
            ZStack {
                // Full-bleed warm base so nothing shows through at the edges.
                Theme.base

                // The coral time-of-day gradient, edge to edge.
                LinearGradient(
                    colors: palette,
                    startPoint: shift ? .topLeading : .top,
                    endPoint: shift ? .bottomTrailing : .bottom
                )

                // A soft coral bloom in the upper third for warmth and depth.
                RadialGradient(
                    colors: [Theme.coral.opacity(0.38), .clear],
                    center: UnitPoint(x: 0.5, y: 0.32),
                    startRadius: 0, endRadius: 460
                )
                .blendMode(.plusLighter)

                // Just the caption, sat below centre. The hour used to be drawn
                // here too; the viewfinder's own hour banner now sits over this
                // card and the two rendered on top of each other.
                VStack {
                    Spacer()
                    Text("no camera here — composing a vibe clip")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.bottom, 18)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { shift = true }
        }
    }

    /// Warm coral gradient stops chosen by the hour: peachy at dawn, bright coral
    /// at midday, deep ember over warm plum at night. Always coral-warm — never
    /// blue, never pure black.
    static func palette(for date: Date) -> [Color] {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<9:   // dawn — soft peach → warm rose
            [Color(hex: 0xFFB27A), Color(hex: 0xFF7B7F), Color(hex: 0x5A2E3A)]
        case 9..<17:  // day — bright coral → deep coral
            [Color(hex: 0xFF8A6E), Color(hex: 0xFF5A5F), Color(hex: 0x6E2A34)]
        case 17..<21: // dusk — coral → warm plum
            [Color(hex: 0xFF7B7F), Color(hex: 0xE64A50), Color(hex: 0x3A1C28)]
        default:      // night — ember coral over deep warm plum
            [Color(hex: 0xFF6B70), Color(hex: 0x8E3038), Color(hex: 0x1E1218)]
        }
    }
}

// MARK: - Look grading

extension View {
    /// Applies a `CameraLook`'s grade + tint as one composited layer. Shared by
    /// the live viewfinder and the post-capture review so the look carries
    /// through. The tint overlay is always composited (even over a live AV layer
    /// where SwiftUI render filters may not reach).
    func applyLook(_ look: CameraLook, animated: Bool = false) -> some View {
        self
            .saturation(look.saturation)
            .contrast(look.contrast)
            .brightness(look.brightness)
            .overlay(
                Rectangle()
                    .fill(look.tint)
                    .opacity(look.tintOpacity)
                    .blendMode(look.tintBlend)
                    .allowsHitTesting(false)
            )
            .animation(animated ? .easeInOut(duration: 0.25) : nil, value: look)
    }
}

// MARK: - Glass pill helper

private extension View {
    /// The shared small-readout treatment: dark glass capsule with a soft rim.
    func glassPill() -> some View {
        self
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(Theme.glassTint)
            }
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.glassRimTop, lineWidth: 0.75))
    }
}

// MARK: - Haptics

private enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func start() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func stop() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
}

// MARK: - Camera plumbing

final class CameraModel: NSObject, ObservableObject {
    /// Off / on / auto flash cycle. Torch (video) is lit only for `.on`; `.auto`
    /// is meaningful for stills, where AVFoundation decides per-frame.
    enum FlashMode {
        case off, on, auto

        var next: FlashMode {
            switch self {
            case .off: .on
            case .on: .auto
            case .auto: .off
            }
        }

        var icon: String {
            switch self {
            case .off: "bolt.slash"
            case .on: "bolt"
            case .auto: "bolt.badge.a"
            }
        }

        var label: String {
            switch self {
            case .off: "Off"
            case .on: "On"
            case .auto: "Auto"
            }
        }

        var avFlashMode: AVCaptureDevice.FlashMode {
            switch self {
            case .off: .off
            case .on: .on
            case .auto: .auto
            }
        }
    }

    let session = AVCaptureSession()
    @Published var isRecording = false
    @Published var flashMode: FlashMode = .off
    /// Current optical/digital zoom, mirrored for the ×-indicator.
    @Published var zoomFactor: CGFloat = 1
    /// Rotation currently pushed onto the capture connections, in degrees.
    /// Published so the preview layer picks up the same angle the outputs use.
    @Published private(set) var rotationAngle: CGFloat = 0
    /// Whether the *live* session is on the front camera. Published separately
    /// from `currentPosition` because it is set from the far side of a
    /// (re)configure: `flip()` moves `currentPosition` immediately, but the
    /// preview's connection doesn't belong to the new camera until the session
    /// queue has committed, and mirroring pushed before then would land on the
    /// outgoing connection and be lost with it.
    @Published private(set) var isFrontCamera = false

    /// How bright the front-camera screen flash glows, 0…1.
    ///
    /// The front camera has no torch — `applyTorch()` guards on
    /// `device.hasTorch`, which is false there, and the front photo output
    /// doesn't support a flash mode either. So arming flash on the front camera
    /// used to do nothing at all. The screen itself is the only light source
    /// available, and this is how much of it to use.
    ///
    /// Drives the overlay's opacity rather than `UIScreen.main.brightness`:
    /// opacity is local to this screen and undoes itself when the view goes
    /// away, where turning the device's brightness up has to be remembered and
    /// restored on every exit path — including a crash or a backgrounding.
    @Published var screenFlashBrightness: Double = 0.75

    /// How thick the glowing ring is, 0…1 of the shorter screen edge. At 1 the
    /// ring closes up into a full-screen wash.
    @Published var screenFlashThickness: Double = 0.25

    /// Whether the screen flash should be showing: front camera, flash armed.
    /// `.auto` counts as armed here — there is no metering to defer to on a
    /// light source the user is aiming themselves.
    var isScreenFlashActive: Bool { isFrontCamera && flashMode != .off }

    /// Everything that reconfigures or starts/stops the session runs here.
    ///
    /// `AVCaptureSession` configuration is not a quick property write: tearing
    /// the inputs and outputs down and rebuilding them stalls on the capture
    /// hardware, and Apple is explicit that it must not happen on the main
    /// thread. It used to — `flip()` called `configure()` straight from the
    /// button's action — so every camera flip froze the whole UI, shutter
    /// included, for as long as the pipeline took to come back. One serial
    /// queue rather than `.global()` so two flips in quick succession can't
    /// reconfigure the session concurrently.
    private let sessionQueue = DispatchQueue(label: "com.ej.explog.camera.session")

    /// Video and audio arrive as raw sample buffers and are written by
    /// `ClipRecorder`, not by an `AVCaptureMovieFileOutput`. That output cannot
    /// survive `configure()` removing the session's inputs to swap cameras — it
    /// finalizes the file the moment its connection goes away — so recording
    /// through it made a mid-take flip truncate the clip. See `ClipRecorder`.
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    /// Owns the queue both capture outputs deliver on — one serial queue for
    /// both, so video and audio buffers stay ordered against each other and
    /// against start/stop.
    private let recorder = ClipRecorder()
    private var photoCompletion: ((String?) -> Void)?
    /// Which camera is live. Written and read on the main thread only (the
    /// torch, zoom and focus helpers all resolve their device through it); the
    /// session queue is handed the position it should configure for rather
    /// than reading this behind the main thread's back.
    private var currentPosition: AVCaptureDevice.Position = .back
    /// Apple's device-aware source of truth for capture rotation, and the KVO
    /// tie holding it. Rebuilt per configure, since it belongs to one device.
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Hard cap enforced by AVFoundation itself; set from the launching context.
    private var maxDuration: TimeInterval = CaptureContext.pulse.maxClipDuration

    var hasCamera: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil ||
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    /// The active capture device for the current position, if any.
    private func currentDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition)
    }

    func startIfAvailable(maxDuration: TimeInterval) {
        self.maxDuration = maxDuration
        guard hasCamera, !session.isRunning else { return }
        let position = currentPosition
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.sessionQueue.async {
                // Re-checked on the queue: two `.task`/`onAppear` passes can
                // both get past the guard above before either has started.
                guard !self.session.isRunning else { return }
                // No take can be in flight before the session has started, so
                // there is no angle to preserve — the coordinator pushes the
                // live one as soon as it's tracking.
                self.configure(position: position, recording: nil)
                self.session.startRunning()
            }
        }
    }

    /// Rebuilds the session's inputs and outputs for `position`.
    ///
    /// Only ever called on `sessionQueue`. The position is a parameter rather
    /// than a read of `currentPosition` so this can't race the main thread's
    /// copy of it, and so a flip that lands mid-reconfigure still configures
    /// for the camera that flip actually asked for.
    ///
    /// `recording` is non-nil only when a take is in flight: mid-recording, the
    /// new camera's connection has to come up at an angle that keeps the open
    /// file coherent rather than at the live one. See the call site in `flip()`.
    private func configure(position: AVCaptureDevice.Position, recording: RecordingRotation?) {
        dispatchPrecondition(condition: .onQueue(sessionQueue))

        session.beginConfiguration()
        // Pinned rather than `.high`, which is free to resolve differently on
        // the front and back cameras. Recording writes into a file whose frame
        // size is fixed at its first frame, so a flip that changed the buffer
        // size mid-take would leave the rest of the clip being rescaled. Both
        // cameras on every supported device do 1080p; `.high` is the fallback
        // if some future one doesn't.
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        session.inputs.forEach { session.removeInput($0) }

        var activeDevice: AVCaptureDevice?
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            activeDevice = device
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        // `canAddOutput` is false for an output already on the session, so
        // these are no-ops on every configure after the first — which is the
        // point: the outputs, and any recording writing from them, live right
        // through a camera swap.
        // The delegates are set at add time, so only on the first configure.
        // Re-setting one on a running session interrupts delivery, which
        // mid-take would punch a hole in the file the flip is meant to survive.
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(self, queue: recorder.queue)
        }
        if session.canAddOutput(audioOutput) {
            session.addOutput(audioOutput)
            audioOutput.setSampleBufferDelegate(self, queue: recorder.queue)
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        // Geometry is pinned inside the configuration block, before the first
        // buffer from the new camera can arrive. Deferring it to the main-actor
        // hop below would let a few frames through at the sensor's default
        // rotation — and mid-flip that means frames of the wrong shape landing
        // in an already-open file.
        //
        // Resolved here too, rather than reused from the outgoing camera: the
        // angle that is level for one camera is not the angle that is level for
        // the other. See `swapRotationAngle`.
        let swappedAngle = recording.map { swapAngle(for: activeDevice, $0) }
        if let swappedAngle { pushRotation(swappedAngle) }
        pinOutputMirroring()
        session.commitConfiguration()

        // The rotation coordinator is per-device, so it's rebuilt here on every
        // (re)configure — including the one behind `flip()`, which is the call
        // that changes which camera these connections belong to. This hops to
        // the main actor: the coordinator, its observation and every
        // `@Published` property below belong there.
        let device = activeDevice
        Task { @MainActor in
            if let device { self.startTrackingRotation(for: device) }
            // Published from the position that was actually configured, so the
            // preview mirrors the camera that is live rather than the one a
            // flip has already optimistically recorded on the main thread.
            self.isFrontCamera = position == .front
            // A take in flight keeps the orientation it started at — catching
            // the connections up on the live one would splice two orientations
            // into the open file. `recordClip`'s completion is what catches them
            // up once the file is closed. Re-pushed rather than skipped: whether
            // a swapped connection is reachable from inside the configuration
            // block isn't guaranteed, and pushing the same angle twice costs
            // nothing.
            if let swappedAngle {
                self.pushRotation(swappedAngle)
            } else {
                self.reapplyRotation()
            }
            self.pinOutputMirroring()
            // Reset zoom to the device's baseline on (re)configure.
            self.zoomFactor = 1
        }
    }

    // MARK: Orientation

    /// Starts tracking the rotation this device's camera needs, and keeps
    /// pushing it at the capture connections as the phone turns.
    ///
    /// This replaces a hand-written table that mapped the window's
    /// `UIInterfaceOrientation` to an angle. Two separate things were wrong
    /// with that, and the first is the "video comes out upside down" bug:
    ///
    /// 1. Nothing ever re-read it on a 180° landscape flip. The camera locks
    ///    the `.landscape` mask, which permits *both* landscape edges, and
    ///    turning the phone end-for-end between them leaves the screen exactly
    ///    the same size — so the view's `onChange(of: screen.size)` geometry
    ///    trigger, the only live signal there was, never fired. Open the camera
    ///    holding it one way, turn it around, and every frame after that (the
    ///    preview *and* the recording) was a full 180° off, with nothing to put
    ///    it right until the screen next changed shape.
    /// 2. The angles were sensor-relative, and the camera's native sensor
    ///    orientation is not the same on every iPhone — it changed on the 17
    ///    Pro. No fixed table can be correct on both sides of that.
    ///
    /// `RotationCoordinator` answers both. It reports the angle *this* device's
    /// camera needs to sit horizon-level with gravity, and it's KVO-observable,
    /// so a landscape flip delivers a new angle on its own instead of waiting
    /// on a layout signal that never arrives.
    @MainActor
    private func startTrackingRotation(for device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        // `.initial` so the current angle lands before the first frame, rather
        // than only once the phone is next moved.
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor [weak self] in self?.apply(rotationAngle: angle) }
        }
    }

    /// What a flip landing mid-take needs to know to keep the open file
    /// coherent across the camera swap. Assembled by `flip()`.
    private struct RecordingRotation {
        /// The angle the file's frames are actually arriving at, read off the
        /// connection rather than from `rotationAngle`: a turn of the phone
        /// mid-take updates the latter (the viewfinder keeps following the
        /// horizon) but is deliberately never pushed at the connections, so the
        /// two can already have drifted apart before the flip.
        var locked: CGFloat
        /// The outgoing camera's level angle for the phone's *current* posture.
        var outgoingLive: CGFloat
    }

    /// Resolves the angle the incoming camera's connections should come up at
    /// mid-take, by asking that camera's own rotation coordinator where level
    /// is. Returns `r.locked` unchanged if there's no device to ask.
    private func swapAngle(for device: AVCaptureDevice?, _ r: RecordingRotation) -> CGFloat {
        guard let device else { return r.locked }
        let incomingLive = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            .videoRotationAngleForHorizonLevelCapture
        return Self.swapRotationAngle(locked: r.locked,
                                      outgoingLive: r.outgoingLive,
                                      incomingLive: incomingLive)
    }

    /// The angle the incoming camera needs so a take already in flight keeps
    /// the orientation it started at.
    ///
    /// Front and back cameras are mounted with different sensor orientations,
    /// so the angle that is level for one is not the angle that is level for
    /// the other — most often the two are a full 180° apart. Carrying the
    /// outgoing camera's angle straight over to the incoming one, which is what
    /// a mid-take flip used to do to hold the frame *shape* steady, did keep the
    /// file's dimensions but stood every frame after the flip on its head.
    ///
    /// What carries over correctly is the *difference* between the two cameras'
    /// level angles for the phone's current posture, applied to the angle the
    /// file is already being written at. A take started in portrait then stays
    /// portrait-up even if the phone has since been turned — mid-take turns are
    /// deliberately not pushed — while the mounting difference is corrected for.
    ///
    /// Returns `locked` unchanged if the result would transpose the frame: a
    /// movie's dimensions are fixed by its first frame, so 0↔180 and 90↔270 can
    /// be spliced into an open file but crossing between those pairs cannot.
    /// That only comes up on a device whose two cameras are mounted a quarter
    /// turn apart, where an upright-but-sideways clip beats a rescaled one.
    static func swapRotationAngle(locked: CGFloat, outgoingLive: CGFloat, incomingLive: CGFloat) -> CGFloat {
        let corrected = (locked + incomingLive - outgoingLive).truncatingRemainder(dividingBy: 360)
        let normalized = corrected < 0 ? corrected + 360 : corrected
        let shapeDelta = abs(normalized - locked).truncatingRemainder(dividingBy: 180)
        let preservesFrameShape = shapeDelta < 1 || shapeDelta > 179
        return preservesFrameShape ? normalized : locked
    }

    /// Re-pushes the current angle. Cheap and idempotent, so the view can call
    /// it whenever it suspects the connections have gone stale — after a
    /// (re)configure, or once a recording that suppressed a turn has ended.
    @MainActor
    func reapplyRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture else { return }
        apply(rotationAngle: angle)
    }

    /// Pushes a rotation onto every capture connection, and mirrors it into
    /// `rotationAngle` so the preview layer turns with the outputs rather than
    /// disagreeing with the file it is previewing.
    @MainActor
    private func apply(rotationAngle angle: CGFloat) {
        rotationAngle = angle
        // Rotating mid-recording would splice two orientations — and, since the
        // buffers themselves come out rotated, two frame shapes — into one
        // file. `recordClip`'s completion catches the connections up once the
        // file is closed.
        guard !isRecording else { return }
        pushRotation(angle)
    }

    /// Writes an angle straight onto the capture connections.
    ///
    /// Deliberately not main-actor-bound: `configure()` calls it from the
    /// session queue inside its configuration block, which is where a freshly
    /// swapped connection has to be set up before it delivers anything.
    private func pushRotation(_ angle: CGFloat) {
        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let connection = output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(angle) else { continue }
            connection.videoRotationAngle = angle
        }
    }

    /// Pins the saved file's mirroring to a known value instead of inheriting
    /// whatever AVFoundation's default happens to be for this configuration.
    ///
    /// Only the *outputs* are pinned here. The live preview stays mirrored on
    /// the front camera — that's the "framing yourself in a mirror" behaviour
    /// every camera app has, and it's the right feel while filming — but it is
    /// pinned to that explicitly too, in `CameraPreview.PreviewView`, rather
    /// than inherited from `AVCaptureVideoPreviewLayer`'s automatic mirroring.
    /// The file is the opposite case: a mirrored front-camera log leaves any
    /// text, logo or asymmetric detail in it reading backwards to everyone who
    /// watches it. So both capture outputs record the true, un-mirrored image,
    /// on either camera.
    ///
    /// Called from `configure()` on the session queue, alongside `pushRotation`
    /// and for the same reason: a swapped connection must be pinned before it
    /// starts delivering, not a main-actor hop later.
    private func pinOutputMirroring() {
        for output in [videoOutput as AVCaptureOutput, photoOutput] {
            guard let connection = output.connection(with: .video),
                  connection.isVideoMirroringSupported else { continue }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    /// Re-caps an already-running session (e.g. capture reopened from Places).
    /// The cap is read when a take starts, so this only has to land before the
    /// next one — it can't shorten a recording already in flight.
    func updateMaxDuration(_ seconds: TimeInterval) {
        maxDuration = seconds
    }

    /// Swaps to the other camera.
    ///
    /// Called straight from the flip button, so the only work done here is the
    /// bookkeeping the main thread owns; the reconfiguration itself — the part
    /// that stalls on the hardware, and that used to lock up the shutter along
    /// with everything else — goes to the session queue.
    func flip() {
        currentPosition = currentPosition == .back ? .front : .back
        let position = currentPosition
        // A take in flight keeps the orientation it started at: the new
        // camera's connection comes up at its sensor default, and letting that
        // land mid-file would change the shape of the frames going into an
        // already-open movie. Read here on the main thread, where
        // `rotationAngle` and `isRecording` live; the angle the file is being
        // written at comes off the connection itself, on the session queue.
        let recording = isRecording
        let outgoingLive = rotationAngle
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let rotation = recording
                ? self.videoOutput.connection(with: .video).map {
                    RecordingRotation(locked: $0.videoRotationAngle, outgoingLive: outgoingLive)
                }
                : nil
            self.configure(position: position, recording: rotation)
            // A torch belongs to the device, not the session: re-assert it
            // after the swap so a lit flash survives flipping to a camera that
            // has one. On the main thread, since it resolves the device
            // through `currentPosition`.
            Task { @MainActor in self.applyTorch() }
        }
    }

    /// Advances the flash cycle and pushes the torch state at the hardware
    /// immediately, so the viewfinder shows the result before capture.
    func cycleFlash() {
        flashMode = flashMode.next
        applyTorch()
    }

    /// Front cameras generally have no torch — `hasTorch` guards that, leaving
    /// `flashMode` set so stills can still fire the flash.
    private func applyTorch() {
        guard let device = currentDevice(), device.hasTorch else { return }
        try? device.lockForConfiguration()
        // Only `.on` lights a continuous torch; `.auto` has no live-preview torch.
        device.torchMode = flashMode == .on ? .on : .off
        device.unlockForConfiguration()
    }

    /// Sets the zoom, clamped to what the device supports (capped so digital
    /// zoom never gets grainy). Updates `zoomFactor` even without a device so the
    /// on-screen indicator still animates in the simulator.
    func setZoom(_ factor: CGFloat) {
        guard let device = currentDevice() else {
            zoomFactor = min(max(factor, 1), 5)
            return
        }
        let maxF = min(device.maxAvailableVideoZoomFactor, 6)
        let clamped = min(max(factor, device.minAvailableVideoZoomFactor), maxF)
        try? device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        zoomFactor = clamped
    }

    /// Best-effort tap-to-focus / expose at a normalised (0…1) point.
    func focus(atNormalized point: CGPoint) {
        guard let device = currentDevice() else { return }
        try? device.lockForConfiguration()
        if device.isFocusPointOfInterestSupported {
            device.focusPointOfInterest = point
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
            device.exposureMode = .autoExpose
        }
        device.unlockForConfiguration()
    }

    func recordClip(completion: @escaping (String?) -> Void) {
        guard !isRecording else { return }
        isRecording = true
        let fileName = "clip-\(UUID().uuidString).mov"
        let url = URL.documentsDirectory.appending(path: fileName)
        // Settings come from the outputs so the file matches what the hardware
        // is actually delivering rather than a guess at it.
        recorder.start(url: url,
                       maxDuration: maxDuration,
                       videoSettings: videoOutput.recommendedVideoSettingsForAssetWriter(writingTo: .mov),
                       audioSettings: audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov)) { [weak self] succeeded in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                completion(succeeded ? fileName : nil)
                // A turn that arrived mid-recording was deliberately not pushed
                // at the connections (it would have spliced two orientations
                // into one file). Now that the file is closed, catch them up —
                // otherwise the *next* clip inherits the angle from before it.
                self.reapplyRotation()
            }
        }
    }

    /// Stops an in-progress recording early; the recorder keeps the file.
    func stopRecording() {
        guard isRecording else { return }
        recorder.stop()
    }

    func capturePhoto(completion: @escaping (String?) -> Void) {
        photoCompletion = completion
        let settings = AVCapturePhotoSettings()
        // Only ask for a flash mode the current device actually supports —
        // setting an unsupported one throws.
        let wanted = flashMode.avFlashMode
        if photoOutput.supportedFlashModes.contains(wanted) {
            settings.flashMode = wanted
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func stop() {
        // Leave the torch off behind us: it outlives the session otherwise and
        // strands the user with the light on after the camera closes.
        if flashMode == .on {
            flashMode = .off
            applyTorch()
        }
        guard session.isRunning else { return }
        // The same queue the configuration runs on, so a stop can't overlap a
        // reconfigure that's still in flight.
        sessionQueue.async { [session] in
            session.stopRunning()
        }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Both capture outputs deliver here, on `bufferQueue` — the same queue the
    /// recorder keeps its state on, so no further synchronisation is needed.
    /// Buffers arriving while nothing is recording are dropped by the recorder.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        recorder.append(sampleBuffer, isVideo: output === videoOutput)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        DispatchQueue.main.async {
            guard let data = photo.fileDataRepresentation() else {
                self.photoCompletion?(nil)
                self.photoCompletion = nil
                return
            }
            let fileName = "photo-\(UUID().uuidString).jpg"
            let url = URL.documentsDirectory.appending(path: fileName)
            let corrected = Self.orientedJPEG(from: data, rotationAngle: self.rotationAngle) ?? data
            try? corrected.write(to: url)
            self.photoCompletion?(fileName)
            self.photoCompletion = nil
        }
    }

    /// Bakes the capture's rotation into the still's pixel data.
    ///
    /// `apply(rotationAngle:)` sets the same `videoRotationAngle` on the photo
    /// connection as on the movie connection, and video comes out correct — but
    /// `AVCapturePhotoOutput` doesn't honour that angle as reliably as
    /// `AVCaptureMovieFileOutput` does, so the still can come back shaped or
    /// tagged differently from what the angle implied. Rather than trusting the
    /// connection, this checks the decoded result against the angle and fixes
    /// it if they disagree.
    ///
    /// The output is always `.up` with the rotation in the pixels, so nothing
    /// downstream has to agree about EXIF: the review screen, the upload and the
    /// feed all read the same image.
    static func orientedJPEG(from data: Data, rotationAngle: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }

        let wantsLandscape = rotationAngle == 0 || rotationAngle == 180
        // `size` is the *displayed* size — EXIF already applied.
        let isLandscape = image.size.width > image.size.height

        // Right shape and already flat: the file is fine as it stands.
        if isLandscape == wantsLandscape, image.imageOrientation == .up { return data }

        // A quarter turn only when the shape is wrong. When it's merely tagged,
        // redrawing flattens the tag into the pixels and changes nothing else.
        //
        // Direction is derived from which landscape edge the interface is on.
        // If a still ever comes out rotated the *wrong* way, this sign is the
        // one thing to flip — the log line below says which branch ran.
        let quarterTurn: CGFloat
        if isLandscape == wantsLandscape {
            quarterTurn = 0
        } else {
            quarterTurn = rotationAngle == 180 ? -.pi / 2 : .pi / 2
        }

        let targetSize = quarterTurn == 0
            ? image.size
            : CGSize(width: image.size.height, height: image.size.width)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: targetSize.width / 2, y: targetSize.height / 2)
            cgContext.rotate(by: quarterTurn)
            // `draw` applies `imageOrientation`, so this flattens EXIF too.
            image.draw(in: CGRect(x: -image.size.width / 2,
                                  y: -image.size.height / 2,
                                  width: image.size.width,
                                  height: image.size.height))
        }

        cameraLog.info("""
            still corrected: angle=\(rotationAngle, privacy: .public) \
            wantsLandscape=\(wantsLandscape, privacy: .public) \
            was=\(Int(image.size.width))x\(Int(image.size.height)) \
            exif=\(image.imageOrientation.rawValue, privacy: .public) \
            turn=\(Int(quarterTurn * 180 / .pi), privacy: .public)°
            """)

        return rendered.jpegData(compressionQuality: 0.9)
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Same angle the outputs are given, so the viewfinder can't disagree with
    /// the file it produces. See `CameraModel.startTrackingRotation(for:)`.
    var rotationAngle: CGFloat

    /// Whether the front camera is live, so the viewfinder can be mirrored
    /// explicitly rather than inheriting whatever default the connection came up
    /// with. See `PreviewView.push()`.
    var isFrontCamera: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.apply(rotation: rotationAngle, mirrored: isFrontCamera)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.apply(rotation: rotationAngle, mirrored: isFrontCamera)
    }

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        private var wantedAngle: CGFloat = 0
        private var wantedMirroring = false

        /// The preview layer owns its own connection, which needs the rotation
        /// and mirroring pushed onto it separately from the outputs'.
        ///
        /// The values are *stored* rather than pushed and forgotten, because
        /// this view's lifecycle and the session's are not synchronised: the
        /// connection only exists once `configure()` has committed a live
        /// input/output graph on the session queue, and `makeUIView` regularly
        /// runs before that. A push that lands early has nothing to write to,
        /// and the coordinator won't offer another angle unless the phone is
        /// physically turned — so a viewfinder opened already-landscape and held
        /// still used to stay stuck on the raw connection's defaults forever,
        /// unrotated and mirrored, while the file it produced came out correct.
        func apply(rotation angle: CGFloat, mirrored: Bool) {
            wantedAngle = angle
            wantedMirroring = mirrored
            push()
        }

        /// UIKit calls this repeatedly as the view settles, including after the
        /// session's graph has come up, so it's the safety net that lets a push
        /// that arrived too early eventually land.
        override func layoutSubviews() {
            super.layoutSubviews()
            push()
        }

        private func push() {
            guard let connection = previewLayer.connection else { return }
            if connection.isVideoRotationAngleSupported(wantedAngle),
               connection.videoRotationAngle != wantedAngle {
                connection.videoRotationAngle = wantedAngle
            }
            guard connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirrored != wantedMirroring {
                connection.isVideoMirrored = wantedMirroring
            }
        }
    }
}
