import CoreLocation
import Foundation

struct Airport: Equatable {
    let icao: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let countryCode: String

    /// The name, folded once at load. Search runs over every airport in the
    /// dataset on each keystroke, and case-folding 18,000 names per character
    /// typed is the whole cost of the query.
    let searchableName: String

    init(icao: String, name: String, coordinate: CLLocationCoordinate2D, countryCode: String) {
        self.icao = icao
        self.name = name
        self.coordinate = coordinate
        self.countryCode = countryCode
        self.searchableName = name.uppercased()
    }

    /// Written out rather than synthesised: `CLLocationCoordinate2D` is not
    /// `Equatable`, and an ICAO identifies an airport anyway.
    static func == (lhs: Airport, rhs: Airport) -> Bool {
        lhs.icao == rhs.icao
    }

    /// Regional-indicator flag for the airport's country, or an empty string
    /// when the country couldn't be resolved.
    var flag: String {
        guard countryCode.count == 2 else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in countryCode.uppercased().unicodeScalars {
            guard let indicator = UnicodeScalar(127_397 + scalar.value) else { return "" }
            scalars.append(indicator)
        }
        return String(scalars)
    }
}

/// Offline ICAO lookup, built from the VAT-Spy dataset the old tracker shipped.
///
/// Everything the route card needs — airport name, position, country — resolves
/// on device, so the route renders instantly and works with no connectivity
/// beyond the traffic feed itself.
final class AirportStore {

    static let shared = AirportStore()

    private var airports: [String: Airport] = [:]

    /// Memoised `nearestAirport` answers, keyed by rounded position.
    private var nearestCache: [String: Airport?] = [:]

    private var isLoaded = false
    private let lock = NSLock()

    private init() {}

    /// Parses the dataset off the main thread. Called at launch so the first
    /// flight the user taps doesn't pay for it.
    func preload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadIfNeeded()
        }
    }

    /// Closest airport to a position, or nil when there is nothing within
    /// `maxNM`. Used to say where an aircraft with no filed destination
    /// actually is — a parked airframe is sitting at a gate somewhere.
    ///
    /// Results are memoised on a ~100 m grid: a parked aircraft reports the
    /// same position for hours, and the window re-reads this on every feed
    /// tick.
    func nearestAirport(to coordinate: CLLocationCoordinate2D, withinNM maxNM: Double = 6) -> Airport? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }

        loadIfNeeded()

        let key = String(
            format: "%.3f|%.3f|%.0f",
            coordinate.latitude, coordinate.longitude, maxNM
        )

        lock.lock()
        if let cached = nearestCache[key] {
            lock.unlock()
            return cached
        }
        let candidates = airports
        lock.unlock()

        // Cheap bounding box first: haversine over 17k airports on every tick
        // is wasteful, and everything outside the box is out of range anyway.
        let latitudeSpan = maxNM / 60.0
        let cosine = max(cos(coordinate.latitude * .pi / 180), 0.01)
        let longitudeSpan = latitudeSpan / cosine

        var best: Airport?
        var bestDistance = maxNM

        for airport in candidates.values {
            guard abs(airport.coordinate.latitude - coordinate.latitude) <= latitudeSpan,
                  abs(airport.coordinate.longitude - coordinate.longitude) <= longitudeSpan else { continue }

            let distance = FlightProgress.distanceNM(from: coordinate, to: airport.coordinate)
            if distance <= bestDistance {
                bestDistance = distance
                best = airport
            }
        }

        lock.lock()
        // A taxiing aircraft would otherwise grow this without bound.
        if nearestCache.count > 400 { nearestCache.removeAll(keepingCapacity: true) }
        nearestCache[key] = best
        lock.unlock()

        return best
    }

    /// The closest airports to a position, nearest first. Used where one field
    /// isn't enough — a weather chip has to fall through to the next station
    /// when the closest strip has never filed a report.
    func nearestAirports(
        to coordinate: CLLocationCoordinate2D,
        withinNM maxNM: Double,
        limit: Int
    ) -> [Airport] {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite, limit > 0 else { return [] }

        loadIfNeeded()

        lock.lock()
        let candidates = airports
        lock.unlock()

        let latitudeSpan = maxNM / 60.0
        let cosine = max(cos(coordinate.latitude * .pi / 180), 0.01)
        let longitudeSpan = latitudeSpan / cosine

        var scored: [(Airport, Double)] = []

        for airport in candidates.values {
            guard abs(airport.coordinate.latitude - coordinate.latitude) <= latitudeSpan,
                  abs(airport.coordinate.longitude - coordinate.longitude) <= longitudeSpan else { continue }

            let distance = FlightProgress.distanceNM(from: coordinate, to: airport.coordinate)
            guard distance <= maxNM else { continue }
            scored.append((airport, distance))
        }

        return scored
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Airports matching what has been typed so far, best first.
    ///
    /// Ranked rather than merely filtered: an exact ICAO is what someone
    /// typing four letters means, and a code that starts with those letters is
    /// a better guess than an airport with them buried in its name. Within a
    /// rank it is alphabetical by ICAO, so the list doesn't reshuffle as the
    /// dictionary's own order changes underneath it.
    func search(_ query: String, limit: Int = 6) -> [Airport] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard needle.count >= 2, limit > 0 else { return [] }

        loadIfNeeded()

        lock.lock()
        let candidates = airports
        lock.unlock()

        var scored: [(Airport, Int)] = []

        for airport in candidates.values {
            let rank: Int
            if airport.icao == needle {
                rank = 0
            } else if airport.icao.hasPrefix(needle) {
                rank = 1
            } else if airport.searchableName.hasPrefix(needle) {
                rank = 2
            } else if airport.searchableName.contains(needle) {
                rank = 3
            } else {
                continue
            }

            scored.append((airport, rank))
        }

        return scored
            .sorted { first, second in
                first.1 == second.1 ? first.0.icao < second.0.icao : first.1 < second.1
            }
            .prefix(limit)
            .map { $0.0 }
    }

    /// Every airport's position, thinned to a cap and sorted for a stable
    /// drawing order.
    ///
    /// For the globe on the welcome screen, which draws the world as the
    /// dataset rather than as imagery: no tiles, no network, nothing to fail on
    /// a first launch before anything has been agreed to. Thinned because
    /// eighteen thousand points is more than a sphere at that size can show and
    /// far more than sixty frames a second wants to transform.
    func sample(limit: Int = 3000) -> [CLLocationCoordinate2D] {
        loadIfNeeded()

        lock.lock()
        let all = Array(airports.values)
        lock.unlock()

        guard all.count > limit else {
            return all.map(\.coordinate)
        }

        // Every nth, by a sorted key, so the thinning is deterministic and
        // spread over the whole dataset rather than clustered wherever the
        // dictionary happened to put things.
        let ordered = all.sorted { $0.icao < $1.icao }
        let stride = max(ordered.count / limit, 1)
        return Swift.stride(from: 0, to: ordered.count, by: stride).map { ordered[$0].coordinate }
    }

    func airport(_ icao: String?) -> Airport? {
        guard let icao = icao?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !icao.isEmpty else { return nil }

        loadIfNeeded()

        lock.lock()
        defer { lock.unlock() }
        return airports[icao]
    }

    private func loadIfNeeded() {
        lock.lock()
        if isLoaded {
            lock.unlock()
            return
        }
        lock.unlock()

        var parsed: [String: Airport] = [:]

        if let url = Bundle.main.url(forResource: "airports", withExtension: "txt"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {

            parsed.reserveCapacity(18_000)

            // Each line is ICAO|Name|Latitude|Longitude|ISO-3166-1 alpha-2
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count >= 4,
                      let latitude = Double(fields[2]),
                      let longitude = Double(fields[3]) else { continue }

                let icao = String(fields[0])
                parsed[icao] = Airport(
                    icao: icao,
                    name: String(fields[1]),
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    countryCode: fields.count >= 5 ? String(fields[4]) : ""
                )
            }
        }

        lock.lock()
        airports = parsed
        isLoaded = true
        lock.unlock()
    }
}
