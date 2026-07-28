import SwiftUI
import UIKit

/// The moment right after capture: the shot full-bleed, a creative rail of tools
/// (text, stickers, draw) down one edge, and a prominent coral **Next** that
/// carries the log into the audience picker. Mirrors the Snap/Instagram flow —
/// this is where captions and stickers get added before posting.
///
/// Overlays are a creative layer on top of the capture while you're editing,
/// and become part of it on Next: `OverlayBurnIn` composites text, stickers and
/// drawings into the media itself — into the pixels for a photo, through an
/// export for a video — and the share screen is handed that copy. The original
/// file is never modified.
///
/// Burning in rather than carrying the overlays forward as data is what makes
/// them land where they were dragged. There is no schema on `Clip` for a
/// position, a colour, a scale or a rotation, and every playback surface draws
/// `Clip.label` as one fixed caption in the bottom-left — so anything not in
/// the media itself arrives as a generic caption, which is what it used to do.
///
/// Where Next goes is decided *here*, by the place toggle, rather than by a
/// segmented control on the screen after it: off sends you straight to the
/// friends picker, on sends you to the place composer.
struct PostCaptureReview: View {
    let media: CapturedMedia
    /// The look picked in the viewfinder, carried through so the grade persists.
    var look: CameraLook = .normal
    /// Passed through to the share screens — see the note on
    /// `CameraCaptureView.router` for why this is an explicit parameter rather
    /// than `@Environment`.
    let logSync: LogSync
    /// Back to the live viewfinder (discard this take).
    let onRetake: () -> Void
    /// The log was sent — tear the whole capture flow down.
    let onSent: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Creative overlays.
    @State private var stickers: [StickerItem] = []
    @State private var strokes: [Stroke] = []
    @State private var liveStroke: Stroke?
    @State private var selectedID: UUID?

    // Tool state.
    @State private var tool: Tool = .none
    @State private var brushColor: Color = Theme.coral

    /// The one caption on the log, typed here and nowhere else.
    ///
    /// Deliberately *not* an overlay item: it has no position, scale or
    /// rotation, and it is never burned into the media. It travels as
    /// `Clip.label`, which is the field every playback surface already draws —
    /// so one caption typed here is the caption Pulse, the feeds, the profile
    /// and the recap all show, rather than pixels baked wherever they landed.
    @State private var caption: String = ""
    /// Whether this video's audio is silenced on playback.
    ///
    /// Carried on the `Clip` and applied by the player, not stripped from the
    /// file: the recording keeps its audio track, so this stays reversible and
    /// costs no export. Video only — a photo has nothing to mute.
    @State private var isMuted = false
    /// The capture's displayed width ÷ height, resolved once from the file.
    ///
    /// Recorded onto the `Clip` so every surface can size its container to the
    /// real shape of the shot *before* the asset loads. `AVAsset` only reports
    /// a natural size asynchronously, long after layout has run, so resolving
    /// this at playback time would mean laying out against a guess and popping
    /// to the right shape once the video arrived. 0 means "not resolved".
    @State private var mediaAspectRatio: Double = 0

    // Flow.
    @State private var showSend = false
    /// Whether Next opens the place composer instead of the friends picker.
    @State private var postToPlace = false
    @State private var savedToast = false
    @State private var showStickerTray = false
    /// The capture with the creative layer burned into it, produced by Next.
    /// Nil until then, and left nil when there was nothing to burn.
    @State private var composedMedia: CapturedMedia?
    /// Next is compositing. Video re-encodes, which is not instant, so the
    /// button has to say so rather than appearing dead.
    @State private var composing = false

    /// Keyboard focus for the caption field. Without an explicit binding
    /// SwiftUI never focuses a `TextField` just because it appeared, and this
    /// one is meant to be ready to type into the moment the screen arrives.
    @FocusState private var captionFocused: Bool

    private enum Tool { case none, draw }

    /// Coral-forward creative palette (white first for legibility over media).
    private let palette: [Color] = [.white, Theme.coral, Color(hex: 0xFF7D90), Theme.mint, Theme.amber, .black]

    /// Whether anything was actually drawn on the shot.
    private var hasOverlays: Bool {
        !stickers.isEmpty || !strokes.isEmpty
    }

    /// What the send screens are handed: the burned-in copy once Next has
    /// produced one, otherwise the untouched capture.
    private var outgoingMedia: CapturedMedia { composedMedia ?? media }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Theme.base.ignoresSafeArea()

                // The shot at its true aspect, graded with the chosen look.
                //
                // `.fit` rather than the feed's full-bleed `.fill`: capture is
                // landscape-only, so filling a portrait screen cropped the shot
                // into a vertical frame the user never composed. The chrome
                // stays portrait; only the media letterboxes, over black.
                ClipView(clip: previewClip, contentMode: .fit)
                    .applyLook(look)
                    .background(Color.black.ignoresSafeArea())
                    .ignoresSafeArea()

                // Drawing surface + committed overlays.
                strokeCanvas

                // Tap-out target for the selection. It sits *under* the overlay
                // layer, so a tap that lands on a sticker is taken by that
                // item's own select gesture and never reaches here — only taps
                // that miss everything clear the selection (and with it the
                // trash button in the top row) and drop the keyboard.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        selectedID = nil
                        captionFocused = false
                    }

                // The hour banner, in exactly the type the viewfinder showed it
                // in — same component, so the stamp can't drift between the two
                // screens. Live, because the log is stamped when it's sent, not
                // when it was shot. The caption rides directly beneath it, a
                // size down, so the two read as one stamp block.
                //
                // Above the tap-out catcher, or the catcher would swallow every
                // tap aimed at the field and the caption could never be focused.
                VStack(spacing: 6) {
                    LiveHourOverlay()
                    captionField
                }

                overlayLayer(in: geo.size)

                // Finger-draw capture sits above overlays only while drawing.
                if tool == .draw {
                    drawingSurface.ignoresSafeArea()
                }

                // Chrome.
                controls
                if tool == .draw { brushBar }
                if showStickerTray { stickerTray }
                if savedToast { savedBanner }
            }
        }
        .preferredColorScheme(.dark)
        // The send screens get the composited capture, not the raw one — and
        // the caption typed on this screen, which is the only place it can be
        // typed. It travels as data rather than burned pixels, so the send
        // screen can show it back and the feeds can draw it themselves.
        //
        // Presented as a sheet, which is what makes Back work: this view stays
        // alive underneath with its caption, stickers and strokes intact, so
        // dismissing the sheet returns to a screen that is still mid-edit
        // rather than a fresh one.
        .sheet(isPresented: $showSend) {
            if postToPlace {
                PublicPlacePostView(media: outgoingMedia, initialName: caption,
                                    aspectRatio: mediaAspectRatio, isMuted: isMuted,
                                    logSync: logSync, onSent: onSent)
            } else {
                SendToFriendsView(media: outgoingMedia, initialLabel: caption,
                                  aspectRatio: mediaAspectRatio, isMuted: isMuted,
                                  logSync: logSync, onSent: onSent)
            }
        }
        .onAppear { seedOverlayDefaults() }
    }

    /// The caption, fixed under the hour stamp.
    ///
    /// One size down from `HourOverlay`'s 34pt and in the same rounded family,
    /// so it reads as the stamp's second line rather than a separate widget —
    /// and it matches the type every playback surface draws `Clip.label` in.
    private var captionField: some View {
        TextField("", text: $caption, prompt: captionPrompt, axis: .vertical)
            .focused($captionFocused)
            .font(.logCaptionCompact)
            .foregroundStyle(.white)
            .tint(Theme.coral)
            .multilineTextAlignment(.center)
            .lineLimit(1...3)
            .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
            .padding(.horizontal, 28)
            // Focused on arrival: the caption is the one thing this screen is
            // asking for, so the keyboard is up and waiting rather than costing
            // a tap to find. Any tap on the media dismisses it.
            .task {
                // The request has to land after the field is installed; asking
                // in the same tick the view appears is silently dropped.
                try? await Task.sleep(for: .milliseconds(60))
                captionFocused = true
            }
    }

    private var captionPrompt: Text {
        Text("Add a caption")
            .foregroundColor(.white.opacity(0.55))
    }

    // MARK: - Media

    private var previewClip: Clip {
        let clip = Clip(author: nil, chat: nil, capturedAt: .now, kind: media.kind,
                        assetFileName: media.assetFileName,
                        label: "", emoji: "✨", hueA: 0.03, hueB: 0.12)
        // So toggling mute is audible (or rather, inaudible) right here rather
        // than only reaching the recipient.
        clip.isMuted = isMuted
        return clip
    }

    private func seedOverlayDefaults() {
#if DEBUG
        if ProcessInfo.processInfo.environment["EXPLOG_REVIEW_SEND"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { showSend = true }
        }
        // Screenshot hook: pre-populate a caption + sticker + a doodle so a static
        // capture shows the creative surface populated.
        guard ProcessInfo.processInfo.environment["EXPLOG_REVIEW_DEMO"] == "1" else { return }
        let mid = UIScreen.main.bounds.width / 2
        caption = "good night ✦"
        stickers.append(StickerItem(emoji: "🌆",
                                    position: CGPoint(x: mid + 90, y: 430), scale: 1.1, rotation: .degrees(10)))
        stickers.append(StickerItem(emoji: "✨",
                                    position: CGPoint(x: mid - 100, y: 380), scale: 0.9, rotation: .zero))
        strokes.append(Stroke(points: (0...20).map { i in
            let t = Double(i) / 20
            return CGPoint(x: mid - 120 + t * 240, y: 520 + sin(t * .pi * 3) * 22)
        }, color: Theme.coral, width: 7))
#endif
    }

    // MARK: - Overlays

    private var strokeCanvas: some View {
        Canvas { ctx, _ in
            for stroke in strokes { draw(stroke, in: ctx) }
            if let liveStroke { draw(liveStroke, in: ctx) }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func draw(_ stroke: Stroke, in ctx: GraphicsContext) {
        guard stroke.points.count > 1 else { return }
        var path = Path()
        path.addLines(stroke.points)
        ctx.stroke(path, with: .color(stroke.color),
                   style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
    }

    @ViewBuilder
    private func overlayLayer(in size: CGSize) -> some View {
        ForEach($stickers) { $item in
            MovableOverlay(position: $item.position, scale: $item.scale, rotation: $item.rotation,
                           isSelected: selectedID == item.id,
                           onSelect: { selectedID = item.id }) {
                Text(item.emoji).font(.system(size: 72))
            }
        }
    }

    /// Transparent full-screen catcher that records finger strokes in draw mode.
    private var drawingSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if liveStroke == nil {
                            liveStroke = Stroke(points: [v.location], color: brushColor, width: brushWidth)
                        } else {
                            liveStroke?.points.append(v.location)
                        }
                    }
                    .onEnded { _ in
                        if let liveStroke, liveStroke.points.count > 1 { strokes.append(liveStroke) }
                        liveStroke = nil
                    }
            )
            // Tap-out, so the rail button isn't the only way back. Simultaneous
            // rather than `.onTapGesture` so it composes with the drag above:
            // a real stroke starts as a drag and never resolves as a tap, while
            // a tap-without-movement leaves at most a one-point stroke, which
            // the `points.count > 1` guard already throws away.
            .simultaneousGesture(
                TapGesture().onEnded {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { tool = .none }
                }
            )
    }

    private var brushWidth: CGFloat { 8 }

    // MARK: - Chrome

    private var controls: some View {
        VStack(spacing: 0) {
            // Top row: retake + (delete selected) + save.
            HStack {
                ReviewIconButton(system: "chevron.left") { onRetake() }
                    .accessibilityLabel("Retake")
                Spacer()
                if selectedID != nil {
                    ReviewIconButton(system: "trash") { deleteSelected() }
                        .accessibilityLabel("Delete selection")
                }
                // Video only — the inverse of the Save-to-Photos gate below.
                // A photo has no audio track, so a mute control on one would be
                // a button that does nothing.
                if media.kind == .video {
                    ReviewIconButton(system: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                     isActive: isMuted) {
                        isMuted.toggle()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .accessibilityLabel("Mute audio")
                    .accessibilityValue(isMuted ? "Muted" : "Sound on")
                }
                if media.kind != .video {
                    ReviewIconButton(system: "arrow.down.to.line") { saveComposite() }
                        .accessibilityLabel("Save to photos")
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()

            // Bottom: creative rail (left) + destination toggle over the
            // coral Next (right).
            HStack(alignment: .bottom) {
                creativeRail
                Spacer()
                VStack(alignment: .trailing, spacing: 10) {
                    placeToggle
                    nextButton
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
    }

    /// The vertical creative rail: Sticker, Draw.
    ///
    /// Text used to head this rail as a draggable, pinchable overlay item. The
    /// caption field on this screen replaced it: one caption, in one place, at a
    /// fixed spot under the hour stamp — so what you type is what every surface
    /// draws, rather than something burned wherever it happened to be dropped.
    private var creativeRail: some View {
        VStack(spacing: 12) {
            ReviewRailButton(system: "face.smiling", label: "Sticker", isActive: false) { addSticker() }
            ReviewRailButton(system: "scribble.variable", label: "Draw", isActive: tool == .draw) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                    tool = tool == .draw ? .none : .draw
                    selectedID = nil
                }
            }
        }
    }

    /// Chooses what Next opens: off → the friends picker, on → the place
    /// composer (name, location, audience).
    ///
    /// A glass capsule that fills coral when armed — the same on/off language
    /// the creative rail uses for Draw, rather than a borrowed icon set.
    private var placeToggle: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                postToPlace.toggle()
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: postToPlace ? "mappin.circle.fill" : "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold))
                Text("Post to a place")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(postToPlace ? Theme.onCoral : .white)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background {
                Capsule().fill(.ultraThinMaterial)
                if postToPlace { Capsule().fill(Theme.coral) }
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Post to a place")
        .accessibilityValue(postToPlace ? "On" : "Off")
        .accessibilityHint("Next asks for a name, a location, and who can see it")
    }

    private var nextButton: some View {
        Button {
            selectedID = nil
            Task { await advance() }
        } label: {
            HStack(spacing: 6) {
                if composing {
                    ProgressView()
                        .tint(Theme.onCoral)
                        .scaleEffect(0.8)
                    Text("Adding your text…")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                } else {
                    Text("Next")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .foregroundStyle(Theme.onCoral)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule().fill(Theme.coral))
            .shadow(color: Theme.coralGlow.opacity(0.5), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(composing)
        .animation(.easeOut(duration: 0.18), value: composing)
        .accessibilityLabel(postToPlace ? "Next: name this place post" : "Next: choose who to send to")
    }

    /// Burns the creative layer into the capture, then opens the send screen.
    ///
    /// Done here rather than at capture time because this is the first moment
    /// the overlays are final, and rather than at playback because burning in
    /// once beats compositing on every view — and because it means every
    /// surface that plays a clip stays a plain video player.
    ///
    /// A capture with nothing drawn on it skips all of this and goes straight
    /// through, so the common case pays nothing.
    private func advance() async {
        guard hasOverlays else {
            // Clearing rather than leaving it: Back from the send screen can
            // return here and delete every sticker and stroke, and a stale
            // burned-in copy would then be sent with overlays the user removed.
            composedMedia = nil
            await resolveAspectRatio(of: media)
            showSend = true
            return
        }
        composing = true
        defer { composing = false }

        if let render = renderOverlayLayer() {
            composedMedia = await OverlayBurnIn.burn(render, into: media)
        }
        // Measured on what actually gets sent. The burn-in re-encodes through a
        // video composition, so the exported copy is the one whose shape the
        // feeds will be sizing containers to.
        await resolveAspectRatio(of: outgoingMedia)
        showSend = true
    }

    /// Reads the capture's displayed dimensions once, for `Clip.videoAspectRatio`.
    ///
    /// `OverlayBurnIn.naturalSize` already resolves this correctly for both
    /// kinds — orientation-applied for a photo, preferred-transform-applied for
    /// a video — and it is the same measurement the burn-in crops against, so
    /// sharing it keeps the stored ratio and the baked overlay in agreement.
    private func resolveAspectRatio(of media: CapturedMedia) async {
        guard let size = await OverlayBurnIn.naturalSize(of: media),
              size.width > 0, size.height > 0 else { return }
        mediaAspectRatio = Double(size.width / size.height)
    }

    /// Flattens the overlays — and only the overlays — onto a transparent
    /// screen-sized canvas.
    ///
    /// Transparent rather than including the media, because the media is
    /// already the thing being drawn onto and re-encoding it through
    /// `ImageRenderer` would throw away its resolution. `saveComposite()` does
    /// include it, correctly: that path is producing a screenshot for Photos,
    /// not a replacement for the capture.
    @MainActor
    private func renderOverlayLayer() -> OverlayBurnIn.OverlayRender? {
        let screen = UIScreen.main.bounds.size
        let renderer = ImageRenderer(content:
            ZStack {
                Color.clear
                staticStrokeCanvas
                staticOverlays
            }
            .frame(width: screen.width, height: screen.height)
        )
        renderer.scale = UIScreen.main.scale
        // Without this the renderer fills the untouched areas with white and
        // the burn-in covers the whole shot.
        renderer.isOpaque = false
        guard let image = renderer.uiImage else { return nil }
        return OverlayBurnIn.OverlayRender(image: image, screenSize: screen)
    }

    // MARK: - Brush bar (draw mode)

    private var brushBar: some View {
        VStack {
            Spacer()
            HStack(spacing: 14) {
                ForEach(palette.indices, id: \.self) { i in
                    let color = palette[i]
                    Button {
                        brushColor = color
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                            .overlay {
                                if colorsEqual(color, brushColor) {
                                    Circle().strokeBorder(Theme.coral, lineWidth: 2.5).padding(-4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    if !strokes.isEmpty { strokes.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .disabled(strokes.isEmpty)
                .opacity(strokes.isEmpty ? 0.4 : 1)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 90)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Sticker tray

    private var stickerTray: some View {
        VStack {
            Spacer()
            EmojiPickerTray { dropSticker($0) }
        }
        .ignoresSafeArea()
        .background(
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { withAnimation { showStickerTray = false } }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var savedBanner: some View {
        VStack {
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.mint)
                Text("Saved to Photos").font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Capsule().fill(.ultraThinMaterial))
            .padding(.bottom, 120)
        }
        .transition(.opacity)
        .allowsHitTesting(false)
    }

    // MARK: - Actions

    private func addSticker() {
        tool = .none
        selectedID = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showStickerTray = true }
    }

    private func dropSticker(_ emoji: String) {
        let item = StickerItem(emoji: emoji,
                               position: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY),
                               scale: 1, rotation: .zero)
        stickers.append(item)
        selectedID = item.id
        showStickerTray = false
    }

    private func deleteSelected() {
        stickers.removeAll { $0.id == selectedID }
        selectedID = nil
    }

    /// Composites the media + overlays into an image and writes it to Photos.
    private func saveComposite() {
        let renderer = ImageRenderer(content:
            ZStack {
                // Same `.fit` over black as the review screen, so the saved
                // image matches what the overlays were positioned against.
                Color.black
                ClipView(clip: previewClip, contentMode: .fit).applyLook(look)
                staticStrokeCanvas
                staticOverlays
            }
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.height)
        )
        renderer.scale = UIScreen.main.scale
        guard let image = renderer.uiImage else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation { savedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { savedToast = false }
        }
    }

    /// Non-interactive copies of the overlays for rendering.
    private var staticStrokeCanvas: some View {
        Canvas { ctx, _ in for stroke in strokes { draw(stroke, in: ctx) } }
    }

    private var staticOverlays: some View {
        ZStack {
            ForEach(stickers) { item in
                Text(item.emoji).font(.system(size: 72))
                    .scaleEffect(item.scale).rotationEffect(item.rotation)
                    .position(item.position)
            }
        }
    }

    // MARK: - Bindings & helpers

    private func colorsEqual(_ a: Color, _ b: Color) -> Bool {
        UIColor(a).cgColor == UIColor(b).cgColor
    }
}

// MARK: - Sticker tray overlay

private extension PostCaptureReview {
    // The tray is presented via a confirmationDialog-like grid; kept simple.
}

// MARK: - Overlay models

private struct StickerItem: Identifiable {
    let id = UUID()
    var emoji: String
    var position: CGPoint
    var scale: CGFloat
    var rotation: Angle
}

private struct Stroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    var color: Color
    var width: CGFloat
}

// MARK: - Movable overlay container

/// Wraps content with move / pinch-scale / rotate gestures, committing to the
/// bound transform on end so overlays stay put between gestures. A coral ring
/// marks the selection.
private struct MovableOverlay<Content: View>: View {
    @Binding var position: CGPoint
    @Binding var scale: CGFloat
    @Binding var rotation: Angle
    var isSelected: Bool
    var onSelect: () -> Void
    var onDoubleTap: (() -> Void)? = nil
    @ViewBuilder var content: () -> Content

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1
    @GestureState private var gestureRotation: Angle = .zero

    var body: some View {
        let drag = DragGesture()
            .updating($dragTranslation) { v, s, _ in s = v.translation }
            .onEnded { v in
                position.x += v.translation.width
                position.y += v.translation.height
            }
        let magnify = MagnificationGesture()
            .updating($gestureScale) { v, s, _ in s = v }
            .onEnded { v in scale = min(max(scale * v, 0.3), 6) }
        let rotate = RotationGesture()
            .updating($gestureRotation) { v, s, _ in s = v }
            .onEnded { v in rotation += v }

        content()
            .padding(6)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.coral, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
            }
            .scaleEffect(scale * gestureScale)
            .rotationEffect(rotation + gestureRotation)
            .position(x: position.x + dragTranslation.width,
                      y: position.y + dragTranslation.height)
            .gesture(drag.simultaneously(with: magnify).simultaneously(with: rotate))
            .onTapGesture(count: 2) { onDoubleTap?() }
            .onTapGesture { onSelect() }
    }
}

// MARK: - Buttons

/// A soft glass circle used across the review chrome. Fills coral when it
/// represents an armed state, matching the creative rail's on/off language.
private struct ReviewIconButton: View {
    let system: String
    var isActive: Bool = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? Theme.onCoral : .white)
                .frame(width: 46, height: 46)
                .background {
                    Circle().fill(.ultraThinMaterial)
                    if isActive { Circle().fill(Theme.coral) }
                }
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        }
        .buttonStyle(.plain)
    }
}

/// A creative-rail item: icon over a tiny label, coral when active.
private struct ReviewRailButton: View {
    let system: String
    let label: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: system)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isActive ? Theme.onCoral : .white)
                    .frame(width: 48, height: 48)
                    .background {
                        Circle().fill(.ultraThinMaterial)
                        if isActive { Circle().fill(Theme.coral) }
                    }
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
                Text(label)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .buttonStyle(.plain)
    }
}
