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
enum PathSmoothing {

    /// How many points are generated between each pair of samples.
    ///
    /// Four is enough to read as a curve at any zoom the map offers and keeps
    /// the overlay's point count to five times the trail's, which for a thinned
    /// long-haul is still a few thousand — well inside what MapKit draws
    /// without complaint.
    private static let subdivisions = 4

    /// Above this many input points the path is left alone.
    ///
    /// A trail this long is a fourteen-hour flight whose samples are already
    /// four or eight miles apart; at that spacing the corners are gentle, and
    /// the smoothing would cost more than it shows.
    private static let maximumInput = 2_000

    /// Longitude jump that means the pair straddles the antimeridian rather
    /// than describing a turn. Interpolating across one would draw a line all
    /// the way around the world.
    private static let dateLineJump: CLLocationDegrees = 180

    /// A denser version of `coordinates`, curved through every original point.
    ///
    /// Returns the input unchanged when there is nothing to gain: fewer than
    /// three points is already exactly the line between them.
    static func smoothed(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        guard coordinates.count >= 3, coordinates.count <= maximumInput else { return coordinates }

        var output: [CLLocationCoordinate2D] = []
        output.reserveCapacity(coordinates.count * subdivisions)
        output.append(coordinates[0])

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
                continue
            }

            for step in 1...subdivisions {
                let t = Double(step) / Double(subdivisions)
                output.append(
                    CLLocationCoordinate2D(
                        latitude: catmullRom(p0.latitude, p1.latitude, p2.latitude, p3.latitude, t),
                        longitude: catmullRom(p0.longitude, p1.longitude, p2.longitude, p3.longitude, t)
                    )
                )
            }
        }

        return output
    }

    /// The uniform Catmull-Rom basis, evaluated on one axis.
    private static func catmullRom(_ p0: Double, _ p1: Double, _ p2: Double, _ p3: Double, _ t: Double) -> Double {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2 * p1)
            + (-p0 + p2) * t
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
            + (-p0 + 3 * p1 - 3 * p2 + p3) * t3
        )
    }
}
