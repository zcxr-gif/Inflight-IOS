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
        );
        out geom tags;
        """

        guard let elements = await Overpass.elements(query) else { return nil }
        return parse(elements)
    }

    private static func parse(_ elements: [[String: Any]]) -> [AirportLayout.Piece] {
        var pieces: [AirportLayout.Piece] = []

        for element in elements {
            guard let tags = element["tags"] as? [String: Any],
                  let raw = tags["aeroway"] as? String,
                  let kind = AirportLayout.Piece.Kind(rawValue: raw),
                  let geometry = element["geometry"] as? [[String: Any]] else { continue }

            let coordinates = geometry.compactMap { node -> CLLocationCoordinate2D? in
                guard let latitude = node["lat"] as? Double,
                      let longitude = node["lon"] as? Double else { return nil }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
            guard coordinates.count >= 2 else { continue }

            let ref = ((tags["ref"] as? String) ?? (tags["name"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let identifier = (element["id"] as? Int).map(String.init)
                ?? "\(raw)-\(coordinates.count)-\(pieces.count)"

            pieces.append(
                AirportLayout.Piece(
                    kind: kind,
                    ref: (ref?.isEmpty == false) ? ref : nil,
                    coordinates: coordinates,
                    id: identifier
                )
            )
        }

        return pieces
    }

    // MARK: - Cache

    private var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent("AirportLayouts", isDirectory: true)
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
