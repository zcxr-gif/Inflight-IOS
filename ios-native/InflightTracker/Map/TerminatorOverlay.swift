import MapKit
import UIKit

/// Night, as a shape on the map.
///
/// Eight bands rather than two. Each one is everything darker than a chosen sun
/// elevation, drawn nested and barely tinted, so where they overlap the wash
/// deepens: a smooth fade from the sunset line down to astronomical night,
/// which is what a terminator actually looks like. Two bands gave two hard
/// edges — one at the sunset line and one where the bands met — and a hard line
/// across the Atlantic is the thing no photograph of the earth has ever shown.
///
/// The shape of each band is worked out honestly. The dark half of the world is
/// a cap centred on the antisolar point, so on any one meridian the dark
/// latitudes are a single arc, and each band is drawn by walking the arc's top
/// edge west to east and its bottom edge back again. The previous version
/// tracked one edge and closed across a pole, which was right for most of the
/// year and wrong every winter: it took only one root of the elevation
/// equation, missed the crossing that bounds a polar night, and left the whole
/// dark cap unshaded behind a staircase of jumps to the pole.
///
/// Everything here is arithmetic on the device. There is nothing to fetch and
/// nothing that can be out of date except the clock.
enum Terminator {

    /// The sunset line: the standard allowance for refraction and the sun's own
    /// radius, which is the moment the disc touches the horizon. The outermost
    /// band, and the faintest.
    static let sunsetElevation: Double = -0.833

    /// Astronomical night — the sun far enough down that the sky itself is no
    /// longer contributing any light. The innermost band, past which nothing
    /// gets darker.
    static let nightElevation: Double = -18

    /// How many bands the fade is made of. Eight puts a step every two and a
    /// half degrees of sun elevation, which at any zoom the map offers is a
    /// gradient rather than a set of edges.
    static let bandCount = 8

    /// Titles the renderer reads back off the polygon, since `MKPolygon`
    /// carries a string and nothing else.
    static let title = "terminator.band"

    static func isBand(_ title: String?) -> Bool { title == Self.title }

    /// How finely each edge is walked, in degrees of longitude.
    ///
    /// Two degrees is a hundred and eighty points along each edge, which is
    /// smooth at any zoom the map offers and cheap enough to rebuild every
    /// couple of minutes without noticing.
    private static let step: Double = 2

    /// The bands, lightest first, each one inside the last.
    static func polygons(at date: Date = Date()) -> [MKPolygon] {
        let sun = SolarPosition.sun(at: date)

        return (0..<bandCount).compactMap { index in
            let fraction = Double(index) / Double(bandCount - 1)
            let elevation = sunsetElevation + (nightElevation - sunsetElevation) * fraction
            return polygon(below: elevation, sun: sun)
        }
    }

    /// Everything darker than one elevation, as a closed shape.
    ///
    /// Two edges rather than one: the northern limit of the dark walked east,
    /// and the southern limit walked back. A meridian with no darkness on it at
    /// all pinches the two edges together at the point furthest from the sun,
    /// so the band closes to nothing where it ends instead of leaping to a pole.
    private static func polygon(below elevation: Double, sun: SolarPosition.Sun) -> MKPolygon? {
        var northern: [CLLocationCoordinate2D] = []
        var southern: [CLLocationCoordinate2D] = []

        var longitude: Double = -180
        while longitude <= 180 {
            let dark = darkLatitudes(atLongitude: longitude, elevation: elevation, sun: sun)
            northern.append(CLLocationCoordinate2D(latitude: dark.upper, longitude: longitude))
            southern.append(CLLocationCoordinate2D(latitude: dark.lower, longitude: longitude))
            longitude += step
        }

        // Stopping at ±180 rather than wrapping keeps this one shape in one
        // world, which is the only way MapKit will fill it.
        let ring = northern + southern.reversed()
        guard ring.count > 3 else { return nil }

        let polygon = MKPolygon(coordinates: ring, count: ring.count)
        polygon.title = title
        return polygon
    }

    /// The stretch of one meridian that is darker than `elevation`.
    ///
    /// Along a meridian the sun's elevation is a single sine of latitude:
    ///
    ///     sin(h) = sin(φ)sin(δ) + cos(φ)cos(δ)cos(H) = R·sin(φ + ψ)
    ///
    /// so the dark stretch is bounded by the at most two latitudes where that
    /// sine meets the threshold. Both roots are taken — the older code kept
    /// only the first, which is the one that runs off the globe on the daylit
    /// side of a winter pole, and losing it is what left the polar night
    /// unshaded.
    ///
    /// Returned pinched — lower equal to upper — where the meridian is lit from
    /// end to end.
    private static func darkLatitudes(
        atLongitude longitude: Double,
        elevation: Double,
        sun: SolarPosition.Sun
    ) -> (lower: Double, upper: Double) {
        let radians = Double.pi / 180
        let hourAngle = (longitude - sun.subsolarLongitude) * radians

        let a = sin(sun.declination)
        let b = cos(sun.declination) * cos(hourAngle)

        let amplitude = (a * a + b * b).squareRoot()
        let phase = atan2(b, a)
        let phaseDegrees = phase / radians

        /// The sine of the sun's elevation at a latitude on this meridian.
        func elevationSine(at latitude: Double) -> Double {
            amplitude * sin(latitude * radians + phase)
        }

        let threshold = sin(elevation * radians)

        // The latitude on this meridian the sun is furthest below — the trough
        // of that sine, or whichever pole is lower when the trough falls off
        // the globe. It is where the band closes to a point as it shrinks, so
        // pinching there keeps the shape continuous from one meridian to the
        // next.
        let trough = wrapped(-90 - phaseDegrees)
        let darkest: Double
        if trough > -90, trough < 90 {
            darkest = trough
        } else {
            darkest = elevationSine(at: -90) < elevationSine(at: 90) ? -90 : 90
        }

        guard amplitude > 1e-9 else { return (darkest, darkest) }

        let ratio = threshold / amplitude
        // The sine never reaches the threshold: the meridian is dark from pole
        // to pole, or lit from pole to pole.
        if ratio >= 1 { return (-90, 90) }
        if ratio <= -1 { return (darkest, darkest) }

        let principal = asin(ratio) / radians
        let crossings = [
            wrapped(principal - phaseDegrees),
            wrapped(180 - principal - phaseDegrees)
        ]
        .filter { $0 > -90 && $0 < 90 }
        .sorted()

        switch crossings.count {
        case 2:
            // The dark cap is centred on the antisolar point and can contain at
            // most one pole, so two crossings on one meridian always bound the
            // dark between them. Checked rather than assumed.
            if elevationSine(at: (crossings[0] + crossings[1]) / 2) < threshold {
                return (crossings[0], crossings[1])
            }
            return darkest <= crossings[0] ? (-90, crossings[0]) : (crossings[1], 90)

        case 1:
            // One crossing: the dark runs from it to whichever pole the sun is
            // further below.
            let edge = crossings[0]
            return darkest < edge ? (-90, edge) : (edge, 90)

        default:
            return elevationSine(at: darkest) < threshold ? (-90, 90) : (darkest, darkest)
        }
    }

    /// An angle in degrees, brought back into (-180, 180].
    private static func wrapped(_ degrees: Double) -> Double {
        let radians = Double.pi / 180
        return atan2(sin(degrees * radians), cos(degrees * radians)) / radians
    }

    /// How each band is painted.
    ///
    /// Deliberately almost nothing on its own: eight of these stack over the
    /// darkest part of the world and it is the stack that has to read, not any
    /// one of them. Even stacked it stays a wash rather than a curtain — an
    /// overlay heavy enough to be unmistakable is also heavy enough to lose the
    /// coastline, the traffic and the routes underneath it, and those are what
    /// the map is for.
    static let bandFill = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 0.045)
            : UIColor(red: 0.00, green: 0.01, blue: 0.05, alpha: 0.055)
    }
}
