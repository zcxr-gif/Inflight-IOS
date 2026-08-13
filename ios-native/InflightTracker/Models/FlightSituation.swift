import CoreLocation
import Foundation

/// What the info window should say about where a flight is going.
///
/// A filed destination always wins — that is the thing worth showing. Only
/// when there isn't one do we fall back to where the aircraft physically is,
/// which for a parked airframe is the gate it is sitting at.
enum FlightSituation {

    /// A destination is filed: show the route and its progress.
    case enroute(progress: FlightProgress?)

    /// On the ground with nothing filed: show the field it is sitting at.
    case grounded(airport: Airport?, isTaxiing: Bool)

    /// Airborne with nothing filed: show the field it is closest to.
    case unplanned(departure: Airport?, nearest: Airport?)

    static func from(_ flight: Flight) -> FlightSituation {
        let arrival = flight.arrivalIcao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !arrival.isEmpty {
            return .enroute(progress: FlightProgress(flight: flight))
        }

        let store = AirportStore.shared

        if FlightPhase.from(flight) == .ground {
            // Nearest wins over the filed departure: an aircraft that has
            // already flown somewhere else is parked at the field it is at,
            // not the one it left.
            let field = store.nearestAirport(to: flight.coordinate)
                ?? store.airport(flight.departureIcao)
            return .grounded(airport: field, isTaxiing: flight.groundSpeedKnots >= 5)
        }

        return .unplanned(
            departure: store.airport(flight.departureIcao),
            // A wider net in the air: the useful reference is the field it is
            // over, not one it could land at.
            nearest: store.nearestAirport(to: flight.coordinate, withinNM: 40)
        )
    }
}
