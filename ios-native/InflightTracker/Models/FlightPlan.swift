import CoreLocation
import Foundation

/// One fix on a filed flight plan.
///
/// The plan as Infinite Flight files it is a *tree*: a procedure — a SID, a
/// STAR, an approach — is one item carrying its fixes as children, and only the
/// leaves have coordinates. The backend walks that tree once and hands back the
/// leaves in order, so nothing on this side has to know the shape of it. See
/// `/api/flights/:flightId/plan`.
struct PlanWaypoint: Equatable, Identifiable {

    let name: String
    let coordinate: CLLocationCoordinate2D

    /// Position in the plan rather than the name: a route can pass the same fix
    /// twice — a hold, a procedure that rejoins the airway it came off — and two
    /// annotations sharing an identity is one annotation.
    let index: Int

    var id: String { "\(index)|\(name)" }

    static func == (lhs: PlanWaypoint, rhs: PlanWaypoint) -> Bool {
        lhs.index == rhs.index
            && lhs.name == rhs.name
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// Where an aircraft has got to along its filed plan.
///
/// The feed says nothing about this — it reports a position, and the plan is a
/// separate list of fixes — so the leg being flown has to be worked out from
/// the geometry. Used by the navigation display for the fix in its corner, and
/// by the flight window for the route it prints.
enum PlanProgress {

    /// The fix the aircraft is heading for, and how far away it is.
    struct Leg: Equatable {
        let waypoint: PlanWaypoint
        let distanceNM: Double
        let bearingDegrees: Double

        /// How long to it at the current ground speed, or nil when the
        /// aircraft is too slow for the estimate to mean anything.
        func timeToRun(groundSpeedKnots: Double) -> TimeInterval? {
            guard groundSpeedKnots > 40, distanceNM > 0 else { return nil }
            return distanceNM / groundSpeedKnots * 3600
        }
    }

    /// The next fix on the plan, or nil when there is no plan to be on.
    ///
    /// Nearest-fix alone is wrong the moment one is passed: an aircraft two
    /// miles beyond a fix is still nearest to it, and the display would name a
    /// waypoint that is behind the wing. So the nearest is taken and then
    /// tested against the leg leaving it — if the aircraft is already down that
    /// leg, the fix at the far end of it is the one being flown to.
    static func next(
        in waypoints: [PlanWaypoint],
        from position: CLLocationCoordinate2D
    ) -> Leg? {
        guard !waypoints.isEmpty else { return nil }

        let distances = waypoints.map {
            FlightProgress.distanceNM(from: position, to: $0.coordinate)
        }
        guard let nearest = distances.indices.min(by: { distances[$0] < distances[$1] }) else {
            return nil
        }

        var index = nearest
        if nearest + 1 < waypoints.count {
            let here = waypoints[nearest].coordinate
            let onwards = waypoints[nearest + 1].coordinate

            // Both vectors in plain degrees, with longitude squeezed by the
            // latitude — over one leg of a route that is flat enough, and the
            // only thing being asked of it is a sign.
            let scale = cos(position.latitude * .pi / 180)
            let toFix = (
                x: (here.longitude - position.longitude) * scale,
                y: here.latitude - position.latitude
            )
            let legAhead = (
                x: (onwards.longitude - here.longitude) * scale,
                y: onwards.latitude - here.latitude
            )

            // Negative means the fix is behind us along its own outbound leg.
            if toFix.x * legAhead.x + toFix.y * legAhead.y < 0 { index = nearest + 1 }
        }

        let waypoint = waypoints[index]
        return Leg(
            waypoint: waypoint,
            distanceNM: FlightProgress.distanceNM(from: position, to: waypoint.coordinate),
            bearingDegrees: FlightProgress.bearingDegrees(from: position, to: waypoint.coordinate)
        )
    }
}
