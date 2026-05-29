import Foundation
import ActivityKit

@available(iOS 16.1, *)
public struct InflightActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var distanceToDestinationNm: Double
        public var currentETA: Date
        public var currentATD: Date?
        public var isLanded: Bool
        /// Wall-clock time the state was last pushed from the app. The widget
        /// uses this to decide whether the pushed `distanceToDestinationNm`
        /// is still fresh enough to trust, or whether it should advance the
        /// plane purely from the time-based estimate (so the marker keeps
        /// moving even when the app is backgrounded and can't push).
        public var lastUpdated: Date

        public init(distanceToDestinationNm: Double,
                    currentETA: Date,
                    currentATD: Date? = nil,
                    isLanded: Bool = false,
                    lastUpdated: Date = Date()) {
            self.distanceToDestinationNm = distanceToDestinationNm
            self.currentETA = currentETA
            self.currentATD = currentATD
            self.isLanded = isLanded
            self.lastUpdated = lastUpdated
        }
    }

    public var callsign: String
    public var airlineName: String
    /// Aircraft model/type, e.g. "Airbus A320-200" or "B738".
    public var aircraftType: String
    /// Painted livery, e.g. "United" or "Ryanair".
    public var liveryName: String
    /// Tail number / registration when known, e.g. "N12345".
    public var registration: String
    public var departureIcao: String
    public var arrivalIcao: String
    public var scheduledDeparture: Date
    public var scheduledArrival: Date
    /// Total great-circle distance between departure and arrival airports.
    /// Captured at start so we can render a progress bar that tracks the
    /// remaining-distance state field without recomputing geography on
    /// every refresh. Optional for back-compat with older callers --
    /// falls back to the initial remaining distance.
    public var totalDistanceNm: Double

    public init(callsign: String,
                airlineName: String,
                aircraftType: String = "",
                liveryName: String = "",
                registration: String = "",
                departureIcao: String,
                arrivalIcao: String,
                scheduledDeparture: Date,
                scheduledArrival: Date,
                totalDistanceNm: Double) {
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
    }
}
