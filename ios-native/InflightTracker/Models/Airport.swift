import CoreLocation
import Foundation

struct Airport {
    let icao: String
    let name: String
    let coordinate: CLLocationCoordinate2D
    let countryCode: String

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
