import Combine
import Foundation

/// The partner virtual airlines, and which of them a callsign belongs to.
///
/// One fetch of the whole directory, held for the session and re-tried on a
/// cooldown if it fails. There are a couple of hundred partners at most, the
/// list changes on the scale of weeks, and every lookup after the first is a
/// dictionary hit — so the alternative, a request per flight window, would be
/// hundreds of round trips to answer a question the app already knew.
///
/// Nothing here decodes or stores an image. See `VirtualAirline`.
@MainActor
final class VirtualAirlineStore: ObservableObject {

    static let shared = VirtualAirlineStore()

    /// Bumped when the directory lands, so a window that opened before the
    /// fetch finished redraws with the VA it now knows about.
    @Published private(set) var revision = 0

    /// Sorted longest code first, so "AIRCANADA" is tried before "AIR" and the
    /// more specific airline wins a callsign both could claim.
    private var directory: [VirtualAirline] = []

    private var isLoading = false

    /// A failed load is not retried for this long. `airline(forCallsign:)` is
    /// called from every flight window and every map pass that draws one, so a
    /// condition that stays true on failure is a request per aeroplane per
    /// tick — which is exactly what the web client had to guard against too.
    private static let retryInterval: TimeInterval = 60
    private var nextAttempt = Date.distantPast

    /// How many pages of a hundred to walk. Three covers the partner roster
    /// several times over; the loop stops early at the last page anyway.
    private static let maximumPages = 3

    private init() {}

    // MARK: - Lookup

    /// The answer to a callsign already asked about, misses included.
    ///
    /// A view asks this from its `body`, which runs again every time the
    /// aeroplane moves — several times a second on a busy server — and the
    /// answer walks a couple of hundred entries. It cannot change while the
    /// directory is what it is, so it is worked out once and remembered.
    /// Cleared when the directory lands, since that is the one thing that can
    /// change it.
    private var answers: [String: Answer] = [:]

    private struct Answer {
        let airline: VirtualAirline?
        let match: VirtualAirline.Match
    }

    /// Bounded. A long session panning across a busy server sees thousands of
    /// callsigns, and a dictionary that only grows is a leak however small its
    /// entries are. Emptied rather than trimmed: rebuilding a few hundred
    /// lookups costs less than tracking which of them were recent.
    private static let maximumAnswers = 1500

    /// The partner VA this callsign flies for, and how firmly, or nil.
    ///
    /// Asking is also what starts the fetch — the answer is nil until it lands,
    /// which is the same shape every other lazily-loaded thing in the app has.
    func airline(forCallsign callsign: String) -> (airline: VirtualAirline, match: VirtualAirline.Match)? {
        load()
        guard !directory.isEmpty else { return nil }

        let key = callsign.uppercased()
        if let cached = answers[key] {
            guard let airline = cached.airline else { return nil }
            return (airline, cached.match)
        }

        var found: (VirtualAirline, VirtualAirline.Match)?
        for airline in directory {
            let match = airline.match(callsign: callsign)
            if match != .unrelated {
                found = (airline, match)
                break
            }
        }

        if answers.count >= Self.maximumAnswers { answers.removeAll(keepingCapacity: true) }
        answers[key] = Answer(airline: found?.0, match: found?.1 ?? .unrelated)
        return found
    }

    /// Every partner that calls this field a hub. Empty until the directory has
    /// landed, and empty for the great majority of airports.
    func airlines(hubbedAt icao: String) -> [VirtualAirline] {
        load()
        let code = icao.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return [] }
        return directory
            .filter { $0.hubs.contains(code) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Loading

    func load() {
        guard directory.isEmpty, !isLoading, Date() >= nextAttempt else { return }
        isLoading = true

        Task { [weak self] in
            let airlines = await VirtualAirlineStore.fetchAll()
            guard let self = self else { return }
            self.isLoading = false

            // An ad whose callsign has no airline word in it can never match
            // anything, so it is dropped here rather than left in the list to
            // be asked a pointless question once per lookup per flight.
            let usable = airlines.filter { !$0.code.isEmpty }

            // Never cache an empty directory as though it were the answer. One
            // bad moment on launch would otherwise leave every flight window
            // saying "no partner" for the rest of the session — and the guard
            // covers "the fetch worked and nothing in it was usable" as well as
            // "the fetch failed", because to everything downstream those are
            // the same state and both have to be able to resolve later.
            guard !usable.isEmpty else {
                self.nextAttempt = Date().addingTimeInterval(Self.retryInterval)
                return
            }

            // Longest code first, so "AIRCANADA" is tried before "AIR" and the
            // more specific airline wins a callsign both could claim.
            self.directory = usable.sorted { $0.code.count > $1.code.count }
            // Every "no partner" answered while the directory was empty is now
            // wrong, and they are the only answers there can be.
            self.answers.removeAll(keepingCapacity: true)
            self.revision &+= 1
        }
    }

    /// Walks the directory's pages.
    ///
    /// Left on the main actor rather than hoisted off it, deliberately. The
    /// only work here that is not a suspension is decoding a few hundred small
    /// JSON objects, once per session, and paying for that on the main thread
    /// costs a frame nobody will see — where an actor hop per page buys a
    /// concurrency problem for no measurable return.
    private static func fetchAll() async -> [VirtualAirline] {
        var all: [VirtualAirline] = []
        var seen: Set<String> = []

        for page in 1...maximumPages {
            guard let url = AppConfig.vaAdsURL(page: page, limit: 100) else { break }

            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 20

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else {
                // A page that fails is the end of what we can say. What has
                // already been read is still a usable directory.
                break
            }

            let batch = decode(data)
            guard !batch.isEmpty else { break }

            for airline in batch where seen.insert(airline.id).inserted {
                all.append(airline)
            }

            // A short page is the last one.
            if batch.count < 100 { break }
        }

        return all
    }

    /// `{ data: [ … ] }`, or a bare array — the endpoint has shipped as both,
    /// and `vaAds.js` reads either.
    private static func decode(_ data: Data) -> [VirtualAirline] {
        let root = try? JSONSerialization.jsonObject(with: data)

        let entries: [Any]
        if let list = root as? [Any] {
            entries = list
        } else if let object = root as? [String: Any], let list = object["data"] as? [Any] {
            entries = list
        } else {
            entries = []
        }

        return entries.compactMap { entry in
            guard let json = entry as? [String: Any] else { return nil }
            return VirtualAirline(json: json)
        }
    }
}
