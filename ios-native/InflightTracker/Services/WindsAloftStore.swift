import CoreLocation
import Foundation
import MapKit

/// Model wind at a chosen flight level, on a grid across whatever the map is
/// looking at.
///
/// Shaped like `AirportLayoutStore`: the map asks synchronously while it lays
/// out, gets whatever is already known, and a fetch runs for the rest. It is an
/// `ObservableObject` for the same reason that one is — a grid that lands after
/// the map has settled has to be drawn when it arrives rather than waiting for
/// the next pan.
///
/// ## Why the region is snapped
///
/// A map moves continuously and a forecast does not. Asking for the wind at
/// exactly wherever the camera stopped would mean a fresh request for every
/// pixel of pan, for numbers that are identical. So the grid is quantised: the
/// visible region is rounded out to a lattice whose step is a whole number of
/// degrees, and every camera position inside one lattice cell asks the same
/// question and gets the cached answer.
final class WindsAloftStore: ObservableObject {

    static let shared = WindsAloftStore()

    /// One point on the grid.
    struct Barb: Equatable, Identifiable {
        let coordinate: CLLocationCoordinate2D
        /// Where the wind is coming *from*, in degrees true.
        let directionDegrees: Double
        let speedKnots: Double

        var id: String {
            "\(Int(coordinate.latitude * 100))|\(Int(coordinate.longitude * 100))"
        }

        static func == (lhs: Barb, rhs: Barb) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.directionDegrees == rhs.directionDegrees
                && lhs.speedKnots == rhs.speedKnots
        }
    }

    /// Whatever the map should currently be drawing. Replaced wholesale when a
    /// new grid lands, so there is never half of one grid and half of another.
    @Published private(set) var barbs: [Barb] = []

    /// The grid on screen, so the map can tell whether the barbs it is holding
    /// are the ones for where it is now.
    @Published private(set) var key: String?

    /// Roughly how many points across and down. Twenty barbs is a chart; a
    /// hundred is a texture, and it is also a hundred columns of model data
    /// asked for in one URL.
    private static let columns = 5
    private static let rows = 4

    /// Outside this the barbs are meaningless — too far out and five points
    /// span a hemisphere, too far in and all five carry the same number.
    private static let minimumSpanDegrees: Double = 0.4
    private static let maximumSpanDegrees: Double = 45

    /// The model publishes hourly. Half of that keeps the arrows honest
    /// without asking for a forecast that has not been re-run.
    private static let lifetime: TimeInterval = 30 * 60

    private struct Entry {
        let barbs: [Barb]
        let fetched: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var inFlight = Set<String>()

    /// Bounded: a session that pans across a continent at six zoom levels
    /// would otherwise keep every grid it ever asked for.
    private static let capacity = 40

    private init() {}

    /// Point the store at what the map is showing. Cheap and idempotent — it
    /// resolves to a lattice key and does nothing when that key is already
    /// drawn and fresh.
    func load(region: MKCoordinateRegion, level: WindLevel) {
        guard let grid = Self.grid(for: region) else {
            // Zoomed somewhere the grid cannot say anything useful about.
            publish(key: nil, barbs: [])
            return
        }

        let wanted = "\(level.rawValue)|\(grid.key)"

        lock.lock()
        let entry = cache[wanted]
        let fresh = entry.map { Date().timeIntervalSince($0.fetched) < Self.lifetime } ?? false
        lock.unlock()

        if fresh, let entry = entry {
            publish(key: wanted, barbs: entry.barbs)
            return
        }

        fetch(grid: grid, level: level, key: wanted)
    }

    /// Drop what is drawn. For the switch going off — barbs for a level nobody
    /// is looking at are barbs the map should not be holding.
    func clear() {
        publish(key: nil, barbs: [])
    }

    /// Announce a new grid, never synchronously.
    ///
    /// `load` is called from inside the map's layout pass, and the map observes
    /// this object — so assigning a `@Published` there would be mutating state
    /// in the middle of a SwiftUI update, which is at best a purple warning and
    /// at worst a render that re-enters itself. Hopping a runloop turn costs
    /// one frame and makes the whole thing ordinary: the assignment lands, the
    /// map is asked to update, and it reads the new grid on the next pass.
    ///
    /// The comparison happens twice on purpose — once to avoid scheduling work
    /// that would change nothing, and again on arrival, because several passes
    /// can be queued before the first one runs.
    private func publish(key newKey: String?, barbs newBarbs: [Barb]) {
        guard key != newKey || barbs != newBarbs else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard self.key != newKey || self.barbs != newBarbs else { return }
            self.key = newKey
            self.barbs = newBarbs
        }
    }

    // MARK: - The lattice

    private struct Grid {
        let coordinates: [CLLocationCoordinate2D]
        let key: String
    }

    /// The points to ask about, and the identity of that question.
    private static func grid(for region: MKCoordinateRegion) -> Grid? {
        let span = region.span
        guard span.latitudeDelta.isFinite, span.longitudeDelta.isFinite else { return nil }
        guard span.latitudeDelta >= minimumSpanDegrees,
              span.latitudeDelta <= maximumSpanDegrees else { return nil }

        // A step of a whole number of degrees where the span allows one, and a
        // clean fraction below that — so the lattice lands on the same numbers
        // whichever direction the map arrived from.
        let step = niceStep(span.latitudeDelta / Double(rows))
        guard step > 0 else { return nil }

        let centreLat = (region.center.latitude / step).rounded() * step
        let centreLon = (region.center.longitude / step).rounded() * step

        var coordinates: [CLLocationCoordinate2D] = []
        for row in 0..<rows {
            let latitude = centreLat + (Double(row) - Double(rows - 1) / 2) * step
            guard abs(latitude) <= 85 else { continue }

            for column in 0..<columns {
                // Longitude degrees are shorter than latitude ones away from
                // the equator, so the lattice is stretched to keep the barbs
                // roughly evenly spaced on screen rather than on the globe.
                let stretch = max(cos(latitude * .pi / 180), 0.2)
                var longitude = centreLon
                    + (Double(column) - Double(columns - 1) / 2) * step / stretch
                while longitude > 180 { longitude -= 360 }
                while longitude < -180 { longitude += 360 }

                coordinates.append(
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )
            }
        }

        guard !coordinates.isEmpty else { return nil }

        return Grid(
            coordinates: coordinates,
            key: String(format: "%.3f|%.3f|%.3f", step, centreLat, centreLon)
        )
    }

    /// The nearest of 0.25, 0.5, 1, 2, 5, 10 degrees. A tidy ladder, so
    /// zooming settles on one of six lattices rather than a new one each time.
    private static func niceStep(_ raw: Double) -> Double {
        let ladder: [Double] = [0.25, 0.5, 1, 2, 5, 10]
        return ladder.first { raw <= $0 } ?? ladder[ladder.count - 1]
    }

    // MARK: - Fetching

    private func fetch(grid: Grid, level: WindLevel, key wanted: String) {
        lock.lock()
        let running = inFlight.contains(wanted)
        if !running { inFlight.insert(wanted) }
        lock.unlock()

        guard !running, let url = Self.url(for: grid, level: level) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            let parsed = Self.parse(data, coordinates: grid.coordinates)

            self.lock.lock()
            self.inFlight.remove(wanted)
            // Stored even when empty: a level the model has no data for at
            // these points is an answer, and re-asking every pan is what this
            // cache exists to stop.
            self.cache[wanted] = Entry(barbs: parsed, fetched: Date())
            if self.cache.count > Self.capacity {
                let oldest = self.cache.min { $0.value.fetched < $1.value.fetched }
                if let stale = oldest?.key { self.cache.removeValue(forKey: stale) }
            }
            self.lock.unlock()

            self.publish(key: wanted, barbs: parsed)
        }.resume()
    }

    /// Open-Meteo takes a list of coordinates in one request and answers with
    /// one result per coordinate, in order — which is the whole reason a grid
    /// is affordable at all.
    private static func url(for grid: Grid, level: WindLevel) -> URL? {
        let latitudes = grid.coordinates.map { String(format: "%.4f", $0.latitude) }
        let longitudes = grid.coordinates.map { String(format: "%.4f", $0.longitude) }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: latitudes.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: longitudes.joined(separator: ",")),
            URLQueryItem(
                name: "hourly",
                value: "wind_speed_\(level.pressureLevel),wind_direction_\(level.pressureLevel)"
            ),
            // Knots, so nothing has to be converted on the way to a barb —
            // which is drawn in knots by definition.
            URLQueryItem(name: "wind_speed_unit", value: "kn"),
            // Integers rather than local ISO strings, so picking the hour
            // nearest now is arithmetic instead of date parsing.
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        return components?.url
    }

    /// One result per coordinate, each carrying an hourly series. The hour
    /// nearest now is the one drawn.
    private static func parse(_ data: Data?, coordinates: [CLLocationCoordinate2D]) -> [Barb] {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        // A single coordinate comes back as an object, several as an array.
        // The grid always asks for several, but reading both costs one line
        // and saves a silent empty layer if that ever changes.
        let results: [[String: Any]]
        if let array = root as? [[String: Any]] {
            results = array
        } else if let single = root as? [String: Any] {
            results = [single]
        } else {
            return []
        }

        let now = Date().timeIntervalSince1970
        var out: [Barb] = []

        for (index, result) in results.enumerated() {
            guard index < coordinates.count,
                  let hourly = result["hourly"] as? [String: Any],
                  let times = hourly["time"] as? [Double] else { continue }

            // The response names its series by pressure level, and there is
            // exactly one speed series and one direction series in it.
            let speeds = hourly.first { $0.key.hasPrefix("wind_speed_") }?.value as? [Any]
            let directions = hourly.first { $0.key.hasPrefix("wind_direction_") }?.value as? [Any]
            guard let speeds = speeds, let directions = directions else { continue }

            guard let hour = times.indices.min(by: {
                abs(times[$0] - now) < abs(times[$1] - now)
            }) else { continue }
            guard hour < speeds.count, hour < directions.count else { continue }

            guard let speed = (speeds[hour] as? NSNumber)?.doubleValue,
                  let direction = (directions[hour] as? NSNumber)?.doubleValue,
                  speed.isFinite, direction.isFinite else { continue }

            // The model reports the coordinate it actually resolved to, which
            // can be a fraction off the one asked for. Its answer wins.
            let latitude = (result["latitude"] as? NSNumber)?.doubleValue
                ?? coordinates[index].latitude
            let longitude = (result["longitude"] as? NSNumber)?.doubleValue
                ?? coordinates[index].longitude
            guard abs(latitude) <= 90, abs(longitude) <= 180 else { continue }

            out.append(
                Barb(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    directionDegrees: direction,
                    speedKnots: speed
                )
            )
        }

        return out
    }
}
