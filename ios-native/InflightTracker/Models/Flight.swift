import CoreLocation
import Foundation

/// Decodes a value that the backend may send as either a string or a number.
struct LooseID: Decodable, Hashable {
    let value: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(Int(double))
        } else {
            value = UUID().uuidString
        }
    }
}

/// Wrapper that turns a single malformed element into `nil` instead of
/// failing the whole payload. One odd aircraft should never blank the map.
struct Failable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

/// One aircraft from an `all_flights_update` packet. The field names mirror
/// the schema documented in `old/www/SocketDataHub.js`.
struct Flight: Decodable, Identifiable, Equatable {

    struct Position: Decodable, Equatable {
        let lat: Double
        let lon: Double
        let alt_ft: Double?
        let gs_kt: Double?
        let vs_fpm: Double?
        let heading_deg: Double?
    }

    struct Aircraft: Decodable, Equatable {
        let aircraftName: String?
        let liveryName: String?
        let registration: String?
    }

    let flightId: LooseID
    let callsign: String?
    let username: String?
    let userId: LooseID?
    let position: Position
    let aircraft: Aircraft?
    let departureIcao: String?
    let arrivalIcao: String?
    let pilotState: Int?

    var id: String { flightId.value }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: position.lat, longitude: position.lon)
    }

    var heading: Double { position.heading_deg ?? 0 }

    var altitudeFeet: Double { position.alt_ft ?? 0 }

    var groundSpeedKnots: Double { position.gs_kt ?? 0 }

    var verticalSpeedFPM: Double { position.vs_fpm ?? 0 }

    var displayName: String {
        let trimmed = callsign?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? (username ?? "Unknown") : trimmed
    }

    var aircraftName: String { aircraft?.aircraftName ?? "" }

    var liveryName: String { aircraft?.liveryName ?? "" }

    /// Sprite key used to pick the plane icon out of the shared sprite sheet.
    var spriteKey: String { AircraftCatalog.spriteKey(for: aircraftName) }

    /// A coordinate check — the backend occasionally reports a null island
    /// position for a session that is still spawning in.
    var hasUsableCoordinate: Bool {
        guard position.lat.isFinite, position.lon.isFinite else { return false }
        guard abs(position.lat) <= 90, abs(position.lon) <= 180 else { return false }
        return !(position.lat == 0 && position.lon == 0)
    }

    var route: String? {
        let departure = departureIcao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let arrival = arrivalIcao?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if departure.isEmpty && arrival.isEmpty { return nil }
        return "\(departure.isEmpty ? "—" : departure) → \(arrival.isEmpty ? "—" : arrival)"
    }
}

/// The payload broadcast on the `all_flights_update` channel.
struct FlightsPayload: Decodable {
    let server: String?
    let flights: [Failable<Flight>]

    var validFlights: [Flight] {
        flights.compactMap { $0.value }.filter { $0.hasUsableCoordinate }
    }
}
