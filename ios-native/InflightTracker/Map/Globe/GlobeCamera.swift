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
    }

    var basis: Basis {
        let lat = latitude * .pi / 180
        let lon = longitude * .pi / 180
        let sinLat = Float(sin(lat)), cosLat = Float(cos(lat))
        let sinLon = Float(sin(lon)), cosLon = Float(cos(lon))

        return Basis(
            east: SIMD3<Float>(-sinLon, cosLon, 0),
            north: SIMD3<Float>(-sinLat * cosLon, -sinLat * sinLon, cosLat),
            out: SIMD3<Float>(cosLat * cosLon, cosLat * sinLon, sinLat)
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

    // MARK: - Moving it

    /// Turns the planet under a finger.
    ///
    /// Scaled by the radius, so a drag moves the ground under the fingertip by
    /// roughly the distance dragged whatever the zoom — which is the only rule
    /// that makes a globe feel like an object rather than like a slider.
    ///
    /// Latitude is clamped rather than allowed to tip over the pole. Going over
    /// the top is a real thing a trackball does, and it arrives upside down:
    /// north stops being up, every label is mirrored, and the way back is not
    /// obvious. A planet you cannot turn upside down is worth more here than
    /// one you can.
    mutating func turn(by translation: CGSize) {
        guard radius > 0 else { return }

        let perPoint = 90.0 / Double(radius)
        longitude -= Double(translation.width) * perPoint
        latitude = min(90, max(-90, latitude + Double(translation.height) * perPoint))

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

    /// How far the sphere may be zoomed, as a multiple of the radius that fits
    /// the viewport.
    ///
    /// The floor leaves the whole planet comfortably inside the screen with the
    /// chrome over it; the ceiling is where the 110m outlines stop being an
    /// outline and start being a polygon, which is about a country filling the
    /// screen. Zooming past the data would be offering detail that is not
    /// there.
    static let minimumScale: CGFloat = 0.9
    static let maximumScale: CGFloat = 14
}
