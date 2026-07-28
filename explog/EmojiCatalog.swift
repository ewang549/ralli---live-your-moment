import Foundation
import os

/// The full emoji range, grouped, for the sticker tray.
///
/// Derived from Unicode scalar properties at first use rather than typed out as
/// literals. A hand-written array is what the tray used to be — fourteen emoji —
/// and the reason it stayed fourteen: every addition is manual, and the list
/// silently ages out of date with each Unicode release. Asking the platform
/// instead means the tray carries whatever the OS can actually draw, which is
/// also exactly the set that will render correctly on that OS.
///
/// There is no public API for the system emoji keyboard as a standalone picker,
/// so this is the alternative to shipping a third-party emoji dataset.
enum EmojiCatalog {
    struct Category: Identifiable, Hashable {
        /// Also the display name — these are unique and stable.
        var id: String { name }
        let name: String
        /// SF Symbol for the category tab.
        let symbol: String
        let emoji: [String]
    }

    /// Built once, on first access, off whatever thread asks. Roughly 1,500
    /// scalars are examined; it costs a few milliseconds and then never again.
    static let categories: [Category] = buildCategories()

    /// Every emoji in one flat list, for search.
    static let all: [String] = categories.flatMap(\.emoji)

    // MARK: - Search

    /// Emoji whose Unicode name contains every whitespace-separated term.
    ///
    /// Matching on `Unicode.Scalar.Properties.name` ("GRINNING FACE", "ROCKET")
    /// is what makes search work without shipping a keyword dictionary. It's
    /// the formal Unicode name, so it finds "face" and "cat" well and slang not
    /// at all — which is the honest trade for carrying no extra data.
    static func search(_ query: String) -> [String] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { emoji in
            let name = searchName(for: emoji)
            return terms.allSatisfy { name.contains($0) }
        }
    }

    /// Lowercased Unicode names of an emoji's scalars, joined. Cached because
    /// search runs this over the whole catalog on every keystroke.
    private static func searchName(for emoji: String) -> String {
        if let hit = nameCache.withLock({ $0[emoji] }) { return hit }
        let name = emoji.unicodeScalars
            .compactMap { $0.properties.name?.lowercased() }
            .joined(separator: " ")
        nameCache.withLock { $0[emoji] = name }
        return name
    }

    private static let nameCache = OSAllocatedUnfairLock(initialState: [String: String]())

    // MARK: - Construction

    /// Category name, tab symbol, and the scalar ranges that belong to it.
    ///
    /// First match wins, so the ranges are ordered to resolve the overlaps the
    /// Unicode blocks genuinely have — the Emoticons block runs straight into
    /// the gesture emoji, and the plant and food emoji share a block. Anything
    /// emoji-presentation that no category claims is swept into Symbols at the
    /// end, so widening Unicode never silently drops an emoji on the floor.
    private static let specs: [(name: String, symbol: String, ranges: [ClosedRange<UInt32>])] = [
        ("Smileys", "face.smiling", [
            0x1F600...0x1F644, 0x1F910...0x1F917, 0x1F920...0x1F92F,
            0x1F970...0x1F97A, 0x1FAE0...0x1FAE8, 0x2639...0x263A,
            0x1F48B...0x1F49F, 0x1F4A2...0x1F4AB, 0x1F5EF...0x1F5EF,
        ]),
        ("People", "hand.wave", [
            0x1F440...0x1F450, 0x1F464...0x1F487, 0x1F574...0x1F596,
            0x1F645...0x1F64F, 0x1F918...0x1F91F, 0x1F930...0x1F93E,
            0x1F9B0...0x1F9DF, 0x1FAF0...0x1FAF8, 0x261D...0x261D,
            0x270A...0x270D, 0x1F3C2...0x1F3CC,
        ]),
        ("Nature", "leaf", [
            0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F343,
            0x1F577...0x1F578, 0x1FAB0...0x1FABF, 0x1F300...0x1F321,
            0x1F324...0x1F32C, 0x2600...0x2604, 0x26C4...0x26C8,
        ]),
        ("Food", "fork.knife", [
            0x1F344...0x1F37F, 0x1F950...0x1F96F, 0x1F32D...0x1F32F,
            0x1F9C0...0x1F9CB, 0x1FAD0...0x1FADF, 0x2615...0x2615,
        ]),
        ("Travel", "airplane", [
            0x1F680...0x1F6C5, 0x1F5FA...0x1F5FF, 0x1F3E0...0x1F3F0,
            0x1F30D...0x1F320, 0x26F0...0x26FA, 0x1F6F0...0x1F6FC,
            0x1F3D4...0x1F3DF,
        ]),
        ("Activities", "figure.run", [
            0x1F380...0x1F3C1, 0x1F3C5...0x1F3CF, 0x1F945...0x1F94F,
            0x1F004...0x1F004, 0x1F0CF...0x1F0CF, 0x26BD...0x26BE,
        ]),
        ("Objects", "lightbulb", [
            0x1F4A1...0x1F4FF, 0x1F500...0x1F53D, 0x1F550...0x1F567,
            0x1F6AA...0x1F6BF, 0x1F9F0...0x1F9FF, 0x2702...0x27B0,
        ]),
    ]

    /// Swept for anything the categories above don't claim. Covers every block
    /// Unicode currently assigns emoji in.
    private static let allEmojiRanges: [ClosedRange<UInt32>] = [
        0x00A9...0x00AE, 0x203C...0x3299, 0x1F000...0x1FAFF,
    ]

    private static func buildCategories() -> [Category] {
        var claimed = Set<UInt32>()
        var result: [Category] = []

        for spec in specs {
            var emoji: [String] = []
            for range in spec.ranges {
                for value in range where !claimed.contains(value) {
                    guard let rendered = emojiString(for: value) else { continue }
                    claimed.insert(value)
                    emoji.append(rendered)
                }
            }
            if !emoji.isEmpty {
                result.append(Category(name: spec.name, symbol: spec.symbol, emoji: emoji))
            }
        }

        // Everything else that renders as emoji, so the catalog is genuinely
        // complete rather than complete-as-of-when-the-ranges-were-written.
        var symbols: [String] = []
        for range in allEmojiRanges {
            for value in range where !claimed.contains(value) {
                guard let rendered = emojiString(for: value) else { continue }
                claimed.insert(value)
                symbols.append(rendered)
            }
        }
        if !symbols.isEmpty {
            result.append(Category(name: "Symbols", symbol: "number", emoji: symbols))
        }

        result.append(Category(name: "Flags", symbol: "flag", emoji: flags))
        return result
    }

    /// A single scalar as a tray-ready string, or nil if it isn't a standalone
    /// emoji.
    ///
    /// Two rungs: scalars that default to emoji presentation are used as they
    /// are, and scalars that *can* be emoji but default to text (✂, ☀, ©) get
    /// an explicit variation selector so they draw as emoji rather than as
    /// glyphs that look like a font bug next to the rest of the grid.
    private static func emojiString(for value: UInt32) -> String? {
        guard let scalar = Unicode.Scalar(value) else { return nil }
        // Skin-tone modifiers and regional indicators are combining pieces, not
        // stickers — dropped one on its own renders as a swatch or a letter box.
        if (0x1F3FB...0x1F3FF).contains(value) { return nil }
        if (0x1F1E6...0x1F1FF).contains(value) { return nil }

        let properties = scalar.properties
        if properties.isEmojiPresentation { return String(scalar) }
        // ASCII digits and `#`/`*` are `isEmoji` but only as keycap bases.
        guard properties.isEmoji, value > 0x00A0 else { return nil }
        return String(scalar) + "\u{FE0F}"
    }

    // MARK: - Flags

    /// Regional-indicator flags, built from ISO 3166-1 alpha-2 codes.
    ///
    /// Built from a code list rather than swept like the rest: a flag is a
    /// *pair* of regional indicators, and only assigned pairs render as a flag.
    /// Sweeping all 676 combinations would fill the tab with letter boxes.
    private static let flags: [String] = {
        let base: Unicode.Scalar = "🇦"
        let scalarA = base.value - UInt32(UnicodeScalar("A").value)
        return isoCodes.compactMap { code in
            let scalars = code.unicodeScalars.compactMap {
                Unicode.Scalar(scalarA + $0.value)
            }
            guard scalars.count == 2 else { return nil }
            return String(String.UnicodeScalarView(scalars))
        }
    }()

    private static let isoCodes: [String] = """
    AD AE AF AG AI AL AM AO AR AT AU AW AZ BA BB BD BE BF BG BH BI BJ BM BN BO \
    BR BS BT BW BY BZ CA CD CF CG CH CI CL CM CN CO CR CU CV CY CZ DE DJ DK DM \
    DO DZ EC EE EG ER ES ET FI FJ FM FO FR GA GB GD GE GH GM GN GQ GR GT GW GY \
    HK HN HR HT HU ID IE IL IN IQ IR IS IT JM JO JP KE KG KH KI KM KN KP KR KW \
    KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MG MH MK ML MM MN MO MR \
    MT MU MV MW MX MY MZ NA NE NG NI NL NO NP NR NZ OM PA PE PG PH PK PL PR PS \
    PT PW PY QA RO RS RU RW SA SB SC SD SE SG SI SK SL SM SN SO SR SS ST SV SY \
    SZ TD TG TH TJ TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VC VE VN VU WS \
    YE ZA ZM ZW
    """.split(whereSeparator: \.isWhitespace).map(String.init)
}
