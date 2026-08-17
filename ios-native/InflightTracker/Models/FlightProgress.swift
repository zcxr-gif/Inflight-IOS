import CoreLocation
import Foundation

/// Flight phase, derived from telemetry since the feed doesn't send one.
enum FlightPhase: String, CaseIterable {
    case ground = "GROUND"
    case climb = "CLIMB"
    case cruise = "CRUISE"
    case descent = "DESCENT"

    /// Sentence case, for anywhere the phase is read as a word rather than
    /// stamped as a label — the map filters list them this way.
    var label: String { rawValue.capitalized }

    /// A glyph per phase, used where the phases are a set of controls rather
    /// than a readout of one aircraft's state.
    var symbol: String {
        switch self {
        case .ground: return "airplane.circle"
        case .climb: return "arrow.up.right.circle"
        case .cruise: return "airplane"
        case .descent: return "arrow.down.right.circle"
        }
    }

    static func from(_ flight: Flight) -> FlightPhase {
        if flight.groundSpeedKnots < 40 && flight.altitudeFeet < 10_000 { return .ground }
        if flight.verticalSpeedFPM > 300 { return .climb }
        if flight.verticalSpeedFPM < -300 { return .descent }
        return .cruise
    }
}

/// Route geometry for a flight: how far it has come, how far is left, and how
/// long that will take at the current ground speed.
struct FlightProgress {

    let departure: Airport
    let arrival: Airport
    let flownNM: Double
    let remainingNM: Double

    var totalNM: Double { flownNM + remainingNM }

    /// 0...1 along the route. Derived from flown vs. flown+remaining rather
    /// than the direct departure-to-arrival distance, so the bar still behaves
    /// when an aircraft is off the great-circle track.
    var fraction: Double {
        guard totalNM > 0 else { return 0 }
        return min(max(flownNM / totalNM, 0), 1)
    }

    /// Hours to run at the current ground speed, or nil when the aircraft is
    /// too slow for the estimate to mean anything.
    func estimatedTimeEnroute(groundSpeedKnots: Double) -> TimeInterval? {
        guard groundSpeedKnots > 40, remainingNM > 0 else { return nil }
        return remainingNM / groundSpeedKnots * 3600
    }

    init?(flight: Flight) {
        guard let departure = AirportStore.shared.airport(flight.departureIcao),
              let arrival = AirportStore.shared.airport(flight.arrivalIcao) else { return nil }

        self.departure = departure
        self.arrival = arrival
        self.flownNM = FlightProgress.distanceNM(from: departure.coordinate, to: flight.coordinate)
        self.remainingNM = FlightProgress.distanceNM(from: flight.coordinate, to: arrival.coordinate)
    }

    /// Great-circle distance in nautical miles.
    static func distanceNM(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let earthRadiusNM = 3440.065
        let degreesToRadians = Double.pi / 180

        let lat1 = from.latitude * degreesToRadians
        let lat2 = to.latitude * degreesToRadians
        let deltaLat = (to.latitude - from.latitude) * degreesToRadians
        let deltaLon = (to.longitude - from.longitude) * degreesToRadians

        let haversine = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)

        return 2 * atan2(sqrt(haversine), sqrt(1 - haversine)) * earthRadiusNM
    }

    /// Initial great-circle bearing, in degrees true, 0..<360.
    ///
    /// Used to tell what is ahead of an aircraft from what is behind it — a
    /// filed route that doubles back passes close to fixes it left an hour ago,
    /// and distance alone cannot separate the two.
    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let degreesToRadians = Double.pi / 180

        let lat1 = from.latitude * degreesToRadians
        let lat2 = to.latitude * degreesToRadians
        let deltaLon = (to.longitude - from.longitude) * degreesToRadians

        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)

        let degrees = atan2(y, x) / degreesToRadians
        return degrees < 0 ? degrees + 360 : degrees
    }
}
