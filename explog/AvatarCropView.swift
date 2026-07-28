import SwiftUI
import UIKit

/// Drag-and-pinch circular crop, shown between picking a photo and saving it.
///
/// Avatars are displayed through a circular mask (`GlassOrbAvatar`, `AvatarView`)
/// with `.scaledToFill()`, which is a blind centre crop — whatever happened to
/// be in the middle of the original survived and an off-centre face was simply
/// cut in half, with no way to say otherwise. Neither `PhotosPicker` nor
/// `PHPickerViewController` offers a crop step, so this is it.
///
/// The mask here is the same circle the avatar will ultimately be drawn in, so
/// what you frame is exactly what you get.
struct AvatarCropView: View {
    let image: UIImage
    /// The cropped square. The caller saves it; cancelling never calls this.
    let onCrop: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Committed transform, updated when each gesture ends so the framing
    /// survives between gestures rather than snapping back.
    @State private var offset: CGSize = .zero
    @State private var scale: CGFloat = 1

    @GestureState private var dragTranslation: CGSize = .zero
    @GestureState private var gestureScale: CGFloat = 1

    /// How far the image can be zoomed. The lower bound is 1 — the image always
    /// at least covers the circle, so a crop can never contain empty space.
    private let minScale: CGFloat = 1
    private let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { proxy in
            // The circle is inset from the narrower screen edge, so the crop
            // area is identical in portrait and landscape.
            let diameter = min(proxy.size.width, proxy.size.height) - 64

            ZStack {
                Color.black.ignoresSafeArea()

                cropSurface(diameter: diameter)

                // Everything outside the circle dimmed, so the framing reads at
                // a glance. `.reverse` on an even-odd fill punches the hole.
                maskOverlay(diameter: diameter)
                    .allowsHitTesting(false)

                controls(diameter: diameter)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Surface

    private func cropSurface(diameter: CGFloat) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            // Sized so the image exactly covers the circle at scale 1, which is
            // what makes `minScale` a genuine floor rather than an estimate.
            .frame(width: diameter, height: diameter)
            .scaleEffect(scale * gestureScale)
            .offset(x: offset.width + dragTranslation.width,
                    y: offset.height + dragTranslation.height)
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .gesture(dragGesture.simultaneously(with: magnifyGesture))
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in state = value }
            .onEnded { value in
                scale = min(max(scale * value, minScale), maxScale)
            }
    }

    private func maskOverlay(diameter: CGFloat) -> some View {
        Rectangle()
            .fill(.black.opacity(0.55))
            .reverseMask { Circle().frame(width: diameter, height: diameter) }
            .ignoresSafeArea()
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                    .frame(width: diameter, height: diameter)
            }
    }

    // MARK: - Chrome

    private func controls(diameter: CGFloat) -> some View {
        VStack {
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            Spacer()

            Text("Drag to reposition · pinch to zoom")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.bottom, 14)

            Button {
                onCrop(render(diameter: diameter))
                dismiss()
            } label: {
                Text("Use photo")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.onCoral)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Theme.coral))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    // MARK: - Rendering

    /// Renders what the circle currently frames into a square image.
    ///
    /// Square rather than pre-masked to a circle: every display site already
    /// applies its own `clipShape(Circle())`, and baking transparency in here
    /// would mean a JPEG (which has no alpha) coming back with a black box in
    /// the corners. The circle is the *framing* tool; the saved file is the
    /// square it inscribes.
    ///
    /// Rendered at the source image's own resolution where possible rather than
    /// at screen scale, so zooming in doesn't quietly hand back a thumbnail —
    /// capped so an enormous original can't produce an absurd avatar.
    private func render(diameter: CGFloat) -> UIImage {
        let maxEdge: CGFloat = 1024
        // How much of the original one on-screen point covers, so a crop taken
        // from a large photo keeps that photo's detail.
        let sourceScale = max(image.size.width, image.size.height) / diameter
        let outputEdge = min(maxEdge, max(diameter, diameter * sourceScale))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: outputEdge, height: outputEdge), format: format)

        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: outputEdge, height: outputEdge)))

            // Replay the on-screen transform in output space: the ratio between
            // the rendered square and the on-screen circle is the only
            // conversion needed, since both are the same crop window.
            let ratio = outputEdge / diameter
            let drawn = aspectFillSize(for: image.size, in: diameter) * scale
            let center = CGPoint(x: outputEdge / 2 + offset.width * ratio,
                                 y: outputEdge / 2 + offset.height * ratio)
            let rect = CGRect(x: center.x - drawn.width * ratio / 2,
                              y: center.y - drawn.height * ratio / 2,
                              width: drawn.width * ratio,
                              height: drawn.height * ratio)
            image.draw(in: rect)
        }
    }

    /// The size `scaledToFill` gives an image inside a square of `edge`.
    private func aspectFillSize(for size: CGSize, in edge: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: edge, height: edge) }
        let ratio = max(edge / size.width, edge / size.height)
        return CGSize(width: size.width * ratio, height: size.height * ratio)
    }
}

private extension CGSize {
    static func * (size: CGSize, scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}

extension View {
    /// Punches `mask` out of the receiver rather than keeping it — the inverse
    /// of `.mask`, which SwiftUI has no built-in for.
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            ZStack {
                Rectangle()
                mask().blendMode(.destinationOut)
            }
            .compositingGroup()
        }
    }
}
