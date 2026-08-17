import CoreLocation
import Foundation

/// The flown path, from the same backend endpoint the Capacitor build used.
///
/// `old/www/flight.js` fetches `/api/flights/<id>/history` and sorts the
/// returned breadcrumbs by date (`sortedRoutePoints`), which is how the web
/// tracker draws a complete path from departure rather than only what it has
/// watched. Same endpoint, same payload shape, same sort.
final class FlightHistoryService {

    static let shared = FlightHistoryService()

    private let lock = NSLock()
    private var inFlight = Set<String>()

    private init() {}

    /// Fetched once per flight per sheet. Completion is on the main queue and
    /// only fires with something worth drawing.
    func load(flightId: String, completion: @escaping ([TrackPoint]) -> Void) {
        guard let url = AppConfig.flightHistoryURL(flightId: flightId) else { return }

        lock.lock()
        let alreadyRunning = inFlight.contains(flightId)
        if !alreadyRunning { inFlight.insert(flightId) }
        lock.unlock()

        guard !alreadyRunning else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }

            self.lock.lock()
            self.inFlight.remove(flightId)
            self.lock.unlock()

            let points = FlightHistoryService.parse(data)
            guard !points.isEmpty else { return }

            DispatchQueue.main.async { completion(points) }
        }.resume()
    }

    // MARK: - Parsing

    /// `{ ok: true, path: [ { lat, lon, alt, gs, time, hdg } ] }`.
    ///
    /// Those are the names the backend actually encodes — see `path_codec.cjs`,
    /// which packs exactly that tuple, and `getFlightPath`, which clamps a
    /// trail with `p.time <= untilMs`. The longer spellings below are the ones
    /// the web tracker's own reader accepts, kept as fallbacks so a payload
    /// from either shape parses.
    ///
    /// Getting these wrong is silent and expensive, which is why they are now
    /// written down. Latitude and longitude were the only two being read
    /// correctly, so paths drew — while `alt`, `gs` and `time` all missed,
    /// leaving every historical point at zero feet, zero knots and *no date*.
    /// The altitude profile was therefore a flat line on the floor, and the
    /// window's elapsed clock had nothing to count from and showed "—:—" for
    /// the whole flight.
    private static func parse(_ data: Data?) -> [TrackPoint] {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let raw = (root["path"] as? [Any]) ?? (root["route"] as? [Any]) ?? []
        guard !raw.isEmpty else { return [] }

        var points: [TrackPoint] = []
        points.reserveCapacity(raw.count)

        for case let entry as [String: Any] in raw {
            guard let latitude = number(entry["latitude"] ?? entry["lat"]),
                  let longitude = number(entry["longitude"] ?? entry["lon"]),
                  latitude.isFinite, longitude.isFinite,
                  abs(latitude) <= 90, abs(longitude) <= 180,
                  !(latitude == 0 && longitude == 0) else { continue }

            points.append(
                TrackPoint(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    altitudeFeet: number(entry["alt"] ?? entry["altitude"] ?? entry["alt_ft"]) ?? 0,
                    groundSpeedKnots: number(entry["gs"] ?? entry["groundSpeed"] ?? entry["speed"] ?? entry["gs_kt"]) ?? 0,
                    date: date(entry["time"] ?? entry["date"] ?? entry["timestamp"])
                )
            )
        }

        // Oldest first, so the path reads departure to now.
        return points.sorted { lhs, rhs in
            switch (lhs.date, rhs.date) {
            case let (left?, right?): return left < right
            default: return false
            }
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            // Milliseconds when the value is far too large to be seconds.
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 3_000_000_000 ? raw / 1000 : raw)
        }

        guard let string = value as? String, !string.isEmpty else { return nil }
        return isoFractional.date(from: string) ?? iso.date(from: string)
    }
}
