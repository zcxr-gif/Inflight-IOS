import Foundation
import ActivityKit

@available(iOS 16.1, *)
public struct InflightActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var distanceToDestinationNm: Double
        public var currentETA: Date
        public var currentATD: Date?
        public var isLanded: Bool

        public init(distanceToDestinationNm: Double,
                    currentETA: Date,
                    currentATD: Date? = nil,
                    isLanded: Bool = false) {
            self.distanceToDestinationNm = distanceToDestinationNm
            self.currentETA = currentETA
            self.currentATD = currentATD
            self.isLanded = isLanded
        }
    }

    public var callsign: String
    public var airlineName: String
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
                departureIcao: String,
                arrivalIcao: String,
                scheduledDeparture: Date,
                scheduledArrival: Date,
                totalDistanceNm: Double) {
        self.callsign = callsign
        self.airlineName = airlineName
        self.departureIcao = departureIcao
        self.arrivalIcao = arrivalIcao
        self.scheduledDeparture = scheduledDeparture
        self.scheduledArrival = scheduledArrival
        self.totalDistanceNm = totalDistanceNm
    }
}
