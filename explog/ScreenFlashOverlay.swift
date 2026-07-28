import SwiftUI

/// The front-camera "screen flash": a white ring of light around the edges of
/// the viewfinder, standing in for the torch the front camera doesn't have.
///
/// A ring rather than a full white sheet because the middle of the screen is
/// the preview — the thing being lit is the user's face, and washing out the
/// image they're framing defeats the point. The ring throws light from the
/// bezel inward while leaving the centre clear, which is also how the ring
/// lights people actually buy for this are shaped.
///
/// At `thickness` 1 the ring closes up and the whole screen glows, for when
/// maximum output matters more than seeing the preview.
struct ScreenFlashOverlay: View {
    /// 0…1. Drives opacity, so this is reversible and scoped to this view —
    /// see `CameraCapture.screenFlashBrightness`.
    let brightness: Double
    /// 0…1 of the shorter screen edge.
    let thickness: Double

    var body: some View {
        GeometryReader { proxy in
            let shortEdge = min(proxy.size.width, proxy.size.height)
            // Half the short edge is the point at which a ring drawn from both
            // sides meets in the middle — beyond that there is no hole left.
            let inset = shortEdge * 0.5 * clamped(thickness)

            ZStack {
                // The glow itself. A soft radial falloff rather than a hard
                // band, so the light reads as illumination rather than as a
                // white border drawn on top of the picture.
                RadialGradient(
                    colors: [.clear, .white.opacity(0.35), .white],
                    center: .center,
                    startRadius: max(0, shortEdge * 0.5 - inset),
                    endRadius: shortEdge * 0.75
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .opacity(clamped(brightness))
            // Pure readout — it must never take a tap away from the shutter or
            // the controls sitting under it.
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.15), value: brightness)
            .animation(.easeOut(duration: 0.15), value: thickness)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}

/// Brightness and thickness sliders for the screen flash, shown only while it
/// is actually on (front camera + flash armed).
///
/// Deliberately compact and translucent: it sits over a live viewfinder that
/// the user is framing themselves in, so it has to be adjustable without
/// covering the shot.
struct ScreenFlashControls: View {
    @Binding var brightness: Double
    @Binding var thickness: Double

    var body: some View {
        VStack(spacing: 8) {
            row(icon: "sun.max.fill", value: $brightness, label: "Flash brightness")
            row(icon: "circle.dashed", value: $thickness, label: "Flash ring thickness")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    private func row(icon: String, value: Binding<Double>, label: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 16)
            Slider(value: value, in: 0...1)
                .tint(Theme.coral)
                .frame(width: 130)
                .accessibilityLabel(label)
        }
    }
}
