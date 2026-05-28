import Foundation
import ActivityKit

@available(iOS 16.1, *)
public struct InflightActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Remaining great-circle distance to the destination (nm). Drives
        /// both the "NM remaining" readout and the plane's position on the
        /// progress line.
        public var distanceToDestinationNm: Double
        /// Total great-circle distance departure → arrival (nm). Lives in
        /// the (mutable) content state -- not the attributes -- so it can be
        /// corrected on a later push if the departure airport's coordinates
        /// weren't known yet when the activity started. A stale/zero total
        /// here is what previously pinned the plane at 0% forever.
        public var totalDistanceNm: Double
        /// Live estimated time of arrival. The lock-screen / Dynamic Island
        /// countdown is rendered with `Text(timerInterval:)` against this
        /// date, so it stays accurate to the second even while the phone is
        /// locked and the app is suspended.
        public var currentETA: Date
        /// Scheduled (filed) departure + arrival. Mutable so that a filed
        /// plan that loads *after* the activity starts can correct the times
        /// shown under each airport -- the root cause of a pinned activity
        /// showing the wrong departure / arrival time.
        public var scheduledDeparture: Date
        public var scheduledArrival: Date
        /// Actual time of departure -- only set once we have real GPS history
        /// confirming the aircraft is airborne.
        public var currentATD: Date?
        public var isLanded: Bool

        public init(distanceToDestinationNm: Double,
                    totalDistanceNm: Double,
                    currentETA: Date,
                    scheduledDeparture: Date,
                    scheduledArrival: Date,
                    currentATD: Date? = nil,
                    isLanded: Bool = false) {
            self.distanceToDestinationNm = distanceToDestinationNm
            self.totalDistanceNm = totalDistanceNm
            self.currentETA = currentETA
            self.scheduledDeparture = scheduledDeparture
            self.scheduledArrival = scheduledArrival
            self.currentATD = currentATD
            self.isLanded = isLanded
        }
    }

    // Static identity -- never changes for the life of the activity.
    public var callsign: String
    public var airlineName: String
    public var departureIcao: String
    public var arrivalIcao: String

    public init(callsign: String,
                airlineName: String,
                departureIcao: String,
                arrivalIcao: String) {
        self.callsign = callsign
        self.airlineName = airlineName
        self.departureIcao = departureIcao
        self.arrivalIcao = arrivalIcao
    }
}
