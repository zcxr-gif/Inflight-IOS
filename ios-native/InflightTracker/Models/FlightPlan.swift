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
