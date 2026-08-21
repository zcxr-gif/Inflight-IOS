import Combine
import CoreLocation
import Foundation

/// METARs, from the same source the Capacitor build used
/// (`old/www/weather.js`): VATSIM's plain-text service.
///
/// Reports are cached for as long as they stay current — stations issue one an
/// hour — so panning the map around a busy area doesn't re-fetch the same
/// field over and over.
final class WeatherService {

    static let shared = WeatherService()

    private struct Entry {
        let metar: Metar?
        let fetched: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var inFlight = Set<String>()

    /// Long enough to stop repeat fetches, short enough that a report never
    /// goes properly stale.
    private let lifetime: TimeInterval = 600

    private init() {}

    /// Fetches reports for the fields the map is marking, so each can be drawn
    /// in its own flight category.
    ///
    /// Bounded by what the map marks — every field being worked plus the
    /// busiest few dozen — and every one of them is cached and de-duplicated
    /// below, so a steady map does no work at all. Called on the same tick as
    /// the markers themselves.
    func prefetch(_ icaos: [String]) {
        for icao in icaos {
            metar(for: icao) { _ in }
        }
    }

    func cached(_ icao: String) -> Metar? {
        lock.lock()
        defer { lock.unlock() }
        return cache[icao.uppercased()]?.metar
    }

    /// Completion runs on the main queue, and only when there is something new
    /// to show.
    func metar(for icao: String, completion: @escaping (Metar?) -> Void) {
        let code = icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 4 else { return }

        lock.lock()
        if let entry = cache[code], Date().timeIntervalSince(entry.fetched) < lifetime {
            let metar = entry.metar
            lock.unlock()
            DispatchQueue.main.async { completion(metar) }
            return
        }
        let alreadyRunning = inFlight.contains(code)
        if !alreadyRunning { inFlight.insert(code) }
        lock.unlock()

        guard !alreadyRunning,
              let url = URL(string: "https://metar.vatsim.net/metar.php?id=\(code)") else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }

            let metar = data
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { Metar.parse($0) }

            self.lock.lock()
            self.cache[code] = Entry(metar: metar, fetched: Date())
            self.inFlight.remove(code)
            self.lock.unlock()

            DispatchQueue.main.async { completion(metar) }
        }.resume()
    }
}

/// What the weather chip is showing: the field the map is over, and the two
/// ends of the open flight's route.
final class WeatherModel: ObservableObject {

    struct Station: Identifiable, Equatable {
        let role: Role
        let airport: Airport
        let metar: Metar?

        var id: String { "\(role.rawValue)|\(airport.icao)" }

        var isDaylight: Bool { SolarPosition.isDaylight(at: airport.coordinate) }
    }

    enum Role: String {
        case nearby
        case departure
        case arrival

        var label: String {
            switch self {
            case .nearby: return "PASSING"
            case .departure: return "DEPARTURE"
            case .arrival: return "ARRIVAL"
            }
        }
    }

    @Published private(set) var nearby: Station?
    @Published private(set) var departure: Station?
    @Published private(set) var arrival: Station?

    /// Reports arrive one at a time; this is what the views re-read.
    @Published private(set) var updatedAt = Date()

    private var lastNearbyLookup: CLLocationCoordinate2D?

    /// The field the open aircraft is passing. Small airfields rarely file a
    /// report, so a few of the closest are tried before giving up.
    ///
    /// `force` is for a change of aircraft: without it, opening a second plane
    /// a few miles from the first would keep showing the first one's field.
    func updateNearby(to coordinate: CLLocationCoordinate2D, force: Bool = false) {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return }

        if !force, let last = lastNearbyLookup,
           FlightProgress.distanceNM(from: last, to: coordinate) < 12 {
            return
        }
        lastNearbyLookup = coordinate

        let candidates = AirportStore.shared.nearestAirports(to: coordinate, withinNM: 260, limit: 4)
        guard let closest = candidates.first else { return }

        // Show the nearest field straight away, then upgrade to whichever of
        // the candidates actually has a report.
        nearby = Station(role: .nearby, airport: closest, metar: WeatherService.shared.cached(closest.icao))

        for airport in candidates {
            WeatherService.shared.metar(for: airport.icao) { [weak self] metar in
                guard let self = self, let metar = metar else { return }
                guard self.nearby?.metar == nil || self.nearby?.airport.icao == airport.icao else { return }
                self.nearby = Station(role: .nearby, airport: airport, metar: metar)
                self.updatedAt = Date()
            }
        }
    }

    /// The open flight's endpoints, or nothing when no flight is open.
    func updateRoute(departure departureIcao: String?, arrival arrivalIcao: String?) {
        departure = station(role: .departure, icao: departureIcao)
        arrival = station(role: .arrival, icao: arrivalIcao)

        load(role: .departure, icao: departureIcao)
        load(role: .arrival, icao: arrivalIcao)
    }

    private func station(role: Role, icao: String?) -> Station? {
        guard let airport = AirportStore.shared.airport(icao) else { return nil }
        return Station(role: role, airport: airport, metar: WeatherService.shared.cached(airport.icao))
    }

    private func load(role: Role, icao: String?) {
        guard let airport = AirportStore.shared.airport(icao) else { return }

        WeatherService.shared.metar(for: airport.icao) { [weak self] metar in
            guard let self = self else { return }
            let resolved = Station(role: role, airport: airport, metar: metar)

            switch role {
            case .departure: self.departure = resolved
            case .arrival: self.arrival = resolved
            case .nearby: self.nearby = resolved
            }

            self.updatedAt = Date()
        }
    }
}
