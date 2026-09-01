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

    /// When each flight's history was last asked for.
    ///
    /// A date rather than a set of ids, and the failure that taught us so was
    /// the quiet kind. The trail store drops the trail of any aircraft missing
    /// from a packet — right, since trails are the expensive part — and the
    /// feed does blink: one short packet or a reconnect and a nine-hour
    /// flight's seeded history is gone. With an id already in a set it would
    /// never be asked for again, so the path silently collapsed to the
    /// fragment recorded since the blink and stayed that way for as long as the
    /// window was open. A date lets the request come back, while still holding
    /// off the storm the set existed to prevent.
    private var asked: [String: Date] = [:]

    private init() {}

    /// How long before a flight whose history came back empty is asked about
    /// again.
    private static let retryInterval: TimeInterval = 45

    /// The flown path this aircraft had before we were watching, in the trail
    /// store, if it can be got.
    ///
    /// Rate-limited rather than once-only, and that is the point of it: a
    /// history that comes back empty — a flight that has only just pushed back
    /// — leaves `hasHistory` false forever, so a plain "ask if we have not
    /// got one" on a method called every layout pass is a request a second for
    /// as long as the window is open.
    ///
    /// Shared rather than kept by whichever map is on screen. Both of them draw
    /// this track, only one of them used to ask for it, and the result was a
    /// planet that drew a flown path starting wherever you happened to have
    /// been when you opened the app while the flat map drew the same flight
    /// from its departure.
    func ensureHistory(for flightId: String) {
        guard !FlightTrailStore.shared.hasHistory(for: flightId) else { return }

        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(asked[flightId] ?? .distantPast) > Self.retryInterval
        if due {
            asked[flightId] = now
            // Nothing worth remembering about the ones before: this exists to
            // stop a repeat, and an id that has not been asked for in a
            // hundred aircraft is not about to be asked for twice.
            if asked.count > 200 { asked = [flightId: now] }
        }
        lock.unlock()

        guard due else { return }
        load(flightId: flightId) { history in
            FlightTrailStore.shared.seed(history, for: flightId)
        }
    }

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

    /// `{ ok: true, path: [ { latitude, longitude, altitude, groundSpeed,
    /// date } ] }`, with `route` accepted as the older key the web tracker
    /// also reads.
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
                    // `alt` included because the web tracker reads it:
                    // `generateAltitudeColoredRoute` takes
                    // `point.altitude || point.alt || 0`, and a breadcrumb
                    // whose height lands under a key this did not know about
                    // decoded as zero — which drew the whole flown path in the
                    // colour of the ground.
                    altitudeFeet: number(
                        entry["altitude"] ?? entry["alt"] ?? entry["alt_ft"] ?? entry["altitudeFt"]
                    ) ?? 0,
                    groundSpeedKnots: number(
                        entry["groundSpeed"] ?? entry["speed"] ?? entry["gs_kt"] ?? entry["gs"]
                    ) ?? 0,
                    date: date(entry["date"] ?? entry["timestamp"])
                )
            )
        }

        // Oldest first, so the path reads departure to now — but only when
        // every breadcrumb actually carries a date to sort on.
        //
        // The old comparator answered `false` for every pair where either side
        // had no date, and that is not a strict weak ordering: with a mixture
        // of dated and undated points it produces cycles — a before b, b before
        // c, c before a — and `sorted(by:)` given a cycle returns an arbitrary
        // permutation. A path whose points come back in an arbitrary order is
        // drawn as a scribble across the map, which is what a history with any
        // missing timestamps looked like. Patching the comparator to fall back
        // on the index does not fix it; it just moves where the cycle forms.
        //
        // So the two cases are separated. Fully dated: sort on the date, with
        // the index breaking ties so equal timestamps keep the order they
        // arrived in. Anything missing: leave the list exactly as the server
        // sent it, which it already sends in order — an untouched path is
        // right far more often than a re-ordered one, and it can never be
        // nonsense.
        guard points.allSatisfy({ $0.date != nil }) else { return points }

        return points.enumerated()
            .sorted { lhs, rhs in
                guard let left = lhs.element.date, let right = rhs.element.date else {
                    return lhs.offset < rhs.offset
                }
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
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
