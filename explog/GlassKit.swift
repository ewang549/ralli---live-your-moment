import SwiftUI

/// Liquid Glass component set. New screens compose these instead of styling
/// surfaces ad hoc, so the material language stays consistent as the social
/// layer grows. Tokens live in `Theme` (see "Liquid Glass tokens").
///
/// The look: real background blur, a faint bright top edge (specular highlight),
/// a darker bottom edge, a soft inner sheen, and a gentle shadow so each pane
/// floats above the one behind it.

// MARK: - Glass container

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 22
    /// `.regularMaterial` for foreground panes, `.ultraThinMaterial` for
    /// background layers that should read as further away.
    var material: Material = .ultraThinMaterial
    /// Slight lift on press, used by interactive cards.
    var isPressed: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
                    .overlay {
                        // Inner sheen: light gathers at the top of the pane.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Theme.glassTint, .clear, Color.black.opacity(0.08)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                    }
                    .overlay {
                        // Rim light: bright top edge fading to a dark bottom edge.
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Theme.glassRimTop, .white.opacity(0.06), Theme.glassRimBottom],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
            }
            .brightness(isPressed ? 0.05 : 0) // glass catches more light under a finger
            .animation(.easeOut(duration: 0.18), value: isPressed)
    }
}

/// Horizontal glass surface for bars (headers, toolbars, floating controls).
struct GlassBar<Content: View>: View {
    var cornerRadius: CGFloat = 26
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(colors: [Theme.glassTint, .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: [Theme.glassRimTop, Theme.glassRimBottom],
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 1
                            )
                    }
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
            }
    }
}

// MARK: - Glow

/// A small gold orb lit from within — unread, live, "now". Used sparingly:
/// it's the one warm light against the cool dark glass.
struct GlowDot: View {
    var size: CGFloat = 9
    var color: Color = Theme.goldGlow
    /// Slow breathing bloom for "live" states.
    var breathing: Bool = false

    @State private var bloom = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [.white.opacity(0.95), color, Theme.goldDeep],
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 0, endRadius: size * 0.75
                )
            )
            .frame(width: size, height: size)
            .shadow(color: color.opacity(bloom ? 0.95 : 0.6), radius: bloom ? size * 1.1 : size * 0.7)
            .shadow(color: color.opacity(0.35), radius: size * 1.8)
            .onAppear {
                guard breathing else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    bloom = true
                }
            }
    }
}

// MARK: - Glass orb avatar

/// Avatars as polished glass marbles: a dimensional bubble with a specular
/// hotspot near the top-left, smooth falloff, and a thin luminous rim.
struct GlassOrbAvatar: View {
    let emoji: String
    /// Base hue of the sphere (matches `Friend.hue`).
    var hue: Double = 0.58
    var size: CGFloat = 44
    /// Gold ring for "has posted" / active states.
    var isActive: Bool = false

    var body: some View {
        ZStack {
            // Body of the sphere: lit from the top-left, falling into shadow.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hue: hue, saturation: 0.45, brightness: 1.0),
                            Color(hue: hue, saturation: 0.7, brightness: 0.72),
                            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1),
                                  saturation: 0.85, brightness: 0.34),
                        ],
                        center: .init(x: 0.3, y: 0.26),
                        startRadius: size * 0.02, endRadius: size * 0.8
                    )
                )

            Text(emoji)
                .font(.system(size: size * 0.44))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)

            // Specular hotspot — the wet, glassy highlight.
            Ellipse()
                .fill(
                    LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.05)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .frame(width: size * 0.42, height: size * 0.26)
                .blur(radius: size * 0.045)
                .offset(x: -size * 0.16, y: -size * 0.28)
                .blendMode(.plusLighter)

            // Thin luminous rim.
            Circle()
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.65), .white.opacity(0.08), .black.opacity(0.25)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: max(1, size * 0.022)
                )
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.5), radius: size * 0.16, y: size * 0.07)
        .overlay {
            if isActive {
                Circle()
                    .strokeBorder(Theme.goldSheen, lineWidth: max(1.5, size * 0.05))
                    .padding(-size * 0.09)
                    .shadow(color: Theme.goldGlow.opacity(0.7), radius: size * 0.14)
            }
        }
    }
}

/// Convenience overload so existing `Friend` rows can adopt the orb look.
extension GlassOrbAvatar {
    init(friend: Friend, size: CGFloat = 44, isActive: Bool = false) {
        self.init(emoji: friend.emoji, hue: friend.hue, size: size, isActive: isActive)
    }
}

// MARK: - Wordmark

/// "Explog" in an elegant serif with a metallic gold sheen.
struct ExplogWordmark: View {
    var size: CGFloat = 44

    var body: some View {
        Text("Explog")
            .font(.system(size: size, weight: .bold, design: .serif))
            .foregroundStyle(Theme.goldSheen)
            .shadow(color: Theme.goldGlow.opacity(0.35), radius: 12)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
    }
}

// MARK: - Background

/// Standard page background for new screens: dark warm charcoal gradient with
/// a faint gold bloom so the glass has something to refract.
struct GlassBackground: View {
    var body: some View {
        ZStack {
            Theme.appBackground
            RadialGradient(
                colors: [Theme.goldGlow.opacity(0.11), .clear],
                center: .init(x: 0.5, y: 0.12),
                startRadius: 0, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Glass field & button

/// Text field on a glass pane — used by onboarding and search.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            TextField(placeholder, text: $text)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            GlassCard(cornerRadius: 16) { Color.clear }
        }
    }
}

/// Primary action: a warm gold pill that glows.
struct GoldButton: View {
    let title: String
    var busy: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(.black)
                } else {
                    Text(title).font(.headline)
                }
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background {
                Capsule()
                    .fill(enabled ? AnyShapeStyle(Theme.goldSheen)
                                  : AnyShapeStyle(Color.white.opacity(0.12)))
                    .shadow(color: enabled ? Theme.goldGlow.opacity(0.5) : .clear, radius: 14, y: 4)
            }
        }
        .disabled(!enabled || busy)
    }
}
