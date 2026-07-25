import SwiftUI

/// Warm Modern component set. New screens compose these instead of styling
/// surfaces ad hoc, so the material language stays consistent as the social
/// layer grows. Tokens live in `Theme`.
///
/// The look: solid warm `surface` cards separated by tone and spacing, one
/// confident coral accent used sparingly, generous rounded shapes, soft low
/// shadows. Frosted glass is a garnish reserved for the floating nav pill and
/// overlays on immersive media — everywhere else uses solid surface.

// MARK: - Shared soft shadow

private extension View {
    /// Soft, low, warm-tinted card shadow. No hard 1px drop lines.
    func softCardShadow() -> some View {
        self
            .shadow(color: Color(hex: 0x14121E, alpha: 0.05), radius: 1.5, y: 1)
            .shadow(color: Color(hex: 0x14121E, alpha: 0.07), radius: 16, y: 8)
    }
}

// MARK: - Surface card

/// Solid warm surface card — the default container. Depth comes from a tonal
/// step above the canvas plus a soft shadow, not from borders.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 16
    /// Opt into frosted glass — reserve for captions/rails floating over media.
    var glass: Bool = false
    /// Slight lift on press, used by interactive cards.
    var isPressed: Bool = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(glass ? AnyShapeStyle(.ultraThinMaterial)
                                : AnyShapeStyle(Theme.surface))
                    .overlay {
                        // Glass panes get a faint rim so they read as a pane over
                        // media; solid cards stay borderless.
                        if glass {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Theme.glassRimTop, lineWidth: 0.75)
                        }
                    }
                    .modifier(CardShadow(glass: glass))
            }
            .scaleEffect(isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.9), value: isPressed)
    }
}

private struct CardShadow: ViewModifier {
    var glass: Bool
    func body(content: Content) -> some View {
        if glass {
            content.shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        } else {
            content.softCardShadow()
        }
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
                            .strokeBorder(Theme.glassRimTop, lineWidth: 0.75)
                    }
                    .shadow(color: Color(hex: 0x14121E, alpha: 0.12), radius: 20, y: 6)
            }
    }
}

// MARK: - Live / online dot

/// A small solid dot for functional "moments": coral for unread, mint for online,
/// coral for a live/streak signal. Breathes slowly only for genuine live states.
struct GlowDot: View {
    var size: CGFloat = 9
    var color: Color = Theme.accent
    var breathing: Bool = false

    @State private var bloom = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.5), lineWidth: max(0.5, size * 0.06))
            }
            .shadow(color: color.opacity(bloom ? 0.7 : 0.4), radius: bloom ? size * 0.9 : size * 0.4)
            .onAppear {
                guard breathing else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    bloom = true
                }
            }
    }
}

// MARK: - Avatar

/// Circular avatar. No heavy ring by default; a thin coral ring signals
/// "new / unseen" (story-style). Online is a small mint dot, added by the caller.
struct GlassOrbAvatar: View {
    let emoji: String
    /// Base hue of the fill (matches `Friend.hue`).
    var hue: Double = 0.58
    var size: CGFloat = 44
    /// Thin coral ring for "new / unseen" / active states.
    var isActive: Bool = false
    /// A real profile photo on disk, when there is one — takes over from the
    /// emoji/gradient fill entirely.
    var photoURL: URL? = nil
    /// Another account's profile photo, served from Storage. Only consulted
    /// when there's no local file, so this account's own avatar keeps rendering
    /// instantly from disk instead of waiting on the network.
    var remotePhotoURL: URL? = nil

    var body: some View {
        ZStack {
            if let photoURL, let uiImage = UIImage(contentsOfFile: photoURL.path) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else if let remotePhotoURL {
                AsyncImage(url: remotePhotoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    // The emoji orb stays put while the photo loads, so the
                    // avatar never flashes empty.
                    ZStack {
                        Circle().fill(Theme.avatarGradient(hue: hue))
                        Text(emoji).font(.system(size: size * 0.5))
                    }
                }
            } else {
                Circle().fill(Theme.avatarGradient(hue: hue))
                Text(emoji).font(.system(size: size * 0.5))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            // Barely-there inner edge so the disc sits cleanly on any surface.
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
        }
        .overlay {
            if isActive {
                Circle()
                    .strokeBorder(Theme.accent, lineWidth: max(1.5, size * 0.05))
                    .padding(-size * 0.08)
            }
        }
    }
}

/// Convenience overload so existing `Friend` rows can adopt the avatar look.
extension GlassOrbAvatar {
    init(friend: Friend, size: CGFloat = 44, isActive: Bool = false) {
        self.init(emoji: friend.emoji, hue: friend.hue, size: size, isActive: isActive,
                  photoURL: friend.avatarPhotoURL)
    }
}

// MARK: - Media action rail

/// One button in a full-bleed feed's right-hand rail: a glass disc over media
/// with a white glyph that lights up in its accent when active (coral by default,
/// coral for likes). An optional count rides underneath.
struct RailButton: View {
    let icon: String
    /// Glyph swapped for its filled variant when active, e.g. "heart" → "heart.fill".
    var activeIcon: String?
    var count: Int?
    var isActive: Bool = false
    /// Accent for the active state — coral for likes, coral otherwise.
    var activeTint: Color = Theme.accent
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Circle().strokeBorder(Theme.glassRimTop, lineWidth: 0.75)
                        }
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)

                    Image(systemName: isActive ? (activeIcon ?? icon) : icon)
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(isActive ? activeTint : .white)
                }
                .frame(width: size, height: size)

                if let count {
                    Text(count.railFormatted)
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
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

/// Thin segments showing position within a set — one per item, the current one
/// lit white. Reads as progress without stealing attention from media.
struct SequenceScrubber: View {
    let count: Int
    let index: Int
    var height: CGFloat = 3

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(count, 1), id: \.self) { position in
                Capsule()
                    .fill(.white.opacity(position == index ? 0.95
                                        : position < index ? 0.5 : 0.22))
                    .frame(height: height)
            }
        }
        .animation(.easeOut(duration: 0.25), value: index)
    }
}

// MARK: - Chips

/// Small commitment pill — "Follow", "Add". Prominent coral-wash call to action
/// when open; solid coral once the commitment is made, so state reads at a glance.
struct AccentChip: View {
    let title: String
    var systemImage: String?
    /// The commitment is made (following / joined).
    var isFilled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
                }
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isFilled ? Theme.onAccent : Theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isFilled ? AnyShapeStyle(Theme.accent)
                                        : AnyShapeStyle(Theme.accentWash))
            }
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isFilled)
    }
}

/// Segmented filter chip for list headers. Selected = coral-wash fill with
/// coral-press text; unselected = sunken with secondary text. The trailing count
/// rides in a small pill so unread volume reads without a badge.
struct FilterChip: View {
    let title: String
    var count: Int = 0
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Theme.accentPressed : Theme.textSecondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isActive ? Theme.onAccent : Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background {
                            Capsule().fill(isActive ? AnyShapeStyle(Theme.accent)
                                                    : AnyShapeStyle(Theme.textSecondary.opacity(0.16)))
                        }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background {
                Capsule().fill(isActive ? AnyShapeStyle(Theme.accentWash)
                                        : AnyShapeStyle(Theme.sunken))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Close button

/// The one dismissal affordance, used on every full-screen cover so "get out of
/// here" always looks and sits the same: a soft disc with an ✕, top-leading.
/// `overMedia` switches it to dark glass so it stays legible over bright video.
struct CloseButton: View {
    var overMedia: Bool = false
    var size: CGFloat = 38
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(overMedia ? Color.white : Theme.textPrimary)
                .frame(width: size, height: size)
                .background {
                    if overMedia {
                        Circle().fill(.ultraThinMaterial)
                            .overlay { Circle().fill(.black.opacity(0.28)) }
                            .overlay { Circle().strokeBorder(Theme.glassRimTop, lineWidth: 0.75) }
                            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                    } else {
                        Circle().fill(Theme.surface)
                            .shadow(color: Color(hex: 0x14121E, alpha: 0.12), radius: 8, y: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
    }
}

// MARK: - Circle button

/// Header affordance: a soft disc with a glyph. `isProminent` promotes it to the
/// screen's one primary action (add friend, create) with a solid coral fill.
struct GlassCircleButton: View {
    let icon: String
    var label: String
    var size: CGFloat = 38
    /// Solid coral fill — the screen's single primary action.
    var isProminent: Bool = false
    /// Small coral dot at the top-right — unseen notifications.
    var hasBadge: Bool = false
    /// How many items are waiting. Anything above zero renders a counted badge
    /// rather than the bare dot: push permission can never be guaranteed, so
    /// opening the app has to be enough on its own to notice a pending friend
    /// request — and a 9pt dot is easy to scroll straight past.
    var badgeCount: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(isProminent ? Theme.onAccent : Theme.textPrimary)
                .frame(width: size, height: size)
                .background {
                    Circle()
                        .fill(isProminent ? AnyShapeStyle(Theme.accent)
                                          : AnyShapeStyle(Theme.surface))
                        .shadow(color: isProminent ? Theme.accent.opacity(0.35)
                                                   : Color(hex: 0x14121E, alpha: 0.1),
                                radius: isProminent ? 12 : 7, y: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if badgeCount > 0 {
                        Text(badgeCount > 9 ? "9+" : "\(badgeCount)")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .foregroundStyle(Theme.onAccent)
                            .padding(.horizontal, badgeCount > 9 ? 4 : 0)
                            .frame(minWidth: 18, minHeight: 18)
                            .background { Capsule().fill(Theme.accent) }
                            // Punches the badge out of the button beneath it so
                            // it reads as a separate, urgent object.
                            .overlay { Capsule().strokeBorder(Theme.base, lineWidth: 2) }
                            .shadow(color: Theme.accent.opacity(0.45), radius: 6, y: 1)
                            .offset(x: 7, y: -5)
                    } else if hasBadge {
                        GlowDot(size: 9).offset(x: 1, y: -1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badgeCount > 0 ? "\(label), \(badgeCount) waiting" : label)
    }
}

// MARK: - Wordmark

/// "ralli" — lowercase, tight tracking, medium-bold, in coral. The brand mark.
///
/// `canonical` is the one true size for the top-level tab headers (Pulse,
/// Places, …). They must all render `RalliWordmark()` with no override so the
/// wordmark is pixel-identical tab to tab and never appears to jump or resize
/// when switching. Only hero/onboarding moments (auth, profile setup) pass a
/// deliberately larger `size`.
struct RalliWordmark: View {
    static let canonical: CGFloat = 30
    var size: CGFloat = canonical

    var body: some View {
        Text("ralli")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .tracking(-size * 0.02)
            .foregroundStyle(Theme.accent)
    }
}

// MARK: - Chat glyph

/// Ralli's custom chat mark — a rounded speech bubble with a short tail, drawn
/// as a single filled path. It replaces SF Symbols' generic `bubble.*` icons
/// everywhere a chat/thread is opened, so the chat affordance reads the same
/// on the home list, the log player rail, and anywhere else it appears.
struct ChatBubbleShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Body fills the top ~80%, leaving room for the tail beneath it.
        let corner = min(rect.width, rect.height) * 0.30
        let body = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width, height: rect.height * 0.82)
        path.addRoundedRect(in: body, cornerSize: CGSize(width: corner, height: corner))

        // Tail dropping from the lower-left, overlapping the body so the
        // non-zero fill merges the two into one continuous bubble.
        let tailInset = corner * 0.55
        path.move(to: CGPoint(x: body.minX + tailInset, y: body.maxY - corner * 0.4))
        path.addLine(to: CGPoint(x: body.minX + tailInset * 0.4, y: rect.maxY))
        path.addLine(to: CGPoint(x: body.minX + tailInset + corner, y: body.maxY))
        path.closeSubpath()
        return path
    }
}

/// The chat mark at a given point size and colour.
struct ChatGlyph: View {
    var size: CGFloat = 22
    var color: Color = Theme.textPrimary

    var body: some View {
        ChatBubbleShape()
            .fill(color)
            .frame(width: size, height: size)
            .accessibilityLabel("Chat")
    }
}

// MARK: - Background

/// Standard page background for browsing screens: the warm canvas. Light-first,
/// beautiful in dark. Immersive media screens use their own full-bleed treatment.
struct GlassBackground: View {
    var body: some View {
        Theme.appBackground.ignoresSafeArea()
    }
}

// MARK: - Field & primary button

/// Text field on a sunken well — no border, an coral focus ring, ink-3 placeholder.
struct GlassField: View {
    let placeholder: String
    @Binding var text: String
    var systemImage: String?

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(focused ? Theme.accent : Theme.textSecondary)
            }
            TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.textTertiary))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.sunken)
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.accent, lineWidth: focused ? 2 : 0)
                }
        }
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// Primary action: a pill in solid coral with legible text. Pressed → coral-press
/// with a slight scale.
struct PrimaryButton: View {
    let title: String
    var busy: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().tint(Theme.onAccent)
                } else {
                    Text(title).font(.system(size: 16, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                Capsule()
                    .fill(enabled ? AnyShapeStyle(Theme.accent)
                                  : AnyShapeStyle(Theme.textSecondary.opacity(0.25)))
                    .shadow(color: enabled ? Theme.accent.opacity(0.3) : .clear, radius: 12, y: 4)
            }
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled || busy)
    }
}

/// Shared press feedback: scale to 0.98 with a quick spring.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isPressed)
    }
}
