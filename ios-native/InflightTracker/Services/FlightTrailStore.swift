import Combine
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
final class FlightTrailStore: ObservableObject {

    static let shared = FlightTrailStore()

    /// Bumped when a backend history is merged in.
    ///
    /// The only thing this class publishes, and deliberately: `record` runs on
    /// the feed's decode queue several times a second for every aircraft on the
    /// server, and a store that announced that would redraw the whole map on
    /// every packet. A seed is the opposite — once per flight you open, on the
    /// main queue, and it is the moment a path goes from a fragment to the
    /// whole trip.
    ///
    /// Without it nothing knows: the map reads this store on its own layout
    /// pass, so a history that landed a moment after the window opened sat
    /// there until the next packet happened to redraw something. Which is why
    /// the path used to take its time appearing.
    @Published private(set) var seedRevision: Int = 0

    private struct Trail {
        var points: [TrackPoint]
        var spacingNM: Double
        /// Set once the backend's history has been merged in, so live samples
        /// never get thinned away back to a fragment.
        var isSeeded: Bool

        /// When this aircraft was first seen, whatever it has done since.
        ///
        /// Separate from the points, because the points are thinned by
        /// DISTANCE: an aircraft parked at a gate moves less than the spacing
        /// and so keeps exactly one sample however long it sits there, and a
        /// trail that fills up is halved, which throws away the oldest sample
        /// there is. Neither is a bug in the thinning — it exists to bound
        /// memory — but both make "the earliest point I still hold" a bad
        /// answer to "how long has this been going". This is the good answer,
        /// and it costs eight bytes per aircraft.
        let firstSeen: Date
    }

    private let lock = NSLock()
    private var trails: [String: Trail] = [:]

    /// When each aircraft was first seen, kept apart from its trail so it
    /// survives the trail being dropped.
    ///
    /// Trails are discarded for anything missing from a packet, which is right
    /// — they are the expensive part and an aircraft that has left the server
    /// is not coming back with the same id. But the feed does blink: one packet
    /// short of a full list, or a reconnect, and a flight that has been in the
    /// air for nine hours comes back looking newly born, resetting the elapsed
    /// clock to zero. This is one date per aircraft, so remembering it across a
    /// blink costs nothing worth measuring.
    private var starts: [String: Date] = [:]

    /// Above this many remembered starts, the oldest half go. Nothing reads a
    /// start for an aircraft that has not been in a packet for hours, and a
    /// dictionary that only grows is a leak however small its entries are.
    private let maximumStarts = 800

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

            // Remembered from before this aircraft last blinked out, when
            // there is one. Otherwise now, and now is when we first saw it.
            let began = starts[flight.id] ?? sample.date ?? Date()
            starts[flight.id] = began

            guard var trail = trails[flight.id] else {
                trails[flight.id] = Trail(
                    points: [sample],
                    spacingNM: initialSpacingNM,
                    isSeeded: false,
                    firstSeen: began
                )
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

        // The starts outlive the trails deliberately, so they are bounded here
        // rather than by the same rule.
        if starts.count > maximumStarts {
            let keep = starts.sorted { $0.value > $1.value }.prefix(maximumStarts / 2)
            starts = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
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

        // The history reaches back further than we do, so its first dated
        // sample is a better "first seen" than ours — that is the flight's own
        // departure rather than the moment the app happened to open.
        let earliest = history.compactMap(\.date).min()
        let known = trails[flightId]?.firstSeen

        let began = [earliest, known, starts[flightId]].compactMap { $0 }.min() ?? Date()
        starts[flightId] = began

        trails[flightId] = Trail(
            points: merged,
            spacingNM: spacing,
            isSeeded: true,
            firstSeen: began
        )

        // Announced on the main queue and outside the lock, because what it
        // sets off is a layout pass — and a layout pass that reads this store
        // is not a thing to start from inside its own mutex.
        DispatchQueue.main.async { [weak self] in
            self?.seedRevision &+= 1
        }
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

    /// The earliest moment this aircraft is known to have been flying.
    ///
    /// The backend's history when it reaches back to departure, and otherwise
    /// when the app first saw it. Nil only for a flight that has never come
    /// through the feed at all.
    func firstSeen(for flightId: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return trails[flightId]?.firstSeen ?? starts[flightId]
    }
}
