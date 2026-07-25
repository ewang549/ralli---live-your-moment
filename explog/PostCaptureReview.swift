import SwiftUI
import UIKit

/// The moment right after capture: the shot full-bleed, a creative rail of tools
/// (text, stickers, draw) down one edge, and a prominent coral **Next** that
/// carries the log into the audience picker. Mirrors the Snap/Instagram flow —
/// this is where captions and stickers get added before posting.
///
/// The captured media stays the source of truth; overlays are a creative layer
/// on top. On Next we hand the chosen share screen the original media plus a
/// caption seeded from any text you added (full burn-in of stickers/drawing
/// into an exported video is a larger, separate job — for photos, Save
/// composites what you see).
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
    @State private var texts: [TextItem] = []
    @State private var stickers: [StickerItem] = []
    @State private var strokes: [Stroke] = []
    @State private var liveStroke: Stroke?
    @State private var selectedID: UUID?

    // Tool state.
    @State private var tool: Tool = .none
    @State private var brushColor: Color = Theme.coral
    @State private var editingText: TextItem?

    // Flow.
    @State private var showSend = false
    /// Whether Next opens the place composer instead of the friends picker.
    @State private var postToPlace = false
    @State private var savedToast = false
    @State private var showStickerTray = false

    private enum Tool { case none, draw }

    /// Fun starter tray for stickers.
    private let emojiTray = ["✨", "❤️", "🔥", "😎", "🥹", "🎉", "☕️", "🌆", "🎧", "🌿", "💯", "👀", "🫶", "🍜"]
    /// Coral-forward creative palette (white first for legibility over media).
    private let palette: [Color] = [.white, Theme.coral, Color(hex: 0xFF7D90), Theme.mint, Theme.amber, .black]

    private var caption: String {
        texts.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

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

                // The hour banner, in exactly the type the viewfinder showed it
                // in — same component, so the stamp can't drift between the two
                // screens. Live, because the log is stamped when it's sent, not
                // when it was shot.
                LiveHourOverlay()

                // Drawing surface + committed overlays.
                strokeCanvas
                overlayLayer(in: geo.size)

                // Finger-draw capture sits above overlays only while drawing.
                if tool == .draw {
                    drawingSurface.ignoresSafeArea()
                }

                // Chrome.
                controls
                if tool == .draw { brushBar }
                if showStickerTray { stickerTray }
                if let item = editingText { textEditor(for: item) }
                if savedToast { savedBanner }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSend) {
            if postToPlace {
                PublicPlacePostView(media: media, initialName: caption,
                                    logSync: logSync, onSent: onSent)
            } else {
                SendToFriendsView(media: media, initialLabel: caption,
                                  logSync: logSync, onSent: onSent)
            }
        }
        .onAppear { seedOverlayDefaults() }
    }

    // MARK: - Media

    private var previewClip: Clip {
        Clip(author: nil, chat: nil, capturedAt: .now, kind: media.kind,
             assetFileName: media.assetFileName,
             label: "", emoji: "✨", hueA: 0.03, hueB: 0.12)
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
        texts.append(TextItem(text: "good night ✦", color: .white,
                              position: CGPoint(x: mid, y: 260), scale: 1.3, rotation: .degrees(-4)))
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
        ForEach($texts) { $item in
            MovableOverlay(position: $item.position, scale: $item.scale, rotation: $item.rotation,
                           isSelected: selectedID == item.id,
                           onSelect: { selectedID = item.id },
                           onDoubleTap: { editingText = item }) {
                Text(item.text.isEmpty ? "Tap to edit" : item.text)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(item.color)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    .padding(.horizontal, 6)
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

    /// The vertical creative rail: Text, Sticker, Draw.
    private var creativeRail: some View {
        VStack(spacing: 12) {
            ReviewRailButton(system: "textformat", label: "Text", isActive: false) { addText() }
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
            showSend = true
        } label: {
            HStack(spacing: 6) {
                Text("Next")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Image(systemName: "arrow.right")
                    .font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Theme.onCoral)
            .padding(.horizontal, 22)
            .frame(height: 52)
            .background(Capsule().fill(Theme.coral))
            .shadow(color: Theme.coralGlow.opacity(0.5), radius: 14, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(postToPlace ? "Next: name this place post" : "Next: choose who to send to")
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
            VStack(spacing: 12) {
                Capsule().fill(Theme.textTertiary).frame(width: 36, height: 5).padding(.top, 8)
                Text("Stickers")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 14) {
                    ForEach(emojiTray, id: \.self) { emoji in
                        Button { dropSticker(emoji) } label: {
                            Text(emoji).font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .ignoresSafeArea()
        .background(
            Color.black.opacity(0.25).ignoresSafeArea()
                .onTapGesture { withAnimation { showStickerTray = false } }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Text editor

    private func textEditor(for item: TextItem) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                .onTapGesture { commitText() }
            VStack(spacing: 24) {
                TextField("", text: bindingForText(item.id)?.text ?? .constant(""), axis: .vertical)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(currentTextColor(item.id))
                    .tint(Theme.coral)
                    .padding(.horizontal, 24)

                // Colour picker for the text.
                HStack(spacing: 14) {
                    ForEach(palette.indices, id: \.self) { i in
                        let color = palette[i]
                        Button {
                            bindingForText(item.id)?.wrappedValue.color = color
                        } label: {
                            Circle().fill(color).frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
                                .overlay {
                                    if colorsEqual(color, currentTextColor(item.id)) {
                                        Circle().strokeBorder(Theme.coral, lineWidth: 2.5).padding(-4)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("Done") { commitText() }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.onCoral)
                    .padding(.horizontal, 28).frame(height: 46)
                    .background(Capsule().fill(Theme.coral))
                    .buttonStyle(.plain)
            }
        }
        .transition(.opacity)
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

    private func addText() {
        tool = .none
        let item = TextItem(text: "", color: .white,
                            position: CGPoint(x: UIScreen.main.bounds.midX, y: UIScreen.main.bounds.midY),
                            scale: 1, rotation: .zero)
        texts.append(item)
        selectedID = item.id
        editingText = item
    }

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
        texts.removeAll { $0.id == selectedID }
        stickers.removeAll { $0.id == selectedID }
        selectedID = nil
    }

    private func commitText() {
        // Drop empty text overlays on close.
        texts.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        withAnimation(.easeInOut(duration: 0.2)) { editingText = nil }
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
            ForEach(texts) { item in
                Text(item.text)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(item.color)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
                    .scaleEffect(item.scale).rotationEffect(item.rotation)
                    .position(item.position)
            }
        }
    }

    // MARK: - Bindings & helpers

    private func bindingForText(_ id: UUID) -> Binding<TextItem>? {
        guard let idx = texts.firstIndex(where: { $0.id == id }) else { return nil }
        return $texts[idx]
    }

    private func currentTextColor(_ id: UUID) -> Color {
        texts.first { $0.id == id }?.color ?? .white
    }

    private func colorsEqual(_ a: Color, _ b: Color) -> Bool {
        UIColor(a).cgColor == UIColor(b).cgColor
    }
}

// MARK: - Sticker tray overlay

private extension PostCaptureReview {
    // The tray is presented via a confirmationDialog-like grid; kept simple.
}

// MARK: - Overlay models

private struct TextItem: Identifiable {
    let id = UUID()
    var text: String
    var color: Color
    var position: CGPoint
    var scale: CGFloat
    var rotation: Angle
}

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

/// A soft glass circle used across the review chrome.
private struct ReviewIconButton: View {
    let system: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(Circle().fill(.ultraThinMaterial))
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
