import CoreLocation
import Foundation

/// What the wind is doing to each end of each runway at a field.
///
/// The one piece of arithmetic that turns a weather panel into something you
/// can fly off. A wind of "220 at 18, gusting 27" is four numbers; what a pilot
/// actually wants out of it is *which runway that favours* and *how much of it
/// is across* — and that is a calculation nobody should be doing in their head
/// on the way to the aeroplane.
///
/// ## Where the runways come from
///
/// `AirportLayoutStore` — the same OpenStreetMap pavement the ground chart is
/// drawn from, already fetched and cached for a month. The geometry is what is
/// trusted for the bearing, not the number painted on the threshold: a runway
/// designator is *magnetic*, rounded to the nearest ten degrees, and often
/// years out of date at high latitudes where the variation moves fastest. The
/// centreline drawn on the map is true, now, and to the metre.
///
/// The painted number is still used, for the one thing it is unambiguous
/// about: which *end* is which. A centreline is a line with two directions and
/// no opinion about them; `09L/27R` says which of the two reciprocals is
/// called what.
///
/// ## Which wind
///
/// Whichever the field has. A METAR wind where one was filed — it is the
/// observation, and it is what an ATIS is reading from — and Apple's otherwise.
/// Both are *true* directions, which is what makes them comparable with the
/// geometry: the wind group in a METAR body is true north, and the magnetic
/// figure a tower reads you is a courtesy done on the ground.
struct RunwayWind: Identifiable {

    /// A wind, from either source, in the units the arithmetic wants.
    struct Wind: Equatable {
        /// The direction it is blowing *from*, true.
        let fromDegrees: Double
        let speedKnots: Double
        let gustKnots: Double?

        /// A METAR's wind, where it has one worth using.
        ///
        /// Nil for calm and nil for variable: a runway favoured by a wind with
        /// no direction is a recommendation with nothing behind it, and
        /// "VRB03KT" is the report saying so itself.
        init?(metar: Metar) {
            guard let direction = metar.windDirectionDegrees,
                  let speed = metar.windSpeedKnots, speed >= 2 else { return nil }
            self.fromDegrees = Double(direction)
            self.speedKnots = Double(speed)
            self.gustKnots = metar.windGustKnots.map { Double($0) }
        }

        init(fromDegrees: Double, speedKnots: Double, gustKnots: Double?) {
            self.fromDegrees = fromDegrees
            self.speedKnots = speedKnots
            self.gustKnots = gustKnots
        }
    }

    /// `27R`, as it is painted.
    let designator: String

    /// True, from the centreline as mapped.
    let trueBearing: Double

    /// Along the runway. Negative is a tailwind.
    let headwindKnots: Double

    /// Across it. Positive is from the right of somebody using this end.
    let crosswindKnots: Double

    /// The same, worked from the gust rather than the mean, where one is
    /// reported. This is the number that decides whether a landing is on.
    let gustCrosswindKnots: Double?

    var id: String { designator }

    var isTailwind: Bool { headwindKnots < -0.5 }

    /// "12 kt down the runway, 4 from the left" — the whole point, in a line.
    ///
    /// Rounded to whole knots because that is the resolution the wind was
    /// reported at; a crosswind quoted to a decimal place from a wind given to
    /// the nearest knot is precision that was never there.
    func summary(showingGust: Bool = true) -> String {
        var parts: [String] = []

        let along = Int(abs(headwindKnots).rounded())
        if along >= 1 {
            parts.append("\(along) kt \(isTailwind ? "on the tail" : "down the runway")")
        }

        let across = Int(abs(crosswindKnots).rounded())
        if across >= 1 {
            parts.append("\(across) kt from the \(crosswindKnots >= 0 ? "right" : "left")")
        }

        if parts.isEmpty { return "Straight down the runway, and barely blowing." }

        if showingGust, let gust = gustCrosswindKnots {
            let gusting = Int(abs(gust).rounded())
            if gusting > across {
                parts.append("\(gusting) across in the gusts")
            }
        }

        return parts.joined(separator: ", ")
    }

    // MARK: - Working them out

    /// Every runway end at a field, best first.
    ///
    /// "Best" is the most headwind, which is the only ordering that needs no
    /// judgement about aircraft type, surface or length — all of which this
    /// knows nothing about and should not pretend to. It is a wind
    /// calculation, not a recommendation, and the copy around it says so.
    static func components(for layout: AirportLayout, wind: Wind) -> [RunwayWind] {
        var byDesignator: [String: RunwayWind] = [:]

        for runway in layout.runways {
            guard let ref = runway.ref?.trimmingCharacters(in: .whitespaces), !ref.isEmpty,
                  let centreline = bearing(of: runway) else { continue }

            let ends = ref
                .split(whereSeparator: { $0 == "/" || $0 == "-" })
                .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                .filter { !$0.isEmpty }

            for (index, end) in ends.enumerated() {
                let heading = self.heading(of: end, centreline: centreline, isSecond: index == 1)
                let component = RunwayWind(designator: end, trueBearing: heading, wind: wind)

                // A field whose apron is mapped twice, or whose runway is
                // drawn in two pieces, would otherwise list 27R twice. The
                // first wins: they are the same strip of concrete and the same
                // answer either way.
                if byDesignator[end] == nil { byDesignator[end] = component }
            }
        }

        return byDesignator.values.sorted { first, second in
            first.headwindKnots == second.headwindKnots
                ? first.designator < second.designator
                : first.headwindKnots > second.headwindKnots
        }
    }

    private init(designator: String, trueBearing: Double, wind: Wind) {
        self.designator = designator
        self.trueBearing = trueBearing

        // The angle between where the wind is coming from and where this end
        // points. Zero is straight down the runway.
        let offset = (wind.fromDegrees - trueBearing) * .pi / 180

        self.headwindKnots = wind.speedKnots * cos(offset)
        self.crosswindKnots = wind.speedKnots * sin(offset)
        self.gustCrosswindKnots = wind.gustKnots.map { $0 * sin(offset) }
    }

    /// The centreline's true bearing, from the first mapped point to the last.
    ///
    /// End to end rather than segment to segment: a runway is straight, and
    /// the two points furthest apart are the least sensitive to a wobble in
    /// how somebody traced it.
    private static func bearing(of runway: AirportLayout.Piece) -> Double? {
        guard let first = runway.coordinates.first,
              let last = runway.coordinates.last,
              FlightProgress.distanceNM(from: first, to: last) > 0.05 else { return nil }

        return FlightProgress.bearingDegrees(from: first, to: last)
    }

    /// Which way this *end* points, given a centreline that has two directions.
    ///
    /// The designator decides, where it is a number: `27` is about 270°, so of
    /// the centreline and its reciprocal it takes whichever is nearer. That
    /// tolerates the several degrees of magnetic variation between a painted
    /// number and the true bearing without ever letting it flip the end round,
    /// because the two candidates are 180° apart and the error is nowhere near
    /// 90°.
    ///
    /// Where the designator is not a number — the handful of fields that name a
    /// strip rather than number it — the drawn order is all there is, so the
    /// first end takes the centreline and the second its reciprocal.
    private static func heading(of end: String, centreline: Double, isSecond: Bool) -> Double {
        let reciprocal = (centreline + 180).truncatingRemainder(dividingBy: 360)

        let digits = end.prefix(while: { $0.isNumber })
        guard let number = Int(digits), number >= 1, number <= 36 else {
            return isSecond ? reciprocal : centreline
        }

        let painted = Double(number) * 10
        return difference(painted, centreline) <= difference(painted, reciprocal) ? centreline : reciprocal
    }

    /// The smaller of the two ways round a circle, in degrees.
    private static func difference(_ first: Double, _ second: Double) -> Double {
        let raw = abs(first - second).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }
}
