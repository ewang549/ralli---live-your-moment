import SwiftUI
import SwiftData
import AVFoundation
import Combine
import PhotosUI
import UIKit

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
/// Snapchat gesture); Video makes a single tap toggle recording; Boomerang fires
/// a short looping burst. Modes never override the `CaptureContext` cap.
enum CaptureMode: String, CaseIterable, Identifiable {
    case boomerang, photo, video

    var id: String { rawValue }

    /// Face on the mode strip, sentence-cased.
    var title: String {
        switch self {
        case .boomerang: "Boomerang"
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
    /// Which gesture the shutter performs.
    @State private var captureMode: CaptureMode = .photo
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

    var body: some View {
        ZStack {
            // Warm dark base behind everything (never pure black).
            Theme.base.ignoresSafeArea()

            viewfinderLayer
                .ignoresSafeArea()

            // Legibility scrims + rule-of-thirds grid ride full-bleed over the
            // viewfinder, beneath the controls.
            edgeScrims.ignoresSafeArea().allowsHitTesting(false)
            if showGrid { RuleOfThirdsGrid().ignoresSafeArea().allowsHitTesting(false) }
            focusReticleLayer.ignoresSafeArea().allowsHitTesting(false)

            // The camera is landscape-only (Ralli video is horizontal), so the
            // controls are laid out for landscape and never reflow to portrait.
            landscapeControls

            // Big self-timer countdown, above everything.
            countdownOverlay.allowsHitTesting(false)
        }
        // Seed the duration from the launching context, push its cap into the
        // session before the first recording, and force the interface into
        // landscape — the camera is landscape-only (Ralli video is horizontal).
        .task {
            maxVideoDuration = VideoDuration(clamping: context.maxClipDuration)
            camera.startIfAvailable(maxDuration: maxDuration)
            InterfaceOrientationLock.lockLandscape()
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
                    CameraPreview(session: camera.session)
                } else {
                    TimeOfDayCard()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .modifier(LookGrade(look: look))
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
            .onTapGesture { location in focus(at: location, in: geo.size) }
        }
    }

    private struct LookGrade: ViewModifier {
        let look: CameraLook
        func body(content: Content) -> some View {
            content.applyLook(look, animated: true)
        }
    }

    /// Soft top/bottom (and right, in landscape) darkening so white glass icons
    /// stay legible over a bright frame, without heavy chrome.
    private var edgeScrims: some View {
        LinearGradient(
            colors: [.black.opacity(0.28), .clear, .clear, .black.opacity(0.32)],
            startPoint: .top, endPoint: .bottom
        )
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

    /// The camera is landscape-only. Shutter pinned to the right edge and
    /// vertically centred (right-thumb zone); flip/flash/gallery stacked just
    /// left of it; close top-leading; grid + self-timer + looks + duration
    /// top-trailing; mode strip and (when open) the looks carousel along the
    /// bottom, inset so they clear the shutter cluster.
    private var landscapeControls: some View {
        ZStack {
            // Top bar.
            VStack {
                HStack(alignment: .top) {
                    closeButton
                    Spacer()
                    HStack(spacing: 10) {
                        gridButton
                        selfTimerButton
                        looksButton
                        durationPill
                    }
                }
                Spacer()
            }

            topReadouts.padding(.top, 4)

            // Mode strip along the bottom; looks carousel rises just above it.
            // Both are inset from the trailing edge so they clear the right-edge
            // shutter cluster.
            VStack(spacing: 12) {
                Spacer()
                if showLooks { looksCarousel }
                modeStrip
            }
            .padding(.trailing, 150)

            // Shutter cluster on the trailing edge, vertically centred.
            HStack {
                Spacer()
                HStack(spacing: 18) {
                    VStack(spacing: 16) {
                        flipButton
                        flashButton
                        galleryButton
                    }
                    shutter
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
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

    /// Gallery / last-capture thumbnail → opens the system photo picker to pull
    /// an existing shot into the send flow.
    private var galleryButton: some View {
        PhotosPicker(selection: $pickedItem, matching: .images) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.glassTint)
                }
                .overlay {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.glassRimTop, lineWidth: 0.75)
                }
                .frame(width: 46, height: 46)
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
            HStack(spacing: 5) {
                Image(systemName: "video")
                    .font(.system(size: 12, weight: .semibold))
                Text(maxVideoDuration.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background {
                Capsule(style: .continuous).fill(.ultraThinMaterial)
                Capsule(style: .continuous).fill(Theme.glassTint)
            }
            .overlay(Capsule(style: .continuous).strokeBorder(Theme.coral, lineWidth: 1.5))
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
    /// (or the underlying swipe on the preview) moves between Photo, Video, and
    /// Boomerang. Sits just under the shutter row.
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
    /// from a mode tap (Video/Boomerang) it runs any armed self-timer first. The
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

    private let size: CGFloat = 82

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
                .stroke(.white, lineWidth: 5)
                .frame(width: size, height: size)

            // Coral progress arc, drawn over the ring while recording.
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.coral, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(-90))
                .shadow(color: Theme.coralGlow.opacity(0.8), radius: 8)

            // Coral-tinted inner fill; shrinks while recording.
            Circle()
                .fill(Theme.coralGradient)
                .frame(width: isRecording ? 34 : 64, height: isRecording ? 34 : 64)
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
                        // Only Photo mode arms hold-to-record; Video/Boomerang
                        // are tap-to-toggle, so a hold there is just a long tap.
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
                        case .video, .boomerang:
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
/// active. The shared secondary-control treatment (≥44pt hit target).
private struct GlassIconButton: View {
    let system: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(isActive ? Theme.coral : .white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(isActive ? Theme.coral.opacity(0.16) : Theme.glassTint)
                }
                .overlay {
                    Circle().strokeBorder(isActive ? Theme.coral.opacity(0.7) : Theme.glassRimTop,
                                          lineWidth: isActive ? 1.5 : 0.75)
                }
        }
        .buttonStyle(.plain)
    }
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

                // Hour, big and calm, with a quiet caption beneath.
                VStack(spacing: 8) {
                    Text(context.date.formatted(.dateTime.hour()))
                        .font(.system(size: 64, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                    Text("no camera here — composing a vibe clip")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
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

    private let movieOutput = AVCaptureMovieFileOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private var videoCompletion: ((String?) -> Void)?
    private var photoCompletion: ((String?) -> Void)?
    private var currentPosition: AVCaptureDevice.Position = .back
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
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted, let self else { return }
            self.configure()
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }

        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
        if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        movieOutput.maxRecordedDuration = CMTime(seconds: maxDuration, preferredTimescale: 600)
        session.commitConfiguration()

        // Reset zoom to the device's baseline on (re)configure.
        zoomFactor = 1
    }

    /// Re-caps an already-running session (e.g. capture reopened from Places).
    func updateMaxDuration(_ seconds: TimeInterval) {
        maxDuration = seconds
        movieOutput.maxRecordedDuration = CMTime(seconds: seconds, preferredTimescale: 600)
    }

    func flip() {
        currentPosition = currentPosition == .back ? .front : .back
        configure()
        // A torch belongs to the device, not the session: re-assert it after the
        // swap so a lit flash survives flipping to a camera that has one.
        applyTorch()
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
        videoCompletion = completion
        isRecording = true
        let url = URL.documentsDirectory.appending(path: "clip-\(UUID().uuidString).mov")
        movieOutput.startRecording(to: url, recordingDelegate: self)
    }

    /// Stops an in-progress recording early; the delegate keeps the file.
    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
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
        DispatchQueue.global(qos: .userInitiated).async {
            self.session.stopRunning()
        }
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            // maxRecordedDuration reached surfaces as an error with a successful file; keep it.
            let succeeded = FileManager.default.fileExists(atPath: outputFileURL.path)
            self.videoCompletion?(succeeded ? outputFileURL.lastPathComponent : nil)
            self.videoCompletion = nil
        }
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
            try? data.write(to: url)
            self.photoCompletion?(fileName)
            self.photoCompletion = nil
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
