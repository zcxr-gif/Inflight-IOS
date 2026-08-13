import CoreLocation
import Foundation

/// The path each aircraft has flown.
///
/// Two sources feed this. The backend's `/api/flights/<id>/history` breadcrumb
/// trail is the authoritative one and covers the flight from departure — it is
/// fetched when a window opens and seeded here. The live feed then keeps
/// extending whatever is stored, so an open window's path stays current, and
/// aircraft nobody has opened still accumulate a path from the moment the app
/// first saw them.
///
/// Points are thinned by distance, and a trail that fills up is halved and its
/// spacing doubled instead of dropping its oldest points, so a long-haul keeps
/// a complete if coarser path rather than a recent fragment.
final class FlightTrailStore {

    static let shared = FlightTrailStore()

    private struct Trail {
        var points: [TrackPoint]
        var spacingNM: Double
        /// Set once the backend's history has been merged in, so live samples
        /// never get thinned away back to a fragment.
        var isSeeded: Bool
    }

    private let lock = NSLock()
    private var trails: [String: Trail] = [:]

    private let initialSpacingNM: Double = 2
    private let maximumPoints = 260

    private init() {}

    /// Called from the feed's decode queue on every packet.
    func record(_ flights: [Flight]) {
        lock.lock()
        defer { lock.unlock() }

        var live = Set<String>(minimumCapacity: flights.count)

        for flight in flights {
            live.insert(flight.id)

            let sample = TrackPoint(
                coordinate: flight.coordinate,
                altitudeFeet: flight.altitudeFeet,
                groundSpeedKnots: flight.groundSpeedKnots,
                date: Date()
            )

            guard var trail = trails[flight.id] else {
                trails[flight.id] = Trail(points: [sample], spacingNM: initialSpacingNM, isSeeded: false)
                continue
            }

            if let last = trail.points.last {
                let moved = FlightProgress.distanceNM(from: last.coordinate, to: sample.coordinate)
                guard moved >= trail.spacingNM else { continue }
            }

            trail.points.append(sample)

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

    /// Replaces a locally-observed fragment with the backend's full history.
    /// Anything recorded after the last history point is kept on the end, so a
    /// path fetched mid-flight doesn't rewind.
    func seed(_ history: [TrackPoint], for flightId: String) {
        guard !history.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var merged = history

        if let existing = trails[flightId]?.points, let cutoff = history.last?.date {
            let newer = existing.filter { point in
                guard let date = point.date else { return false }
                return date > cutoff
            }
            merged.append(contentsOf: newer)
        }

        let spacing = max(initialSpacingNM, Double(merged.count) / Double(maximumPoints) * initialSpacingNM)
        trails[flightId] = Trail(points: merged, spacingNM: spacing, isSeeded: true)
    }

    func hasHistory(for flightId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return trails[flightId]?.isSeeded ?? false
    }

    func points(for flightId: String) -> [TrackPoint] {
        lock.lock()
        defer { lock.unlock() }
        return trails[flightId]?.points ?? []
    }
}
