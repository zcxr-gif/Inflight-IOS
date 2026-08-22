import CoreLocation
import Foundation

/// Two points on the map and the leg between them.
///
/// A ruler, which every serious map has and this one did not: how far is that
/// aircraft from the field it is diverting to, how long is that leg really,
/// what heading would you fly it on. All of it is geometry the app already
/// knows how to do — the same great-circle maths the route cards use — with
/// nowhere to put the answer until now.
struct MapMeasurement: Equatable {

    /// Whether the map is in measuring mode. Held apart from the two points so
    /// that leaving the mode and coming back to it keeps the last leg, which
    /// is almost always what somebody wants when they tap the ruler again.
    var isOn = false

    var start: CLLocationCoordinate2D?
    var end: CLLocationCoordinate2D?

    /// A leg only exists once both ends do.
    var isComplete: Bool { start != nil && end != nil }

    var distanceNM: Double? {
        guard let start = start, let end = end else { return nil }
        return FlightProgress.distanceNM(from: start, to: end)
    }

    /// Initial great-circle bearing. The *initial* one, because on a long leg
    /// the heading changes the whole way along it and the number at the start
    /// is the only one a single figure can honestly be.
    var bearingDegrees: Double? {
        guard let start = start, let end = end else { return nil }
        return FlightProgress.bearingDegrees(from: start, to: end)
    }

    /// Adds the next point.
    ///
    /// The third tap starts again rather than doing nothing or silently moving
    /// an end: with two points down, another tap on the map is somebody
    /// measuring something else.
    mutating func add(_ coordinate: CLLocationCoordinate2D) {
        if start == nil {
            start = coordinate
        } else if end == nil {
            end = coordinate
        } else {
            start = coordinate
            end = nil
        }
    }

    mutating func clear() {
        start = nil
        end = nil
    }

    static func == (lhs: MapMeasurement, rhs: MapMeasurement) -> Bool {
        lhs.isOn == rhs.isOn
            && Self.same(lhs.start, rhs.start)
            && Self.same(lhs.end, rhs.end)
    }

    private static func same(
        _ lhs: CLLocationCoordinate2D?,
        _ rhs: CLLocationCoordinate2D?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (a?, b?): return a.latitude == b.latitude && a.longitude == b.longitude
        default: return false
        }
    }
}

extension MapMeasurement {

    /// The distance, in both of the units anybody asks it in.
    var distanceLabel: String? {
        guard let nm = distanceNM, nm.isFinite else { return nil }
        let km = nm * 1.852
        return "\(Format.number(nm)) NM · \(Format.number(km)) km"
    }

    /// Roughly how long it would take. Deliberately vague about the aircraft:
    /// it is a sense of scale, not a flight plan, so it says the speed it
    /// assumed rather than pretending to know the aeroplane.
    var timeLabel: String? {
        guard let nm = distanceNM, nm > 1 else { return nil }
        let hours = nm / Self.assumedCruiseKnots
        return "\(Format.duration(hours * 3600)) at \(Int(Self.assumedCruiseKnots)) kts"
    }

    /// A middling jet cruise. Round, and stated wherever the estimate is shown.
    private static let assumedCruiseKnots: Double = 450

    /// The nearest field to each end, when there is one close enough to be
    /// what the tap meant.
    func endpointLabel(for coordinate: CLLocationCoordinate2D?) -> String? {
        guard let coordinate = coordinate else { return nil }
        guard let airport = AirportStore.shared.nearestAirport(
            to: coordinate,
            withinNM: Self.snapNM
        ) else {
            return Self.coordinateLabel(coordinate)
        }
        return airport.icao
    }

    /// How close a tap has to land to a field before the readout names it
    /// rather than reading out degrees. Wide enough to catch "I meant that
    /// airport", narrow enough not to claim one you were nowhere near.
    private static let snapNM: Double = 12

    /// Degrees and minutes, the way a position is written.
    static func coordinateLabel(_ coordinate: CLLocationCoordinate2D) -> String {
        func part(_ value: Double, _ positive: String, _ negative: String) -> String {
            let magnitude = abs(value)
            let degrees = Int(magnitude)
            let minutes = Int(((magnitude - Double(degrees)) * 60).rounded())
            return String(format: "%d°%02d'%@", degrees, minutes, value >= 0 ? positive : negative)
        }
        return "\(part(coordinate.latitude, "N", "S")) \(part(coordinate.longitude, "E", "W"))"
    }
}
