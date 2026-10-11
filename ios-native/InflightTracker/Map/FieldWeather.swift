import CoreLocation
import UIKit

/// A field's weather, drawn as weather rather than written: the badge on its
/// pin, and what falls on the map close in over it.
///
/// Both come from the METAR the field is already coloured by — see
/// `Metar.precipitation` — so nothing here asks for anything.
enum FieldWeather {

    /// What a report has to say for its field to be marked. Clouds alone are
    /// not marked: the code's colour already says how low they are, and a map
    /// with a badge on every overcast field would be a map of badges.
    static func kind(of metar: Metar?) -> Metar.Precipitation? {
        metar?.precipitation
    }

    /// Short, stable, and the whole of what the badge is drawn from — the
    /// image id's tail.
    static func key(_ kind: Metar.Precipitation, _ intensity: Metar.Intensity) -> String {
        let heavy = intensity == .heavy ? "+" : ""
        switch kind {
        case .thunderstorm: return "ts" + heavy
        case .snow: return "sn" + heavy
        case .rain: return "ra" + heavy
        case .drizzle: return "dz"
        case .fog: return "fg"
        }
    }

    // MARK: - The badge

    /// How far the canvas reaches past the pin on each side and above it, so
    /// the badge can sit on the pin's shoulder without moving the pin: the pin
    /// stays centred on the canvas's foot, which is what the layer anchors.
    private static let sideReach: CGFloat = 9
    private static let topReach: CGFloat = 9
    private static let diameter: CGFloat = 16

    /// The field's pin with the weather on its shoulder.
    static func pin(_ pin: UIImage, with kind: Metar.Precipitation, _ intensity: Metar.Intensity) -> UIImage {
        let canvas = CGSize(
            width: pin.size.width + sideReach * 2,
            height: pin.size.height + topReach
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false

        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let pinOrigin = CGPoint(x: sideReach, y: topReach)
            pin.draw(at: pinOrigin)

            let disc = CGRect(
                x: pinOrigin.x + pin.size.width - diameter * 0.45,
                y: pinOrigin.y - diameter * 0.55,
                width: diameter,
                height: diameter
            )
            draw(kind, intensity, in: disc, context: context.cgContext)
        }
    }

    private static func draw(_ kind: Metar.Precipitation, _ intensity: Metar.Intensity, in disc: CGRect, context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 0.5), blur: 1.5, color: UIColor.black.withAlphaComponent(0.5).cgColor)
        UIColor(white: 0.08, alpha: 0.82).setFill()
        UIBezierPath(ovalIn: disc).fill()
        context.restoreGState()

        let ring = UIBezierPath(ovalIn: disc.insetBy(dx: 0.6, dy: 0.6))
        ring.lineWidth = 1.2
        ringColour(kind, intensity).setStroke()
        ring.stroke()

        guard let glyph = glyph(kind, intensity) else { return }
        let side = disc.width * 0.62
        let size = glyph.size
        let scale = min(side / max(size.width, 1), side / max(size.height, 1))
        let drawn = CGSize(width: size.width * scale, height: size.height * scale)
        glyph.draw(in: CGRect(
            x: disc.midX - drawn.width / 2,
            y: disc.midY - drawn.height / 2,
            width: drawn.width,
            height: drawn.height
        ))
    }

    /// The edge says how bad it is at a glance: amber round a storm, red round
    /// anything heavy, white otherwise.
    private static func ringColour(_ kind: Metar.Precipitation, _ intensity: Metar.Intensity) -> UIColor {
        if kind == .thunderstorm { return UIColor(red: 1.0, green: 0.78, blue: 0.2, alpha: 1) }
        if intensity == .heavy { return UIColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1) }
        return UIColor.white.withAlphaComponent(0.85)
    }

    private static func glyph(_ kind: Metar.Precipitation, _ intensity: Metar.Intensity) -> UIImage? {
        let weight = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        let rain = UIColor(red: 0.42, green: 0.74, blue: 1.0, alpha: 1)
        let ice = UIColor(red: 0.82, green: 0.93, blue: 1.0, alpha: 1)

        let name: String
        let palette: [UIColor]
        switch kind {
        case .thunderstorm:
            name = "cloud.bolt.rain.fill"
            palette = [.white, UIColor(red: 1.0, green: 0.82, blue: 0.25, alpha: 1), rain]
        case .snow:
            name = "snowflake"
            palette = [ice]
        case .rain:
            name = intensity == .heavy ? "cloud.heavyrain.fill" : "cloud.rain.fill"
            palette = [.white, rain]
        case .drizzle:
            name = "cloud.drizzle.fill"
            palette = [.white, rain]
        case .fog:
            name = "cloud.fog.fill"
            palette = [.white, UIColor(white: 0.72, alpha: 1)]
        }

        let colours = UIImage.SymbolConfiguration(paletteColors: palette)
        return UIImage(systemName: name, withConfiguration: weight.applying(colours))?
            .withRenderingMode(.alwaysOriginal)
    }
}

// MARK: - Close in over a field

extension FieldWeather {

    /// The weather where the map is looking, once it is close enough to be
    /// looking at a field: what the nearest field reporting any is reporting.
    struct Local: Equatable {
        let icao: String
        let kind: Metar.Precipitation
        let intensity: Metar.Intensity
        /// Where the wind is coming from, so the rain leans with it.
        let windFromDegrees: Int?
        let windKnots: Int?

        /// What is drawn changes only when one of these does, rounded so a
        /// report that moves the wind by a few degrees does not redraw it.
        var key: String {
            let wind = windFromDegrees.map { String($0 / 20) } ?? "-"
            let speed = windKnots.map { String(min($0, 40) / 10) } ?? "-"
            return "\(icao)|\(FieldWeather.key(kind, intensity))|\(wind)|\(speed)"
        }
    }

    /// How close the map has to be before anything falls: about a county
    /// across. Further out, the rain over one field would be falling on fifty.
    static let localMinZoom: Double = 7.5

    /// How far from the middle of the map a field can be and still be the one
    /// whose weather this is.
    static let localRadiusNM: Double = 25

    /// The nearest fields to a point that have filed a report, nearest first;
    /// the first answers. Fields that have never been asked are asked, and
    /// answer on a later pass.
    static func local(at centre: CLLocationCoordinate2D) -> Local? {
        let candidates = AirportStore.shared.nearestAirports(to: centre, withinNM: localRadiusNM, limit: 4)
        var unasked: [String] = []
        for airport in candidates {
            guard let report = WeatherService.shared.cached(airport.icao) else {
                unasked.append(airport.icao)
                continue
            }
            WeatherService.shared.prefetch(unasked)
            guard let kind = report.precipitation else { return nil }
            return Local(
                icao: airport.icao,
                kind: kind,
                intensity: report.intensity,
                windFromDegrees: report.windDirectionDegrees,
                windKnots: report.windSpeedKnots
            )
        }
        WeatherService.shared.prefetch(unasked)
        return nil
    }
}
