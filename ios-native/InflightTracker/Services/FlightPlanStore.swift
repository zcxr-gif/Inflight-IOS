import CoreLocation
import Foundation

/// The filed plans currently being drawn, one per flight.
///
/// Shaped like `FlightHistoryService`, and for the same reason: the map reads
/// it synchronously while laying out, so it has to answer immediately with
/// whatever it has and go and get the rest. A flight asked about for the first
/// time returns nothing and starts a fetch; the plan lands a moment later and
/// the next packet — every few seconds — draws it.
///
/// ## Why it caches misses
///
/// Most pilots file no plan at all. Without remembering that, every packet
/// would re-ask the backend for an answer that is not going to change, for
/// every aircraft anybody taps — and three things ask now, not one: the map's
/// route layer, the flight window's route card, and the navigation display.
/// A miss is therefore stored like a hit, and both expire on the same clock —
/// a plan can be filed or amended mid-flight, so neither answer is permanent.
final class FlightPlanStore {

    static let shared = FlightPlanStore()

    private struct Entry {
        let waypoints: [PlanWaypoint]
        let fetchedAt: Date
    }

    /// Long enough that tapping around the map costs one request per aircraft,
    /// short enough that a plan filed after pushback appears within a leg.
    private static let ttl: TimeInterval = 10 * 60

    /// Bounded so a long session panning across a busy server cannot grow this
    /// without limit. Oldest fetch is evicted, which is the one least likely to
    /// be on screen.
    private static let capacity = 60

    private let lock = NSLock()
    private var plans: [String: Entry] = [:]
    private var inFlight = Set<String>()

    private init() {}

    /// What we have for this flight right now, and a fetch if that is nothing.
    ///
    /// Deliberately not `async`. The caller is `MKMapView` layout, which cannot
    /// wait, and a plan is worth having a second late rather than not at all.
    func waypoints(for flightId: String) -> [PlanWaypoint] {
        lock.lock()
        let entry = plans[flightId]
        let fresh = entry.map { Date().timeIntervalSince($0.fetchedAt) < Self.ttl } ?? false
        lock.unlock()

        if fresh, let entry = entry { return entry.waypoints }

        fetch(flightId)
        // A stale plan is a better thing to draw than nothing while the fresh
        // one is on its way: the route has almost certainly not changed.
        return entry?.waypoints ?? []
    }

    private func fetch(_ flightId: String) {
        guard let url = AppConfig.flightPlanURL(flightId: flightId) else { return }

        lock.lock()
        let alreadyRunning = inFlight.contains(flightId)
        if !alreadyRunning { inFlight.insert(flightId) }
        lock.unlock()

        guard !alreadyRunning else { return }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self else { return }
            let waypoints = Self.parse(data)

            self.lock.lock()
            self.inFlight.remove(flightId)
            // Stored even when empty: "this pilot filed nothing" is an answer,
            // and re-asking for it on every packet is what this exists to stop.
            self.plans[flightId] = Entry(waypoints: waypoints, fetchedAt: Date())
            if self.plans.count > Self.capacity {
                let oldest = self.plans.min { $0.value.fetchedAt < $1.value.fetchedAt }
                if let key = oldest?.key { self.plans.removeValue(forKey: key) }
            }
            self.lock.unlock()
        }.resume()
    }

    /// `{ ok, flightId, flightPlanId, waypoints: [{ name, lat, lon }] }`.
    private static func parse(_ data: Data?) -> [PlanWaypoint] {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["waypoints"] as? [[String: Any]] else {
            return []
        }

        var out: [PlanWaypoint] = []
        for item in raw {
            guard let lat = item["lat"] as? Double,
                  let lon = item["lon"] as? Double else { continue }
            // The backend drops (0,0) already; this is the belt to its braces,
            // because a fix at null island drags the whole drawn route into the
            // Atlantic.
            guard lat != 0 || lon != 0 else { continue }
            guard abs(lat) <= 90, abs(lon) <= 180 else { continue }

            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(
                PlanWaypoint(
                    name: (name?.isEmpty ?? true) ? "—" : name!,
                    coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                    index: out.count
                )
            )
        }
        return out
    }
}
