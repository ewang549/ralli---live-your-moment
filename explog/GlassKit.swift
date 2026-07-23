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

// MARK: - Gold action rail

/// One button in a full-bleed feed's right-hand rail: a glass disc, a gold-
/// tinted glyph, and an optional count underneath. The active state (liked,
/// saved) fills the glyph and blooms gold so it reads instantly over video.
struct GoldRailButton: View {
    let icon: String
    /// Glyph swapped for its filled variant when active, e.g. "heart" → "heart.fill".
    var activeIcon: String?
    var count: Int?
    var isActive: Bool = false
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle().fill(
                                LinearGradient(colors: [Theme.glassTint, .clear],
                                               startPoint: .top, endPoint: .bottom)
                            )
                        }
                        .overlay {
                            Circle().strokeBorder(
                                isActive
                                ? AnyShapeStyle(Theme.goldRim)
                                : AnyShapeStyle(LinearGradient(
                                    colors: [Theme.glassRimTop, Theme.glassRimBottom],
                                    startPoint: .top, endPoint: .bottom)),
                                lineWidth: isActive ? 1.4 : 1
                            )
                        }
                        // The bloom only exists in the active state — that's what
                        // keeps gold feeling earned rather than decorative.
                        .shadow(color: isActive ? Theme.goldGlow.opacity(0.55) : .black.opacity(0.4),
                                radius: isActive ? 14 : 8, y: isActive ? 0 : 4)

                    // Inactive glyphs carry a soft amber tint, active ones the
                    // full metal — so the rail reads gold at rest and lights up
                    // rather than changing colour when you tap it.
                    Image(systemName: isActive ? (activeIcon ?? icon) : icon)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(isActive ? AnyShapeStyle(Theme.goldSheen)
                                                  : AnyShapeStyle(Theme.goldSoft.opacity(0.9)))
                }
                .frame(width: size, height: size)

                if let count {
                    Text(count.railFormatted)
                        .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(isActive ? Theme.gold : Theme.textPrimary.opacity(0.9))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .contentTransition(.numericText())
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isActive)
    }
}

private extension Int {
    /// Rail counts stay two glyphs wide so the stack doesn't jitter: 1.2K, 3.4M.
    var railFormatted: String {
        switch self {
        case ..<1_000: "\(self)"
        case ..<1_000_000: String(format: "%.1fK", Double(self) / 1_000)
        default: String(format: "%.1fM", Double(self) / 1_000_000)
        }
    }
}

// MARK: - Sequence scrubber

/// Thin gold segments showing position within a set — one segment per item,
/// the current one lit. Reads as progress without stealing attention from media.
struct SequenceScrubber: View {
    let count: Int
    let index: Int
    var height: CGFloat = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(count, 1), id: \.self) { position in
                Capsule()
                    .fill(position == index
                          ? AnyShapeStyle(Theme.goldSheen)
                          : AnyShapeStyle(Theme.textPrimary.opacity(position < index ? 0.4 : 0.18)))
                    .frame(height: height)
                    .shadow(color: position == index ? Theme.goldGlow.opacity(0.6) : .clear, radius: 5)
            }
        }
        .animation(.easeOut(duration: 0.25), value: index)
    }
}

// MARK: - Chips

/// Gold-outlined pill — "Follow", "Add", and other lightweight commitments.
/// Filled once the commitment is made, so state is legible at a glance.
struct GoldChip: View {
    let title: String
    var systemImage: String?
    var isFilled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                }
                Text(title).font(.system(size: 13, weight: .bold, design: .rounded))
            }
            .foregroundStyle(isFilled ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.gold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background {
                Capsule()
                    .fill(isFilled ? AnyShapeStyle(Theme.goldSheen) : AnyShapeStyle(Material.ultraThinMaterial))
                    .overlay {
                        Capsule().strokeBorder(Theme.gold.opacity(isFilled ? 0 : 0.7), lineWidth: 1)
                    }
                    .shadow(color: Theme.goldGlow.opacity(isFilled ? 0.45 : 0.2), radius: 8)
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isFilled)
    }
}

/// Segmented filter chip for list headers. Active = gold fill; the trailing
/// count rides in a small gold pill so unread volume reads without a badge.
struct FilterChip: View {
    let title: String
    var count: Int = 0
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(isActive ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.textSecondary))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .heavy, design: .rounded).monospacedDigit())
                        .foregroundStyle(isActive ? Color.black.opacity(0.65) : Theme.gold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(isActive ? Color.black.opacity(0.14) : Theme.gold.opacity(0.16))
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule()
                    .fill(isActive ? AnyShapeStyle(Theme.goldSheen) : AnyShapeStyle(Material.ultraThinMaterial))
                    .overlay {
                        Capsule().strokeBorder(
                            isActive ? Color.clear : Theme.glassRimTop.opacity(0.4), lineWidth: 1)
                    }
                    .shadow(color: isActive ? Theme.goldGlow.opacity(0.4) : .clear, radius: 10)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Close button

/// The one dismissal affordance, used on every full-screen cover so "get out of
/// here" always looks and sits the same: a glass disc with an ✕, top-leading.
/// `overMedia` darkens it so it stays legible floating over bright video.
struct CloseButton: View {
    var overMedia: Bool = false
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            if overMedia { Circle().fill(.black.opacity(0.35)) }
                        }
                        .overlay {
                            Circle().strokeBorder(Theme.glassRimTop.opacity(0.5), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

// MARK: - Glass circle button

/// Header affordance: a glass disc with a glyph. `isGold` promotes it to the
/// screen's primary action (add friend, create) with a metal fill.
struct GlassCircleButton: View {
    let icon: String
    var label: String
    var size: CGFloat = 38
    var isGold: Bool = false
    /// Small gold dot at the top-right — unseen notifications.
    var hasBadge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(isGold ? AnyShapeStyle(Color.black) : AnyShapeStyle(Theme.textPrimary))
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(isGold ? AnyShapeStyle(Theme.goldSheen) : AnyShapeStyle(Material.ultraThinMaterial))
                        .overlay {
                            Circle().strokeBorder(
                                isGold ? Color.clear : Theme.glassRimTop.opacity(0.5), lineWidth: 1)
                        }
                        .shadow(color: isGold ? Theme.goldGlow.opacity(0.5) : .black.opacity(0.35),
                                radius: isGold ? 12 : 6, y: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if hasBadge {
                        GlowDot(size: 9).offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

// MARK: - Wordmark

/// "Ralli" in an elegant serif with a metallic gold sheen.
struct RalliWordmark: View {
    var size: CGFloat = 44

    var body: some View {
        Text("Ralli")
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
