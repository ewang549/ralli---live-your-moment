import Foundation

// MARK: - Content filter
//
// The client half of the Guideline 1.2 filtering requirement. The server's
// `moderateText` in `functions/index.js` is the enforcement — it's the one an
// attacker can't skip — and this is the same rule applied before the round
// trip, for two reasons:
//
//  1. Feedback. Someone typing gets told at the moment they type rather than
//     after a request fails, which is the difference between a rule and a bug.
//  2. Coverage. Profile name, bio and city are written straight to Firestore
//     under the `onlySoftProfileFields` rule, not through a callable, so there
//     is no server function in that path to reject them. Here is the only
//     place that text is checked before it becomes public.
//
// Keep the term list in step with `BLOCKED_TERMS` on the server. The two are
// separate on purpose — one is enforcement, one is UX — but a term that only
// exists on one side means the app either accepts something it shouldn't or
// rejects something the server would have taken.

enum ContentFilter {
    /// Unambiguous terms only. Anything that depends on context belongs in the
    /// report queue, where a person decides, rather than here where a false
    /// positive blocks a legitimate post with no way around it.
    private static let blockedTerms: [String] = [
        // Slurs.
        "nigger", "nigga", "faggot", "fag", "kike", "spic", "chink", "wetback",
        "tranny", "retard", "retarded", "coon", "gook", "raghead", "beaner",
        // Sexual content. Context-dependent words ("escort") are deliberately
        // absent — a police escort and a Ford Escort are not this, and a filter
        // that can't tell should defer to the report queue.
        "porn", "pornhub", "xvideos", "onlyfans", "cumshot", "blowjob", "handjob",
        "creampie", "gangbang", "hentai", "milf", "nudes", "camgirl",
        // Sexual content involving minors — zero tolerance, no near-miss allowance.
        "childporn", "cp0rn", "lolicon", "shotacon", "jailbait", "pedo", "pedophile",
        // Solicitation that shows up in this shape of app.
        "sellingnudes", "sexcam", "hookupnow",
    ]

    /// Built once, with every letter allowed to repeat: "nigger" becomes
    /// `n+i+g+g+e+r+`, so "niiiigger" matches without the text having to be
    /// collapsed first. Collapsing runs was the obvious approach and is wrong —
    /// it turns "coon" into "con" and starts rejecting "con artist".
    ///
    /// Word boundaries keep "Scunthorpe" and "assess" out, and they still hold
    /// under the quantifiers: `n+i+g+g+e+r+` needs two g's, so "Niger" is safe.
    private static let pattern: NSRegularExpression? = {
        let alternation = blockedTerms
            .map { $0.map { "\($0)+" }.joined() }
            .joined(separator: "|")
        return try? NSRegularExpression(pattern: "\\b(\(alternation))\\b",
                                        options: [.caseInsensitive])
    }()

    /// The message shown wherever a post is refused. States the rule as well as
    /// the refusal — App Review looks for the zero-tolerance policy being real,
    /// and a user deserves to know which line they crossed.
    static let rejectionMessage =
        "That breaks Ralli's community guidelines. Ralli has zero tolerance for objectionable content."

    /// True when `text` contains an unambiguously objectionable term.
    static func isObjectionable(_ text: String) -> Bool {
        guard let pattern, !text.isEmpty else { return false }

        func matches(_ candidate: String) -> Bool {
            let range = NSRange(candidate.startIndex..., in: candidate)
            return pattern.firstMatch(in: candidate, range: range) != nil
        }

        let folded = normalized(text)
        // Second pass with separators removed catches "f.a.g" and "n i g g e r",
        // which survive the first as separate one-letter tokens.
        return matches(folded) || matches(folded.replacingOccurrences(of: " ", with: ""))
    }

    /// Folds the cheap evasions into a comparable form: leetspeak digits and
    /// the separators used to break a word up while leaving it readable.
    /// Repeated letters are handled by the pattern, not here.
    ///
    /// Deliberately lossy — the result is only ever compared, never stored or
    /// shown to anyone.
    private static func normalized(_ text: String) -> String {
        var folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                  locale: .current)

        for (glyph, letter) in [("0", "o"), ("1", "i"), ("|", "i"), ("!", "i"),
                                ("3", "e"), ("4", "a"), ("@", "a"),
                                ("5", "s"), ("$", "s"), ("7", "t")] {
            folded = folded.replacingOccurrences(of: glyph, with: letter)
        }

        // Anything that isn't a letter or digit becomes a single space, so the
        // separator-spaced evasions rejoin once the caller strips the spaces.
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}
