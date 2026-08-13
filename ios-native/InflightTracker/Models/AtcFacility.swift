import Foundation

/// One controller currently on frequency.
///
/// Comes from the feed's `secondary_data_update` packet, which is the same
/// channel the web tracker reads (`old/www/flight.js`, and the schema written
/// up in `old/www/SocketDataHub.js`): a server name and an array of facilities,
/// each a type id, a controller, the field or FIR they are working, and when
/// they opened the position.
struct AtcFacility: Identifiable, Equatable {

    /// What the controller is working. Ids are the backend's own — the web
    /// tracker's `atcTypeToString` is the reference for the mapping.
    enum Kind: Int, CaseIterable {
        case ground = 0
        case tower = 1
        case unicom = 2
        case clearance = 3
        case approach = 4
        case departure = 5
        case center = 6
        case atis = 7

        /// Anything the backend sends that isn't in the table above. Its own
        /// case rather than a fallback to `tower`, so an unrecognised id reads
        /// as unknown instead of as a position nobody is actually working.
        case unknown = -1

        /// The badge on the row: three or four letters, the way a strip or a
        /// frequency listing writes it.
        var code: String {
            switch self {
            case .ground: return "GND"
            case .tower: return "TWR"
            case .unicom: return "UNI"
            case .clearance: return "DEL"
            case .approach: return "APP"
            case .departure: return "DEP"
            case .center: return "CTR"
            case .atis: return "ATIS"
            case .unknown: return "—"
            }
        }

        var label: String {
            switch self {
            case .ground: return "Ground"
            case .tower: return "Tower"
            case .unicom: return "Unicom"
            case .clearance: return "Clearance"
            case .approach: return "Approach"
            case .departure: return "Departure"
            case .center: return "Center"
            case .atis: return "ATIS"
            case .unknown: return "Unknown"
            }
        }

        /// Order within one field, from the ground up: the sequence a departing
        /// aircraft would actually talk to.
        var rank: Int {
            switch self {
            case .atis: return 0
            case .clearance: return 1
            case .ground: return 2
            case .tower: return 3
            case .departure: return 4
            case .approach: return 5
            case .center: return 6
            case .unicom: return 7
            case .unknown: return 8
            }
        }
    }

    let kind: Kind
    let controller: String

    /// ICAO of the field, or the FIR's identifier for a centre.
    let station: String

    /// When the position was opened, when the backend gave us something we
    /// could read.
    let openedAt: Date?

    /// One controller can only work one position at one field, so this is
    /// stable across packets — which is what keeps the list from re-animating
    /// every refresh.
    var id: String { "\(station)|\(kind.rawValue)|\(controller)" }

    /// A centre works an airspace, not an airport, so its identifier will not
    /// be in the airport dataset — worth knowing before trying to look one up.
    var isCenter: Bool { kind == .center }

    /// How long they have been on, as `2h 14m`. Nil when the backend didn't
    /// send a usable start time, which it sometimes doesn't.
    func onlineLabel(now: Date = Date()) -> String? {
        guard let openedAt = openedAt else { return nil }

        let seconds = now.timeIntervalSince(openedAt)
        guard seconds.isFinite, seconds >= 0 else { return nil }

        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return "just now" }
        guard minutes >= 60 else { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Built straight from the socket's dictionary, like `Flight` — a facility
    /// with no controller or no station has nothing to show, so it is dropped
    /// rather than rendered as a row of dashes.
    init?(payload: [String: Any]) {
        guard let station = AtcFacility.text(payload["airportName"]) else { return nil }

        self.station = station.uppercased()
        self.controller = AtcFacility.text(payload["username"]) ?? "Unknown"

        let rawType = AtcFacility.integer(payload["type"])
        self.kind = rawType.flatMap { Kind(rawValue: $0) } ?? .unknown

        self.openedAt = AtcFacility.date(payload["startTime"])
    }

    // MARK: - Lenient readers

    /// The backend has sent the start time as epoch seconds, epoch
    /// milliseconds, and as an ISO-8601 string. All three resolve.
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            guard raw > 0, raw.isFinite else { return nil }
            // Anything past the year ~2286 in seconds is milliseconds.
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
        }

        guard let string = text(value) else { return nil }
        if let epoch = Double(string) {
            return date(NSNumber(value: epoch))
        }
        return isoFormatter.date(from: string) ?? isoFormatterWithFraction.date(from: string)
    }

    private static let isoFormatter = ISO8601DateFormatter()

    private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

/// Every controller at one field or FIR, which is how the ATC panel lists them:
/// a station, then the positions open there.
struct AtcStation: Identifiable {

    let identifier: String
    let facilities: [AtcFacility]

    var id: String { identifier }

    /// A centre station: airspace rather than a field, so there is no airport
    /// behind its identifier and nowhere on the map to be taken to.
    var isCenter: Bool { facilities.contains(where: { $0.isCenter }) }

    /// The airport behind the identifier, when there is one.
    var airport: Airport? {
        guard !isCenter else { return nil }
        return AirportStore.shared.airport(identifier)
    }

    /// Groups a packet into stations: fields first, ordered by how much is
    /// open at each — the busiest airport is the one worth reading first —
    /// and centres last, since they cover airspace rather than a place.
    static func group(_ facilities: [AtcFacility]) -> [AtcStation] {
        let grouped = Dictionary(grouping: facilities) { $0.station }

        return grouped
            .map { identifier, list in
                AtcStation(
                    identifier: identifier,
                    facilities: list.sorted { $0.kind.rank < $1.kind.rank }
                )
            }
            .sorted { first, second in
                if first.isCenter != second.isCenter { return second.isCenter }
                if first.facilities.count != second.facilities.count {
                    return first.facilities.count > second.facilities.count
                }
                return first.identifier < second.identifier
            }
    }
}
