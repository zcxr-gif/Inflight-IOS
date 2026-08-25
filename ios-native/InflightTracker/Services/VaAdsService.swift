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

    /// What the VA calls itself. The only thing of theirs that reaches a screen.
    let name: String

    /// The callsign template its members fly under — "Air Canada 001VA". Used
    /// to match flights, never displayed.
    let callsign: String

    /// The fields it lists as hubs, as ICAO codes.
    let hubs: [String]
}

/// A VA shown against a flight, and the reason it is being shown.
///
/// The two are very different claims and the window must not blur them: one
/// says this aircraft is flying that VA's callsign, the other says the VA is
/// simply hubbed at an end of the route.
struct VaPartner: Equatable {

    enum Basis: Equatable {
        /// The callsign's airline name resolves to this VA.
        case flying
        /// No callsign match — this VA is hubbed at the named field.
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
            return VaPartner(ad: ad, basis: .flying)
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

        return VaAd(id: identifier, name: name, callsign: callsign, hubs: hubs(in: raw))
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
        var parts = rawTokens(callsign)
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
    private static func code(fromCallsign callsign: String) -> String {
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
