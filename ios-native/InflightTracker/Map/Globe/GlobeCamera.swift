import CoreGraphics
import CoreLocation
import Foundation
import simd

/// Where the planet is being looked at from, and the arithmetic that turns a
/// place on it into a place on the screen.
///
/// A value, not an object: it is passed to the canvas that draws the borders
/// and to the SwiftUI layer that draws the markers, and those two must agree
/// about where Heathrow is to the pixel or the labels sit off their airports.
/// One struct, used by both, is how that is guaranteed rather than hoped for.
///
/// ## The projection
///
/// Orthographic — the view from infinitely far away, which is what makes a
/// globe look like a planet rather than like a fisheye photograph of one. The
/// camera's own basis is three orthogonal directions worked out once per frame:
/// `out` towards the viewer, `east` to the right, `north` up. Projecting is
/// then three dot products, and the third of them — the depth — is also the
/// visibility test, because a point on the far side of a sphere is exactly a
/// point whose direction leans away from the camera.
struct GlobeCamera: Equatable {

    /// Where on the planet the middle of the screen is.
    var latitude: Double
    var longitude: Double

    /// The sphere's radius in points.
    var radius: CGFloat

    /// Where the middle of the sphere is drawn.
    var center: CGPoint

    init(
        latitude: Double = 20,
        longitude: Double = 0,
        radius: CGFloat = 160,
        center: CGPoint = .zero
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.center = center
    }

    // MARK: - The basis

    /// The three directions the projection measures against, worked out once
    /// per frame rather than per point.
    struct Basis {
        let east: SIMD3<Float>
        let north: SIMD3<Float>
        let out: SIMD3<Float>

        /// The same three directions kept to full precision.
        ///
        /// `Float` carries about seven digits, which on a planet six and a
        /// half thousand kilometres across is a resolution of some forty
        /// centimetres. That was invisible while the zoom stopped at a country
        /// filling the screen; at two hundred metres across a phone it is
        /// three quarters of a point, and a line drawn through such points
        /// zigzags by more than half its own width.
        ///
        /// So the cartography — ten thousand coastline points, redrawn every
        /// frame, and quantised to a tenth of a degree in the file anyway —
        /// stays single precision, and the handful of things that are drawn
        /// *at* that zoom and have to sit where they really are get these: the
        /// flown path, the route, the tracks. See `project(_:using:)`.
        let preciseEast: SIMD3<Double>
        let preciseNorth: SIMD3<Double>
        let preciseOut: SIMD3<Double>
    }

    var basis: Basis {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let sinLat = sin(lat), cosLat = cos(lat)
        let sinLon = sin(lon), cosLon = cos(lon)

        let east = SIMD3<Double>(-sinLon, cosLon, 0)
        let north = SIMD3<Double>(-sinLat * cosLon, -sinLat * sinLon, cosLat)
        let out = SIMD3<Double>(cosLat * cosLon, cosLat * sinLon, sinLat)

        return Basis(
            east: SIMD3<Float>(Float(east.x), Float(east.y), Float(east.z)),
            north: SIMD3<Float>(Float(north.x), Float(north.y), Float(north.z)),
            out: SIMD3<Float>(Float(out.x), Float(out.y), Float(out.z)),
            preciseEast: east,
            preciseNorth: north,
            preciseOut: out
        )
    }

    // MARK: - Projecting

    /// Where a direction lands, and how far towards the viewer it leans.
    ///
    /// `depth` runs from 1 at the point facing the camera to -1 at its
    /// antipode, and zero is exactly the limb. Everything that has to know
    /// whether something is round the back reads it: the border clipper, the
    /// marker fade, and the hit test.
    struct Projected {
        let point: CGPoint
        let depth: Float

        var isVisible: Bool { depth >= 0 }
    }

    func project(_ vector: SIMD3<Float>, using basis: Basis) -> Projected {
        let x = simd_dot(vector, basis.east)
        let y = simd_dot(vector, basis.north)
        let depth = simd_dot(vector, basis.out)

        return Projected(
            point: CGPoint(
                x: center.x + CGFloat(x) * radius,
                // Screen y grows downward and north does not.
                y: center.y - CGFloat(y) * radius
            ),
            depth: depth
        )
    }

    func project(_ coordinate: CLLocationCoordinate2D) -> Projected {
        project(GlobeGeometry.vector(coordinate), using: basis)
    }

    /// The same projection, without throwing away forty centimetres of the
    /// answer. See `Basis.preciseEast`.
    func project(_ vector: SIMD3<Double>, using basis: Basis) -> Projected {
        let x = simd_dot(vector, basis.preciseEast)
        let y = simd_dot(vector, basis.preciseNorth)
        let depth = simd_dot(vector, basis.preciseOut)

        return Projected(
            point: CGPoint(
                x: center.x + CGFloat(x) * radius,
                y: center.y - CGFloat(y) * radius
            ),
            depth: Float(depth)
        )
    }

    // MARK: - Moving it

    /// Turns the planet so the ground follows a finger.
    ///
    /// ## The ground stays under your thumb, which it did not
    ///
    /// This used to be `90 / radius` degrees per point, and the reasoning was
    /// sound at exactly one place: drag by the sphere's whole radius and you
    /// travel from the middle of the disc to the limb, which is ninety
    /// degrees. But the orthographic projection between those two ends is a
    /// *sine*, not a ratio. The screen offset of a point `a` radians from the
    /// middle is `R·sin a`, so the angle for an offset `d` is `asin(d/R)` —
    /// and near the middle that is `d/R` radians, which is 57.3 degrees per
    /// radius, not 90.
    ///
    /// So every drag moved the ground a little over one and a half times as
    /// far as the finger that was dragging it. On a whole planet you read that
    /// as a globe with a light flywheel; zoomed in, where the sphere is
    /// effectively a flat map, you read it as the map sliding out from under
    /// you. It is the single thing that stopped this feeling like Maps.
    ///
    /// ## And longitude is not the same as distance
    ///
    /// A degree of longitude is a full degree of ground at the equator and
    /// almost nothing near a pole, so pinning the ground under a finger means
    /// dividing by the cosine of the latitude. Clamped, because that factor
    /// runs away to infinity at the poles and a globe that spins wildly when
    /// you nudge Svalbard is worse than one that lags a little.
    ///
    /// Applied as the *change* since the last update rather than as the whole
    /// translation from the start of the drag, which is what lets both of
    /// these be right: the cosine is the one at the latitude you are at now,
    /// and the sines add up along the path you actually took.
    mutating func drag(by translation: CGSize) {
        guard radius > 0 else { return }

        let reach = Double(radius)
        func angle(_ points: CGFloat) -> Double {
            let ratio = Double(points) / reach
            return asin(max(-1, min(1, ratio))) * 180 / .pi
        }

        // Above about seventy-seven degrees the parallel is short enough that
        // following the finger exactly means spinning the planet faster than
        // anybody meant to.
        let shrink = max(0.22, cos(latitude * .pi / 180))

        longitude -= angle(translation.width) / shrink
        latitude = min(90, max(-90, latitude + angle(translation.height)))
        longitude = Self.wrapped(longitude)
    }

    /// Longitude folded back into ±180, however many turns it has taken.
    ///
    /// A globe is spun, repeatedly and in one direction, so this is reached far
    /// more often than it is on a map. Written as one remainder and one
    /// correction rather than a loop: a fast flick can carry several turns in a
    /// single gesture update, and `while longitude > 180` would be a loop whose
    /// length depends on how hard somebody swiped.
    static func wrapped(_ longitude: Double) -> Double {
        var folded = (longitude + 180).truncatingRemainder(dividingBy: 360)
        if folded < 0 { folded += 360 }
        return folded - 180
    }

    /// The planet's radius in metres, which is what turns a zoom into a
    /// distance across the ground.
    static let earthRadiusMetres: Double = 6_371_008.8

    /// How much ground a point of screen is worth, in the middle of the disc.
    ///
    /// Only true in the middle, which is where whatever you are looking at is.
    var metresPerPoint: Double {
        radius > 0 ? Self.earthRadiusMetres / Double(radius) : .infinity
    }

    /// How far the sphere may be pulled back, as a multiple of the radius that
    /// fits the viewport. The floor leaves the whole planet comfortably inside
    /// the screen with the chrome over it.
    static let minimumScale: CGFloat = 0.9

    /// How close it may be pushed in, as the width of ground across the short
    /// side of the screen.
    ///
    /// A distance rather than a multiple, and that is the whole of the fix.
    /// The ceiling used to be twenty-four times a fitted planet, which sounds
    /// generous and is not: a fitted planet is about a hundred and sixty
    /// points, so the closest you could get was a view some six hundred
    /// kilometres across. That is a country. You could not reach an airport,
    /// let alone its layout — the flat map turns its pavement on at nine
    /// nautical miles, and this stopped thirty-five times further out than
    /// that.
    ///
    /// It was also the wrong *kind* of number. A multiple of the fitted radius
    /// is a multiple of the screen, so the same setting meant a different
    /// closest approach on a phone and on an iPad. Two hundred metres across
    /// the short side is two hundred metres everywhere, and it is about where
    /// Maps stops as well: close enough to read a taxiway designator, not so
    /// close that a hundred and ten metre coastline becomes the subject.
    static let minimumSpanMetres: Double = 200

    /// The sphere radius that puts `metres` of ground across `points` of
    /// screen, in the middle of the disc.
    static func radius(forSpan metres: Double, across points: CGFloat) -> CGFloat {
        guard metres > 0, points > 0 else { return 0 }
        return CGFloat(earthRadiusMetres * Double(points) / metres)
    }
}
