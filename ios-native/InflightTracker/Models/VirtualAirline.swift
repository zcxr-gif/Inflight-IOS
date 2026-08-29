import Foundation

/// A partner virtual airline, as the VA-Ads directory describes it.
///
/// The web tracker's `vaAds.js` reads the same endpoint and draws banners,
/// logos and a slide-over of cards from it. This build deliberately takes only
/// the words. A VA is worth knowing about because it tells you who you are
/// looking at — that "Air Canada 001VA" over the Atlantic is somebody's flight
/// on somebody's roster, not a callsign that happens to rhyme with an airline.
/// That is a sentence. Rendering it as a banner would turn a fact about the
/// aeroplane into an advertisement sitting in the middle of the flight window,
/// so the image fields are not decoded at all: what cannot be stored cannot be
/// drawn by accident later.
struct VirtualAirline: Identifiable, Equatable {

    let id: String

    /// The airline's own name — "Ocean Virtual", "Air Norway Virtual".
    let name: String

    /// The callsign the VA declares, placeholders and all: "Ocean XXVA",
    /// "United ##UA", "Air Canada 001VA". Both halves of the matching come out
    /// of this — the leading airline word, and the trailing membership tag.
    let callsign: String

    let tagline: String
    let region: String

    /// Whether the VA says it is taking applications. Shown as a word, never
    /// as a badge to tap.
    let isRecruiting: Bool

    /// The fields the VA calls home, upper-cased.
    let hubs: [String]

    /// The leading airline word of the declared callsign, separators removed —
    /// "Air Canada 001VA" → "AIRCANADA".
    ///
    /// This is what a live callsign is matched against. Empty for an ad whose
    /// callsign is only a tag, which can never match anything and is filtered
    /// out of the directory rather than left in to match everything.
    ///
    /// Stored rather than computed. Every lookup walks the whole directory
    /// asking each entry whether a callsign is its own, and a computed property
    /// here would re-split and re-upper-case the same declared callsign a
    /// couple of hundred times per question — once per entry, per lookup, per
    /// redraw of a window that is on screen while an aeroplane moves.
    let code: String

    /// The suffix a member appends to their flight number: "Ocean XXVA" → "VA",
    /// "United ##UA" → "UA". Empty when the VA declares no tag, in which case
    /// membership is unknowable from the callsign alone and the generic "VA"
    /// stands in.
    let tag: String

    // MARK: - Derived

    /// One line for the panels: where it flies from, and whether it is hiring.
    var summary: String {
        var parts: [String] = []
        if !region.isEmpty { parts.append(region) }
        if let hub = hubs.first, !hub.isEmpty {
            parts.append(hubs.count > 1 ? "\(hub) +\(hubs.count - 1)" : hub)
        }
        if isRecruiting { parts.append("Recruiting") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Callsign matching

extension VirtualAirline {

    /// How a live callsign relates to this VA.
    enum Match: Equatable {

        /// The callsign is not this airline's at all.
        ///
        /// Spelled `unrelated` rather than `none` on purpose: `Match.none` and
        /// `Optional.none` are written identically at a use site, and every
        /// caller here holds one inside the other.
        case unrelated

        /// The airline matches but the flight carries no membership tag —
        /// somebody flying the livery, or a member who left the tag off.
        case airline

        /// The airline matches *and* the flight number carries the VA's tag.
        case member
    }

    /// Whether `callsign` belongs to this VA, and how firmly.
    ///
    /// Mirrors `vaAds.js` exactly, including the parts of it that look fussy
    /// and are not:
    ///
    /// * **Weight-class words are peeled off the end first.** Pilots append
    ///   "Heavy" and "Super" to a callsign because that is what they say on
    ///   frequency. Read the last token without stripping them and a member
    ///   flying a 777 comes out as "not a member".
    /// * **The airline word must end on a word boundary.** A raw prefix test
    ///   lets a VA coded "UNI" swallow every "United ###" on the server.
    /// * **A tag only counts glued to a number or standing alone.** A bare
    ///   `hasSuffix` makes "Moskva" a member of every VA whose tag is "VA".
    func match(callsign: String) -> Match {
        let code = self.code
        guard !code.isEmpty else { return .unrelated }

        let tokens = VirtualAirline.tokens(of: callsign)
        let compact = tokens.joined()
        guard compact.hasPrefix(code),
              VirtualAirline.boundaries(of: tokens).contains(code.count) else {
            return .unrelated
        }

        // A VA that declares no tag of its own still has the convention: the
        // letters "VA" on the flight number are what a virtual airline member
        // writes. It is the weakest signal here, which is why it is only ever
        // reached once the airline itself has already matched.
        let tag = self.tag.isEmpty ? "VA" : self.tag
        return VirtualAirline.carries(tag: tag, in: tokens) ? .member : .airline
    }

    /// Upper-cased, separator-free tokens, with the spoken weight class off the
    /// end: "Air Canada 001VA Heavy" → ["AIR", "CANADA", "001VA"].
    static func tokens(of callsign: String) -> [String] {
        var tokens = rawTokens(of: callsign)
        while tokens.count > 1, weightClasses.contains(tokens[tokens.count - 1]) {
            tokens.removeLast()
        }
        return tokens
    }

    private static let weightClasses: Set<String> = ["HEAVY", "SUPER"]

    /// The same split, with the weight class left on.
    static func rawTokens(of callsign: String) -> [String] {
        callsign
            .uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" || $0 == "/" })
            .map(String.init)
    }

    /// The offsets into the joined tokens that land on a real word boundary:
    /// the end of every token, plus the letters→digits seam at the *start* of
    /// a glued one ("UNITED123" → 6). An airline code has to line up with one
    /// of these, or a VA coded "UNI" swallows every "United ###" on the server.
    static func boundaries(of tokens: [String]) -> Set<Int> {
        var bounds: Set<Int> = []
        var offset = 0

        for token in tokens {
            let letters = token.prefix { $0.isLetter }
            if letters.count < token.count,
               token[token.index(token.startIndex, offsetBy: letters.count)].isNumber,
               !letters.isEmpty {
                bounds.insert(offset + letters.count)
            }
            offset += token.count
            bounds.insert(offset)
        }

        return bounds
    }

    /// Is `tag` a membership tag on this callsign, rather than letters that
    /// happen to end a word?
    ///
    /// Checked on the last two tokens, because a second trailing tag is common
    /// — "Air Norway 123NV EX" — and would otherwise hide the first.
    static func carries(tag: String, in tokens: [String]) -> Bool {
        guard !tag.isEmpty else { return false }

        for token in tokens.suffix(2) {
            guard token.hasSuffix(tag) else { continue }
            if token == tag { return true }
            let before = token.index(token.endIndex, offsetBy: -tag.count - 1, limitedBy: token.startIndex)
            if let before = before, token[before].isNumber { return true }
        }
        return false
    }

    /// The VA's matching code: the airline-name part of its declared callsign,
    /// compacted.
    ///
    /// The trailing flight-number/tag token goes, so "Air Canada 001VA"
    /// advertises as "AIRCANADA" rather than "AIR" — which used to swallow Air
    /// India, Air France and Airbus alike. A trailing "VIRTUAL" goes too:
    /// members fly the real airline's callsign ("United 123"), never "United
    /// Virtual 123", so a partner registered as "United Virtual" has to resolve
    /// to "UNITED" or it matches nothing at all. A single-token callsign
    /// ("DLVA") is kept whole — there is nothing else in it.
    ///
    /// Note the tokens are the *raw* ones — the weight class is not peeled off
    /// here, only off a live callsign being tested. A pilot says "Heavy"; a VA
    /// does not register one in its own callsign, so a declared callsign that
    /// ends in one is bad data rather than a 777, and reading it as an airline
    /// name would let "United Super" claim every United flight on the server.
    /// This is `vaAds.js`'s rule too, and the two must agree or the same
    /// aeroplane is credited to different VAs on the web and on the phone.
    static func code(fromCallsign callsign: String) -> String {
        var parts = rawTokens(of: callsign)
        guard !parts.isEmpty else { return "" }

        if parts.count >= 2, isFlightNumberToken(parts[parts.count - 1]) { parts.removeLast() }
        if parts.count >= 2, parts[parts.count - 1] == "VIRTUAL" { parts.removeLast() }
        return parts.joined()
    }

    /// The membership tag of a declared callsign.
    static func tag(fromCallsign callsign: String) -> String {
        let tokens = tokens(of: callsign)
        guard let last = tokens.last else { return "" }

        // <flight number or placeholder><TAG>: "001VA" → "VA", "##UA" → "UA".
        var digits = 0
        var letters = ""
        for character in last {
            if letters.isEmpty, character.isNumber || character == "X" || character == "#" {
                digits += 1
            } else if character.isLetter {
                letters.append(character)
            } else {
                return ""
            }
        }
        if digits > 0, !letters.isEmpty { return letters }

        // Declared as its own short word: "Delta VA". Counted against the raw
        // split, which is what `vaAds.js` does — the weight class is stripped
        // to find the last token but not to decide whether there was more than
        // one of them.
        if rawTokens(of: callsign).count >= 2, last.count <= 3, last.allSatisfy(\.isLetter) {
            return last
        }
        return ""
    }

    /// A token that is a flight number, a placeholder for one, or a bare tag
    /// rather than part of the airline's name: "123", "001VA", "##UA", "XXVA",
    /// "VA". Airline words — "CANADA", "AIRWAYS" — are kept.
    private static func isFlightNumberToken(_ token: String) -> Bool {
        if token.contains(where: \.isNumber) { return true }
        // A placeholder run of X or # with an optional tag after it.
        let placeholder = token.prefix { $0 == "X" || $0 == "#" }
        if !placeholder.isEmpty, token.dropFirst(placeholder.count).allSatisfy(\.isLetter) { return true }
        // A short standalone word is a tag, not an airline.
        return token.count <= 3 && token.allSatisfy(\.isLetter)
    }
}

// MARK: - Decoding

extension VirtualAirline {

    /// Built from one entry of the directory's JSON.
    ///
    /// Hand-decoded rather than `Codable` because the backend is loose about
    /// its key names — `vaAds.js` normalises half a dozen spellings of the same
    /// field — and because the image keys have to be *ignored*, which a
    /// synthesised decoder would happily not do.
    init?(json: [String: Any]) {
        let id = (json["id"] as? String) ?? (json["_id"] as? String) ?? ""
        let callsign = ((json["callsign"] as? String)
            ?? (json["callsignCode"] as? String)
            ?? (json["code"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()

        // An ad with no id or no callsign can neither be identified nor
        // matched, so there is nothing here worth keeping.
        guard !id.isEmpty, !callsign.isEmpty else { return nil }

        let name = ((json["name"] as? String)
            ?? (json["vaName"] as? String)
            ?? (json["title"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        self.id = id
        self.name = name
        self.callsign = callsign
        self.code = VirtualAirline.code(fromCallsign: callsign)
        self.tag = VirtualAirline.tag(fromCallsign: callsign)
        self.tagline = ((json["tagline"] as? String) ?? (json["slogan"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = ((json["region"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.isRecruiting = (json["recruiting"] as? Bool)
            ?? ((json["recruiting"] as? String)?.lowercased() == "true")

        let raw = json["icao"] ?? json["hubs"] ?? json["hub"]
        let hubs: [String]
        if let list = raw as? [String] {
            hubs = list
        } else if let joined = raw as? String {
            hubs = joined.split(separator: ",").map(String.init)
        } else {
            hubs = []
        }
        self.hubs = hubs
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty }
    }
}
