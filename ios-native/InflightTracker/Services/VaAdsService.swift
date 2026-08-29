import Foundation

/// One virtual airline, as the VA-Ads directory describes it.
///
/// The name, the callsign it flies under, and the fields it calls home — and
/// nothing else. The directory also carries logos, banner artwork, taglines and
/// links, and none of it is parsed here on purpose: that material belongs to
/// the VAs who uploaded it, and the app has no licence to redraw it. What the
/// app shows of a partner is its NAME, as text. Anything more is a copyright
/// question this file is deliberately not in a position to get wrong.
struct VaAd: Identifiable, Equatable {

    let id: String

    /// What the VA calls itself.
    let name: String

    /// The callsign template its members fly under — "Air Canada 001VA".
    let callsign: String

    /// The fields it lists as hubs, as ICAO codes.
    let hubs: [String]

    /// The one-line pitch and the longer write-up, as the VA wrote them.
    let tagline: String
    let description: String

    /// How it describes itself in the directory's own vocabulary.
    let type: String
    let region: String
    let tags: [String]

    let isRecruiting: Bool
    let isFeatured: Bool

    /// Where it can be reached. Only http(s) survives parsing, so an ad cannot
    /// smuggle some other scheme into a link the app will open.
    let website: URL?
    let discord: URL?

    /// Its crew centre's address on the site, when it has one configured. Never
    /// guessed from the callsign — a VA with a custom slug would 404.
    let crewCentre: URL?

    /// The airline-name part of its callsign, compacted: "AIRCANADA".
    var code: String { VaAdsService.code(fromCallsign: callsign) }

    /// Every way there is to reach this VA, in the order the site offers them.
    var links: [VaLink] {
        var out: [VaLink] = []
        if let crewCentre = crewCentre {
            out.append(VaLink(label: "Crew Centre", symbol: "person.badge.key", url: crewCentre))
        }
        if let website = website {
            out.append(VaLink(label: "Website", symbol: "globe", url: website))
        }
        if let discord = discord {
            out.append(VaLink(label: "Discord", symbol: "bubble.left.and.bubble.right", url: discord))
        }
        return out
    }
}

/// One way to reach a VA. Identifiable by its label, which is unique within an
/// ad — there is one crew centre, one website, one Discord.
struct VaLink: Identifiable, Equatable {
    let label: String
    let symbol: String
    let url: URL

    var id: String { label }
}

/// A VA shown against a flight, and the reason it is being shown.
///
/// The two are very different claims and the window must not blur them: one
/// says this aircraft is flying that VA's callsign, the other says the VA is
/// simply hubbed at an end of the route.
struct VaPartner: Equatable {

    enum Basis: Equatable {
        /// The callsign resolves to this VA *and* marks the pilot as one of
        /// theirs — it carries the VA's tag, or the pilot is on its roster.
        case member
        /// The callsign is this VA's airline name without either of those. A
        /// partner's airline, flown by someone the VA doesn't claim.
        case callsign
        /// No callsign match at all — this VA is hubbed at the named field.
        case hubbed(String)
    }

    let ad: VaAd
    let basis: Basis
}

/// Reads the VA-Ads directory the web tracker reads.
///
///   GET /api/va-ads                  the directory, paginated
///   GET /api/va-ads/banner/:icao     the VAs hubbed at one field
///
/// Both are public and read-only. Nothing here writes, and nothing here reports
/// what the pilot looked at — the web client fires impression beacons for the
/// VAs' own scorecards; a native window that quietly did the same would be
/// tracking this app's users through a surface they never opted into.
///
/// Every failure is silent and empty. A slow or unreachable ads service must
/// cost the airport panel and the flight window nothing at all.
final class VaAdsService {

    static let shared = VaAdsService()

    private init() {}

    // MARK: - State

    private struct DirectoryEntry {
        /// The VA's matching code — the airline-name part of its callsign,
        /// compacted. "Air Canada 001VA" → "AIRCANADA".
        let code: String
        let ad: VaAd
    }

    private let lock = NSLock()

    /// Sorted longest code first, so the most specific VA claims a callsign.
    private var directory: [DirectoryEntry] = []
    private var directoryLoaded = false
    private var directoryTask: Task<Void, Never>?

    /// Set after a failed load. A directory that cannot be reached must not
    /// turn into one request per flight per redraw.
    private var directoryRetryAfter: Date?

    /// ICAO → the VAs hubbed there. Only successful answers land here; a failed
    /// request is not cached as "no partners".
    private var hubCache: [String: [VaAd]] = [:]

    private static let retryCooldown: TimeInterval = 20
    private static let directoryPages = 3
    private static let pageSize = 100

    // MARK: - Lookups

    /// The VAs that call this field a hub, in the order the backend ranked them.
    func partners(hubbedAt icao: String?) async -> [VaAd] {
        let code = Self.normalisedIcao(icao)
        guard !code.isEmpty else { return [] }

        lock.lock()
        if let cached = hubCache[code] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let ads = await fetchAds(
            path: "/api/va-ads/banner/\(code)",
            query: [URLQueryItem(name: "limit", value: "8")]
        ) else { return [] }

        lock.lock()
        hubCache[code] = ads
        lock.unlock()

        return ads
    }

    /// The VA to show against a flight.
    ///
    /// Its own first: a callsign whose airline name resolves to a partner is
    /// that partner's flight, and that is the only claim worth making. Failing
    /// that the window falls back to a VA hubbed where the flight is going, then
    /// where it came from — which is an advertisement rather than a fact about
    /// the aircraft, and is labelled as one.
    func partner(for flight: Flight) async -> VaPartner? {
        await loadDirectory()

        if let ad = matched(callsign: flight.callsign) {
            // The tag settles it on its own. Only when it doesn't is the roster
            // worth a request — most flights never need one.
            if Self.callsignMarksMember(flight.callsign, of: ad) {
                return VaPartner(ad: ad, basis: .member)
            }
            let roster = await roster(for: ad.id)
            let handle = Self.normalisedUsername(flight.username)
            return VaPartner(ad: ad, basis: roster.contains(handle) ? .member : .callsign)
        }

        for icao in [flight.arrivalIcao, flight.departureIcao] {
            let code = Self.normalisedIcao(icao)
            guard !code.isEmpty else { continue }
            if let first = await partners(hubbedAt: code).first {
                return VaPartner(ad: first, basis: .hubbed(code))
            }
        }

        return nil
    }

    /// The partner whose airline name this callsign is flying under, from the
    /// warm directory. Synchronous — `loadDirectory()` is what fills it.
    ///
    /// The code must end on a callsign WORD boundary, which is what stops a VA
    /// whose name is a fragment of a longer one from hijacking the flight: "UNI"
    /// (Uni Air) cannot swallow "United 123", because the boundary after "UNI"
    /// is not a boundary of that callsign.
    private func matched(callsign: String?) -> VaAd? {
        let compact = Self.compact(callsign)
        guard !compact.isEmpty else { return nil }

        let bounds = Self.boundaries(callsign)

        lock.lock()
        let entries = directory
        lock.unlock()

        return entries.first { compact.hasPrefix($0.code) && bounds.contains($0.code.count) }?.ad
    }

    // MARK: - Membership

    /// The VAs' rosters, by ad id, once each has answered. A VA with no roster
    /// published — or one whose feed is unreachable — is an empty set, which
    /// means the tag alone decides.
    private var rosterCache: [String: Set<String>] = [:]
    private var rosterTasks: [String: Task<Set<String>, Never>] = [:]

    /// Everyone this VA claims, keyed the way `normalisedUsername` keys them.
    func roster(for adId: String) async -> Set<String> {
        // The id is pasted into a path, so it is checked rather than escaped:
        // ours are hex object ids, and anything else is not one.
        let id = adId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return [] }

        lock.lock()
        if let cached = rosterCache[id] {
            lock.unlock()
            return cached
        }
        if let inFlight = rosterTasks[id] {
            lock.unlock()
            return await inFlight.value
        }
        let task = Task { await self.fetchRoster(id) }
        rosterTasks[id] = task
        lock.unlock()

        return await task.value
    }

    private func fetchRoster(_ id: String) async -> Set<String> {
        var handles: Set<String> = []
        var failed = true

        if var components = URLComponents(
            string: "\(AppConfig.apiBaseURLString)/api/public/va/\(id)/pilots"
        ) {
            components.queryItems = [URLQueryItem(name: "limit", value: "500")]

            if let url = components.url {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                request.setValue("application/json", forHTTPHeaderField: "Accept")

                if let result = try? await URLSession.shared.data(for: request),
                   let http = result.1 as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode),
                   let root = try? JSONSerialization.jsonObject(with: result.0) as? [String: Any] {
                    failed = false
                    for entry in (root["pilots"] as? [Any]) ?? [] {
                        guard let row = entry as? [String: Any],
                              let username = Self.text(row["username"]) else { continue }
                        handles.insert(Self.normalisedUsername(username))
                    }
                }
            }
        }

        lock.lock()
        defer { lock.unlock() }
        rosterTasks[id] = nil
        // A roster that never arrived is not the same as a VA with no pilots;
        // remembering the failure as "nobody" would mark real members as
        // strangers for the life of the process.
        if !failed { rosterCache[id] = handles }
        return handles
    }

    /// The roster this VA has already answered with, or nil if it has not been
    /// asked yet. For the synchronous passes over the live packet, which cannot
    /// wait on a request.
    private func warmRoster(for adId: String) -> Set<String>? {
        lock.lock()
        defer { lock.unlock() }
        return rosterCache[adId]
    }

    /// The aircraft this VA has in the air right now, out of the packet the map
    /// is already holding.
    ///
    /// Same rule the site's live-fleet list uses: the callsign must be this
    /// VA's airline, and the flight must then be claimed either by the VA's tag
    /// or by its roster. Synchronous, so it reads whatever roster has already
    /// arrived — call `roster(for:)` first if the answer needs to be complete.
    func fleet(of ad: VaAd, in flights: [Flight]) -> [Flight] {
        let roster = warmRoster(for: ad.id) ?? []
        return flights.filter { flight in
            guard Self.callsignMatches(flight.callsign, ad: ad) else { return false }
            if Self.callsignMarksMember(flight.callsign, of: ad) { return true }
            return roster.contains(Self.normalisedUsername(flight.username))
        }
    }

    /// Does this callsign's leading airline word belong to this ad? The same
    /// word-boundary test `matched(callsign:)` runs, against one ad instead of
    /// the whole directory — so it needs no warm directory.
    private static func callsignMatches(_ callsign: String?, ad: VaAd) -> Bool {
        let code = ad.code
        guard !code.isEmpty else { return false }
        return compact(callsign).hasPrefix(code) && boundaries(callsign).contains(code.count)
    }

    /// The VA's callsign tag — the suffix a member appends to their flight
    /// number, read off the VA's declared callsign:
    ///
    ///   "Ocean XXVA"       → "VA"   (XX is the flight-number placeholder)
    ///   "United ##UA"      → "UA"
    ///   "Air Canada 001VA" → "VA"
    ///   "Delta VA"         → "VA"   (declared as its own word)
    ///   "Ocean"            → ""     (none declared — membership unknowable)
    private static func vaTag(of ad: VaAd) -> String {
        let parts = rawTokens(ad.callsign)
        guard let last = stripWeightClass(parts).last else { return "" }

        // <number or placeholder run><TAG>
        let leading = last.prefix { $0.isNumber || $0 == "X" || $0 == "#" }
        if !leading.isEmpty {
            let rest = String(last.dropFirst(leading.count))
            if !rest.isEmpty, rest.allSatisfy({ $0.isLetter }) { return rest }
        }

        // Declared as a separate short word, and not the airline name itself.
        if parts.count >= 2, (1...3).contains(last.count), last.allSatisfy({ $0.isLetter }) {
            return last
        }

        return ""
    }

    /// Is `tag` a real tag on this token, rather than letters that happen to end
    /// it? A bare suffix test is far too greedy — "MOSKVA" and "NOVA" would both
    /// count for a "VA". It counts only when the tag is the whole token (a
    /// declared word: "Air Norway 123 NV") or is glued straight onto the flight
    /// number ("123NV").
    private static func tokenCarriesTag(_ token: String, tag: String) -> Bool {
        guard !tag.isEmpty, token.hasSuffix(tag) else { return false }
        if token == tag { return true }
        let before = token[token.index(token.endIndex, offsetBy: -tag.count - 1)]
        return before.isNumber
    }

    /// Does this callsign mark the pilot as one of the VA's own?
    ///
    /// The VA's declared tag when it has one, otherwise the standard "VA"
    /// suffix. Checked on the last two tokens (weight-class words stripped)
    /// because pilots often append a second tag after the VA one — "Air Norway
    /// 123NV EX" — and the tag may be written as its own word.
    private static func callsignMarksMember(_ callsign: String?, of ad: VaAd) -> Bool {
        let tag = { let declared = vaTag(of: ad); return declared.isEmpty ? "VA" : declared }()
        return tokens(callsign).suffix(2).contains { tokenCarriesTag($0, tag: tag) }
    }

    /// Canonical key for roster ⇆ live-feed username matching.
    ///
    /// The roster and the socket feed are two sources for the SAME handle and
    /// they don't always agree byte for byte: case, stray whitespace, a
    /// full-width character, a different Unicode composition, or an invisible
    /// zero-width mark can appear on one side and not the other. Both sides go
    /// through this, or they do not line up.
    private static func normalisedUsername(_ username: String?) -> String {
        let invisible: Set<Character> = ["\u{00AD}", "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}",
                                         "\u{200F}", "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}",
                                         "\u{202E}", "\u{2060}", "\u{FEFF}"]
        return (username ?? "")
            .precomposedStringWithCompatibilityMapping
            .filter { !invisible.contains($0) && !$0.isWhitespace }
            .lowercased()
    }

    // MARK: - Directory

    private func loadDirectory() async {
        lock.lock()
        if directoryLoaded {
            lock.unlock()
            return
        }
        if let retry = directoryRetryAfter, retry > Date() {
            lock.unlock()
            return
        }
        if let inFlight = directoryTask {
            lock.unlock()
            await inFlight.value
            return
        }

        let task = Task { await self.fetchDirectory() }
        directoryTask = task
        lock.unlock()

        await task.value
    }

    private func fetchDirectory() async {
        var all: [VaAd] = []
        var failed = false

        for page in 1...Self.directoryPages {
            guard let ads = await fetchAds(
                path: "/api/va-ads",
                query: [
                    URLQueryItem(name: "limit", value: String(Self.pageSize)),
                    URLQueryItem(name: "page", value: String(page))
                ]
            ) else {
                failed = true
                break
            }

            all.append(contentsOf: ads)
            // Short page: that was the last one.
            if ads.count < Self.pageSize { break }
        }

        lock.lock()
        defer { lock.unlock() }

        directoryTask = nil

        // Never remember an empty directory as if it were the answer — one bad
        // network moment at launch would otherwise leave every window partnerless
        // for the life of the process.
        guard !failed, !all.isEmpty else {
            directoryRetryAfter = Date().addingTimeInterval(Self.retryCooldown)
            return
        }

        directory = all
            .map { DirectoryEntry(code: Self.code(fromCallsign: $0.callsign), ad: $0) }
            .filter { !$0.code.isEmpty }
            .sorted { $0.code.count > $1.code.count }
        directoryLoaded = true
        directoryRetryAfter = nil
    }

    // MARK: - Transport

    private func fetchAds(path: String, query: [URLQueryItem]) async -> [VaAd]? {
        guard var components = URLComponents(string: AppConfig.apiBaseURLString + path) else { return nil }
        components.queryItems = query

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let result = try? await URLSession.shared.data(for: request),
              let http = result.1 as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }

        return Self.decode(result.0)
    }

    /// The backend has answered with a bare array, with `{ data: [...] }`, and —
    /// for the single-pick banner — with `{ data: {...} }`. All three are read.
    private static func decode(_ data: Data) -> [VaAd] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        let entries: [Any]
        if let array = root as? [Any] {
            entries = array
        } else if let object = root as? [String: Any] {
            if let array = object["data"] as? [Any] {
                entries = array
            } else if let one = object["data"] as? [String: Any] {
                entries = [one]
            } else {
                entries = []
            }
        } else {
            entries = []
        }

        return entries.compactMap { $0 as? [String: Any] }.compactMap(normalise)
    }

    /// Field names aren't pinned down on the backend, so the common variants are
    /// folded into one shape. An ad with no name is dropped rather than shown as
    /// "Unknown VA": the name is the entire thing this app displays, and a row
    /// that doesn't name anybody advertises nothing.
    private static func normalise(_ raw: [String: Any]) -> VaAd? {
        guard let name = firstText(in: raw, keys: ["name", "vaName", "title"]) else { return nil }

        let callsign = (firstText(in: raw, keys: ["callsign", "callsignCode", "code"]) ?? "").uppercased()
        let identifier = firstText(in: raw, keys: ["id", "_id"]) ?? name

        return VaAd(
            id: identifier,
            name: name,
            callsign: callsign,
            hubs: hubs(in: raw),
            tagline: firstText(in: raw, keys: ["tagline", "slogan"]) ?? "",
            description: firstText(in: raw, keys: ["description", "desc"]) ?? "",
            type: (firstText(in: raw, keys: ["type"]) ?? "").uppercased(),
            region: firstText(in: raw, keys: ["region"]) ?? "",
            tags: list(in: raw, key: "tags"),
            isRecruiting: flag(raw["recruiting"]),
            isFeatured: flag(raw["featured"]),
            website: safeURL(firstText(in: raw, keys: ["website", "websiteUrl", "website_url", "url", "link"])),
            discord: safeURL(firstText(in: raw, keys: ["discord", "discordUrl", "discord_url"])),
            crewCentre: crewCentreURL(firstText(in: raw, keys: ["slug"]))
        )
    }

    /// Deliberately absent from everything above: `logo`, `bannerUrl` and the
    /// rest of the artwork. The VAs own those, and the app has no licence to
    /// redraw them — so they are never parsed, and there is nothing here for a
    /// later change to start showing by accident.

    private static func flag(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let string = value as? String { return string.lowercased() == "true" }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    /// An array, or the comma-separated string the backend sometimes sends
    /// instead.
    private static func list(in raw: [String: Any], key: String) -> [String] {
        if let array = raw[key] as? [Any] {
            return array.compactMap { text($0) }
        }
        if let joined = text(raw[key]) {
            return joined.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// http(s) only. Anything else — a `javascript:` or a custom scheme — is
    /// dropped rather than handed to the system to open.
    private static func safeURL(_ string: String?) -> URL? {
        guard let string = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    /// The crew centre lives at inflight.info/crew/<slug>. The slug is checked
    /// against the same shape the site allows before it is pasted into a path.
    private static func crewCentreURL(_ slug: String?) -> URL? {
        let value = (slug ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value.count <= 80,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }),
              let first = value.first, first.isLetter || first.isNumber
        else { return nil }
        return URL(string: "https://inflight.info/crew/\(value)")
    }

    private static func hubs(in raw: [String: Any]) -> [String] {
        var codes: [String] = []

        for key in ["icao", "hubs", "hub"] {
            if let list = raw[key] as? [Any] {
                codes = list.compactMap { text($0) }
                break
            }
            if let joined = text(raw[key]), !joined.isEmpty {
                codes = joined.components(separatedBy: ",")
                break
            }
        }

        return codes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            .filter { !$0.isEmpty }
    }

    private static func firstText(in raw: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = text(raw[key]), !value.isEmpty { return value }
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    // MARK: - Callsign arithmetic
    //
    // Ported from the web tracker's vaAds.js so the two agree about which VA a
    // callsign belongs to. A flight that reads as Oceanic on the site and as
    // something else in the app would be worse than neither showing anything.

    private static let separators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "-_/"))

    /// Weight-class words a pilot appends for heavy/super aircraft — "United 2UA
    /// Heavy". They are spoken wake-turbulence categories, never part of the
    /// airline name, so they come off the end before anything else is read.
    private static let weightClasses: Set<String> = ["HEAVY", "SUPER"]

    private static func tokens(_ callsign: String?) -> [String] {
        stripWeightClass(rawTokens(callsign))
    }

    private static func stripWeightClass(_ tokens: [String]) -> [String] {
        var parts = tokens
        while parts.count > 1, let last = parts.last, weightClasses.contains(last) {
            parts.removeLast()
        }
        return parts
    }

    private static func rawTokens(_ callsign: String?) -> [String] {
        (callsign ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
    }

    private static func compact(_ callsign: String?) -> String {
        tokens(callsign).joined()
    }

    /// Offsets into the compacted callsign that land on a real word boundary:
    /// the end of each token, plus the letter→digit seam inside a glued one
    /// ("UNITED123" → after "UNITED").
    private static func boundaries(_ callsign: String?) -> Set<Int> {
        var bounds: Set<Int> = []
        var accumulated = 0

        for token in tokens(callsign) {
            if let seam = letterDigitSeam(token) { bounds.insert(accumulated + seam) }
            accumulated += token.count
            bounds.insert(accumulated)
        }

        return bounds
    }

    /// Length of a token's leading letters when it glues an airline name onto a
    /// flight number. Nil when the token isn't shaped that way.
    private static func letterDigitSeam(_ token: String) -> Int? {
        var letters = 0
        for character in token {
            if character.isLetter {
                letters += 1
            } else if character.isNumber {
                return letters > 0 ? letters : nil
            } else {
                return nil
            }
        }
        return nil
    }

    /// True when a token is a flight number, a placeholder for one, or a short
    /// tag word — rather than part of the airline's name. "001", "001VA", "##UA"
    /// and "VA" all are; "CANADA" and "AIRWAYS" are not.
    private static func isFlightNumberToken(_ token: String) -> Bool {
        if token.contains(where: { $0.isNumber }) { return true }

        let placeholder = token.prefix { $0 == "X" || $0 == "#" }
        if !placeholder.isEmpty, token.dropFirst(placeholder.count).allSatisfy({ $0.isLetter }) {
            return true
        }

        return (1...3).contains(token.count) && token.allSatisfy { $0.isLetter }
    }

    /// The VA's matching code: its callsign with the flight-number token dropped,
    /// compacted. "Air Canada 001VA" → "AIRCANADA", so it cannot swallow Air
    /// India or Air France the way a bare "AIR" would.
    ///
    /// A trailing "Virtual" comes off too — members fly "United 123", never
    /// "United Virtual 123", so a VA registered as "United Virtual" must still
    /// resolve to UNITED or it matches nothing that ever flies.
    fileprivate static func code(fromCallsign callsign: String) -> String {
        var parts = rawTokens(callsign)
        guard !parts.isEmpty else { return "" }

        if parts.count >= 2, isFlightNumberToken(parts[parts.count - 1]) { parts.removeLast() }
        if parts.count >= 2, parts[parts.count - 1] == "VIRTUAL" { parts.removeLast() }

        return parts.joined()
    }

    /// An ICAO fit to be pasted into a path. Anything with punctuation in it is
    /// not a field code and is refused rather than escaped.
    private static func normalisedIcao(_ icao: String?) -> String {
        let code = (icao ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty, code.count <= 8, code.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return ""
        }
        return code
    }
}
