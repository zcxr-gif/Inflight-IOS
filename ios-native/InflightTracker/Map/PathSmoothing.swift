import CoreLocation
import Foundation

/// Rounds off the corners of a flown path.
///
/// ## Why the path has corners at all
///
/// `FlightTrailStore` thins breadcrumbs by distance — two nautical miles apart
/// at first, and double that each time a long trail is halved. That is the
/// right trade for memory, but it means a turn the aeroplane flew as an arc
/// arrives as three or four points with hard angles between them, and a
/// polyline drawn straight through them looks like a route filed by somebody
/// with a ruler rather than a track flown by an aeroplane.
///
/// Interpolating puts the curve back. It invents nothing about *where* the
/// aircraft was — every original sample is still on the line, and the curve
/// only decides how to get between two of them — which is the same claim the
/// straight segment was already making, made more plausibly.
///
/// ## Catmull-Rom, and why not a Bézier
///
/// A Catmull-Rom spline passes *through* its control points. A Bézier does not,
/// so it would pull the drawn line off the samples we actually have, and the
/// aircraft would sit beside its own track in a turn. Passing through the data
/// is the whole requirement here.
///
/// ## Centripetal, and why not uniform
///
/// The uniform basis — which is what this was — spaces its parameter evenly
/// whatever the points do, and breadcrumbs are not evenly spaced. A trail is
/// thinned by *distance*, so a hold or a slow taxi puts several samples close
/// together and a cruise leg puts the next one eight miles away, and a uniform
/// spline through that overshoots: it swings wide of the short segment,
/// sometimes far enough to loop back over itself. A cusp in a flight path is a
/// claim the aeroplane turned inside out.
///
/// The centripetal parameterisation (alpha = 0.5) is the standard answer, and
/// it is provably free of both cusps and self-intersections. It costs four
/// square roots per segment and it is the reason the curve now reads as a
/// flight rather than as a ribbon someone shook.
enum PathSmoothing {

    /// How many points are generated between each pair of samples.
    ///
    /// Chosen against the size of the input rather than fixed, so a short trail
    /// gets a genuinely smooth curve and a long one does not turn into fifty
    /// thousand points. Four was the old figure for every case; on the tracks
    /// this actually draws — the store thins to a few hundred samples — it left
    /// the corners visibly faceted at any zoom close enough to see one.
    private static let minimumSubdivisions = 4
    private static let maximumSubdivisions = 14

    /// Roughly how many points the smoothed path should come out at.
    ///
    /// A budget rather than a limit: the subdivision count is this divided by
    /// the sample count, clamped. Three thousand is a few frames' work for
    /// MapKit and finer than any screen can resolve a curve at.
    private static let pointBudget = 3_000

    /// Above this many input points the path is left alone.
    ///
    /// A trail this long is a fourteen-hour flight whose samples are already
    /// four or eight miles apart; at that spacing the corners are gentle, and
    /// the smoothing would cost more than it shows.
    private static let maximumInput = 4_000

    /// The exponent that makes this centripetal. Uniform is 0, chordal is 1,
    /// and a half is the one that behaves.
    private static let alpha = 0.5

    /// Longitude jump that means the pair straddles the antimeridian rather
    /// than describing a turn. Interpolating across one would draw a line all
    /// the way around the world.
    private static let dateLineJump: CLLocationDegrees = 180

    /// A denser version of `coordinates`, curved through every original point,
    /// and which original point each one of them came from.
    ///
    /// The origins are what let the track be coloured exactly. Smoothing
    /// inserts points *between* samples, so a drawn point is not a sample and
    /// has no height of its own — but it does belong to a known piece of track,
    /// the one running from sample `origin` to the next. Colouring by that is
    /// exact, and it is the thing the old gradient could not do: it was handed
    /// fractions along the line and had to guess where on the curve they fell.
    ///
    /// `origins[i]` is an index into the *input*, and is non-decreasing.
    struct Curve {
        var coordinates: [CLLocationCoordinate2D]
        var origins: [Int]
    }

    /// Returns the input unchanged when there is nothing to gain: fewer than
    /// three points is already exactly the line between them.
    static func smoothedWithOrigins(_ coordinates: [CLLocationCoordinate2D]) -> Curve {
        guard coordinates.count >= 3, coordinates.count <= maximumInput else {
            return Curve(coordinates: coordinates, origins: Array(coordinates.indices))
        }

        let subdivisions = min(
            max(pointBudget / coordinates.count, minimumSubdivisions),
            maximumSubdivisions
        )

        var output: [CLLocationCoordinate2D] = []
        var origins: [Int] = []
        output.reserveCapacity(coordinates.count * subdivisions)
        origins.reserveCapacity(coordinates.count * subdivisions)
        output.append(coordinates[0])
        origins.append(0)

        for index in 0..<(coordinates.count - 1) {
            let p1 = coordinates[index]
            let p2 = coordinates[index + 1]

            // The two points either side, clamped at the ends so the first and
            // last segments still curve rather than kinking into the endpoint.
            let p0 = coordinates[max(index - 1, 0)]
            let p3 = coordinates[min(index + 2, coordinates.count - 1)]

            // Anything crossing the date line is emitted straight. The spline
            // has no idea longitude wraps, and would take the long way round.
            let straddles = abs(p0.longitude - p1.longitude) > dateLineJump
                || abs(p1.longitude - p2.longitude) > dateLineJump
                || abs(p2.longitude - p3.longitude) > dateLineJump
            guard !straddles else {
                output.append(p2)
                origins.append(index)
                continue
            }

            let before = output.count
            append(
                segmentFrom: p0, p1, p2, p3,
                subdivisions: subdivisions,
                into: &output
            )
            // Everything this segment produced belongs to the piece of track
            // that starts at `index`, whether it emitted a whole curve or gave
            // up and emitted one point.
            origins.append(contentsOf: repeatElement(index, count: output.count - before))
        }

        return Curve(coordinates: output, origins: origins)
    }

    /// One segment of the curve — the piece between `p1` and `p2`, shaped by
    /// its neighbours.
    private static func append(
        segmentFrom p0: CLLocationCoordinate2D,
        _ p1: CLLocationCoordinate2D,
        _ p2: CLLocationCoordinate2D,
        _ p3: CLLocationCoordinate2D,
        subdivisions: Int,
        into output: inout [CLLocationCoordinate2D]
    ) {
        // The knots: each one further along than the last by the distance
        // between its points, raised to alpha. This is the whole difference
        // between centripetal and uniform — uniform is these four being 0, 1,
        // 2, 3 whatever the points do.
        let t0 = 0.0
        let t1 = t0 + knotSpan(p0, p1)
        let t2 = t1 + knotSpan(p1, p2)
        let t3 = t2 + knotSpan(p2, p3)

        // Coincident samples collapse a span to nothing, and a zero span is a
        // division by zero two lines further down. Two points in the same place
        // have no curve between them anyway.
        guard t1 > t0, t2 > t1, t3 > t2 else {
            output.append(p2)
            return
        }

        for step in 1...subdivisions {
            let t = t1 + (t2 - t1) * Double(step) / Double(subdivisions)
            output.append(
                CLLocationCoordinate2D(
                    latitude: interpolate(
                        p0.latitude, p1.latitude, p2.latitude, p3.latitude,
                        t0, t1, t2, t3, t
                    ),
                    longitude: interpolate(
                        p0.longitude, p1.longitude, p2.longitude, p3.longitude,
                        t0, t1, t2, t3, t
                    )
                )
            )
        }
    }

    /// How far along the knot vector one segment carries: its length, raised to
    /// alpha. In degrees, which is not a distance — but it is the same scale on
    /// both axes at the latitudes traffic actually flies, and the parameter
    /// only has to be monotonic and roughly proportional for the curve to
    /// behave.
    private static func knotSpan(
        _ from: CLLocationCoordinate2D,
        _ to: CLLocationCoordinate2D
    ) -> Double {
        let dx = to.longitude - from.longitude
        let dy = to.latitude - from.latitude
        return pow((dx * dx + dy * dy).squareRoot(), alpha)
    }

    /// Barry-Goldman: three rounds of linear interpolation up the knot vector,
    /// which evaluates the non-uniform Catmull-Rom spline without ever building
    /// its basis matrix. One axis at a time.
    private static func interpolate(
        _ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double,
        _ t0: Double, _ t1: Double, _ t2: Double, _ t3: Double,
        _ t: Double
    ) -> Double {
        let a1 = (t1 - t) / (t1 - t0) * p0 + (t - t0) / (t1 - t0) * p1
        let a2 = (t2 - t) / (t2 - t1) * p1 + (t - t1) / (t2 - t1) * p2
        let a3 = (t3 - t) / (t3 - t2) * p2 + (t - t2) / (t3 - t2) * p3

        let b1 = (t2 - t) / (t2 - t0) * a1 + (t - t0) / (t2 - t0) * a2
        let b2 = (t3 - t) / (t3 - t1) * a2 + (t - t1) / (t3 - t1) * a3

        return (t2 - t) / (t2 - t1) * b1 + (t - t1) / (t2 - t1) * b2
    }
}
