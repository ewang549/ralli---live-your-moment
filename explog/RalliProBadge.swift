import SwiftUI

// MARK: - Pro gold
//
// The one place in Ralli that uses gold. The design system's "no gold" rule
// exists so nothing competes with coral for brand attention — this is the
// deliberate exception, and it earns it by meaning something specific:
// "Pro" and nothing else. Coral still owns the brand; gold only ever labels the
// tier. Keeping the palette here (rather than in `Theme`) is the guard rail —
// it stays reachable for a Pro badge and awkward to reach for anything else.

/// Brass → champagne → brass, on the diagonal.
///
/// Three stops rather than two: a flat two-stop ramp reads as yellow plastic,
/// while a bright band pinched between two deep brasses reads as light catching
/// metal. The bright stop sits slightly past centre so the sheen looks lit from
/// the upper left rather than perfectly symmetrical.
enum ProGold {
    static let deep = Color(hex: 0x8A6015)
    static let mid = Color(hex: 0xC9992F)
    static let champagne = Color(hex: 0xF8EDC2)

    /// The fill for "Pro" itself.
    static var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: deep, location: 0.00),
                .init(color: mid, location: 0.28),
                .init(color: champagne, location: 0.54),
                .init(color: mid, location: 0.74),
                .init(color: deep, location: 1.00),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Warm halo used behind the label at hero sizes. Deliberately weak — the
    /// shine should suggest metal, not emit light.
    static let glow = Color(hex: 0xD8A93A)
}

/// "Pro" in gold — the reusable premium label.
///
/// Sized relative to whatever it sits beside, so it can ride the wordmark on a
/// hero screen or a row label in settings without being re-tuned each time.
/// Pass `showsGlow: false` for small/inline uses, where a halo just muddies the
/// glyphs.
struct RalliProBadge: View {
    var size: CGFloat = 20
    /// Hero treatment: halo behind the text and an extra highlight pass across
    /// the top of the glyphs.
    ///
    /// Both are off for inline use on purpose. At row sizes the highlight lands
    /// on strokes only a couple of points tall, which lifts them close to the
    /// warm canvas behind and costs more contrast than the shine is worth — the
    /// five-stop gradient alone already reads as metal at that scale.
    var showsGlow: Bool = true

    var body: some View {
        Text("Pro")
            .font(.system(size: size, weight: .heavy, design: .rounded))
            .tracking(-size * 0.01)
            .foregroundStyle(ProGold.gradient)
            .overlay {
                if showsGlow {
                    Text("Pro")
                        .font(.system(size: size, weight: .heavy, design: .rounded))
                        .tracking(-size * 0.01)
                        .foregroundStyle(
                            LinearGradient(colors: [ProGold.champagne.opacity(0.5), .clear],
                                           startPoint: .top,
                                           endPoint: UnitPoint(x: 0.5, y: 0.42))
                        )
                        .blendMode(.screen)
                }
            }
            .shadow(color: ProGold.glow.opacity(showsGlow ? 0.45 : 0),
                    radius: size * 0.5, y: size * 0.04)
            .accessibilityLabel("Pro")
    }
}

/// The full "ralli Pro" lockup: the coral wordmark with the gold tier label
/// beside it, both scaled from one number so they always sit correctly
/// together.
struct RalliProWordmark: View {
    var size: CGFloat = RalliWordmark.canonical
    var showsGlow: Bool = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.18) {
            RalliWordmark(size: size)
            RalliProBadge(size: size * 0.72, showsGlow: showsGlow)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ralli Pro")
    }
}

#Preview {
    VStack(spacing: 28) {
        RalliProWordmark(size: 46)
        RalliProWordmark()
        HStack(spacing: 6) {
            Text("Your plan").foregroundStyle(Theme.textSecondary)
            RalliProBadge(size: 15, showsGlow: false)
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Theme.appBackground)
}
