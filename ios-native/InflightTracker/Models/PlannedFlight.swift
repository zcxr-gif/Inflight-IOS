import CoreLocation
import Foundation

/// A flight somebody means to make: both ends, the stand at each end, and when.
///
/// The third tense the tracker keeps. `PilotLiveStatus` is the present —
/// where an aeroplane is right now — and `pilot_logbook` is the past, and both
/// of those are *observed*: nobody types them, and every field in them is
/// something the sim or the feed actually reported. This one is the future, and
/// it is the only one that is entirely a claim. Nothing here is measured; all
/// of it is what a pilot intends, which is why it is a separate table, a
/// separate type, and never mixed into the logbook's totals.
///
/// ## Gates
///
/// A stand is a name and, when it was picked off a map rather than typed, a
/// place. Both are kept — see `Stand` — because they answer different
/// questions: the name is what you say on the radio and what still means
/// something in a year, and the point is what lets the app draw it.
struct PlannedFlight: Identifiable, Equatable {

    /// The row's own id, assigned by Postgres. Empty on a plan that has never
    /// been saved, which is how the editor tells a new plan from an edit.
    let id: String

    var originICAO: String
    var destinationICAO: String

    var departureStand: Stand?
    var arrivalStand: Stand?

    /// Off blocks and on blocks, the way a timetable means them. Both optional:
    /// a route planned on a Sunday for "some evening this week" is a real plan.
    var scheduledOut: Date?
    var scheduledIn: Date?

    var callsign: String
    var aircraft: String
    var livery: String
    var remarks: String

    var status: Status

    var updatedAt: Date?

    /// One end of the plan: which stand, and where it is if the app was ever
    /// told.
    ///
    /// The coordinate is deliberately optional rather than the two being
    /// separate fields on the plan. A gate typed on the keyboard has a name and
    /// no position, and a gate tapped on the airport map has both — that is the
    /// entire difference between what a free account records and what Pro
    /// records, and modelling it as one value with an optional half is what
    /// keeps every reader from having to know about the two ways in.
    struct Stand: Equatable {

        /// `B24`, `501`, `Cargo 3` — the field's own name for the spot.
        var ref: String

        /// Where it was, when it was picked. Nil for a typed gate.
        ///
        /// Held rather than looked up again each time: OpenStreetMap is the
        /// source, OpenStreetMap changes, and a stand somebody chose in March
        /// should still draw in September whether or not the node it came from
        /// survived a resurvey.
        var coordinate: CLLocationCoordinate2D?

        init(ref: String, coordinate: CLLocationCoordinate2D? = nil) {
            self.ref = ref
            self.coordinate = coordinate
        }

        /// Built from one of `GateStore`'s stands, which is the Pro path: the
        /// name and the position arrive together because the map had both.
        init(_ gate: Gate) {
            self.ref = gate.ref
            self.coordinate = gate.coordinate
        }

        static func == (lhs: Stand, rhs: Stand) -> Bool {
            lhs.ref == rhs.ref
                && lhs.coordinate?.latitude == rhs.coordinate?.latitude
                && lhs.coordinate?.longitude == rhs.coordinate?.longitude
        }
    }

    /// Where the plan has got to.
    ///
    /// Flown and cancelled plans are kept rather than deleted, because the most
    /// useful thing to start a new plan from is one you have already flown.
    enum Status: String, CaseIterable, Identifiable {
        case planned
        case flown
        case cancelled

        var id: String { rawValue }

        var label: String {
            switch self {
            case .planned: return "Planned"
            case .flown: return "Flown"
            case .cancelled: return "Cancelled"
            }
        }

        var symbol: String {
            switch self {
            case .planned: return "calendar"
            case .flown: return "checkmark.seal.fill"
            case .cancelled: return "xmark.circle"
            }
        }
    }

    // MARK: - Making one

    /// A blank plan, optionally already knowing where it starts.
    ///
    /// The origin is passed in because the commonest way to reach the editor is
    /// from a field's own panel — you are looking at Heathrow and you decide to
    /// fly out of it — and making somebody type an ICAO they are already
    /// looking at is the kind of small rudeness that stops a feature being used.
    static func blank(from origin: String = "", to destination: String = "") -> PlannedFlight {
        PlannedFlight(
            id: "",
            originICAO: origin.uppercased(),
            destinationICAO: destination.uppercased(),
            departureStand: nil,
            arrivalStand: nil,
            scheduledOut: nil,
            scheduledIn: nil,
            callsign: "",
            aircraft: "",
            livery: "",
            remarks: "",
            status: .planned,
            updatedAt: nil
        )
    }

    var isSaved: Bool { !id.isEmpty }

    /// Whether this is worth sending to the server.
    ///
    /// Both ends and nothing else. The gates are the point of the feature and
    /// the schedule is most of the rest of it, but a plan with neither is still
    /// a route somebody wants written down, and refusing to save one would mean
    /// deciding on their behalf which half of their own plan matters.
    var isComplete: Bool {
        Self.isValidICAO(originICAO) && Self.isValidICAO(destinationICAO)
    }

    /// The same shape the table's own check constraint uses. Three or four
    /// letters or digits — which is ICAO, and also the handful of fields
    /// Infinite Flight carries under a three-character code.
    static func isValidICAO(_ text: String) -> Bool {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard (3...4).contains(candidate.count) else { return false }
        return candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// `EGLL → KJFK`, for a row that has room for one line.
    var routeLabel: String {
        "\(originICAO) → \(destinationICAO)"
    }

    /// `B24 → 4A`, and nothing at all when neither end has a stand on it.
    var standsLabel: String? {
        let out = departureStand?.ref
        let arrive = arrivalStand?.ref
        switch (out, arrive) {
        case let (.some(out), .some(arrive)): return "Gate \(out) → \(arrive)"
        case let (.some(out), .none): return "Gate \(out) → —"
        case let (.none, .some(arrive)): return "Gate — → \(arrive)"
        case (.none, .none): return nil
        }
    }

    /// How long the plan says the flight is, when it says both ends of it.
    var blockMinutes: Int? {
        guard let out = scheduledOut, let arrive = scheduledIn, arrive > out else { return nil }
        return Int(arrive.timeIntervalSince(out) / 60)
    }
}

// MARK: - Reading a row

/// PostgREST hands these back as plain rows — this is a table the owner reads
/// directly rather than a function, because "yours and no other" is a rule
/// row-level security states completely. See `SupabaseData.select`.
extension PlannedFlight: Decodable {

    enum CodingKeys: String, CodingKey {
        case id
        case originICAO = "origin_icao"
        case destinationICAO = "destination_icao"
        case departureGate = "departure_gate"
        case arrivalGate = "arrival_gate"
        case departureGateLatitude = "departure_gate_latitude"
        case departureGateLongitude = "departure_gate_longitude"
        case arrivalGateLatitude = "arrival_gate_latitude"
        case arrivalGateLongitude = "arrival_gate_longitude"
        case scheduledOut = "scheduled_out"
        case scheduledIn = "scheduled_in"
        case callsign
        case aircraft
        case livery
        case remarks
        case status
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decode(String.self, forKey: .id)
        originICAO = try c.decode(String.self, forKey: .originICAO)
        destinationICAO = try c.decode(String.self, forKey: .destinationICAO)

        departureStand = Self.stand(
            ref: try c.decodeIfPresent(String.self, forKey: .departureGate),
            latitude: try c.decodeIfPresent(Double.self, forKey: .departureGateLatitude),
            longitude: try c.decodeIfPresent(Double.self, forKey: .departureGateLongitude)
        )
        arrivalStand = Self.stand(
            ref: try c.decodeIfPresent(String.self, forKey: .arrivalGate),
            latitude: try c.decodeIfPresent(Double.self, forKey: .arrivalGateLatitude),
            longitude: try c.decodeIfPresent(Double.self, forKey: .arrivalGateLongitude)
        )

        scheduledOut = Self.date(try c.decodeIfPresent(String.self, forKey: .scheduledOut))
        scheduledIn = Self.date(try c.decodeIfPresent(String.self, forKey: .scheduledIn))
        updatedAt = Self.date(try c.decodeIfPresent(String.self, forKey: .updatedAt))

        callsign = (try c.decodeIfPresent(String.self, forKey: .callsign)) ?? ""
        aircraft = (try c.decodeIfPresent(String.self, forKey: .aircraft)) ?? ""
        livery = (try c.decodeIfPresent(String.self, forKey: .livery)) ?? ""
        remarks = (try c.decodeIfPresent(String.self, forKey: .remarks)) ?? ""

        let rawStatus = (try c.decodeIfPresent(String.self, forKey: .status)) ?? ""
        // An unknown status reads as planned rather than throwing. The set can
        // only grow server-side, and a client shipped before it grew should
        // show the row rather than fail the whole list on one value it has
        // never heard of.
        status = Status(rawValue: rawStatus) ?? .planned
    }

    private static func stand(ref: String?, latitude: Double?, longitude: Double?) -> Stand? {
        guard let ref = ref?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty else {
            return nil
        }
        guard let latitude = latitude, let longitude = longitude else { return Stand(ref: ref) }
        return Stand(
            ref: ref,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        )
    }

    /// Postgres timestamps carry a variable number of fractional digits, which
    /// `.iso8601` alone rejects. `SupabaseAuth.Timestamp` already knows that,
    /// so this borrows it rather than keeping a second answer to the same
    /// question that could drift from the first.
    private static func date(_ text: String?) -> Date? {
        guard let text = text else { return nil }
        return SupabaseAuth.Timestamp.date(from: text)
    }
}

// MARK: - Writing one

extension PlannedFlight {

    /// The row to send.
    ///
    /// `NSNull` rather than omission for every optional, and that is the whole
    /// reason this is written out by hand rather than encoded. PostgREST leaves
    /// a column alone when a `PATCH` body has no key for it, so clearing a gate
    /// by omitting it would silently do nothing at all — the gate would stay,
    /// the app would show it gone, and the two would disagree until the next
    /// launch.
    ///
    /// The id is never sent: on an insert Postgres assigns it, and on a patch
    /// it is in the URL. Neither is `user_id`, `created_at` or `updated_at` —
    /// the trigger owns all three, and a client that sent them would be
    /// ignored anyway.
    var row: [String: Any] {
        var row: [String: Any] = [
            "origin_icao": originICAO.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            "destination_icao": destinationICAO.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            "status": status.rawValue,
        ]

        func text(_ value: String) -> Any {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? NSNull() : trimmed
        }

        row["callsign"] = text(callsign)
        row["aircraft"] = text(aircraft)
        row["livery"] = text(livery)
        row["remarks"] = text(remarks)

        row["departure_gate"] = departureStand.map { text($0.ref) } ?? NSNull()
        row["arrival_gate"] = arrivalStand.map { text($0.ref) } ?? NSNull()

        // Written out rather than bridged through `as Any?`, which is the trap
        // here: an optional cast to `Any?` comes back wrapped rather than nil,
        // so `?? NSNull()` never fires and a typed gate would post a `nil`
        // JSON-serialisation would refuse.
        func number(_ value: Double?) -> Any {
            guard let value = value else { return NSNull() }
            return value
        }

        row["departure_gate_latitude"] = number(departureStand?.coordinate?.latitude)
        row["departure_gate_longitude"] = number(departureStand?.coordinate?.longitude)
        row["arrival_gate_latitude"] = number(arrivalStand?.coordinate?.latitude)
        row["arrival_gate_longitude"] = number(arrivalStand?.coordinate?.longitude)

        row["scheduled_out"] = Self.stamp(scheduledOut)
        row["scheduled_in"] = Self.stamp(scheduledIn)

        return row
    }

    private static let outbound: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func stamp(_ date: Date?) -> Any {
        guard let date = date else { return NSNull() }
        return outbound.string(from: date)
    }
}
