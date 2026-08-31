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

        /// The same reach as an angle, which is what a cull that has to add it
        /// to the angle the *view* can see needs. Held rather than derived
        /// because `acos` per ring per frame is the one thing this whole file
        /// exists to avoid.
        let radiusAngle: Float

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
                self.radiusAngle = .pi
                return
            }

            let centre = sum / length
            var lowest: Float = 1
            for point in points { lowest = min(lowest, simd_dot(point, centre)) }

            self.axis = centre
            self.radiusCosine = lowest
            self.radiusAngle = acos(max(-1, min(1, lowest)))
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

    /// Which way an aircraft is pointing, as a direction lying along the
    /// sphere's surface at the place it is.
    ///
    /// Worked out once when the packet lands rather than once a frame, for the
    /// same reason positions are: the aeroplane's heading does not change when
    /// the planet is turned, only the basis it is measured against. Projecting
    /// this is then two dot products, and the screen angle of a sprite comes
    /// out of it directly — see `GlobeCanvasView.drawTraffic`.
    ///
    /// The tangent frame is the usual one: east along the parallel, north along
    /// the meridian. It stays defined at the poles, where a longitude still
    /// names a direction to face even though every direction is south.
    static func headingVector(
        latitude: Double,
        longitude: Double,
        headingDegrees: Double
    ) -> SIMD3<Float> {
        let lon = longitude * .pi / 180
        let east = SIMD3<Float>(Float(-sin(lon)), Float(cos(lon)), 0)
        let north = simd_cross(vector(latitude: latitude, longitude: longitude), east)

        let heading = headingDegrees * .pi / 180
        let along = north * Float(cos(heading)) + east * Float(sin(heading))

        // A heading at the pole, or one that has cancelled itself out through
        // rounding, would otherwise be a zero vector and a sprite pointing at
        // nothing. North is the honest fallback: it is what a compass rose
        // draws when it has nothing to say.
        let length = simd_length(along)
        return length > 1e-5 ? along / length : north
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

    // MARK: - Level of detail

    /// How much of the border data a frame actually walks.
    ///
    /// The globe is drawn at radii spanning a factor of fifteen — a planet that
    /// fits on a phone at one end, a country filling the screen at the other —
    /// and the point count that makes a coastline smooth at the top of that
    /// range is thirty thousand line segments spent on a shape three hundred
    /// points across at the bottom of it. Which is the whole of why turning the
    /// globe used to stutter: every frame paid the zoomed-in price.
    ///
    /// ## A level thins points. It never removes shapes
    ///
    /// The coarser levels used to drop whole rings as well — no island under
    /// two and a half degrees at `rough`, under one at `coarse` — and that is
    /// what made a pinch look like the planet was being redrawn underneath it.
    /// Two and a half degrees is thirty points of screen at the radius `rough`
    /// was still being used at, so every Greek island, the Canaries and half
    /// the Caribbean blinked out the moment a finger landed and blinked back
    /// when it lifted.
    ///
    /// Every level now carries every ring. Thinning a coastline moves it by
    /// well under a point; removing one is a shape appearing and disappearing,
    /// which the eye is built to notice. The specks cost about seventeen
    /// hundred points at the very bottom of the range, where they are drawn at
    /// a radius of a hundred and sixty and every one of them is smaller than a
    /// pixel.
    enum Detail {

        /// Every sixth point. For a planet that is *moving* at the bottom of
        /// the zoom range — a coastline sliding under a finger is being looked
        /// at as a shape rather than as a shoreline, and a sixth of the points
        /// hold the shape at a radius where a country is thirty points across.
        case rough

        /// Every third point. The whole planet on a screen, where a coastline
        /// is a few hundred points long and the difference is invisible.
        case coarse

        /// Every other point.
        case medium

        /// Everything, for a camera close enough that the decimation would
        /// start showing as straight lines across a bay.
        case full
    }

    static func borders(for detail: Detail) -> [Ring] {
        switch detail {
        case .rough: return roughBorders
        case .coarse: return coarseBorders
        case .medium: return mediumBorders
        case .full: return borders
        }
    }

    /// All built lazily off the full set, so an install that never opens the
    /// planet decodes nothing and one that opens it zoomed out never builds the
    /// finer of them.
    private static let roughBorders: [Ring] = decimate(borders, keepingEvery: 6)
    private static let coarseBorders: [Ring] = decimate(borders, keepingEvery: 3)
    private static let mediumBorders: [Ring] = decimate(borders, keepingEvery: 2)

    /// Thins every ring, and keeps every one of them.
    private static func decimate(_ rings: [Ring], keepingEvery step: Int) -> [Ring] {
        var out: [Ring] = []
        out.reserveCapacity(rings.count)

        for ring in rings {
            let points = ring.points
            // Not worth thinning a ring that would come out a triangle: the
            // shape would change rather than soften.
            guard points.count > step * 4 else {
                out.append(ring)
                continue
            }

            var kept: [SIMD3<Float>] = []
            kept.reserveCapacity(points.count / step + 2)
            var index = 0
            while index < points.count {
                kept.append(points[index])
                index += step
            }
            // These rings are closed, and a stride that does not divide the
            // length would leave the last one open — which on a filled planet
            // is a country with a slice cut out of it.
            if let last = points.last, kept.last != last { kept.append(last) }

            out.append(Ring(points: kept))
        }

        return out
    }

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
