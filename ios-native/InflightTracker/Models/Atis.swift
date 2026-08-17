import Foundation

/// A field's ATIS, read for the four things a pilot listens to it for: which
/// information letter is current, which runways are in use, what approach to
/// expect, and anything the controller has added on the end.
///
/// A port of `parseAtis` from `old/www/flight.js`. Infinite Flight's ATIS is
/// generated prose rather than a coded report, so this reads it the way that
/// one did — by looking for the phrases the generator uses — and keeps the text
/// itself, which is the only thing guaranteed to say everything.
struct Atis: Equatable {

    let raw: String

    /// The phonetic letter, as a letter — `A` for Alpha. Nil when the text
    /// doesn't name one.
    let information: String?

    /// `0522Z`, when the report timestamps itself.
    let time: String?

    /// Runways in use, as `31R` or `04L/04R`. Nil where the ATIS didn't say,
    /// which for a small field is most of the time.
    let landingRunways: String?
    let departingRunways: String?

    /// `ILS`, `VISUAL`, `RNAV` — what to expect on the way in.
    let approach: String?

    /// Whatever the controller added: "no pattern work", "expect delays".
    let remarks: String?

    /// Whether anything beyond the raw text was resolved. A report this could
    /// make nothing of is still worth showing as prose, but it shouldn't get a
    /// row of empty chips over it.
    var hasStructure: Bool {
        information != nil
            || landingRunways != nil
            || departingRunways != nil
            || approach != nil
    }

    init?(_ text: String?) {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count > 10 else { return nil }

        self.raw = text

        self.information = Self.firstMatch(in: text, pattern: "information\\s+([A-Za-z]+)")
            .map { Self.phoneticLetter($0) }

        self.time = Self.firstMatch(in: text, pattern: "(\\d{4})\\s*Z").map { "\($0)Z" }

        self.landingRunways = Self.firstMatch(in: text, pattern: "Landing\\s+([^,.]+)")
            .flatMap { Self.runways(in: $0) }

        self.departingRunways = Self.firstMatch(in: text, pattern: "Departing\\s+([^,.]+)")
            .flatMap { Self.runways(in: $0) }

        self.approach = Self.firstMatch(in: text, pattern: "expect\\s+(.*?)\\s+approach")
            .map { $0.uppercased() }

        let remark = Self.firstMatch(
            in: text,
            pattern: "Remarks[.,]\\s*(.*?)(?=\\.|Landing|Departing|Advise|$)"
        )?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.remarks = (remark?.isEmpty == false) ? remark : nil
    }

    // MARK: - Reading the prose

    /// First capture group of `pattern`, case-insensitively.
    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }

        let value = String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Every runway designator in a phrase, joined — "Runways 4 Left and 4
    /// Right" is two, and the chip should say both.
    private static func runways(in phrase: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\\d{2}[LRC]?") else { return nil }

        let range = NSRange(phrase.startIndex..., in: phrase)
        let found = regex.matches(in: phrase, options: [], range: range).compactMap { match -> String? in
            guard let captured = Range(match.range, in: phrase) else { return nil }
            return String(phrase[captured]).uppercased()
        }

        return found.isEmpty ? nil : found.joined(separator: "/")
    }

    /// The generator writes the word — "Information Alpha" — where what is
    /// wanted on a chip is the letter. An unrecognised word keeps its own first
    /// character, which is what a bare "Information A" already is.
    private static func phoneticLetter(_ word: String) -> String {
        let alphabet = [
            "ALPHA": "A", "BRAVO": "B", "CHARLIE": "C", "DELTA": "D", "ECHO": "E",
            "FOXTROT": "F", "GOLF": "G", "HOTEL": "H", "INDIA": "I", "JULIETT": "J",
            "JULIET": "J", "KILO": "K", "LIMA": "L", "MIKE": "M", "NOVEMBER": "N",
            "OSCAR": "O", "PAPA": "P", "QUEBEC": "Q", "ROMEO": "R", "SIERRA": "S",
            "TANGO": "T", "UNIFORM": "U", "VICTOR": "V", "WHISKEY": "W", "XRAY": "X",
            "X-RAY": "X", "YANKEE": "Y", "ZULU": "Z"
        ]

        let upper = word.uppercased()
        if let letter = alphabet[upper] { return letter }
        return String(upper.prefix(1))
    }
}
