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

    /// Reads a filed plan out of whichever shape the backend answered in.
    ///
    /// ## Why there is more than one shape
    ///
    /// This was written against `{ ok, flightId, waypoints: [{ name, lat, lon }] }`
    /// — a flat list the backend had flattened for us. What the same route
    /// looks like coming out of Infinite Flight, which is where the backend
    /// gets it and what the web tracker reads directly, is
    /// `{ ok, plan: { flightPlanItems: [...] } }`: a *tree*, whose leaves carry
    /// `location: { latitude, longitude }` and whose branches are procedures
    /// with their fixes nested inside as `children`. A parser that knows only
    /// the flat form reads that as no waypoints at all, silently, for every
    /// flight — which is a map that never draws a filed route and never says
    /// why. See `old/www/flight.js` → `extractPlanRoute`, which walks the tree.
    ///
    /// So both are read, along with the items at the root without the `plan`
    /// wrapper, and a fix is taken from whichever of the coordinate spellings
    /// it carries. This is the same tolerance `AircraftPhotoService` applies to
    /// its endpoint, for the same reason: one client, several backend vintages,
    /// and the failure when they disagree is silence rather than an error.
    private static func parse(_ data: Data?) -> [PlanWaypoint] {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let plan = root["plan"] as? [String: Any]

        let items = (root["waypoints"] as? [[String: Any]])
            ?? (plan?["flightPlanItems"] as? [[String: Any]])
            ?? (plan?["waypoints"] as? [[String: Any]])
            ?? (root["flightPlanItems"] as? [[String: Any]])
            ?? []

        var out: [PlanWaypoint] = []
        flatten(items, depth: 0, into: &out)
        return out
    }

    /// Walks the tree, taking the leaves in order.
    ///
    /// A branch is a procedure — a SID, a STAR, an airway — and its `children`
    /// are the fixes along it. Taking the branch itself would plot one point
    /// for a dozen, so only leaves are kept, exactly as the web tracker does.
    ///
    /// The depth cap is not defensive dressing: this walks a structure from the
    /// network, and a document that referred to itself would otherwise be a
    /// hang inside a map layout pass. Nothing real is more than two or three
    /// deep.
    private static func flatten(
        _ items: [[String: Any]],
        depth: Int,
        into out: inout [PlanWaypoint]
    ) {
        guard depth < 6 else { return }

        for item in items {
            if let children = item["children"] as? [[String: Any]], !children.isEmpty {
                flatten(children, depth: depth + 1, into: &out)
                continue
            }

            guard let coordinate = coordinate(in: item) else { continue }
            out.append(
                PlanWaypoint(name: name(of: item), coordinate: coordinate, index: out.count)
            )
        }
    }

    /// A fix's position, however this payload spells it.
    private static func coordinate(in item: [String: Any]) -> CLLocationCoordinate2D? {
        let location = item["location"] as? [String: Any]

        let latitude = (item["lat"] as? Double)
            ?? (item["latitude"] as? Double)
            ?? (location?["latitude"] as? Double)
            ?? (location?["lat"] as? Double)

        let longitude = (item["lon"] as? Double)
            ?? (item["lng"] as? Double)
            ?? (item["longitude"] as? Double)
            ?? (location?["longitude"] as? Double)
            ?? (location?["lon"] as? Double)

        guard let lat = latitude, let lon = longitude else { return nil }

        // The backend drops (0,0) already; this is the belt to its braces,
        // because a fix at null island drags the whole drawn route into the
        // Atlantic.
        guard lat != 0 || lon != 0 else { return nil }
        guard abs(lat) <= 90, abs(lon) <= 180 else { return nil }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// What to label the fix. `identifier` is the one on the chart; `name` is
    /// what the flat form called it. Either is better than the dash, which is
    /// what an unnamed corner gets.
    private static func name(of item: [String: Any]) -> String {
        for key in ["name", "identifier", "ident"] {
            guard let value = (item[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            return value
        }
        return "—"
    }
}
