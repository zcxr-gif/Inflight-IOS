import ActivityKit
import Foundation

/// The Live Activity's contract with the backend.
///
/// Ported from the Capacitor build's widget (`old/native-ios/InflightLiveActivity`)
/// because the backend already pushes exactly this shape — changing the names
/// here would break every activity already running on a shipped build.
///
/// Both halves decode by hand rather than through the synthesized `Codable`,
/// and that is the whole point of the file. A pushed activity is decoded
/// inside the system's widget process: if decoding throws, nothing surfaces —
/// no crash, no log the app can see, just an activity that never appears or
/// never moves again. The synthesized decoder throws on any key the payload
/// doesn't carry, *including* keys whose property has a default value, which
/// is precisely how the update pushes managed to fail silently for as long as
/// they did. Decoding every field with `decodeIfPresent` and a fallback means
/// a backend that is a version behind (or ahead) degrades a reading rather
/// than the whole banner.
public struct InflightActivityAttributes: ActivityAttributes {

    public struct ContentState: Codable, Hashable {

        /// Great-circle distance still to run. Refreshed on each push.
        public var distanceToDestinationNm: Double

        /// Live estimate of arrival, or nil when there is nothing to estimate
        /// from — an aircraft still at its gate has no ground speed to divide
        /// a distance by. It used to be a plain `Date` defaulted to *now*,
        /// which is why a banner started before pushback read "Arriving" from
        /// the moment it appeared.
        public var currentETA: Date?

        /// Actual time of departure, when the backend knows it. The live API
        /// doesn't expose one, so this is usually absent.
        public var currentATD: Date?

        public var isLanded: Bool

        /// When the backend last pushed. The widget uses it to decide whether
        /// `distanceToDestinationNm` is still worth trusting, or whether it
        /// should fall back to advancing the aircraft on the clock alone —
        /// which is what keeps the marker moving between pushes.
        public var lastUpdated: Date

        public var altitudeFt: Int
        public var groundSpeedKt: Int

        public init(distanceToDestinationNm: Double,
                    currentETA: Date?,
                    currentATD: Date? = nil,
                    isLanded: Bool = false,
                    lastUpdated: Date = Date(),
                    altitudeFt: Int = 0,
                    groundSpeedKt: Int = 0) {
            self.distanceToDestinationNm = distanceToDestinationNm
            self.currentETA = currentETA
            self.currentATD = currentATD
            self.isLanded = isLanded
            self.lastUpdated = lastUpdated
            self.altitudeFt = altitudeFt
            self.groundSpeedKt = groundSpeedKt
        }

        private enum CodingKeys: String, CodingKey {
            case distanceToDestinationNm, currentETA, currentATD, isLanded
            case lastUpdated, altitudeFt, groundSpeedKt
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            distanceToDestinationNm = try box.decodeIfPresent(Double.self, forKey: .distanceToDestinationNm) ?? 0
            currentETA = try box.decodeIfPresent(Date.self, forKey: .currentETA)
            currentATD = try box.decodeIfPresent(Date.self, forKey: .currentATD)
            isLanded = try box.decodeIfPresent(Bool.self, forKey: .isLanded) ?? false
            // An older backend sends no timestamp; treating that as "now" makes
            // the reading look fresh, which is the right call — the alternative
            // is a widget that immediately distrusts every value it was given.
            lastUpdated = try box.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
            altitudeFt = try box.decodeIfPresent(Int.self, forKey: .altitudeFt) ?? 0
            groundSpeedKt = try box.decodeIfPresent(Int.self, forKey: .groundSpeedKt) ?? 0
        }
    }

    public var callsign: String
    public var airlineName: String

    /// Aircraft model/type, e.g. "Airbus A320-200".
    public var aircraftType: String

    /// Painted livery, e.g. "United". Also the key half of the lookup that
    /// finds the photo the banner is drawn on.
    public var liveryName: String

    /// Tail number when known, e.g. "N12345".
    public var registration: String

    public var departureIcao: String
    public var arrivalIcao: String
    public var scheduledDeparture: Date
    public var scheduledArrival: Date

    /// Total great-circle distance between the two fields, captured at start so
    /// the progress bar can track remaining distance without recomputing any
    /// geography on every render.
    public var totalDistanceNm: Double

    /// Whose flight this is. Empty when the activity was started from the
    /// flight window rather than by a watched pilot's takeoff.
    public var pilotUsername: String

    /// The backend's id for this flight.
    ///
    /// Carried in the attributes specifically so an activity the *server*
    /// started can be matched back to an aircraft on the map. The app never
    /// saw that activity begin, so this is the only thing tying the banner in
    /// the Dynamic Island to a row in the friends list.
    public var flightId: String

    public init(callsign: String,
                airlineName: String = "",
                aircraftType: String = "",
                liveryName: String = "",
                registration: String = "",
                departureIcao: String,
                arrivalIcao: String,
                scheduledDeparture: Date,
                scheduledArrival: Date,
                totalDistanceNm: Double,
                pilotUsername: String = "",
                flightId: String = "") {
        self.callsign = callsign
        self.airlineName = airlineName
        self.aircraftType = aircraftType
        self.liveryName = liveryName
        self.registration = registration
        self.departureIcao = departureIcao
        self.arrivalIcao = arrivalIcao
        self.scheduledDeparture = scheduledDeparture
        self.scheduledArrival = scheduledArrival
        self.totalDistanceNm = totalDistanceNm
        self.pilotUsername = pilotUsername
        self.flightId = flightId
    }

    private enum CodingKeys: String, CodingKey {
        case callsign, airlineName, aircraftType, liveryName, registration
        case departureIcao, arrivalIcao, scheduledDeparture, scheduledArrival
        case totalDistanceNm, pilotUsername, flightId
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        callsign = try box.decodeIfPresent(String.self, forKey: .callsign) ?? "Flight"
        airlineName = try box.decodeIfPresent(String.self, forKey: .airlineName) ?? ""
        aircraftType = try box.decodeIfPresent(String.self, forKey: .aircraftType) ?? ""
        liveryName = try box.decodeIfPresent(String.self, forKey: .liveryName) ?? ""
        registration = try box.decodeIfPresent(String.self, forKey: .registration) ?? ""
        departureIcao = try box.decodeIfPresent(String.self, forKey: .departureIcao) ?? "————"
        arrivalIcao = try box.decodeIfPresent(String.self, forKey: .arrivalIcao) ?? "————"
        scheduledDeparture = try box.decodeIfPresent(Date.self, forKey: .scheduledDeparture) ?? Date()
        scheduledArrival = try box.decodeIfPresent(Date.self, forKey: .scheduledArrival) ?? Date()
        totalDistanceNm = try box.decodeIfPresent(Double.self, forKey: .totalDistanceNm) ?? 0
        pilotUsername = try box.decodeIfPresent(String.self, forKey: .pilotUsername) ?? ""
        flightId = try box.decodeIfPresent(String.self, forKey: .flightId) ?? ""
    }

    /// The arrival time known when the banner started, or nil when there was
    /// none to be had.
    ///
    /// The attributes of a running activity cannot be changed, so an estimate
    /// that did not exist at the start can never be filled in here — it lives
    /// in `ContentState.currentETA` instead. Written as arrival == departure
    /// rather than as an optional because the shape is the backend's, and this
    /// file does not get to add fields to it.
    public var plannedArrival: Date? {
        scheduledArrival > scheduledDeparture ? scheduledArrival : nil
    }

    /// Which cached photo this flight's banner is drawn on.
    public var photoKey: String { PhotoKey.make(type: aircraftType, livery: liveryName) }

    /// "Airbus A320 · United", skipping empties and not saying the same word
    /// twice when the livery already names the type.
    public var aircraftDescriptor: String {
        let type = aircraftType.trimmingCharacters(in: .whitespaces)
        let livery = liveryName.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !type.isEmpty { parts.append(type) }
        if !livery.isEmpty, livery.caseInsensitiveCompare(type) != .orderedSame { parts.append(livery) }
        return parts.joined(separator: " · ")
    }
}
