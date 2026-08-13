import CoreLocation
import Foundation

/// Where each aircraft has actually been seen, so the map can draw the path a
/// flight has flown rather than a straight line between its endpoints.
///
/// The feed has no history — it broadcasts current positions only — so a trail
/// starts the moment the app first sees that aircraft. Nothing here is
/// fabricated: the part of the route that happened before then is drawn as a
/// dashed assumption, not as flown track.
///
/// Points are thinned by distance, and a trail that fills up is halved and its
/// spacing doubled instead of dropping its oldest points, so a long-haul still
/// keeps a complete (if coarser) path rather than a recent fragment.
final class FlightTrailStore {

    static let shared = FlightTrailStore()

    private struct Trail {
        var points: [CLLocationCoordinate2D]
        var spacingNM: Double
    }

    private let lock = NSLock()
    private var trails: [String: Trail] = [:]

    private let initialSpacingNM: Double = 2
    private let maximumPoints = 100

    private init() {}

    /// Called from the feed's decode queue on every packet.
    func record(_ flights: [Flight]) {
        lock.lock()
        defer { lock.unlock() }

        var live = Set<String>(minimumCapacity: flights.count)

        for flight in flights {
            live.insert(flight.id)

            guard var trail = trails[flight.id] else {
                trails[flight.id] = Trail(points: [flight.coordinate], spacingNM: initialSpacingNM)
                continue
            }

            if let last = trail.points.last {
                let moved = FlightProgress.distanceNM(from: last, to: flight.coordinate)
                guard moved >= trail.spacingNM else { continue }
            }

            trail.points.append(flight.coordinate)

            if trail.points.count > maximumPoints {
                // Halve the resolution rather than forget where it came from.
                trail.points = trail.points.enumerated()
                    .compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
                trail.spacingNM *= 2
            }

            trails[flight.id] = trail
        }

        // Aircraft that have left the server keep no trail.
        if trails.count > live.count {
            trails = trails.filter { live.contains($0.key) }
        }
    }

    func trail(for flightId: String) -> [CLLocationCoordinate2D] {
        lock.lock()
        defer { lock.unlock() }
        return trails[flightId]?.points ?? []
    }
}
