import Foundation

/// Reading a virtual airline out of a flight callsign.
///
/// A port of the callsign vocabulary in the web tracker's `vaAds.js`, and it is
/// worth restating why it is this fiddly rather than a prefix test.
///
/// Pilots fly under the **full airline callsign** — "United 123", "Air Canada
/// 001VA" — never a short VA code. So a partner is matched on the leading
/// airline *name* of the callsign, and the match has to end on a real word
/// boundary: without that, a VA coded "UNI" (Uni Air) swallows every "United
/// ###" on the server. The trailing flight-number token is dropped before the
/// code is read, so "Air Canada 001VA" advertises as "AIRCANADA" rather than as
/// "AIR" — which used to catch Air India and Airbus with it.
///
/// The membership tag is the other half: the suffix a member appends to the
/// flight number ("United 123**UA**"). A tag only counts where it is a real tag
/// — the whole token, or glued straight onto a number — or "MOSKVA" reads as a
/// member of every VA tagged "VA".
enum VaCallsign {

    /// Weight-class words a pilot appends for heavy/super aircraft. They are
    /// spoken wake-turbulence categories, never part of the airline name or the
    /// tag, so they come off the end before anything else is read — otherwise a
    /// member flying a heavy reads as "not a registered member".
    private static let weightClasses: Set<String> = ["HEAVY", "SUPER"]

    /// The callsign's uppercased, separator-free tokens, with any trailing
    /// weight-class words removed.
    static func tokens(_ callsign: String) -> [String] {
        var parts = callsign
            .uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "\t" })
            .map(String.init)

        while parts.count > 1, let last = parts.last, weightClasses.contains(last) {
            parts.removeLast()
        }
        return parts
    }

    /// The callsign with every separator removed: "Air Canada 001VA" →
    /// "AIRCANADA001VA".
    static func compact(_ callsign: String) -> String {
        tokens(callsign).joined()
    }

    /// The offsets into `compact()` that land on a real word boundary: the end
    /// of each token, plus the letter→digit seam inside a glued one ("UNITED123"
    /// → after "UNITED"). A VA's code has to line up with one of these.
    static func boundaries(_ callsign: String) -> Set<Int> {
        var bounds: Set<Int> = []
        var accumulated = 0

        for token in tokens(callsign) {
            let letters = token.prefix { $0.isLetter }
            // Only a seam — letters *then* a digit — is a boundary. A token
            // that is all letters is covered by its own end below.
            if !letters.isEmpty, letters.count < token.count,
               token[token.index(token.startIndex, offsetBy: letters.count)].isNumber {
                bounds.insert(accumulated + letters.count)
            }
            accumulated += token.count
            bounds.insert(accumulated)
        }
        return bounds
    }

    /// True when a token is a flight number, a placeholder or a bare tag rather
    /// than part of the airline's name: "001", "001VA", "XXVA", "##UA", "VA".
    /// Airline words — "CANADA", "AIRWAYS" — are kept.
    static func isFlightNumberToken(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber }) { return true }

        // A placeholder run ("XX", "##") with an optional tag after it. VAs
        // commonly register a template callsign like "United ##UA".
        let placeholders = token.prefix { $0 == "X" || $0 == "#" }
        if !placeholders.isEmpty, token.dropFirst(placeholders.count).allSatisfy({ $0.isLetter }) {
            return true
        }

        return token.count <= 3 && token.allSatisfy { $0.isLetter }
    }

    /// The VA's own matching code: the airline-name part of its declared
    /// callsign, compacted.
    ///
    /// A trailing "VIRTUAL" is dropped along with the flight-number token —
    /// members fly "United 123", never "United Virtual 123", so a partner filed
    /// as "United Virtual" still has to resolve to "UNITED" or it never matches
    /// a real flight at all.
    static func code(for declaredCallsign: String) -> String {
        var parts = declaredCallsign
            .uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" || $0 == "\t" })
            .map(String.init)

        guard !parts.isEmpty else { return "" }
        if parts.count >= 2, isFlightNumberToken(parts[parts.count - 1]) { parts.removeLast() }
        if parts.count >= 2, parts[parts.count - 1] == "VIRTUAL" { parts.removeLast() }
        return parts.joined()
    }

    /// The membership tag a VA's declared callsign implies:
    ///
    ///     "Ocean XXVA"       → "VA"   (XX is the flight-number placeholder)
    ///     "United ##UA"      → "UA"
    ///     "Air Canada 001VA" → "VA"
    ///     "Delta VA"         → "VA"   (declared as its own word)
    ///     "Ocean"            → ""     (none declared — membership unknowable)
    static func tag(for declaredCallsign: String) -> String {
        let parts = tokens(declaredCallsign)
        guard let last = parts.last else { return "" }

        // <number or placeholder run><TAG>
        let head = last.prefix { $0.isNumber || $0 == "X" || $0 == "#" }
        let rest = last.dropFirst(head.count)
        if !head.isEmpty, !rest.isEmpty, rest.allSatisfy({ $0.isLetter }) {
            return String(rest)
        }

        // Declared as a separate short word, and not the airline name itself.
        if parts.count >= 2, last.count <= 3, last.allSatisfy({ $0.isLetter }) {
            return last
        }
        return ""
    }

    /// Does this flight's leading airline word belong to `code`?
    static func callsign(_ callsign: String, matchesCode code: String) -> Bool {
        guard !code.isEmpty else { return false }
        let compacted = compact(callsign)
        guard compacted.hasPrefix(code) else { return false }
        return boundaries(callsign).contains(code.count)
    }

    /// Is `tag` a real tag on this token, rather than letters that happen to end
    /// it? It counts only as the whole token ("Air Norway 123 NV") or glued onto
    /// a number ("123NV") — which is what keeps "9ANV", "MOSKVA" and "NOVA" out.
    private static func token(_ token: String, carries tag: String) -> Bool {
        guard !token.isEmpty, !tag.isEmpty, token.hasSuffix(tag) else { return false }
        if token == tag { return true }
        let before = token[token.index(token.endIndex, offsetBy: -(tag.count + 1))]
        return before.isNumber
    }

    /// Does the callsign carry `tag` as a membership tag?
    ///
    /// Checked on the last two tokens: pilots often append a second trailing tag
    /// after the VA one ("Air Norway 123NV EX"), and the tag may be written as
    /// its own word.
    static func callsign(_ callsign: String, carriesTag tag: String) -> Bool {
        guard !tag.isEmpty else { return false }
        return tokens(callsign).suffix(2).contains { token($0, carries: tag) }
    }
}
