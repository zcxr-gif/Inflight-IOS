import Foundation

/// A partner virtual airline, as the VA-Ads backend describes one.
///
/// The web tracker reads the same three endpoints (`vaAds.js`) and renders a
/// banner: an uploaded image, a logo chip, an animated WebP. **None of that is
/// carried here.** The fields below are the ad's *words* — who the VA is, where
/// it is based, what it flies for, how to reach it — and the artwork keys are
/// deliberately not decoded, so there is nothing in the app that could draw one
/// even by accident. A VA reads as a row of type in the same voice as the rest
/// of the panel it sits in, rather than as an advert pasted into it.
///
/// Every field is optional on the wire and several arrive under more than one
/// name — the backend has answered with `hub`, `hubs` and `icao` for the same
/// thing — so the decoding below is tolerant in exactly the places `normalizeAd()`
/// is, and drops anything it cannot read rather than failing the whole list.
struct VirtualAirline: Identifiable, Equatable {

    let id: String

    /// The VA's crew centre address (`/crew/<slug>`), when it has one. Never
    /// guessed from the callsign — a VA with a custom slug would 404.
    let slug: String?

    /// The declared callsign, e.g. "Air Canada 001VA". This is what members fly
    /// under, and what `VaCallsign` reads a matching code and a membership tag
    /// out of.
    let callsign: String

    let name: String
    let tagline: String
    let summary: String

    /// "CARGO", "PASSENGER", … whatever the VA filed. Shown verbatim, title-cased.
    let kind: String
    let region: String

    let isRecruiting: Bool
    let isFeatured: Bool

    let tags: [String]

    /// Hubs, as ICAO codes.
    let hubs: [String]

    /// Both are http(s)-only. Anything else — a `javascript:` URL smuggled in
    /// through the ad data — is dropped rather than carried as a link nobody
    /// should be able to tap.
    let website: URL?
    let discord: URL?

    let views: Int

    /// What the row says under the name when the VA filed nothing to say.
    /// Falls back through the ad's own words before giving up on the line.
    var blurb: String {
        for candidate in [tagline, summary] where !candidate.isEmpty {
            return candidate
        }
        return ""
    }

    /// Where it flies from, as one line: "KJFK · EGLL · OMDB", capped so a VA
    /// that filed twenty hubs does not take the row with it.
    func hubLine(limit: Int = 4) -> String {
        guard !hubs.isEmpty else { return "" }
        let shown = hubs.prefix(limit).joined(separator: " · ")
        let rest = hubs.count - min(hubs.count, limit)
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }
}

// MARK: - Decoding

extension VirtualAirline {

    /// Reads one ad out of the backend's JSON, or nil if there is no id to file
    /// it under.
    ///
    /// A port of `normalizeAd()` in the web tracker, minus the two artwork
    /// fields: the same alternate key names, the same splitting of a
    /// comma-separated string into a list, the same http(s)-only rule on links.
    init?(json: [String: Any]) {
        let id = Self.string(json, "id", "_id")
        guard !id.isEmpty else { return nil }

        self.id = id
        self.slug = Self.slug(from: Self.string(json, "slug"))
        self.callsign = Self.string(json, "callsign", "callsignCode", "code").uppercased()

        let name = Self.string(json, "name", "vaName", "title")
        self.name = name.isEmpty ? "Unknown VA" : name

        self.tagline = Self.string(json, "tagline", "slogan")
        self.summary = Self.string(json, "description", "desc")
        self.kind = Self.string(json, "type").uppercased()
        self.region = Self.string(json, "region")
        self.isRecruiting = Self.bool(json["recruiting"])
        self.isFeatured = Self.bool(json["featured"])
        self.tags = Self.list(json["tags"])
        self.hubs = Self.list(json["icao"] ?? json["hubs"] ?? json["hub"]).map { $0.uppercased() }
        self.website = Self.link(Self.string(json, "website", "websiteUrl", "website_url", "url", "link"))
        self.discord = Self.link(Self.string(json, "discord", "discordUrl", "discord_url"))
        self.views = Self.int(json["views"] ?? json["viewCount"])
    }

    /// The first of `keys` that carries a non-empty string.
    private static func string(_ json: [String: Any], _ keys: String...) -> String {
        for key in keys {
            if let value = json[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    /// A list that has arrived both ways: as a real array, and as one
    /// comma-separated string.
    private static func list(_ raw: Any?) -> [String] {
        if let array = raw as? [Any] {
            return array.compactMap {
                let text = String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
        }
        if let text = raw as? String {
            return text
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// `true` and `"true"` both mean true; this backend has sent each.
    private static func bool(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let text = raw as? String { return text.lowercased() == "true" }
        return false
    }

    private static func int(_ raw: Any?) -> Int {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) ?? 0 }
        return 0
    }

    /// http(s) only. The ad text is written by a third party, so a link out of
    /// it is checked before it is ever offered as one.
    private static func link(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    /// The same character set the web tracker allows in a crew-centre slug.
    /// Anything else is treated as "no crew centre".
    private static func slug(from raw: String) -> String? {
        let candidate = raw.lowercased()
        guard candidate.count <= 81, let first = candidate.first,
              first.isASCII, first.isLetter || first.isNumber else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return candidate
    }
}

/// One scheduled event a VA has published.
struct VirtualAirlineEvent: Identifiable, Equatable {

    let id: String
    let title: String
    let detail: String
    let link: URL?
    let startsAt: Date?

    init?(json: [String: Any]) {
        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }

        self.id = (json["id"] as? String) ?? title
        self.title = title
        self.detail = (json["description"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if let raw = json["link"] as? String, let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            self.link = url
        } else {
            self.link = nil
        }

        self.startsAt = (json["startsAt"] as? String).flatMap(Self.date(from:))
    }

    /// ISO-8601, with and without fractional seconds — the feed sends both.
    private static func date(from raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }

    var isLive: Bool {
        guard let startsAt = startsAt else { return false }
        // The web tracker calls an event live from its start until two hours
        // after it, which is about as long as a group flight runs.
        let elapsed = Date().timeIntervalSince(startsAt)
        return elapsed >= 0 && elapsed <= 2 * 60 * 60
    }
}
