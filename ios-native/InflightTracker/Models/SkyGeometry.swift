import CoreLocation
import Foundation
import simd

/// Where the sky is being looked at from.
///
/// Not necessarily where the phone is. The traffic this app draws is flying in
/// Infinite Flight, not over the user's head, so the vantage is a choice: the
/// device's own position, the cockpit of whatever the pilot is flying, or a
/// field somebody wants to stand at the threshold of. Everything below is the
/// same arithmetic whichever it is.
struct SkyObserver: Equatable {

    let latitude: Double
    let longitude: Double

    /// Feet above mean sea level, the same datum the feed reports aircraft in.
    /// Ground level is close enough for a vantage on the surface — the error is
    /// a few hundred feet against distances measured in miles.
    let altitudeFeet: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// One aircraft, placed in the sky over the observer.
///
/// The heavy half of the arithmetic — where in the world this thing is, in
/// which direction and how far up — is done once per packet and kept here. The
/// device's attitude changes thirty times a second, and all that costs is
/// turning the vector below into a point on the screen.
struct SkyTarget: Identifiable, Equatable {

    let id: String
    let callsign: String
    let aircraftName: String

    /// Whether this is one of the pilot's own aircraft, which is drawn to be
    /// found rather than to be read past.
    let isMine: Bool

    /// Compass bearing from the observer, degrees true, `0..<360`.
    let bearingDegrees: Double

    /// Above the horizon positive. Below it happens all the time: anything far
    /// enough away is over the curve, and everything on the ground is beneath
    /// you unless you are on the ground with it.
    let elevationDegrees: Double

    let distanceNauticalMiles: Double
    let altitudeFeet: Double

    /// How far above the observer it is, which is the number a pilot actually
    /// wants when the vantage is their own cockpit.
    let relativeAltitudeFeet: Double

    /// The direction to it as a unit vector in CoreMotion's true-north
    /// reference frame: X true north, Y west, Z up.
    let direction: SIMD3<Double>
}

/// Turning positions into directions, and directions into points on a screen.
enum SkyGeometry {

    /// Mean earth radius. The sky view is not navigation — it is pointing at
    /// things — so a sphere is the right model and an ellipsoid would be
    /// arithmetic nobody could see the result of.
    static let earthRadiusMeters = 6_371_008.8

    static let metersPerFoot = 0.3048
    static let metersPerNauticalMile = 1852.0

    /// Where an aircraft sits in the sky as seen from the observer.
    ///
    /// Flat-earth arithmetic on the horizontal — a local tangent plane, good to
    /// well under a degree at the couple of hundred miles this view shows, and
    /// far cheaper than the spherical formulae for a figure that is redrawn for
    /// every aircraft on every packet. The vertical is *not* flat: the drop of
    /// the curve is what puts distant traffic under the horizon, which is where
    /// it genuinely is.
    static func target(for flight: Flight, from observer: SkyObserver, isMine: Bool) -> SkyTarget {
        let originLatitude = observer.latitude * .pi / 180
        let targetLatitude = flight.latitude * .pi / 180

        // Wrapped, so a vantage at Anadyr and traffic at Nome are 300 miles
        // apart rather than most of the way round the world.
        var deltaLongitude = (flight.longitude - observer.longitude) * .pi / 180
        if deltaLongitude > .pi { deltaLongitude -= 2 * .pi }
        if deltaLongitude < -.pi { deltaLongitude += 2 * .pi }

        let east = deltaLongitude * cos((originLatitude + targetLatitude) / 2) * earthRadiusMeters
        let north = (targetLatitude - originLatitude) * earthRadiusMeters
        let ground = (east * east + north * north).squareRoot()

        let climb = (flight.altitudeFeet - observer.altitudeFeet) * metersPerFoot
        // The earth falling away underneath the line of sight.
        let drop = (ground * ground) / (2 * earthRadiusMeters)
        let up = climb - drop

        let slant = max((ground * ground + up * up).squareRoot(), 1)

        var bearing = atan2(east, north) * 180 / .pi
        if bearing < 0 { bearing += 360 }

        return SkyTarget(
            id: flight.id,
            callsign: flight.displayName,
            aircraftName: flight.aircraftName,
            isMine: isMine,
            bearingDegrees: bearing,
            elevationDegrees: atan2(up, ground) * 180 / .pi,
            distanceNauticalMiles: (ground * ground + up * up).squareRoot() / metersPerNauticalMile,
            altitudeFeet: flight.altitudeFeet,
            relativeAltitudeFeet: flight.altitudeFeet - observer.altitudeFeet,
            // North, west, up — CoreMotion's frame, not east-north-up, so the
            // attitude matrix can be applied to it without a change of basis
            // thirty times a second.
            direction: SIMD3(north / slant, -east / slant, up / slant)
        )
    }

    /// Where a direction lands on the screen, or nil when it is behind the
    /// camera.
    ///
    /// A pinhole model, which is what a phone camera is close enough to be.
    /// `rotation` is CoreMotion's attitude — it carries a vector in the
    /// device's own frame out into the reference frame — so its transpose is
    /// what brings the world back into the device's frame, where the rear
    /// camera looks down −Z, +X is the right-hand edge and +Y is the top.
    static func project(
        _ direction: SIMD3<Double>,
        rotation: simd_double3x3,
        focalLength: Double,
        in size: CGSize
    ) -> CGPoint? {
        let device = rotation.transpose * direction

        let depth = -device.z
        // Everything behind the phone, and the ring right at the edge of vision
        // where the projection runs away to infinity.
        guard depth > 0.02 else { return nil }

        return CGPoint(
            x: size.width / 2 + CGFloat(device.x / depth * focalLength),
            y: size.height / 2 - CGFloat(device.y / depth * focalLength)
        )
    }

    /// A direction in the reference frame, from a compass bearing and an angle
    /// above the horizon. The horizon marks are built with this.
    static func direction(bearingDegrees: Double, elevationDegrees: Double) -> SIMD3<Double> {
        let bearing = bearingDegrees * .pi / 180
        let elevation = elevationDegrees * .pi / 180
        let flat = cos(elevation)
        return SIMD3(cos(bearing) * flat, -sin(bearing) * flat, sin(elevation))
    }

    /// Which way the back of the phone is pointing, as a compass bearing.
    ///
    /// The camera looks down the device's −Z, and the attitude carries that out
    /// into the world; north and west come back as X and Y, so east is −Y.
    static func azimuth(of rotation: simd_double3x3) -> Double {
        let forward = rotation * SIMD3(0, 0, -1)
        var bearing = atan2(-forward.y, forward.x) * 180 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    /// How long the lens is, in points, for a view of this size.
    ///
    /// The camera reports the field of view across the long axis of its image,
    /// and the preview is filled aspect-fill — which on a phone means the long
    /// axis is the one shown whole and the sides are cropped. So the long side
    /// of the view spans exactly that angle, and one focal length describes
    /// both axes because the pixels are square.
    static func focalLength(fieldOfViewDegrees: Double, in size: CGSize) -> Double {
        let field = min(max(fieldOfViewDegrees, 20), 140) * .pi / 180
        return Double(max(size.width, size.height)) / 2 / tan(field / 2)
    }
}
