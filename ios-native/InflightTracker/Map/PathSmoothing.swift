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

    /// A point on the drawn curve, and where it came from.
    ///
    /// `progress` is the position in the *input*: the index of the sample this
    /// point follows, plus how far along to the next one. 3.25 is a quarter of
    /// the way from sample 3 to sample 4.
    ///
    /// Carried because the curve is denser than the samples and everything
    /// drawn along it — the altitude colour above all — is known only at the
    /// samples. Without this the colour has to be snapped to the nearest
    /// sample, which puts a step every two miles back into a ramp whose whole
    /// point is that it does not step.
    struct Point {
        let coordinate: CLLocationCoordinate2D
        let progress: Double
    }

    /// How many points are generated between each pair of samples.
    ///
    /// Chosen against the size of the input rather than fixed, so a short trail
    /// gets a genuinely smooth curve and a long one does not turn into fifty
    /// thousand points. Four was the old figure for every case; on the tracks
    /// this actually draws — the store thins to a few hundred samples — it left
    /// the corners visibly faceted at any zoom close enough to see one.
    private static let minimumSubdivisions = 4
    private static let maximumSubdivisions = 36

    /// Roughly how many points the smoothed path should come out at.
    ///
    /// A budget rather than a limit: the subdivision count is this divided by
    /// the sample count, clamped.
    ///
    /// It was three thousand, on the reasoning that a denser curve is more for
    /// MapKit to stroke. That reasoning belonged to a renderer that stroked
    /// every point it was given, however little of the track was on screen.
    /// `FlownPathRenderer` resamples to about a point of screen per segment
    /// before it draws anything, so density here costs memory and the walk that
    /// discards it — a few hundred kilobytes and some tens of microseconds a
    /// tile — and costs nothing at all in drawing.
    ///
    /// Which is worth spending, because the old figure was the reason a track
    /// went faceted when you looked at one turn closely: a point every fifth of
    /// a mile is a corner every hundred pixels once you are close enough. This
    /// is a point every sixteenth of one on the trails that actually draw.
    private static let pointBudget = 9_000

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

    /// A denser version of `coordinates`, curved through every original point.
    ///
    /// Returns the input unchanged when there is nothing to gain: fewer than
    /// three points is already exactly the line between them.
    static func smoothed(_ coordinates: [CLLocationCoordinate2D]) -> [Point] {
        guard coordinates.count >= 3, coordinates.count <= maximumInput else {
            return coordinates.enumerated().map {
                Point(coordinate: $0.element, progress: Double($0.offset))
            }
        }

        let subdivisions = min(
            max(pointBudget / coordinates.count, minimumSubdivisions),
            maximumSubdivisions
        )

        var output: [Point] = []
        output.reserveCapacity(coordinates.count * subdivisions)
        output.append(Point(coordinate: coordinates[0], progress: 0))

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
                output.append(Point(coordinate: p2, progress: Double(index + 1)))
                continue
            }

            append(
                segmentFrom: p0, p1, p2, p3,
                index: index,
                subdivisions: subdivisions,
                into: &output
            )
        }

        return output
    }

    /// One segment of the curve — the piece between `p1` and `p2`, shaped by
    /// its neighbours.
    private static func append(
        segmentFrom p0: CLLocationCoordinate2D,
        _ p1: CLLocationCoordinate2D,
        _ p2: CLLocationCoordinate2D,
        _ p3: CLLocationCoordinate2D,
        index: Int,
        subdivisions: Int,
        into output: inout [Point]
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
            output.append(Point(coordinate: p2, progress: Double(index + 1)))
            return
        }

        for step in 1...subdivisions {
            let fraction = Double(step) / Double(subdivisions)
            let t = t1 + (t2 - t1) * fraction
            output.append(
                Point(
                    coordinate: CLLocationCoordinate2D(
                        latitude: interpolate(
                            p0.latitude, p1.latitude, p2.latitude, p3.latitude,
                            t0, t1, t2, t3, t
                        ),
                        longitude: interpolate(
                            p0.longitude, p1.longitude, p2.longitude, p3.longitude,
                            t0, t1, t2, t3, t
                        )
                    ),
                    // The knot parameter is not the fraction — that is the
                    // whole point of the centripetal basis — but the samples
                    // either side of this point are still `index` and
                    // `index + 1`, and the step count is even between them.
                    // That is what the colour needs, and it is all it needs.
                    progress: Double(index) + fraction
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
