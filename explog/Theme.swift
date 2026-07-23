import SwiftUI

/// Ralli's single palette: warm gold on rich warm dark.
///
/// There is no second accent. Anything that needs to draw the eye uses `gold`
/// (or `goldSoft`/`goldGlow` for the quieter tiers); everything else is base,
/// glass, and the two text tones. The old orange accent has been retired —
/// if you reach for a new hardcoded colour, add a token here instead.
enum Theme {

    // MARK: - Base
    //
    // Never pure black: a faint warm undertone keeps gold from looking neon and
    // gives the frosted panes something to sit against.

    /// Page base — deep warm charcoal.
    static let base = Color(red: 0.055, green: 0.050, blue: 0.046)
    /// One step up: cards and rows that need to separate from the base.
    static let baseElevated = Color(red: 0.105, green: 0.098, blue: 0.092)
    /// Two steps up: inset fields, pressed states, chip backgrounds.
    static let baseRaised = Color(red: 0.165, green: 0.155, blue: 0.145)

    // MARK: - Text

    /// Near-white, not pure white — pure white on dark vibrates.
    static let textPrimary = Color(red: 0.96, green: 0.95, blue: 0.93)
    /// Muted warm grey for secondary and supporting copy.
    static let textSecondary = Color(red: 0.96, green: 0.95, blue: 0.93).opacity(0.56)

    // MARK: - Gold

    /// Bright polished gold: active states, highlights, primary actions.
    static let gold = Color(red: 0.98, green: 0.78, blue: 0.40)
    /// Softer amber, one tier down: secondary marks, tints, inactive-but-warm.
    static let goldSoft = Color(red: 0.86, green: 0.66, blue: 0.34)
    /// The glow tier — used in shadows and blooms, rarely as a fill.
    static let goldGlow = Color(red: 1.0, green: 0.74, blue: 0.32)
    /// Deep edge of the metal, for gradient falloff.
    static let goldDeep = Color(red: 0.72, green: 0.48, blue: 0.15)

    // MARK: - Glass

    /// Tint layered over the blur so glass reads as a pane, not a hole.
    static let glassTint = Color.white.opacity(0.055)
    /// Bright specular top edge and darker bottom edge of a glass pane.
    static let glassRimTop = Color.white.opacity(0.28)
    static let glassRimBottom = Color.black.opacity(0.35)

    /// Ends of the app background gradient.
    static let glassBackgroundTop = Color(red: 0.085, green: 0.078, blue: 0.070)
    static let glassBackgroundBottom = Color(red: 0.038, green: 0.034, blue: 0.031)

    // MARK: - Gold gradients

    /// Metallic sheen: highlight → gold → deep → highlight, so it reads as a
    /// curved metal surface rather than a flat yellow fill.
    static let goldSheen = LinearGradient(
        colors: [Color(red: 1.0, green: 0.93, blue: 0.76),
                 gold,
                 goldDeep,
                 Color(red: 1.0, green: 0.89, blue: 0.68)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Thin metal for rings and strokes — brighter at the top-left light source.
    static let goldRim = LinearGradient(
        colors: [Color(red: 1.0, green: 0.92, blue: 0.74), gold, goldDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // MARK: - Backgrounds

    /// Page background: a subtle vertical gradient, so glass has depth behind it.
    static var appBackground: LinearGradient {
        LinearGradient(colors: [glassBackgroundTop, base, glassBackgroundBottom],
                       startPoint: .top, endPoint: .bottom)
    }

    static func avatarGradient(hue: Double) -> LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.65, brightness: 0.95),
                Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.65),
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
}

/// Formats a cooldown like the sketch's "59:01" timer.
func cooldownString(_ remaining: TimeInterval) -> String {
    let total = max(0, Int(remaining))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
