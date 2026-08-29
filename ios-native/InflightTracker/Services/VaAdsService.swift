import Combine
import Foundation

/// The partner virtual airlines, from the same VA-Ads endpoints the web tracker
/// reads (`vaAds.js`):
///
///     GET /api/va-ads                  the directory, paginated
///     GET /api/va-ads/banner/:icao     the partners advertising at a field
///     GET /api/public/va/:id/events    that VA's scheduled events
///     GET /api/public/va/:id/pilots    its roster, for the count
///
/// Everything here is text. The responses carry a logo and a banner image, and
/// this deliberately does not decode either — see `VirtualAirline`. A partner
/// reaches the app as words in a panel, never as artwork pasted into one.
///
/// Nothing in here is load-bearing. Every request fails soft: a directory that
/// will not load leaves the sections it feeds simply absent, which is the same
/// thing to look at as a server with no partners on it.
final class VaAdsService: ObservableObject {

    static let shared = VaAdsService()

    /// The whole partner directory, once it has loaded. Ordered as the backend
    /// returned it, which puts the featured VAs first.
    @Published private(set) var partners: [VirtualAirline] = []

    /// Held apart from an empty list so a panel can say "nothing yet" rather
    /// than "no partners" while the first request is still out.
    @Published private(set) var hasAnswered = false

    /// The directory is a few hundred rows that change when somebody signs a
    /// partnership. Once an hour is far more often than that.
    private static let lifetime: TimeInterval = 60 * 60

    /// A failed load must not turn into a request per row: the panels call
    /// `refresh()` on appear and the flight window asks for a match on every
    /// packet, so a cold miss backs off before it tries again.
    private static let retryDelay: TimeInterval = 20

    /// Pages of 100. Three covers the roster with room to spare, and is the
    /// bound that stops a paginated endpoint that never says "last page" from
    /// walking the whole table.
    private static let maximumPages = 3

    private var lastLoad: Date?
    private var retryAfter: Date?
    private var isLoading = false

    /// Partner codes, longest first, so the most specific VA claims a callsign
    /// before a shorter one can. Rebuilt with `partners`.
    private var directory: [(code: String, ad: VirtualAirline)] = []

    private init() {}

    // MARK: - The directory

    /// Load the directory if it is stale. Cheap enough to call on every appear —
    /// a date comparison until the hour is up.
    func refresh(force: Bool = false) {
        if !force, let last = lastLoad, Date().timeIntervalSince(last) < Self.lifetime { return }
        if !force, let retry = retryAfter, Date() < retry { return }
        guard !isLoading else { return }

        isLoading = true

        Task { [weak self] in
            guard let self = self else { return }
            let loaded = await Self.loadDirectory()

            await MainActor.run {
                self.isLoading = false
                self.hasAnswered = true

                // Never cache an empty directory as if it were the answer: one
                // bad network moment at launch would otherwise leave every VA
                // surface blank for the whole session. Keeping the old list and
                // arming a retry is what makes that recoverable.
                guard let loaded = loaded, !loaded.isEmpty else {
                    self.retryAfter = Date().addingTimeInterval(Self.retryDelay)
                    return
                }

                self.retryAfter = nil
                self.lastLoad = Date()
                self.partners = loaded
                self.directory = loaded
                    .map { (code: VaCallsign.code(for: $0.callsign), ad: $0) }
                    .filter { !$0.code.isEmpty }
                    .sorted { $0.code.count > $1.code.count }
            }
        }
    }

    /// Nil for "could not read the service at all", which is held apart from a
    /// service that answered with nothing.
    private static func loadDirectory() async -> [VirtualAirline]? {
        var all: [VirtualAirline] = []

        for page in 1...maximumPages {
            guard var components = URLComponents(string: "\(AppConfig.apiBaseURLString)/api/va-ads") else {
                return nil
            }
            components.queryItems = [
                URLQueryItem(name: "limit", value: "100"),
                URLQueryItem(name: "page", value: "\(page)")
            ]
            guard let url = components.url, let root = await json(url) else { return nil }

            let ads = list(from: root)
            all.append(contentsOf: ads)
            if ads.isEmpty { break }

            // Stop on the last page the backend names; without a pagination
            // block there is no way to ask for another one honestly.
            guard let pagination = root["pagination"] as? [String: Any],
                  let total = intValue(pagination["totalPages"]), page < total else { break }
        }

        return all
    }

    // MARK: - Reading the directory

    /// The partners hubbed at a field, from the directory already in memory.
    /// Synchronous, so a panel can draw the section on its first frame; the
    /// authoritative list for a field comes from `partners(advertisingAt:)`.
    func partners(hubbedAt icao: String) -> [VirtualAirline] {
        let code = icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else { return [] }
        return partners.filter { $0.hubs.contains(code) }
    }

    /// The partners advertising at a field, as the backend picks them. Answers
    /// with an empty list on any failure — the field's panel simply has no VA
    /// section, which is the ordinary case for most airports anyway.
    func partners(advertisingAt icao: String, limit: Int = 8) async -> [VirtualAirline] {
        let code = icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty,
              let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              var components = URLComponents(string: "\(AppConfig.apiBaseURLString)/api/va-ads/banner/\(escaped)")
        else { return [] }

        components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
        guard let url = components.url, let root = await Self.json(url) else { return [] }

        // `?pick=random` answers with a single object under `data`; the plain
        // call answers with an array. Both have been seen from this endpoint.
        if let single = root["data"] as? [String: Any], let ad = VirtualAirline(json: single) {
            return [ad]
        }
        return Self.list(from: root)
    }

    /// The partner whose airline name this flight is flying under, if any.
    ///
    /// Synchronous and allocation-light: it is asked once per flight window and
    /// reads the warm directory. A cold call kicks the load off and answers nil,
    /// which is the honest answer — the app does not yet know.
    func partner(forCallsign callsign: String) -> VirtualAirline? {
        guard !directory.isEmpty else {
            refresh()
            return nil
        }

        let compacted = VaCallsign.compact(callsign)
        guard !compacted.isEmpty else { return nil }
        let bounds = VaCallsign.boundaries(callsign)

        return directory.first {
            compacted.hasPrefix($0.code) && bounds.contains($0.code.count)
        }?.ad
    }

    /// Is this pilot flying as a registered member of `ad`, or just under an
    /// airline name that happens to be a partner's?
    ///
    /// "Air Canada 001VA" is a member; "Air Canada 500" is a partner's airline
    /// without the VA's tag on it. Where a VA declared no tag of its own, the
    /// standard "VA" suffix stands in.
    func isMember(callsign: String, of ad: VirtualAirline) -> Bool {
        let tag = VaCallsign.tag(for: ad.callsign)
        return VaCallsign.callsign(callsign, carriesTag: tag.isEmpty ? "VA" : tag)
    }

    // MARK: - One VA's own feeds

    /// Upcoming events, soonest first. Empty on any failure.
    func events(for id: String) async -> [VirtualAirlineEvent] {
        guard let url = Self.publicURL(id, "events"), let root = await Self.json(url) else { return [] }
        let raw = (root["events"] as? [[String: Any]]) ?? []
        return raw.compactMap(VirtualAirlineEvent.init(json:))
    }

    /// How many pilots the VA has on its roster. Nil where the feed did not
    /// answer — which reads differently from a VA with nobody on the books.
    func rosterCount(for id: String) async -> Int? {
        guard let base = Self.publicURL(id, "pilots"),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return nil }

        // The roster itself is never shown — only the count — so one row is all
        // this asks for, and the totals come back in the envelope either way.
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        guard let url = components.url, let root = await Self.json(url) else { return nil }
        return Self.intValue(root["rosterTotal"]) ?? Self.intValue(root["total"])
    }

    private static func publicURL(_ id: String, _ path: String) -> URL? {
        guard !id.isEmpty,
              let escaped = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "\(AppConfig.apiBaseURLString)/api/public/va/\(escaped)/\(path)")
    }

    // MARK: - Scorecards

    /// What a partner's daily scorecard counts.
    enum Impression: String {
        /// The VA appeared in front of somebody — a row in a list, a line on a
        /// field, the partner line in a flight window.
        case impression
        /// Its own page was opened.
        case open
        /// A link out of it was followed.
        case click
    }

    /// Seen-type events are counted once per launch per VA, so a list scrolled
    /// back and forth does not inflate anybody's numbers. A click is a real,
    /// separate action every time and is never deduplicated.
    private static let deduplicated: Set<Impression> = [.impression, .open]

    private var pending: [[String: String]] = []
    private var counted: Set<String> = []
    private var flushTask: Task<Void, Never>?
    private let statsLock = NSLock()

    /// Queue one event. Batched, and silent about everything — a blocked or
    /// offline stats endpoint must never change what the user sees.
    func track(_ impression: Impression, for id: String) {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }

        statsLock.lock()
        if Self.deduplicated.contains(impression) {
            guard counted.insert("\(impression.rawValue):\(id)").inserted else {
                statsLock.unlock()
                return
            }
        }
        pending.append(["vaId": id, "type": impression.rawValue])
        let full = pending.count >= 20
        statsLock.unlock()

        if full || impression == .click {
            // A click is the one event the app might be leaving the screen
            // straight after, so it does not wait for the batch.
            flush()
        } else {
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        statsLock.lock()
        let alreadyScheduled = flushTask != nil
        if !alreadyScheduled {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.flush()
            }
        }
        statsLock.unlock()
    }

    private func flush() {
        statsLock.lock()
        flushTask?.cancel()
        flushTask = nil
        let batch = pending
        pending = []
        statsLock.unlock()

        guard !batch.isEmpty,
              let url = URL(string: "\(AppConfig.apiBaseURLString)/api/va-stats/track"),
              let body = try? JSONSerialization.data(withJSONObject: ["events": batch])
        else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 8

        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Transport

    /// One GET, decoded as an object. Nil for anything that did not come back
    /// as readable JSON — including an array at the root, which this backend
    /// also answers with and which `list(from:)` handles through `rootArray`.
    private static func json(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }

        let parsed = try? JSONSerialization.jsonObject(with: data)
        if let object = parsed as? [String: Any] { return object }
        if let array = parsed as? [Any] { return ["data": array] }
        return nil
    }

    /// The ads in a response, whether they arrived at the root or under `data`.
    private static func list(from root: [String: Any]) -> [VirtualAirline] {
        let raw = (root["data"] as? [Any]) ?? (root["ads"] as? [Any]) ?? []
        return raw.compactMap { ($0 as? [String: Any]).flatMap(VirtualAirline.init(json:)) }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String { return Int(text) }
        return nil
    }
}
