import CoreLocation
import Foundation

/// One sample on a flight's path.
///
/// Both sources produce these: the backend's breadcrumb history, and the live
/// feed as it ticks, so the map and the window don't care which part of a path
/// they are looking at.
struct TrackPoint {
    let coordinate: CLLocationCoordinate2D
    let altitudeFeet: Double
    let groundSpeedKnots: Double
    let date: Date?
}

extension TrackPoint {

    /// Whether this sample was taken off the ground.
    ///
    /// The same rule the phase chip uses — see `FlightPhase.from` — rather than
    /// a second, private notion of "flying" that could disagree with the word
    /// printed next to the callsign. It is deliberately coarse: an aeroplane
    /// past forty knots is treated as away, so a fast take-off roll counts as
    /// airborne for the few seconds before the wheels actually leave. Nothing
    /// downstream is quoted to the second.
    var isAirborne: Bool {
        !(groundSpeedKnots < 40 && altitudeFeet < 10_000)
    }

    /// When the aircraft last left the ground, as far as this path shows.
    ///
    /// Read backwards for the newest sample still on the ground; the sample
    /// after it is the earliest moment the path knows the aircraft was flying.
    /// Backwards rather than forwards because an aeroplane can do the trip
    /// twice on one flight id — a touch and go, a diversion, a pilot who
    /// respawned — and the question is always about the leg being flown now.
    ///
    /// Nil in the two cases where there is no honest answer: the aircraft is on
    /// the ground, so the last leg is over; or the path holds no ground sample
    /// at all, because the window was opened on a flight already at cruise and
    /// the backend's history does not reach back to the runway.
    static func lastTakeoff(in track: [TrackPoint]) -> Date? {
        guard let ground = track.lastIndex(where: { !$0.isAirborne }) else { return nil }
        let after = track.index(after: ground)
        guard after < track.endIndex else { return nil }
        return track[after...].compactMap(\.date).first
    }

    /// ...and when it last touched down. The same walk the other way up.
    static func lastLanding(in track: [TrackPoint]) -> Date? {
        guard let air = track.lastIndex(where: { $0.isAirborne }) else { return nil }
        let after = track.index(after: air)
        guard after < track.endIndex else { return nil }
        return track[after...].compactMap(\.date).first
    }
}
