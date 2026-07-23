import SwiftUI

enum Theme {
    static let background = Color(red: 0.05, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let surfaceLight = Color(red: 0.17, green: 0.17, blue: 0.21)
    static let accent = Color(red: 1.0, green: 0.45, blue: 0.26)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)

    // MARK: - Liquid Glass tokens
    //
    // Additive: existing screens keep `background`/`surface`/`accent` above.
    // New surfaces compose these with the components in GlassKit.swift.

    /// Deep charcoal with a warm undertone — never pure black.
    static let glassBackgroundTop = Color(red: 0.07, green: 0.065, blue: 0.075)
    static let glassBackgroundBottom = Color(red: 0.04, green: 0.035, blue: 0.038)

    /// Tint layered over the blur so glass reads as a pane, not a hole.
    static let glassTint = Color.white.opacity(0.055)
    /// Bright specular top edge and darker bottom edge of a glass pane.
    static let glassRimTop = Color.white.opacity(0.28)
    static let glassRimBottom = Color.black.opacity(0.35)

    /// Warm amber/gold accent — the single source of warmth.
    static let gold = Color(red: 0.98, green: 0.76, blue: 0.36)
    static let goldDeep = Color(red: 0.85, green: 0.55, blue: 0.16)
    static let goldGlow = Color(red: 1.0, green: 0.72, blue: 0.3)

    /// Metallic sheen for the wordmark.
    static let goldSheen = LinearGradient(
        colors: [Color(red: 1.0, green: 0.91, blue: 0.72),
                 gold,
                 goldDeep,
                 Color(red: 1.0, green: 0.88, blue: 0.66)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Page background for new screens.
    static var appBackground: LinearGradient {
        LinearGradient(colors: [glassBackgroundTop, glassBackgroundBottom],
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
