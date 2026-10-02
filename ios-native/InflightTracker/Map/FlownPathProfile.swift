import CoreLocation
import Foundation

/// The flown path in the air: at the height the aeroplane flew it, so it runs
/// up off the runway, along the cruise and down again, and arrives exactly
/// at the 3D aircraft at the end of it.
///
/// ## How Mapbox is told the heights
///
/// A line in Mapbox has one geometry and no third coordinate, but its
/// `line-z-offset` can be worked out per vertex from how far along the line
/// that vertex is (`line-progress`). So every run of the path carries its
/// heights as one array, sampled at even steps of distance from one end to
/// the other, and the expression reads the array at the vertex's progress.
/// The distance is measured the way Mapbox measures it — straight lines on
/// the Web Mercator square — or the heights would slide along the line
/// wherever the track runs north or south.
///
/// ## Which heights
///
/// The same as the aeroplane's (`AircraftAttitude.heightMetres`): above the
/// field it was last seen on the ground at, through
/// `AircraftModelStyle.drawnLift`, so the track and the model meet. Real
/// heights, the same at every zoom.
enum FlownPathProfile {

    /// The most samples one run's heights are written as. A run is drawn
    /// with no more vertices than this in any ordinary flight, and Mapbox
    /// interpolates between samples, so more would buy nothing.
    static let maximumSamples = 768

    // MARK: - Heights

    /// Each sample's height above the ground, in metres, and the altitude of
    /// the field the track was last on the ground at.
    ///
    /// Above whichever field the aeroplane last stood on before that sample —
    /// or the first one after it, for the part of a track before any ground —
    /// so the taxi sits on the ground and the climb starts from it, wherever
    /// the field is. A sample with no height sent (`bands` nil) takes the
    /// height between its neighbours that have one, rather than dropping to
    /// the ground and back.
    static func heights(of points: [TrackPoint], bands: [Int?]) -> (heights: [Double], groundFeet: Double?) {
        guard !points.isEmpty, bands.count == points.count else { return ([], nil) }

        // The field under each sample: the last ground before it.
        var reference = [Double?](repeating: nil, count: points.count)
        var lastGround: Double?
        for index in points.indices {
            if bands[index] != nil, !points[index].isAirborne { lastGround = points[index].altitudeFeet }
            reference[index] = lastGround
        }
        // ...and before any, the first one after.
        let firstGround = points.indices.first { bands[$0] != nil && !points[$0].isAirborne }
            .map { points[$0].altitudeFeet }

        var known = [Double?](repeating: nil, count: points.count)
        for index in points.indices where bands[index] != nil {
            let point = points[index]
            guard point.isAirborne else {
                known[index] = 0
                continue
            }
            let field = reference[index] ?? firstGround ?? 0
            known[index] = max(point.altitudeFeet - field, 0) * 0.3048
        }

        return (filled(known), lastGround)
    }

    /// Gaps closed by straight lines between the heights either side of
    /// them, and held level past the last one at either end.
    private static func filled(_ values: [Double?]) -> [Double] {
        guard let first = values.firstIndex(where: { $0 != nil }) else {
            return [Double](repeating: 0, count: values.count)
        }
        var out = [Double](repeating: values[first] ?? 0, count: values.count)
        var previous = first
        for index in values.indices where index > first {
            guard let value = values[index] else { continue }
            out[index] = value
            let start = values[previous] ?? 0
            let span = Double(index - previous)
            if span > 1 {
                for gap in (previous + 1)..<index {
                    out[gap] = start + (value - start) * Double(gap - previous) / span
                }
            }
            previous = index
        }
        let last = values[previous] ?? 0
        for index in values.indices where index > previous { out[index] = last }
        return out
    }

    /// The height at a point of the smoothed curve that lies on the piece of
    /// track starting at sample `origin`.
    ///
    /// How far along that piece the point is comes from its distance to the
    /// samples at either end, and the height follows a Catmull–Rom curve
    /// through the samples around it, so a climb that levels off rounds into
    /// its level rather than kinking into it. Never past either end's height,
    /// so it does not overshoot a cruise level and dip back down to it.
    static func height(
        at coordinate: CLLocationCoordinate2D,
        after origin: Int,
        of points: [TrackPoint],
        heights: [Double]
    ) -> Double {
        let count = heights.count
        guard count > 0 else { return 0 }
        let i1 = min(max(origin, 0), count - 1)
        let i2 = min(i1 + 1, count - 1)
        guard i1 != i2 else { return heights[i1] }

        let fromStart = planarDistance(points[i1].coordinate, coordinate)
        let toEnd = planarDistance(coordinate, points[i2].coordinate)
        let t = fromStart + toEnd > 0 ? fromStart / (fromStart + toEnd) : 0

        let p0 = heights[max(i1 - 1, 0)]
        let p1 = heights[i1]
        let p2 = heights[i2]
        let p3 = heights[min(i2 + 1, count - 1)]
        let t2 = t * t
        let t3 = t2 * t
        let curve = 0.5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3)
        return min(max(curve, min(p1, p2)), max(p1, p2))
    }

    /// Near enough for telling where between two samples a point lies.
    private static func planarDistance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let scale = cos((a.latitude + b.latitude) / 2 * .pi / 180)
        let dx = (b.longitude - a.longitude) * scale
        let dy = b.latitude - a.latitude
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - For Mapbox

    /// A run's heights at even steps along it, as Mapbox measures distance.
    static func resampled(_ coordinates: [CLLocationCoordinate2D], heights: [Double]) -> [Double] {
        guard coordinates.count >= 2, heights.count == coordinates.count else {
            return heights.isEmpty ? [0, 0] : [heights[0], heights[0]]
        }

        var along = [0.0]
        along.reserveCapacity(coordinates.count)
        var previous = mercator(coordinates[0])
        for coordinate in coordinates.dropFirst() {
            let point = mercator(coordinate)
            along.append(along[along.count - 1] + hypot(point.x - previous.x, point.y - previous.y))
            previous = point
        }
        let total = along[along.count - 1]
        guard total > 0 else { return [heights[0], heights[heights.count - 1]] }

        let samples = min(max(coordinates.count, 2), maximumSamples)
        var out: [Double] = []
        out.reserveCapacity(samples)
        var segment = 0
        for step in 0..<samples {
            let distance = total * Double(step) / Double(samples - 1)
            while segment < along.count - 2, along[segment + 1] < distance { segment += 1 }
            let length = along[segment + 1] - along[segment]
            let share = length > 0 ? min(max((distance - along[segment]) / length, 0), 1) : 0
            out.append(heights[segment] + (heights[segment + 1] - heights[segment]) * share)
        }
        return out
    }

    /// Heights as the map draws them: the aeroplanes', to the decimetre,
    /// which is as fine as anyone will see and keeps the feature small.
    static func lifted(_ profile: [Double]) -> [Double] {
        profile.map { (AircraftModelStyle.drawnLift(heightMetres: $0) * 10).rounded() / 10 }
    }

    /// The vertex's height: its progress along the line, read off the
    /// feature's `elevation` array between the two samples either side.
    static func elevationExpression() -> [Any] {
        let profile: [Any] = ["array", "number", ["get", "elevation"]]
        return [
            "at-interpolated",
            ["*", ["line-progress"], ["-", ["length", profile], 1]],
            profile,
        ]
    }

    /// Longitude and latitude on Mapbox's unit square, without wrapping, so a
    /// track carried across the antimeridian stays continuous.
    private static func mercator(_ coordinate: CLLocationCoordinate2D) -> (x: Double, y: Double) {
        let latitude = min(max(coordinate.latitude, -85.051129), 85.051129) * .pi / 180
        return (coordinate.longitude / 360, log(tan(.pi / 4 + latitude / 2)) / (2 * .pi))
    }
}
