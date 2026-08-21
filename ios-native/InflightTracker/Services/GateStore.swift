import CoreLocation
import Foundation

/// Where a field's stands are, from OpenStreetMap.
///
/// The live feed carries no stand assignment — an aircraft reports where it is
/// and nothing about what it is parked on — so the only way to say "B24 is
/// occupied" is to know where B24 is and see something sitting there. This
/// fetches the where.
///
/// The query is the one the old tracker's dispatch board used, kept the same
/// on purpose: it already handles the ways OSM disagrees with itself about
/// parking spots — gates as nodes, stands as polygons, aprons named rather
/// than referenced — and a field that worked in the web build works here.
///
/// Fetched per field, on demand, and then kept: stands are repainted about as
/// often as terminals are rebuilt, so a cached answer stays right for a long
/// time and a field whose panel is opened twice costs one request.
/// Reads and writes on the main thread, like the rest of the app's stores —
/// the panel asks on appearance and the answer lands in a `@Published`.
final class GateStore: ObservableObject {

    static let shared = GateStore()

    enum State: Equatable {
        case idle
        case loading
        /// Stands, which may legitimately be none: plenty of fields have no
        /// parking mapped at all, and that is an answer rather than a failure.
        case ready([Gate])
        /// The lookup itself failed — offline, or Overpass refusing to serve.
        case failed
    }

    @Published private(set) var states: [String: State] = [:]

    /// Overpass mirrors are a shared, donated resource. One request per field
    /// per install per month is a polite way to use them; hammering them on
    /// every packet is not, which is why nothing here is on the feed's path.
    private static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!
    private static let cacheLifetime: TimeInterval = 30 * 24 * 3600

    /// Wide enough for the fields that sprawl — remote hardstands at Dallas or
    /// Dubai sit a long way from the terminal core.
    private static let searchRadiusMetres = 7000

    private var inFlight: Set<String> = []

    private init() {}

    func state(for icao: String) -> State {
        states[icao.uppercased()] ?? .idle
    }

    func gates(for icao: String) -> [Gate] {
        if case .ready(let gates) = state(for: icao) { return gates }
        return []
    }

    /// Loads a field's stands, from disk if they have been fetched before.
    ///
    /// Safe to call on every appearance: a field already loaded or already
    /// being loaded does nothing.
    func load(_ airport: Airport) {
        let icao = airport.icao.uppercased()

        switch state(for: icao) {
        case .ready, .loading: return
        case .idle, .failed: break
        }
        guard !inFlight.contains(icao) else { return }

        if let cached = readCache(icao) {
            states[icao] = .ready(cached)
            return
        }

        inFlight.insert(icao)
        states[icao] = .loading

        Task { [weak self] in
            let gates = await Self.fetch(icao: icao, at: airport.coordinate)
            await MainActor.run {
                guard let self = self else { return }
                self.inFlight.remove(icao)
                if let gates = gates {
                    self.writeCache(gates, for: icao)
                    self.states[icao] = .ready(gates)
                } else {
                    self.states[icao] = .failed
                }
            }
        }
    }

    // MARK: - Overpass

    /// Nil means the lookup failed. An empty array means the field genuinely
    /// has nothing mapped, which is worth caching so it is not asked again.
    private static func fetch(icao: String, at coordinate: CLLocationCoordinate2D) async -> [Gate]? {
        // Every flavour of parking spot OSM uses, as nodes *and* ways: some
        // mappers draw stands as polygons, and `out center` gives those a
        // representative point to measure against. Aprons need a ref or a name
        // or they would match every nameless patch of concrete on the field.
        let query = """
        [out:json][timeout:25];
        (
          node["aeroway"="gate"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
          node["aeroway"="parking_position"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
          node["aeroway"="stand"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
          way["aeroway"="parking_position"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
          way["aeroway"="stand"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
          way["aeroway"="apron"]["ref"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
          way["aeroway"="apron"]["name"](around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude));
        );
        out center tags;
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return parse(data)
        } catch {
            return nil
        }
    }

    private static func parse(_ data: Data) -> [Gate]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { return nil }

        var byRef: [String: Gate] = [:]

        for element in elements {
            guard let tags = element["tags"] as? [String: Any] else { continue }

            // The name a person would use, in the order a field labels them.
            let ref = (tags["ref"] as? String)
                ?? (tags["local_ref"] as? String)
                ?? (tags["name"] as? String)
            guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else { continue }

            // Nodes carry their position; ways carry the centre of the polygon.
            let centre = element["center"] as? [String: Any]
            guard let latitude = (element["lat"] as? Double) ?? (centre?["lat"] as? Double),
                  let longitude = (element["lon"] as? Double) ?? (centre?["lon"] as? Double) else { continue }

            let kind = Gate.Kind(rawValue: (tags["aeroway"] as? String) ?? "") ?? .apron
            let gate = Gate(
                ref: ref,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                kind: kind
            )

            // Two elements sharing a name is normal — a gate node inside its
            // own stand polygon. The more specific one wins, which is what
            // keeps the marker on the spot rather than on the apron around it.
            if let existing = byRef[ref], existing.kind.precedence <= kind.precedence { continue }
            byRef[ref] = gate
        }

        return Array(byRef.values)
    }

    // MARK: - Cache

    private static let cacheDirectoryName = "Gates"

    private var cacheDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base.appendingPathComponent(Self.cacheDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func cacheURL(_ icao: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(icao).json")
    }

    private func readCache(_ icao: String) -> [Gate]? {
        guard let url = cacheURL(icao),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let written = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(written) < Self.cacheLifetime,
              let data = try? Data(contentsOf: url),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }

        return rows.compactMap { row in
            guard let ref = row["ref"] as? String,
                  let latitude = row["lat"] as? Double,
                  let longitude = row["lon"] as? Double else { return nil }
            return Gate(
                ref: ref,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                kind: Gate.Kind(rawValue: (row["kind"] as? String) ?? "") ?? .apron
            )
        }
    }

    private func writeCache(_ gates: [Gate], for icao: String) {
        guard let url = cacheURL(icao) else { return }
        let rows = gates.map { gate in
            [
                "ref": gate.ref,
                "lat": gate.coordinate.latitude,
                "lon": gate.coordinate.longitude,
                "kind": gate.kind.rawValue,
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
