import MapKit
import UIKit

/// Night, as a shape on the map.
///
/// Two bands rather than one. The outer is civil twilight — the sun between
/// half a degree and six degrees below the horizon, which is the part of the
/// world where it is neither day nor properly dark — and the inner is night
/// proper. Drawn together they give the soft edge a terminator actually has,
/// and the alternative is a hard line across the Atlantic that no photograph
/// of the earth has ever shown.
///
/// Everything here is arithmetic on the device. There is nothing to fetch and
/// nothing that can be out of date except the clock.
enum Terminator {

    /// Sun elevations the two bands are bounded by.
    ///
    /// The first is the standard sunrise allowance for refraction and the
    /// sun's own radius — the moment the disc touches the horizon. The second
    /// is the civil twilight convention, past which you can no longer read
    /// outside.
    static let sunsetElevation: Double = -0.833
    static let civilTwilightElevation: Double = -6

    /// Titles the renderer reads back off the polygon, since `MKPolygon`
    /// carries a string and nothing else.
    static let nightTitle = "terminator.night"
    static let twilightTitle = "terminator.twilight"

    /// How finely the ring is walked, in degrees of longitude.
    ///
    /// Two degrees is a hundred and eighty points around the world, which is
    /// smooth at any zoom the map offers and cheap enough to rebuild every
    /// couple of minutes without noticing.
    private static let step: Double = 2

    /// The two bands, darkest last so it draws on top.
    static func polygons(at date: Date = Date()) -> [MKPolygon] {
        let sun = SolarPosition.sun(at: date)

        var out: [MKPolygon] = []
        if let twilight = polygon(below: civilTwilightElevation, sun: sun, title: twilightTitle) {
            out.append(twilight)
        }
        // Built second and added second: the night band sits inside the
        // twilight one, and the overlap is what makes the edge read as a fade
        // rather than as two outlines.
        if let night = polygon(below: sunsetElevation, sun: sun, title: nightTitle) {
            out.append(night)
        }
        return out
    }

    /// Everything darker than one elevation, as a closed shape.
    ///
    /// Walks the ring from one edge of the world to the other and then closes
    /// across whichever pole is in the dark — which is the summer pole's
    /// opposite, and flips twice a year at the equinoxes.
    private static func polygon(
        below elevation: Double,
        sun: SolarPosition.Sun,
        title: String
    ) -> MKPolygon? {
        // At the pole the hour angle drops out and the elevation is simply the
        // declination, so this is the whole test for which end is dark.
        let northIsDark = sun.declination * 180 / .pi < elevation
        let darkPole: Double = northIsDark ? 90 : -90

        var coordinates: [CLLocationCoordinate2D] = []
        var longitude: Double = -180

        while longitude <= 180 {
            if let latitude = SolarPosition.terminatorLatitude(
                atLongitude: longitude,
                elevationDegrees: elevation,
                sun: sun
            ) {
                coordinates.append(
                    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                )
            } else {
                // No crossing on this meridian: it is polar day or polar night
                // all the way up. Following the dark pole keeps the ring closed
                // and puts the boundary where it belongs — hard against the
                // edge of the lit cap.
                coordinates.append(
                    CLLocationCoordinate2D(latitude: darkPole, longitude: longitude)
                )
            }
            longitude += step
        }

        guard coordinates.count > 3 else { return nil }

        // Close the band across the dark pole. Stopping at ±180 rather than
        // wrapping keeps this one shape in one world, which is the only way
        // MapKit will fill it.
        coordinates.append(CLLocationCoordinate2D(latitude: darkPole, longitude: 180))
        coordinates.append(CLLocationCoordinate2D(latitude: darkPole, longitude: -180))

        let polygon = MKPolygon(coordinates: coordinates, count: coordinates.count)
        polygon.title = title
        return polygon
    }

    /// How each band is painted.
    ///
    /// Light on purpose. This is a wash that says which half of the world is
    /// asleep, not a curtain: an overlay heavy enough to be unmistakable is
    /// also heavy enough to lose the coastline, the traffic and the routes
    /// underneath it, and those are what the map is for.
    static func fill(for title: String?) -> UIColor {
        switch title {
        case nightTitle:
            return UIColor { traits in
                traits.userInterfaceStyle == .light
                    ? UIColor(red: 0.05, green: 0.07, blue: 0.16, alpha: 0.26)
                    : UIColor(red: 0.00, green: 0.01, blue: 0.05, alpha: 0.34)
            }
        default:
            return UIColor { traits in
                traits.userInterfaceStyle == .light
                    ? UIColor(red: 0.10, green: 0.13, blue: 0.26, alpha: 0.13)
                    : UIColor(red: 0.01, green: 0.03, blue: 0.10, alpha: 0.18)
            }
        }
    }
}
