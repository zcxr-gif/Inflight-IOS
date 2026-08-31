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

    /// The sun elevation band `index` is drawn at, from the sunset line down to
    /// astronomical night.
    ///
    /// Shared rather than worked out where the shapes are, because the planet
    /// draws the same fade out of the same numbers — see
    /// `GlobeCanvasView.drawNight` — and a terminator that softened over
    /// eighteen degrees on one map and some other span on the other would be
    /// two different claims about the same evening.
    static func elevation(atIndex index: Int) -> Double {
        guard bandCount > 1 else { return nightElevation }
        let fraction = Double(index) / Double(bandCount - 1)
        return sunsetElevation + (nightElevation - sunsetElevation) * fraction
    }

    /// How deep band `index` is, as a fraction of full night.
    ///
    /// The same accumulation `alpha(atIndex:step:)` builds, divided by what the
    /// innermost band comes to — which is what a renderer needs when it has
    /// been given the colour of full night rather than a per-band step. The
    /// planet is drawn that way: its night is a palette colour, and each ring
    /// is that colour at this fraction of its strength.
    static func depth(atIndex index: Int) -> Double {
        let deepest = alpha(atIndex: bandCount - 1, step: depthStep)
        guard deepest > 0 else { return 1 }
        return min(1, alpha(atIndex: index, step: depthStep) / deepest)
    }

    /// The step the fraction above is shaped by. Between the two the map itself
    /// uses, since this one is about the *shape* of the fade rather than about
    /// how heavy it is.
    private static let depthStep: Double = 0.05

    /// Titles the renderer reads the band's own darkness back off, since
    /// `MKPolygon` carries a string and nothing else.
    private static let titlePrefix = "terminator.band."

    static func isBand(_ title: String?) -> Bool {
        title?.hasPrefix(titlePrefix) == true
    }

    /// How finely each edge is walked, in degrees of longitude.
    ///
    /// Two degrees is a hundred and eighty points along each edge, which is
    /// smooth at any zoom the map offers and cheap enough to rebuild every
    /// couple of minutes without noticing.
    private static let step: Double = 2

    /// The bands, lightest first.
    ///
    /// Each one is a *ring*: the dark cap at its own elevation with the next
    /// band's cap punched out of it as an interior polygon. Nested filled caps
    /// would have been simpler and are what this drew first, but they paint the
    /// deep night eight times over — eight translucent world-sized fills
    /// composited on every frame of every pan, which is exactly the sort of
    /// overdraw that costs a map its frame rate. Cut into rings, every pixel of
    /// the wash is painted once and the picture is identical, because each
    /// ring simply carries the alpha that many overlapping fills would have
    /// accumulated to.
    static func polygons(at date: Date = Date()) -> [MKPolygon] {
        let sun = SolarPosition.sun(at: date)

        let rings: [[CLLocationCoordinate2D]] = (0..<bandCount).map { index in
            ring(below: elevation(atIndex: index), sun: sun)
        }

        var out: [MKPolygon] = []
        out.reserveCapacity(bandCount)

        for (index, outer) in rings.enumerated() {
            guard outer.count > 3 else { continue }

            // The innermost band has nothing under it: past astronomical night
            // the sky is as dark as it gets, so that one is a solid cap.
            //
            // The hole is wound the opposite way round to the ring it is cut
            // from, which is the convention that makes it a hole under either
            // fill rule rather than only under even-odd.
            let inner = index + 1 < rings.count ? Array(rings[index + 1].reversed()) : []
            let holes = inner.count > 3
                ? [MKPolygon(coordinates: inner, count: inner.count)]
                : []

            let polygon = MKPolygon(
                coordinates: outer,
                count: outer.count,
                interiorPolygons: holes
            )
            polygon.title = "\(titlePrefix)\(index)"
            out.append(polygon)
        }

        return out
    }

    /// The boundary of everything darker than one elevation, as a closed ring.
    ///
    /// Two edges rather than one: the northern limit of the dark walked east,
    /// and the southern limit walked back. A meridian with no darkness on it at
    /// all pinches the two edges together at the point furthest from the sun,
    /// so the band closes to nothing where it ends instead of leaping to a pole.
    private static func ring(
        below elevation: Double,
        sun: SolarPosition.Sun
    ) -> [CLLocationCoordinate2D] {
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
        return northern + southern.reversed()
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

    /// How much of one band's wash is in place by the time you reach it.
    ///
    /// The rings do not overlap, so each has to carry the darkness the stack of
    /// caps would have built up: one wash of `step`, composited `index + 1`
    /// times, is `1 - (1 - step)^(index + 1)`. The result is the same picture
    /// the nested version drew, painted once instead of eight times.
    private static func alpha(atIndex index: Int, step: Double) -> Double {
        1 - pow(1 - step, Double(index + 1))
    }

    /// How each band is painted.
    ///
    /// Deliberately gentle: even at its deepest this is a wash rather than a
    /// curtain, because an overlay heavy enough to be unmistakable is also
    /// heavy enough to lose the coastline, the traffic and the routes
    /// underneath it, and those are what the map is for.
    ///
    /// Built once, because a dynamic colour is resolved against the map's
    /// traits every time a renderer asks for it.
    private static let fills: [UIColor] = (0..<Terminator.bandCount).map { index in
        UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(
                    red: 0.05, green: 0.07, blue: 0.16,
                    alpha: Terminator.alpha(atIndex: index, step: 0.045)
                )
                : UIColor(
                    red: 0.00, green: 0.01, blue: 0.05,
                    alpha: Terminator.alpha(atIndex: index, step: 0.055)
                )
        }
    }

    /// The wash for a band, read back off the polygon's own title.
    static func fill(for title: String?) -> UIColor {
        guard let title = title,
              let index = Int(title.dropFirst(titlePrefix.count)),
              fills.indices.contains(index)
        else { return fills[0] }
        return fills[index]
    }
}
