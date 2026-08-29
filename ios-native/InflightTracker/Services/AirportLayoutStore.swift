import CoreLocation
import Foundation

/// Where a field's runways, taxiways, aprons and terminals are.
///
/// Same source and the same bargain as the stands: fetched from OpenStreetMap
/// once per field, cached for a month, and never on the feed's path. A field
/// is only asked about when the map is close enough to draw it, so panning
/// across a continent costs nothing.
///
/// Reads and writes on the main thread, like the app's other stores.
final class AirportLayoutStore: ObservableObject {

    static let shared = AirportLayoutStore()

    enum State: Equatable {
        case idle
        case loading
        case ready(AirportLayout)
        case failed

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.failed, .failed): return true
            case let (.ready(left), .ready(right)):
                return left.icao == right.icao && left.pieces.count == right.pieces.count
            default: return false
            }
        }
    }

    @Published private(set) var states: [String: State] = [:]

    private static let cacheLifetime: TimeInterval = 30 * 24 * 3600

    private var inFlight: Set<String> = []

    private init() {}

    func state(for icao: String) -> State { states[icao.uppercased()] ?? .idle }

    func layout(for icao: String) -> AirportLayout? {
        if case .ready(let layout) = state(for: icao) { return layout }
        return nil
    }

    /// Safe to call whenever the map settles: a field already loaded, already
    /// loading, or already found wanting does nothing.
    func load(_ airport: Airport) {
        let icao = airport.icao.uppercased()

        switch state(for: icao) {
        case .ready, .loading, .failed: return
        case .idle: break
        }
        guard !inFlight.contains(icao) else { return }

        if let cached = readCache(icao) {
            states[icao] = .ready(cached)
            return
        }

        inFlight.insert(icao)
        states[icao] = .loading

        Task { [weak self] in
            let pieces = await Self.fetch(at: airport.coordinate)
            // Weak again on the way in rather than reaching for the outer
            // closure's `self`, which is a mutable capture crossing into
            // concurrent code — a warning today and an error under Swift 6.
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.inFlight.remove(icao)
                guard let pieces = pieces else {
                    self.states[icao] = .failed
                    return
                }
                let layout = AirportLayout(icao: icao, pieces: pieces)
                self.writeCache(layout)
                self.states[icao] = .ready(layout)
            }
        }
    }

    // MARK: - Overpass

    private static func fetch(at coordinate: CLLocationCoordinate2D) async -> [AirportLayout.Piece]? {
        // `out geom` rather than `out center`: pavement is the shape, so the
        // whole run of nodes is the point of asking.
        let around = Overpass.around(coordinate)
        let query = """
        [out:json][timeout:25];
        (
          way["aeroway"="runway"](\(around));
          way["aeroway"="taxiway"](\(around));
          way["aeroway"="apron"](\(around));
          way["aeroway"="terminal"](\(around));
          node["aeroway"="holding_position"](\(around));
          way["aeroway"="holding_position"](\(around));
        );
        out geom tags;
        """

        guard let elements = await Overpass.elements(query) else { return nil }
        return parse(elements)
    }

    /// Two passes, because one of the five kinds cannot be read on its own.
    ///
    /// Pavement is a shape and arrives as one. A holding position is a *point*
    /// on a taxiway — the node where the paint is, with no extent and no
    /// direction — and what a chart draws there is a bar across the taxiway. So
    /// the pavement is parsed first, and the hold bars are worked out against
    /// it afterwards.
    private static func parse(_ elements: [[String: Any]]) -> [AirportLayout.Piece] {
        var pieces: [AirportLayout.Piece] = []
        var holdNodes: [(coordinate: CLLocationCoordinate2D, id: String)] = []

        for element in elements {
            guard let tags = element["tags"] as? [String: Any],
                  let raw = tags["aeroway"] as? String,
                  let kind = AirportLayout.Piece.Kind(rawValue: raw) else { continue }

            let identifier = (element["id"] as? Int).map(String.init)
                ?? "\(raw)-\(pieces.count)-\(holdNodes.count)"

            // A holding position recorded as a bare node. Held back for the
            // second pass, which is the only place the taxiway under it is
            // known.
            if kind == .holdShort, element["geometry"] == nil {
                guard let latitude = element["lat"] as? Double,
                      let longitude = element["lon"] as? Double else { continue }
                holdNodes.append(
                    (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), identifier)
                )
                continue
            }

            guard let geometry = element["geometry"] as? [[String: Any]] else { continue }

            let coordinates = geometry.compactMap { node -> CLLocationCoordinate2D? in
                guard let latitude = node["lat"] as? Double,
                      let longitude = node["lon"] as? Double else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            guard coordinates.count >= 2 else { continue }

            let ref = ((tags["ref"] as? String) ?? (tags["name"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            pieces.append(
                AirportLayout.Piece(
                    kind: kind,
                    ref: (ref?.isEmpty == false) ? ref : nil,
                    coordinates: coordinates,
                    id: identifier
                )
            )
        }

        // The pavement a hold bar could be painted on. Runways as well as
        // taxiways: a few fields record the position on the runway edge rather
        // than on the taxiway leading to it.
        let pavement = pieces.filter { $0.kind == .taxiway || $0.kind == .runway }
        for node in holdNodes {
            guard let bar = holdShort(at: node.coordinate, across: pavement, id: node.id) else { continue }
            pieces.append(bar)
        }

        return pieces
    }

    /// A bar across whatever the holding position is standing on.
    ///
    /// The node says where the paint is and nothing else, so the direction has
    /// to come from the pavement. The nearest segment of the nearest way is the
    /// taxiway's centreline there; the bar is laid square across it.
    ///
    /// Returns nil when there is no pavement near enough to be the thing it is
    /// painted on — an orphaned node, or a field whose taxiways OSM does not
    /// have. A bar drawn at a guessed angle is worse than no bar.
    private static func holdShort(
        at coordinate: CLLocationCoordinate2D,
        across pavement: [AirportLayout.Piece],
        id: String
    ) -> AirportLayout.Piece? {
        var bestBearing: Double?
        var bestDistance = Double.greatestFiniteMagnitude

        for piece in pavement {
            for index in 1..<piece.coordinates.count {
                let from = piece.coordinates[index - 1]
                let to = piece.coordinates[index]
                // Measured to the segment's ends rather than to the segment
                // itself. The node is one of the way's own nodes at almost
                // every field, so it lands exactly on an end and the crude
                // measure is the exact one.
                let distance = min(metres(from, coordinate), metres(to, coordinate))
                guard distance < bestDistance else { continue }
                bestDistance = distance
                bestBearing = bearing(from, to)
            }
        }

        // Twenty-five metres: wider than a hold bar sits from its own
        // centreline node, and narrow enough that a node belonging to nothing
        // finds nothing.
        guard let along = bestBearing, bestDistance <= 25 else { return nil }

        let across = along + 90
        let half = Self.holdBarMetres / 2
        return AirportLayout.Piece(
            kind: .holdShort,
            ref: nil,
            coordinates: [
                offset(coordinate, bearing: across, metres: -half),
                offset(coordinate, bearing: across, metres: half)
            ],
            id: id
        )
    }

    /// How wide a hold bar is drawn, in metres.
    ///
    /// A code-C taxiway is twenty-three metres of pavement and a code-F one is
    /// sixty; the bar is painted right across it. Twenty-six is a taxiway of
    /// the width most of them are, and drawing every bar the same width is what
    /// a chart does — the paint is a symbol here, not a survey.
    private static let holdBarMetres: CLLocationDistance = 26

    private static func metres(
        _ from: CLLocationCoordinate2D,
        _ to: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: to.latitude, longitude: to.longitude))
    }

    private static func bearing(
        _ from: CLLocationCoordinate2D,
        _ to: CLLocationCoordinate2D
    ) -> Double {
        let fromLatitude = from.latitude * .pi / 180
        let toLatitude = to.latitude * .pi / 180
        let deltaLongitude = (to.longitude - from.longitude) * .pi / 180

        let y = sin(deltaLongitude) * cos(toLatitude)
        let x = cos(fromLatitude) * sin(toLatitude)
            - sin(fromLatitude) * cos(toLatitude) * cos(deltaLongitude)
        return atan2(y, x) * 180 / .pi
    }

    private static func offset(
        _ origin: CLLocationCoordinate2D,
        bearing degrees: Double,
        metres: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        let earthRadius = 6_371_000.0
        let angular = metres / earthRadius
        let radians = degrees * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180

        let destinationLatitude = asin(
            sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(radians)
        )
        let destinationLongitude = longitude + atan2(
            sin(radians) * sin(angular) * cos(latitude),
            cos(angular) - sin(latitude) * sin(destinationLatitude)
        )

        return CLLocationCoordinate2D(
            latitude: destinationLatitude * 180 / .pi,
            longitude: destinationLongitude * 180 / .pi
        )
    }

    // MARK: - Cache

    private var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        // Versioned, and the version is what makes a change to the *shape* of
        // this data reach anyone.
        //
        // A field is cached for a month. Add a kind to the query — hold bars,
        // here — and every field somebody has already looked at keeps serving
        // the answer from before it existed, for up to thirty days, with no
        // way to tell from the file that it is short of anything. Bumping the
        // directory retires the lot at once. The old one is left for the
        // system to reclaim with the rest of the caches.
        let directory = base.appendingPathComponent("AirportLayouts.v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cacheURL(_ icao: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(icao).json")
    }

    private func readCache(_ icao: String) -> AirportLayout? {
        guard let url = cacheURL(icao),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let written = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(written) < Self.cacheLifetime,
              let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        let pieces = rows.compactMap { row -> AirportLayout.Piece? in
            guard let raw = row["kind"] as? String,
                  let kind = AirportLayout.Piece.Kind(rawValue: raw),
                  let id = row["id"] as? String,
                  let flat = row["points"] as? [Double], flat.count >= 4 else { return nil }

            var coordinates: [CLLocationCoordinate2D] = []
            coordinates.reserveCapacity(flat.count / 2)
            for index in stride(from: 0, to: flat.count - 1, by: 2) {
                coordinates.append(
                    CLLocationCoordinate2D(latitude: flat[index], longitude: flat[index + 1])
                )
            }

            return AirportLayout.Piece(
                kind: kind,
                ref: row["ref"] as? String,
                coordinates: coordinates,
                id: id
            )
        }

        return AirportLayout(icao: icao, pieces: pieces)
    }

    private func writeCache(_ layout: AirportLayout) {
        guard let url = cacheURL(layout.icao) else { return }

        // Coordinates flattened to a plain array of doubles: a field is a few
        // hundred ways of a few dozen nodes, and a dictionary per node turns a
        // small file into a large one.
        let rows = layout.pieces.map { piece -> [String: Any] in
            var row: [String: Any] = [
                "kind": piece.kind.rawValue,
                "id": piece.id,
                "points": piece.coordinates.flatMap { [$0.latitude, $0.longitude] },
            ]
            if let ref = piece.ref { row["ref"] = ref }
            return row
        }

        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
