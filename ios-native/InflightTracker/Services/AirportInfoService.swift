import Foundation

/// Everything about a field that isn't in the bundled dataset: its photograph,
/// and the details the backend knows and a VAT-Spy line never carried.
///
/// The web tracker fetched both (`old/www/flight.js` ->
/// `createAirportInfoWindowHTML`) from two different backends — the photo from
/// the Indgo API, the rest from ACARS — and used the results in one header.
/// Same two calls here, gathered behind one type so a panel asks for "the
/// field" rather than orchestrating two requests and a fallback.
struct AirportInfo: Equatable {

    /// Photograph of the field. Nil is the common case, not an error: most of
    /// the world's 17,000 strips have never had one taken for this.
    let imageURL: URL?

    let city: String?
    let state: String?

    /// Feet above sea level.
    let elevationFeet: Int?

    /// The airspace class the field sits in — `B`, `C`, `D`. Written out as
    /// "Class B" where it is shown.
    let airspaceClass: String?

    /// Olson zone, as the backend writes it. Only the first word is kept: the
    /// field carries a trailing offset that goes stale twice a year.
    let timezone: String?

    /// Whether the simulator has modelled buildings here, which is the one
    /// thing on this panel that is about the sim rather than about aviation.
    /// Worth a badge — it is why people fly somewhere.
    let has3DBuildings: Bool

    /// A field with nothing resolved. Distinct from "not asked yet", which is
    /// nil, so a panel can tell a finished lookup that found nothing from one
    /// still in the air.
    static let empty = AirportInfo(
        imageURL: nil,
        city: nil,
        state: nil,
        elevationFeet: nil,
        airspaceClass: nil,
        timezone: nil,
        has3DBuildings: false
    )

    /// `Los Angeles, California` — whichever halves came back.
    var locationLabel: String? {
        let parts = [city, state].compactMap { value -> String? in
            guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
            return value
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// `Asia/Tokyo`, with the offset the backend appends dropped.
    var timezoneLabel: String? {
        guard let zone = timezone?.split(separator: " ").first, !zone.isEmpty else { return nil }
        return String(zone)
    }

    var elevationLabel: String? {
        guard let feet = elevationFeet else { return nil }
        return "\(Format.number(Double(feet))) ft"
    }

    /// Whether anything at all came back worth drawing. A lookup that resolved
    /// only an empty object shouldn't open a header on the panel.
    var hasContent: Bool {
        imageURL != nil
            || locationLabel != nil
            || elevationFeet != nil
            || airspaceClass != nil
            || timezone != nil
            || has3DBuildings
    }
}

/// Resolves and caches `AirportInfo`, one field at a time.
///
/// Both halves are optional and independent: a field can have a photo and no
/// details, or details and no photo, and either request failing leaves the
/// other's answer intact. The panel is drawn from the bundled dataset either
/// way — this only ever adds to it.
final class AirportInfoService {

    static let shared = AirportInfoService()

    private var cache: [String: AirportInfo] = [:]

    /// Panels waiting on a lookup that is already running, keyed by ICAO. A
    /// field can be open in a panel and named on a flight's route card at the
    /// same time; both are answered by the one pair of requests.
    private var waiting: [String: [(AirportInfo) -> Void]] = [:]

    private let lock = NSLock()

    private init() {}

    /// What is already known about a field, without asking for anything.
    /// Lets a panel draw its header on the first frame for a field looked at
    /// twice, rather than flashing a placeholder over a photo it already has.
    func cached(_ icao: String) -> AirportInfo? {
        lock.lock()
        defer { lock.unlock() }
        return cache[icao.uppercased()]
    }

    /// `completion` runs on the main thread, once, with whatever resolved.
    ///
    /// Answers are cached for the session including the empty one — a field
    /// with no photo and no details would otherwise be re-asked every time its
    /// panel opened, and the answer does not change.
    func info(for icao: String, completion: @escaping (AirportInfo) -> Void) {
        let code = icao.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 4 else {
            DispatchQueue.main.async { completion(.empty) }
            return
        }

        lock.lock()
        if let cached = cache[code] {
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        // A second ask for the same field while the first is still in the air
        // joins it rather than firing a duplicate pair of requests — and is
        // still answered, which is why this is a queue and not a flag.
        if waiting[code] != nil {
            waiting[code]?.append(completion)
            lock.unlock()
            return
        }
        waiting[code] = [completion]
        lock.unlock()

        let group = DispatchGroup()

        var imageURL: URL?
        var details: Details?

        group.enter()
        fetchImageURL(code) { resolved in
            imageURL = resolved
            group.leave()
        }

        group.enter()
        fetchDetails(code) { resolved in
            details = resolved
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            let info = AirportInfo(
                imageURL: imageURL,
                city: details?.city,
                state: details?.state,
                elevationFeet: details?.elevation.map { Int($0.rounded()) },
                airspaceClass: details?.class,
                timezone: details?.timezone,
                has3DBuildings: details?.has3dBuildings ?? false
            )

            guard let self = self else { return }

            self.lock.lock()
            self.cache[code] = info
            let waiters = self.waiting.removeValue(forKey: code) ?? []
            self.lock.unlock()

            for waiter in waiters { waiter(info) }
        }
    }

    // MARK: - The photograph

    private struct ImageEntry: Decodable {
        let imageUrl: String?
        let imageUrls: [String]?

        var firstURL: URL? {
            let candidates = (imageUrls ?? []) + [imageUrl].compactMap { $0 }
            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let url = URL(string: trimmed) { return url }
            }
            return nil
        }
    }

    private func fetchImageURL(_ icao: String, completion: @escaping (URL?) -> Void) {
        guard let url = URL(string: "\(AppConfig.apiBaseURLString)/api/airports/\(icao)") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data else {
                completion(nil)
                return
            }

            let decoder = JSONDecoder()

            // The endpoint has answered with both a bare object and a
            // single-element array, the same as the aircraft lookup does.
            if let entry = try? decoder.decode(ImageEntry.self, from: data) {
                completion(entry.firstURL)
            } else if let list = try? decoder.decode([ImageEntry].self, from: data) {
                completion(list.first?.firstURL)
            } else {
                completion(nil)
            }
        }
        .resume()
    }

    // MARK: - The details

    private struct Details: Decodable {
        struct Country: Decodable {
            let isoCode: String?
        }

        let city: String?
        let state: String?
        let country: Country?
        let elevation: Double?
        let timezone: String?
        let has3dBuildings: Bool?

        /// `class` is a keyword, so the property is spelled out and mapped.
        let `class`: String?

        private enum CodingKeys: String, CodingKey {
            case city, state, country, elevation, timezone, has3dBuildings
            case `class` = "class"
        }
    }

    private struct DetailsEnvelope: Decodable {
        let ok: Bool?
        let airport: Details?
    }

    private func fetchDetails(_ icao: String, completion: @escaping (Details?) -> Void) {
        guard let url = URL(string: "\(AppConfig.socketURLString)/api/airport/\(icao)") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { data, _, _ in
            guard let data = data,
                  let envelope = try? JSONDecoder().decode(DetailsEnvelope.self, from: data),
                  envelope.ok != false else {
                completion(nil)
                return
            }
            completion(envelope.airport)
        }
        .resume()
    }
}
