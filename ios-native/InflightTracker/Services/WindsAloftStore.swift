import CoreLocation
import Foundation
import MapKit

/// Model weather at a chosen flight level, on a grid across whatever the map is
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
///
/// ## Why one store serves three layers
///
/// The barbs, the particles and the coloured field all want the same thing —
/// what the air is doing over the piece of world on screen — and Open-Meteo
/// answers for a list of coordinates and a list of variables in a single call.
/// So there is one request, and everything on the weather layer is drawn from
/// its answer. That is a third of the network it would otherwise be, and it is
/// also the only way to guarantee the layers agree: an arrow pointing one way
/// with a particle drifting the other beside it is the map arguing with itself,
/// and it cannot happen if there is only one set of numbers.
final class WindsAloftStore: ObservableObject {

    static let shared = WindsAloftStore()

    /// One point on the grid, as the barbs want it.
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

    /// What a caller wants drawn, which is what decides how much is asked for.
    ///
    /// Barbs alone keep the request exactly as small as it always was — twenty
    /// points, two variables. Everything else is opt-in, and nobody who has not
    /// turned a field on pays for one.
    struct Demand: Equatable {
        var level: WindLevel = .fl340
        /// Whether anything needs to interpolate between the samples, which is
        /// what the dense lattice is for.
        var needsField = false
        var needsTemperature = false
        var needsShear = false

        /// The identity of the *question*. Two demands with the same key have
        /// the same answer, so they share a cache entry.
        var key: String {
            [
                level.rawValue,
                needsField ? "f" : "b",
                needsTemperature ? "t" : "-",
                needsShear ? "s" : "-"
            ].joined()
        }
    }

    /// Whatever the map should currently be drawing. Replaced wholesale when a
    /// new grid lands, so there is never half of one grid and half of another.
    @Published private(set) var barbs: [Barb] = []

    /// The same numbers as something that can be asked about the places between
    /// them. Nil until a demand asks for one.
    @Published private(set) var field: WeatherField?

    /// The grid on screen, so the map can tell whether what it is holding is
    /// for where it is now.
    @Published private(set) var key: String?

    /// How many points across and down, for each of the two densities.
    ///
    /// Twenty barbs is a chart; seventy points is a field. The sparse one is
    /// what the arrows have always used and is left exactly as it was, because
    /// every point is a location on somebody's daily quota — the dense one is
    /// only ever fetched for a layer that genuinely cannot be drawn without it.
    private static let sparse = (columns: 5, rows: 4)
    private static let dense = (columns: 10, rows: 7)

    /// Which of the field's points get an arrow, so a dense grid does not draw
    /// seventy barbs on top of each other.
    private static let barbStride = 2

    /// The span of map the grid is drawn over, in degrees of latitude.
    ///
    /// Both ends used to be much tighter, on the reasoning that five points
    /// across a hemisphere say nothing and five points across an airfield all
    /// say the same thing. The first half of that is wrong in the one case
    /// people most want it: the whole question over an ocean is which way the
    /// jet is running, and twenty arrows across the North Atlantic answer it
    /// exactly the way a chart does. The second half is true but harmless — the
    /// wind at the field is still the wind at the field.
    ///
    /// Both are clamps rather than cut-offs — see `grid(for:size:holding:)`.
    /// Zooming past either end stops the lattice getting any finer or any
    /// coarser; it does not take the layer off the map.
    private static let minimumSpanDegrees: Double = 0.15
    private static let maximumSpanDegrees: Double = 120

    /// The model publishes hourly. Half of that keeps the arrows honest
    /// without asking for a forecast that has not been re-run.
    private static let lifetime: TimeInterval = 30 * 60

    private struct Entry {
        let barbs: [Barb]
        let field: WeatherField?
        let fetched: Date
    }

    private let lock = NSLock()
    private var cache: [String: Entry] = [:]
    private var inFlight = Set<String>()

    /// The lattice step currently in use, which is what makes the ladder
    /// sticky. Read and written only from `load`, which the map calls from its
    /// own layout pass on the main thread.
    private var heldStep: Double?

    /// Bounded: a session that pans across a continent at six zoom levels
    /// would otherwise keep every grid it ever asked for.
    private static let capacity = 40

    private init() {}

    /// Point the store at what the map is showing. Cheap and idempotent — it
    /// resolves to a lattice key and does nothing when that key is already
    /// drawn and fresh.
    func load(region: MKCoordinateRegion, demand: Demand) {
        let size = demand.needsField ? Self.dense : Self.sparse
        guard let grid = Self.grid(for: region, size: size, holding: heldStep) else {
            // A region with no finite span at all — a map that has not laid
            // out yet. Nothing is published: what is drawn stays drawn until
            // there is a real region to answer for.
            return
        }
        heldStep = grid.latitudeStep

        let wanted = "\(demand.key)|\(grid.key)"

        lock.lock()
        let entry = cache[wanted]
        let fresh = entry.map { Date().timeIntervalSince($0.fetched) < Self.lifetime } ?? false
        lock.unlock()

        if fresh, let entry = entry {
            publish(key: wanted, barbs: entry.barbs, field: entry.field)
            return
        }

        fetch(grid: grid, demand: demand, key: wanted)
    }

    /// Drop what is drawn. For the switch going off — a grid for a layer nobody
    /// is looking at is a grid the map should not be holding.
    func clear() {
        heldStep = nil
        publish(key: nil, barbs: [], field: nil)
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
    /// Keyed on the key alone now that a field rides along with the barbs. The
    /// key already names the region, the level and everything asked for, so two
    /// publishes that share one are the same answer by construction — and
    /// comparing a whole interpolable field for equality on every layout pass
    /// would be a great deal of work to discover that.
    private func publish(key newKey: String?, barbs newBarbs: [Barb], field newField: WeatherField?) {
        guard key != newKey else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.key != newKey else { return }
            self.key = newKey
            self.barbs = newBarbs
            self.field = newField
        }
    }

    // MARK: - The lattice

    private struct Grid {
        let coordinates: [CLLocationCoordinate2D]
        let columns: Int
        let rows: Int
        /// The lattice's own origin and spacing, which is what a field is.
        let south: CLLocationDegrees
        let west: CLLocationDegrees
        let latitudeStep: CLLocationDegrees
        let longitudeStep: CLLocationDegrees
        let key: String
    }

    /// The points to ask about, and the identity of that question.
    ///
    /// A genuinely rectangular lattice, which it did not used to be: the
    /// longitude step used to be stretched by the cosine of each *row's* own
    /// latitude, so no two rows lined up and the result was a scatter of points
    /// rather than a grid. That was fine while the only consumer drew one arrow
    /// per point and never asked about the gaps. It is not fine for anything
    /// that interpolates, so the stretch is now taken once at the centre and
    /// applied to the whole grid — square enough on screen over any region
    /// small enough to be worth drawing, and an actual lattice.
    private static func grid(
        for region: MKCoordinateRegion,
        size: (columns: Int, rows: Int),
        holding held: Double?
    ) -> Grid? {
        let span = region.span
        guard span.latitudeDelta.isFinite, span.longitudeDelta.isFinite else { return nil }

        // Clamped rather than refused.
        //
        // Both ends used to hand back nil, and nil cleared the key — which took
        // the arrows, the coloured wash and every particle off the map at once.
        // So a pinch that went one notch past the bottom of the range made the
        // whole wind layer vanish, and backing off brought it back with a fresh
        // fetch and a full reseed. That is the loading and unloading, and there
        // was never a reason for it: the wind over a field is still the wind
        // over that field when you zoom into it. Past either end the lattice
        // simply stops getting any finer or any coarser.
        let latitudeSpan = min(
            max(span.latitudeDelta, minimumSpanDegrees),
            maximumSpanDegrees
        )

        // A step of a whole number of degrees where the span allows one, and a
        // clean fraction below that — so the lattice lands on the same numbers
        // whichever direction the map arrived from.
        let step = niceStep(latitudeSpan / Double(size.rows), holding: held)
        guard step > 0 else { return nil }

        let centreLat = (region.center.latitude / step).rounded() * step
        let centreLon = (region.center.longitude / step).rounded() * step

        let stretch = max(cos(centreLat * .pi / 180), 0.2)
        let longitudeStep = step / stretch

        let south = centreLat - Double(size.rows - 1) / 2 * step
        let west = centreLon - Double(size.columns - 1) / 2 * longitudeStep

        // Off the top or the bottom of the world is a grid whose rows are not
        // where it says they are. Slid back rather than clipped, so the field
        // stays a rectangle.
        let north = south + Double(size.rows - 1) * step
        let slide: Double
        if north > 85 { slide = 85 - north }
        else if south < -85 { slide = -85 - south }
        else { slide = 0 }

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(size.columns * size.rows)
        for row in 0..<size.rows {
            let latitude = south + slide + Double(row) * step
            for column in 0..<size.columns {
                coordinates.append(
                    CLLocationCoordinate2D(
                        latitude: latitude,
                        longitude: WeatherField.wrapped(west + Double(column) * longitudeStep)
                    )
                )
            }
        }

        guard !coordinates.isEmpty else { return nil }

        return Grid(
            coordinates: coordinates,
            columns: size.columns,
            rows: size.rows,
            south: south + slide,
            west: west,
            latitudeStep: step,
            longitudeStep: longitudeStep,
            key: String(
                format: "%dx%d|%.3f|%.3f|%.3f",
                size.columns, size.rows, step, centreLat + slide, centreLon
            )
        )
    }

    /// How far past a rung's own boundary the zoom has to go before the next
    /// rung is taken.
    ///
    /// A ladder alone still changes rung the instant the arithmetic crosses a
    /// boundary, and a new rung is a new lattice: a new key, a new request, a
    /// raster thrown away and rebuilt, and every particle reseeded. A pinch
    /// that settles near a boundary crosses it repeatedly, so the layer spent
    /// the zoom restarting itself. A quarter is enough that the rung only
    /// changes on a zoom somebody meant.
    private static let stepHysteresis: Double = 1.25

    /// The rungs themselves. The top reaches as far as `maximumSpanDegrees`
    /// does: without a rung above ten, every view wider than a country rounded
    /// to the same ten-degree lattice and asked for a grid far denser than the
    /// map could show.
    private static let ladder: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 20, 30]

    /// The nearest rung of a tidy ladder, so zooming settles on one of a
    /// handful of lattices rather than minting a new one at every scale.
    ///
    /// `held` is the rung already in use, and it is kept while the view is
    /// anywhere near still being its own — see `stepHysteresis`.
    private static func niceStep(_ raw: Double, holding held: Double? = nil) -> Double {
        let wanted = ladder.first { raw <= $0 } ?? ladder[ladder.count - 1]

        guard let held = held,
              held != wanted,
              let rung = ladder.firstIndex(of: held) else { return wanted }

        // The band the held rung covers on its own, widened at both ends.
        let ceiling = held * stepHysteresis
        let floor = rung == 0 ? 0 : ladder[rung - 1] / stepHysteresis
        return raw > floor && raw <= ceiling ? held : wanted
    }

    // MARK: - Fetching

    private func fetch(grid: Grid, demand: Demand, key wanted: String) {
        lock.lock()
        let running = inFlight.contains(wanted)
        if !running { inFlight.insert(wanted) }
        lock.unlock()

        guard !running, let url = Self.url(for: grid, demand: demand) else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            let field = Self.parse(data, grid: grid, demand: demand)
            let barbs = field?.barbs(stride: demand.needsField ? Self.barbStride : 1) ?? []

            self.lock.lock()
            self.inFlight.remove(wanted)
            // Stored even when empty: a level the model has no data for at
            // these points is an answer, and re-asking every pan is what this
            // cache exists to stop.
            self.cache[wanted] = Entry(barbs: barbs, field: field, fetched: Date())
            if self.cache.count > Self.capacity {
                let oldest = self.cache.min { $0.value.fetched < $1.value.fetched }
                if let stale = oldest?.key { self.cache.removeValue(forKey: stale) }
            }
            self.lock.unlock()

            self.publish(key: wanted, barbs: barbs, field: field)
        }.resume()
    }

    /// The series this demand needs, named exactly.
    ///
    /// Exactly, and not by prefix, because the shear layer asks for two levels
    /// at once and `wind_speed_250hPa` and `wind_speed_300hPa` both start with
    /// `wind_speed_`. Reading whichever one the dictionary happened to hand
    /// back first is a shear field computed against itself.
    private static func series(for demand: Demand) -> [String] {
        var names = [
            "wind_speed_\(demand.level.pressureLevel)",
            "wind_direction_\(demand.level.pressureLevel)"
        ]
        if demand.needsTemperature {
            names.append("temperature_\(demand.level.pressureLevel)")
        }
        if demand.needsShear {
            names.append("wind_speed_\(demand.level.below.pressureLevel)")
            names.append("wind_direction_\(demand.level.below.pressureLevel)")
        }
        return names
    }

    /// Open-Meteo takes a list of coordinates in one request and answers with
    /// one result per coordinate, in order — which is the whole reason a grid
    /// is affordable at all. It takes a list of variables the same way, which
    /// is why three layers cost one call rather than three.
    private static func url(for grid: Grid, demand: Demand) -> URL? {
        let latitudes = grid.coordinates.map { String(format: "%.4f", $0.latitude) }
        let longitudes = grid.coordinates.map { String(format: "%.4f", $0.longitude) }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: latitudes.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: longitudes.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: series(for: demand).joined(separator: ",")),
            // Metres per second, because the field holds components and
            // everything physical downstream — how far a particle moves in a
            // second — is metric. Knots are put back on at the one place they
            // are read, which is the barb.
            URLQueryItem(name: "wind_speed_unit", value: "ms"),
            // Integers rather than local ISO strings, so picking the hour
            // nearest now is arithmetic instead of date parsing.
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        return components?.url
    }

    /// One result per coordinate, each carrying an hourly series. The hour
    /// nearest now is the one drawn.
    ///
    /// The results come back in the order they were asked for, which is what
    /// makes the answer a grid rather than a scatter — position `i` in the
    /// response is position `i` in the lattice, and a result that fails to
    /// parse leaves a hole rather than shifting everything after it.
    private static func parse(_ data: Data?, grid: Grid, demand: Demand) -> WeatherField? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) else { return nil }

        // A single coordinate comes back as an object, several as an array.
        // The grid always asks for several, but reading both costs one line
        // and saves a silent empty layer if that ever changes.
        let results: [[String: Any]]
        if let array = root as? [[String: Any]] {
            results = array
        } else if let single = root as? [String: Any] {
            results = [single]
        } else {
            return nil
        }

        let points = grid.columns * grid.rows
        guard results.count >= points else { return nil }

        var u = [Double](repeating: 0, count: points)
        var v = [Double](repeating: 0, count: points)
        var temperature = [Double](repeating: 0, count: points)
        var shear = [Double](repeating: 0, count: points)
        var filled = 0

        let now = Date().timeIntervalSince1970
        let level = demand.level
        let lower = level.below
        // The vertical gap the shear is divided by, in thousands of feet.
        let gap = max(Double(level.approximateFeet - lower.feet) / 1_000, 0.5)

        for index in 0..<points {
            let result = results[index]
            guard let hourly = result["hourly"] as? [String: Any],
                  let times = hourly["time"] as? [Double] else { continue }

            guard let hour = times.indices.min(by: {
                abs(times[$0] - now) < abs(times[$1] - now)
            }) else { continue }

            func read(_ name: String) -> Double? {
                guard let series = hourly[name] as? [Any], hour < series.count,
                      let value = (series[hour] as? NSNumber)?.doubleValue,
                      value.isFinite else { return nil }
                return value
            }

            guard let speed = read("wind_speed_\(level.pressureLevel)"),
                  let direction = read("wind_direction_\(level.pressureLevel)")
            else { continue }

            let components = Self.components(speed: speed, from: direction)
            u[index] = components.u
            v[index] = components.v
            filled += 1

            if demand.needsTemperature {
                temperature[index] = read("temperature_\(level.pressureLevel)") ?? 0
            }

            if demand.needsShear,
               let lowerSpeed = read("wind_speed_\(lower.pressureLevel)"),
               let lowerDirection = read("wind_direction_\(lower.pressureLevel)") {
                let below = Self.components(speed: lowerSpeed, from: lowerDirection)
                // The *vector* difference, which is the whole point: a wind
                // that keeps its speed and swings ninety degrees between two
                // levels has enormous shear, and a scalar subtraction of two
                // speeds would call it nothing at all.
                let du = components.u - below.u
                let dv = components.v - below.v
                shear[index] = (du * du + dv * dv).squareRoot()
                    * WeatherField.knotsPerMetrePerSecond / gap
            }
        }

        // A grid where most points failed is a level the model does not carry
        // here, and drawing the handful that did is worse than drawing nothing:
        // the interpolation would spread a few real numbers across a rectangle
        // of zeroes and present the result as a field.
        guard filled >= points * 3 / 4 else { return nil }

        var scalars: [WeatherHeat: [Double]] = [:]
        if demand.needsTemperature { scalars[.temperature] = temperature }
        if demand.needsShear { scalars[.shear] = shear }

        return WeatherField(
            south: grid.south,
            west: grid.west,
            latitudeStep: grid.latitudeStep,
            longitudeStep: grid.longitudeStep,
            columns: grid.columns,
            rows: grid.rows,
            u: u,
            v: v,
            scalars: scalars
        )
    }

    /// A meteorological wind — a speed and the direction it blows *from* — as
    /// the eastward and northward components everything downstream wants.
    private static func components(speed: Double, from direction: Double) -> (u: Double, v: Double) {
        let radians = direction * .pi / 180
        return (u: -speed * sin(radians), v: -speed * cos(radians))
    }
}
