import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Dynamic colour helpers

extension Color {
    /// Two-tone dynamic colour: resolves light/dark from the trait environment so
    /// a single token adapts automatically. The whole Warm Modern palette is built
    /// on this — browsing is light-first, immersive media leans dark.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(dark) : NSColor(light)
        })
        #else
        self = light
        #endif
    }

    /// Hex convenience for the palette tables (`0xRRGGBB`, optional alpha).
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

/// Ralli's "Warm Modern" palette.
///
/// The feeling is warm, calm, human: a paper-warm canvas, one confident accent
/// (iris) with personality, generous rounded shapes, real whitespace, restraint.
/// No gold, no pure black, no heavy chrome. Colour earns attention because most
/// of the screen is quiet neutral — aim for one primary iris action per screen.
///
/// Every token is dual-mode: light-first for browsing, beautiful in dark. Glass
/// is a garnish reserved for the floating nav and media overlays; everywhere else
/// uses solid `surface`. Coral and mint are *functional* moments (a like, an
/// online dot), never decoration.
enum Theme {

    // MARK: - Neutrals
    //
    // Warm-tinted; never pure #000 / #FFF. Separate regions with a tonal step
    // (canvas → surface) and spacing, not borders.

    /// App background — warm chalk (light) / warm near-black (dark).
    static let base = Color(light: Color(hex: 0xFAF8F4), dark: Color(hex: 0x131118))
    /// Cards, sheets, rows — one tonal step up from the canvas.
    static let baseElevated = Color(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x1C1A23))
    /// Inputs, wells, pressed rows (light) / raised surfaces & menus (dark).
    static let baseRaised = Color(light: Color(hex: 0xF0EDE7), dark: Color(hex: 0x262330))

    // Semantic aliases matching the spec's names, for new code.
    static let canvas = base
    static let surface = baseElevated
    static let sunken = baseRaised
    static let elevated = baseRaised

    // MARK: - Text (ink)

    /// Primary text.
    static let textPrimary = Color(light: Color(hex: 0x1B1922), dark: Color(hex: 0xF5F2F8))
    /// Secondary / supporting copy. Passes AA on surface — don't drop below this.
    static let textSecondary = Color(light: Color(hex: 0x726C7A), dark: Color(hex: 0xA6A0B0))
    /// Hints, disabled.
    static let textTertiary = Color(light: Color(hex: 0xA8A2AE), dark: Color(hex: 0x6E6878))

    /// Subtle border — a last resort when a tonal step isn't enough.
    static let hairline = Color(light: Color(hex: 0xE8E3DB), dark: Color(white: 1, opacity: 0.08))

    // MARK: - Iris (the one brand accent)
    //
    // Primary actions, active states, links, brand. On any screen, one primary
    // iris action leads. Never a large flat iris fill behind lots of text — use
    // `irisWash` for tinted surfaces instead.

    /// Primary accent.
    static let iris = Color(light: Color(hex: 0x5A4FF3), dark: Color(hex: 0x8C82FF))
    /// Pressed / hover.
    static let irisPress = Color(light: Color(hex: 0x4A40D6), dark: Color(hex: 0x6E63F0))
    /// Tinted chip / badge backgrounds.
    static let irisWash = Color(light: Color(hex: 0xECEAFE), dark: Color(hex: 0x8C82FF, alpha: 0.16))
    /// Slightly muted iris for secondary marks / inactive-but-branded glyphs.
    static let irisSoft = Color(light: Color(hex: 0x6A60F0), dark: Color(hex: 0x9E95FF))
    /// Colour used for the soft accent glow behind genuine "live" states.
    static let irisGlow = iris

    /// Legible foreground on an iris fill: white in light, near-black in dark
    /// (dark iris is the lighter #8C82FF). Pair with iris buttons/chips.
    static let onIris = Color(light: .white, dark: Color(hex: 0x131118))

    // MARK: - Coral (the brand accent)
    //
    // Ralli's signature is a warm coral (updated from iris). Primary actions,
    // active states, likes, streaks, and "live now" warmth. Kept in the red-pink
    // coral range — never drifting toward the old orange/gold.

    /// Primary brand accent.
    static let coral = Color(light: Color(hex: 0xFF5A5F), dark: Color(hex: 0xFF7B7F))
    /// Pressed / hover.
    static let coralPress = Color(light: Color(hex: 0xE64A50), dark: Color(hex: 0xF0656A))
    /// Tinted chip / badge / wash backgrounds.
    static let coralWash = Color(light: Color(hex: 0xFFECEC), dark: Color(hex: 0xFF5A5F, alpha: 0.16))
    /// Soft accent glow behind genuine "live" states (recording, focus).
    static let coralGlow = coral
    /// Legible foreground on a coral fill: white in light, near-black in dark
    /// (dark coral is the lighter #FF7B7F).
    static let onCoral = Color(light: .white, dark: Color(hex: 0x131118))

    // MARK: - Functional accents (moments, not decoration)

    /// Online, success, confirmations.
    static let mint = Color(light: Color(hex: 0x24C2A0), dark: Color(hex: 0x34D4B0))
    /// Warnings only — never decorative.
    static let amber = Color(light: Color(hex: 0xF5A524), dark: Color(hex: 0xF7B23B))

    // MARK: - Glass (garnish: nav pill + media overlays only)

    /// Faint tint layered over blur so glass reads as a pane, not a hole.
    static let glassTint = Color(light: .white.opacity(0.5), dark: .white.opacity(0.06))
    /// Soft rim on a glass pane.
    static let glassRimTop = Color(light: .white.opacity(0.7), dark: .white.opacity(0.14))
    static let glassRimBottom = Color(light: .black.opacity(0.06), dark: .black.opacity(0.25))

    // MARK: - Gradients

    /// Subtle iris gradient for primary fills — reads as a soft surface, not a
    /// hard flat block. Used for pill buttons and selected chips.
    static let irisGradient = LinearGradient(
        colors: [iris, irisPress],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Coral gradient for the primary capture fills (the shutter) — a soft
    /// surface, not a flat block.
    static let coralGradient = LinearGradient(
        colors: [coral, coralPress],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Page background: a barely-there vertical warm gradient so large surfaces
    /// don't feel dead flat. Mostly just `canvas`.
    static var appBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color(light: Color(hex: 0xFDFBF8), dark: Color(hex: 0x17141D)),
                base,
                Color(light: Color(hex: 0xF6F2EC), dark: Color(hex: 0x100E15)),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: - Content gradients (faces/photos supply the colour)

    static func avatarGradient(hue: Double) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.55, brightness: 0.92),
                Color(hue: (hue + 0.1).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.68),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    static func clipGradient(hueA: Double, hueB: Double) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hueA, saturation: 0.55, brightness: 0.55),
                Color(hue: hueB, saturation: 0.7, brightness: 0.25),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }
}

extension Date {
    var clockTime: String {
        formatted(date: .omitted, time: .shortened)
    }

    var relativeHour: String {
        let interval = Date.now.timeIntervalSince(self)
        if interval < 3600 { return "\(max(1, Int(interval / 60)))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return formatted(.dateTime.weekday(.abbreviated))
    }

    /// Bare "2h" / "3d" stamp for list rows, where the caption owns the line and
    /// the age of it has to fit in the few points left over.
    var shortRelative: String {
        let interval = max(0, Date.now.timeIntervalSince(self))
        if interval < 60 { return "now" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        if interval < 86400 { return "\(Int(interval / 3600))h" }
        if interval < 7 * 86400 { return "\(Int(interval / 86400))d" }
        return "\(Int(interval / (7 * 86400)))w"
    }
}

/// Formats a cooldown like the sketch's "59:01" timer.
func cooldownString(_ remaining: TimeInterval) -> String {
    let total = max(0, Int(remaining))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
