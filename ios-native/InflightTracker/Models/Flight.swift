import CoreLocation
import Foundation

/// One aircraft from an `all_flights_update` packet.
///
/// Built straight from the socket's dictionary rather than round-tripping
/// through `JSONSerialization` + `JSONDecoder` — that re-serialised and
/// re-parsed the entire payload on every update, which on a busy server is
/// megabytes of pointless work several times a minute.
///
/// Fields the app doesn't display aren't parsed at all, and the sprite key is
/// resolved once here instead of on every draw. Field names mirror the schema
/// documented in `old/www/SocketDataHub.js`.
struct Flight: Identifiable, Equatable {

    let id: String
    let callsign: String?
    let username: String?

    let latitude: Double
    let longitude: Double
    let altitudeFeet: Double
    let groundSpeedKnots: Double
    let verticalSpeedFPM: Double
    let heading: Double

    let aircraftName: String
    let liveryName: String
    let registration: String?

    /// Whether anyone is actually flying it — sent alongside the position, and
    /// not something the telemetry could be made to tell us.
    let pilotState: PilotState

    let departureIcao: String?
    let arrivalIcao: String?

    /// Resolved once at parse time — the map re-reads this on every frame.
    let spriteKey: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var displayName: String {
        guard let callsign = callsign, !callsign.isEmpty else { return username ?? "Unknown" }
        return callsign
    }

    /// Fails when the payload has no usable identity or position, which drops
    /// a single bad aircraft instead of the whole packet.
    init?(payload: [String: Any]) {
        guard let id = Flight.text(payload["flightId"]),
              let position = payload["position"] as? [String: Any],
              let latitude = Flight.number(position["lat"]),
              let longitude = Flight.number(position["lon"]),
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }

        self.id = id
        self.latitude = latitude
        self.longitude = longitude

        self.callsign = Flight.text(payload["callsign"])
        self.username = Flight.text(payload["username"])
        // Via `number` because the backend has sent it as both a number and a
        // string; `Int(_:)` traps on a non-finite double, so it is checked
        // rather than force-converted.
        self.pilotState = PilotState.from(
            Flight.number(payload["pilotState"]).flatMap { $0.isFinite ? Int($0) : nil }
        )
        self.departureIcao = Flight.text(payload["departureIcao"])
        self.arrivalIcao = Flight.text(payload["arrivalIcao"])

        self.altitudeFeet = Flight.number(position["alt_ft"]) ?? 0
        self.groundSpeedKnots = Flight.number(position["gs_kt"]) ?? 0
        self.verticalSpeedFPM = Flight.number(position["vs_fpm"]) ?? 0
        self.heading = Flight.number(position["heading_deg"]) ?? 0

        let aircraft = payload["aircraft"] as? [String: Any]
        self.aircraftName = Flight.text(aircraft?["aircraftName"]) ?? ""
        self.liveryName = Flight.text(aircraft?["liveryName"]) ?? ""
        self.registration = Flight.text(aircraft?["registration"])

        self.spriteKey = AircraftCatalog.spriteKey(for: aircraftName)
    }

    // MARK: - Lenient readers

    /// The backend has sent numbers as both JSON numbers and strings.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Empty and whitespace-only strings read as absent, and an id sent as a
    /// number still resolves.
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
