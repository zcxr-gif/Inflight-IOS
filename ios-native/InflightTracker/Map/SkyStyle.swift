import CoreLocation
import Foundation

/// The sky over the map when it is tilted far enough to show one: the colour
/// of the real sky over wherever the map is looking, now.
///
/// Worked out from the sun's height there (`SolarPosition`) through five
/// skies — night, twilight, the golden hour, a low sun and full day — and
/// blended between them, so the sky over a flight into the evening goes
/// gold, then violet, then dark with stars, a degree of sun at a time.
///
/// Each sky comes in two strengths, for the light map and the dark one: the
/// same sky, but on the dark map a deeper blue and a horizon that glows less,
/// so the ground under it does not look as if a light had been left on.
///
/// Pulled out to a whole planet on the globe, the sky gives way to space.
enum SkyStyle {

    /// One sky. The colours are Mapbox's: `horizon` is the haze at the
    /// horizon and over the distant ground, `high` the sky overhead, and
    /// `space` what is above that.
    struct Palette: Equatable {
        var horizon: RGB
        var high: RGB
        var space: RGB
        var stars: Double
        var blend: Double
    }

    struct RGB: Equatable {
        var red: Double
        var green: Double
        var blue: Double

        init(_ hex: UInt32) {
            red = Double((hex >> 16) & 0xff)
            green = Double((hex >> 8) & 0xff)
            blue = Double(hex & 0xff)
        }

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        func mixed(with other: RGB, _ share: Double) -> RGB {
            RGB(
                red: red + (other.red - red) * share,
                green: green + (other.green - green) * share,
                blue: blue + (other.blue - blue) * share
            )
        }

        var css: String {
            "rgb(\(Int(red.rounded())), \(Int(green.rounded())), \(Int(blue.rounded())))"
        }
    }

    /// The skies, by the sun's height in degrees.
    private static let light: [(sun: Double, palette: Palette)] = [
        (-14, Palette(horizon: RGB(0x26314d), high: RGB(0x0d1530), space: RGB(0x04060f), stars: 0.7, blend: 0.10)),
        (-7, Palette(horizon: RGB(0x8c7aa6), high: RGB(0x2f3a72), space: RGB(0x0f1638), stars: 0.3, blend: 0.16)),
        (2, Palette(horizon: RGB(0xf7bf8c), high: RGB(0x6a7fc0), space: RGB(0x27336e), stars: 0, blend: 0.16)),
        (10, Palette(horizon: RGB(0xeadfcf), high: RGB(0x5a92d6), space: RGB(0x2b5fb0), stars: 0, blend: 0.12)),
        (25, Palette(horizon: RGB(0xd8eaf8), high: RGB(0x4a97e8), space: RGB(0x2a6fcf), stars: 0, blend: 0.10)),
    ]

    private static let dark: [(sun: Double, palette: Palette)] = [
        (-14, Palette(horizon: RGB(0x121a2b), high: RGB(0x080d20), space: RGB(0x020309), stars: 0.8, blend: 0.10)),
        (-7, Palette(horizon: RGB(0x4a3f63), high: RGB(0x1e2650), space: RGB(0x0a0f28), stars: 0.35, blend: 0.14)),
        (2, Palette(horizon: RGB(0xa8705a), high: RGB(0x3e4f8c), space: RGB(0x19224f), stars: 0.05, blend: 0.14)),
        (10, Palette(horizon: RGB(0x7d7f92), high: RGB(0x335f9f), space: RGB(0x1c3f7a), stars: 0, blend: 0.10)),
        (25, Palette(horizon: RGB(0x5d7ea6), high: RGB(0x2f6dbd), space: RGB(0x1d4f9c), stars: 0, blend: 0.08)),
    ]

    /// The sky for a sun this many degrees above the horizon.
    static func palette(sunElevation: Double, isLight: Bool) -> Palette {
        let skies = isLight ? light : dark
        guard sunElevation > skies[0].sun else { return skies[0].palette }
        for index in 1..<skies.count where sunElevation <= skies[index].sun {
            let low = skies[index - 1]
            let high = skies[index]
            let share = (sunElevation - low.sun) / (high.sun - low.sun)
            return Palette(
                horizon: low.palette.horizon.mixed(with: high.palette.horizon, share),
                high: low.palette.high.mixed(with: high.palette.high, share),
                space: low.palette.space.mixed(with: high.palette.space, share),
                stars: low.palette.stars + (high.palette.stars - low.palette.stars) * share,
                blend: low.palette.blend + (high.palette.blend - low.palette.blend) * share
            )
        }
        return skies[skies.count - 1].palette
    }

    /// The sky over a place, now.
    static func palette(at coordinate: CLLocationCoordinate2D, date: Date = Date(), isLight: Bool) -> Palette {
        palette(sunElevation: SolarPosition.elevationDegrees(at: coordinate, date: date), isLight: isLight)
    }

    /// Space, for the globe seen whole: dark, with stars, and a rim of the
    /// sky's own colour round the planet.
    private static let space = RGB(0x070a16)

    /// The zooms the sky gives way to space between.
    private static let spaceZoom = 4.0
    private static let skyZoom = 7.0

    /// The sky as Mapbox's atmosphere.
    static func atmosphere(_ palette: Palette) -> [String: Any] {
        func zoomed(_ far: Any, _ near: Any) -> [Any] {
            ["interpolate", ["linear"], ["zoom"], spaceZoom, far, skyZoom, near]
        }
        return [
            "range": [2.0, 18.0],
            "color": palette.horizon.css,
            "high-color": palette.high.css,
            "space-color": zoomed(space.mixed(with: palette.space, 0.15).css, palette.space.css),
            "horizon-blend": zoomed(0.06, palette.blend),
            "star-intensity": zoomed(max(palette.stars, 0.35), palette.stars),
        ]
    }
}
