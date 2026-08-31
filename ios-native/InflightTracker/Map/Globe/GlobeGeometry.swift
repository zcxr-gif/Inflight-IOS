import CoreLocation
import Foundation
import simd

/// The lines the globe is drawn from, as unit vectors on a sphere.
///
/// ## Why vectors rather than degrees
///
/// A globe is an orthographic projection, and the textbook form of it is four
/// trigonometric functions per point per frame. At ten and a half thousand
/// border points redrawn while a finger is moving, that is the whole frame
/// budget spent on `sin`.
///
/// A point on a sphere is a direction, though, and a direction does not change
/// when the camera turns — only the basis it is measured against does. So the
/// trigonometry happens once here, at load, and a frame is nine multiplies and
/// six adds per point against a basis worked out once for the whole frame. See
/// `GlobeCamera.project`.
///
/// The cost is memory, and it is not much: three floats a point is 127 KB for
/// every border in the world.
enum GlobeGeometry {

    /// One closed ring — a country's outline, or a line of the graticule.
    ///
    /// A struct around a plain array rather than a nested array so the drawing
    /// side can hold a slice of one without copying it.
    struct Ring {
        let points: [SIMD3<Float>]

        /// The ring's own bounding cone: the direction of its middle, and the
        /// cosine of the angle from that direction to its furthest point.
        ///
        /// The whole of the culling. A ring is entirely behind the planet when
        /// the angle between the camera and its centre exceeds a right angle by
        /// more than the ring's own radius, which is one dot product and one
        /// comparison for a country the camera cannot see. On a globe that is
        /// most of them, every frame.
        let axis: SIMD3<Float>
        let radiusCosine: Float

        init(points: [SIMD3<Float>]) {
            self.points = points

            var sum = SIMD3<Float>(repeating: 0)
            for point in points { sum += point }

            // A ring whose points cancel out — a great circle, which is what
            // every meridian is — has no meaningful centre. Such a ring is
            // never culled: a cosine of -1 says "reaches everywhere", which for
            // a line that genuinely wraps the planet is the truth.
            let length = simd_length(sum)
            guard length > 0.0001 else {
                self.axis = SIMD3<Float>(0, 0, 1)
                self.radiusCosine = -1
                return
            }

            let centre = sum / length
            var lowest: Float = 1
            for point in points { lowest = min(lowest, simd_dot(point, centre)) }

            self.axis = centre
            self.radiusCosine = lowest
        }
    }

    /// A direction on the unit sphere.
    ///
    /// Z is up through the north pole and X points at the Greenwich meridian on
    /// the equator, which is the ordinary geocentric convention and the one
    /// `GlobeCamera` builds its basis in.
    static func vector(latitude: Double, longitude: Double) -> SIMD3<Float> {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let cosLat = cos(lat)
        return SIMD3<Float>(
            Float(cosLat * cos(lon)),
            Float(cosLat * sin(lon)),
            Float(sin(lat))
        )
    }

    static func vector(_ coordinate: CLLocationCoordinate2D) -> SIMD3<Float> {
        vector(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    // MARK: - The borders

    /// Every country outline in the world, loaded once.
    ///
    /// `world-borders.bin`, built by `tools/globe-borders/build.py` from
    /// Natural Earth 1:110m. Lazily, because the globe is one screen of several
    /// and somebody who never opens it should not pay for it — and once,
    /// because the file does not change.
    static let borders: [Ring] = loadBorders()

    /// Meridians and parallels, every thirty degrees.
    ///
    /// Generated rather than stored: it is a formula, and a file for it would
    /// be a file that could disagree with the projection drawing it.
    ///
    /// Thirty is the coarsest spacing that still reads as a grid rather than as
    /// stray lines. Finer looked like graph paper behind the traffic, which is
    /// the one thing the globe is for.
    static let graticule: [Ring] = makeGraticule(everyDegrees: 30)

    private static func loadBorders() -> [Ring] {
        guard let url = Bundle.main.url(forResource: "world-borders", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else {
            // The globe draws its graticule and its traffic and says nothing
            // about it. A missing resource is a build problem, not something to
            // fail a screen over.
            print("[globe] world-borders.bin is missing from the bundle")
            return []
        }
        return decode(data)
    }

    /// See `tools/globe-borders/build.py` for the format this is the other half
    /// of. Every length is checked against what is actually there rather than
    /// trusted, because a truncated resource should draw fewer countries rather
    /// than read off the end of a buffer.
    private static func decode(_ data: Data) -> [Ring] {
        var rings: [Ring] = []

        data.withUnsafeBytes { raw in
            guard raw.count >= 8 else { return }
            guard raw[0] == 0x49, raw[1] == 0x46, raw[2] == 0x47, raw[3] == 0x42 else {
                print("[globe] world-borders.bin does not start with IFGB")
                return
            }
            guard raw[4] == 1 else {
                print("[globe] world-borders.bin is version \(raw[4]), which this build cannot read")
                return
            }

            let ringCount = Int(raw.loadUnaligned(fromByteOffset: 6, as: UInt16.self))
            let lengthsStart = 8
            guard raw.count >= lengthsStart + ringCount * 2 else { return }

            var lengths: [Int] = []
            lengths.reserveCapacity(ringCount)
            var total = 0
            for index in 0..<ringCount {
                let length = Int(raw.loadUnaligned(
                    fromByteOffset: lengthsStart + index * 2,
                    as: UInt16.self
                ))
                lengths.append(length)
                total += length
            }

            let pointsStart = lengthsStart + ringCount * 2
            guard raw.count >= pointsStart + total * 4 else {
                print("[globe] world-borders.bin is shorter than its own header says")
                return
            }

            var offset = pointsStart
            rings.reserveCapacity(ringCount)
            for length in lengths {
                var points: [SIMD3<Float>] = []
                points.reserveCapacity(length)
                for _ in 0..<length {
                    let x = raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                    let y = raw.loadUnaligned(fromByteOffset: offset + 2, as: Int16.self)
                    offset += 4
                    points.append(vector(
                        latitude: Double(y) * 90.0 / 32767.0,
                        longitude: Double(x) * 180.0 / 32767.0
                    ))
                }
                guard points.count >= 2 else { continue }
                rings.append(Ring(points: points))
            }
        }

        return rings
    }

    private static func makeGraticule(everyDegrees step: Double) -> [Ring] {
        var rings: [Ring] = []

        // Meridians, pole to pole. Every two degrees along, which is fine
        // enough that the arc reads as a curve at any zoom the globe allows.
        var longitude = -180.0
        while longitude < 180 {
            var points: [SIMD3<Float>] = []
            var latitude = -90.0
            while latitude <= 90 {
                points.append(vector(latitude: latitude, longitude: longitude))
                latitude += 2
            }
            rings.append(Ring(points: points))
            longitude += step
        }

        // Parallels. The poles themselves are a point rather than a circle and
        // are left out; a ring of zero radius is a dot nobody asked for.
        var latitude = -90 + step
        while latitude < 90 {
            var points: [SIMD3<Float>] = []
            var longitude = -180.0
            while longitude <= 180 {
                points.append(vector(latitude: latitude, longitude: longitude))
                longitude += 2
            }
            rings.append(Ring(points: points))
            latitude += step
        }

        return rings
    }
}
