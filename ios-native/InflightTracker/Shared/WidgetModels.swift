import Foundation

/// One aircraft, flattened to what a widget can draw without the live socket.
///
/// Deliberately not `Flight`: that type is built from the socket's dictionary
/// and carries `CLLocationCoordinate2D` and a sprite key resolved against an
/// atlas the widget doesn't load. This is the subset that survives being
/// written to disk and read back by another process minutes later, with the
/// route geometry already worked out — a widget has no time to be computing
/// great-circle distances while the system waits on its render.
public struct WidgetFlight: Codable, Hashable, Identifiable {

    public var id: String
    public var callsign: String
    public var username: String
    public var aircraftType: String
    public var liveryName: String
    public var registration: String

    public var departureIcao: String
    public var arrivalIcao: String

    public var altitudeFt: Int
    public var groundSpeedKt: Int
    public var verticalSpeedFPM: Int

    /// Route geometry, resolved by the app while it had the airport table
    /// open. Zero total means the route couldn't be resolved — the widget
    /// draws the aircraft without a progress track rather than a wrong one.
    public var flownNM: Double
    public var remainingNM: Double
    public var totalNM: Double

    /// When it gets there at its current speed, or nil while it is too slow
    /// for that estimate to mean anything.
    public var eta: Date?

    /// When the app last saw it. Everything a widget shows is this old, and
    /// the widget says so rather than presenting a stale reading as live.
    public var capturedAt: Date

    public init(id: String,
                callsign: String,
                username: String = "",
                aircraftType: String = "",
                liveryName: String = "",
                registration: String = "",
                departureIcao: String = "",
                arrivalIcao: String = "",
                altitudeFt: Int = 0,
                groundSpeedKt: Int = 0,
                verticalSpeedFPM: Int = 0,
                flownNM: Double = 0,
                remainingNM: Double = 0,
                totalNM: Double = 0,
                eta: Date? = nil,
                capturedAt: Date = Date()) {
        self.id = id
        self.callsign = callsign
        self.username = username
        self.aircraftType = aircraftType
        self.liveryName = liveryName
        self.registration = registration
        self.departureIcao = departureIcao
        self.arrivalIcao = arrivalIcao
        self.altitudeFt = altitudeFt
        self.groundSpeedKt = groundSpeedKt
        self.verticalSpeedFPM = verticalSpeedFPM
        self.flownNM = flownNM
        self.remainingNM = remainingNM
        self.totalNM = totalNM
        self.eta = eta
        self.capturedAt = capturedAt
    }

    /// 0…1 along the route, or nil when there is no route to be along.
    public var progress: Double? {
        guard totalNM > 1 else { return nil }
        return min(max(flownNM / totalNM, 0), 1)
    }

    /// Which photo this aircraft is drawn on.
    public var photoKey: String { PhotoKey.make(type: aircraftType, livery: liveryName) }

    /// What it is doing, from telemetry — the feed doesn't send a phase.
    /// Matches `FlightPhase.from` in the app so the two never disagree.
    public var phaseLabel: String {
        if groundSpeedKt < 40 && altitudeFt < 10_000 { return "On ground" }
        if verticalSpeedFPM > 300 { return "Climbing" }
        if verticalSpeedFPM < -300 { return "Descending" }
        return "Cruising"
    }

    public var phaseSymbol: String {
        if groundSpeedKt < 40 && altitudeFt < 10_000 { return "airplane.circle" }
        if verticalSpeedFPM > 300 { return "arrow.up.right" }
        if verticalSpeedFPM < -300 { return "arrow.down.right" }
        return "airplane"
    }

    public var routeLabel: String {
        let from = departureIcao.isEmpty ? "————" : departureIcao
        let to = arrivalIcao.isEmpty ? "————" : arrivalIcao
        return "\(from) → \(to)"
    }
}

/// Everything the widgets read, written by the app in one go.
///
/// One file rather than several: a widget that read a pinned flight from one
/// and a friends list from another could catch them mid-write and draw a pair
/// that never existed together.
public struct WidgetSnapshot: Codable {

    /// The flight the user chose to keep an eye on.
    public var pinned: WidgetFlight?

    /// Watched pilots who are currently flying, most interesting first.
    public var friends: [WidgetFlight]

    /// How many pilots are on the list at all — the widget says "3 of 12
    /// flying", which needs both numbers.
    public var friendCount: Int

    public var updatedAt: Date

    public init(pinned: WidgetFlight? = nil,
                friends: [WidgetFlight] = [],
                friendCount: Int = 0,
                updatedAt: Date = Date()) {
        self.pinned = pinned
        self.friends = friends
        self.friendCount = friendCount
        self.updatedAt = updatedAt
    }

    public static let empty = WidgetSnapshot()

    /// What the widget gallery shows before the app has ever run. Real-looking
    /// rather than blank: an empty tile in the picker reads as a broken widget
    /// and doesn't get added.
    public static let preview = WidgetSnapshot(
        pinned: WidgetFlight(
            id: "preview",
            callsign: "BAW117",
            username: "Inflight",
            aircraftType: "Boeing 777-300ER",
            liveryName: "British Airways",
            departureIcao: "EGLL",
            arrivalIcao: "KJFK",
            altitudeFt: 37_000,
            groundSpeedKt: 486,
            flownNM: 1_420,
            remainingNM: 1_580,
            totalNM: 3_000,
            eta: Date().addingTimeInterval(3 * 3600 + 15 * 60)
        ),
        friendCount: 8
    )
}

/// How an aircraft is turned into a photo-cache filename.
///
/// Shared because the app writes with it and the widget reads with it, and a
/// mismatch between the two is invisible: every lookup simply misses and every
/// widget quietly falls back to the drawn backdrop.
public enum PhotoKey {

    public static func make(type: String, livery: String) -> String {
        let clean: (String) -> String = { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                // Liveries arrive with slashes, spaces and the occasional
                // full stop in them. Everything that isn't a letter, a digit
                // or a dash becomes a dash, which keeps the key a legal
                // filename and makes path traversal impossible by
                // construction rather than by checking for it.
                .map { $0.isLetter || $0.isNumber ? $0 : "-" }
                .reduce(into: "") { out, char in
                    if char == "-" && out.hasSuffix("-") { return }
                    out.append(char)
                }
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }

        let typePart = clean(type)
        let liveryPart = clean(livery)
        if typePart.isEmpty && liveryPart.isEmpty { return "unknown" }
        // Long liveries would otherwise push the filename past what the file
        // system takes; the type carries most of the identity anyway.
        return String("\(typePart)_\(liveryPart)".prefix(120))
    }
}
