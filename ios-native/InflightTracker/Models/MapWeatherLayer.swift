import Foundation

/// The weather drawn *under* the traffic, as tiles.
///
/// One at a time rather than a set of switches. The two cover the same sky from
/// two directions — radar sees what is falling now, the satellite sees what is
/// up there — and stacked they are two translucent images competing for the
/// same pixels with the map underneath them both. Picking one is also half the
/// tiles fetched.
///
/// They come from different places and answer on different clocks, which the
/// labels are careful about: RainViewer's radar is a ten-minute mosaic of the
/// last two hours, and NASA's satellite is a daily global composite.
enum MapWeatherLayer: String, CaseIterable, Identifiable {

    case off

    /// Composite radar reflectivity — where it is raining or snowing.
    case radar

    /// Satellite imagery — where the cloud is, including the vast majority of
    /// the sky that has no radar under it at all.
    case satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .radar: return "Radar"
        case .satellite: return "Cloud"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "slash.circle"
        case .radar: return "cloud.rain.fill"
        case .satellite: return "cloud.fill"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "No weather tiles. The map draws the traffic and nothing under it."
        case .radar:
            return "Composite precipitation radar, two hours of it. Coarse when zoomed right in — the free tier serves tiles only down to a low zoom and the map scales them up from there."
        case .satellite:
            return "NASA's global satellite imagery, a day at a time. Reads at cruise and out over the ocean, where there is no radar to see with — but it is today's picture rather than this minute's, and the strip can be dragged back through the last few days."
        }
    }
}

/// Which level the winds are drawn for.
///
/// Pressure levels, because that is what the model produces and what a chart
/// is drawn on; the flight level beside each is the rounded standard-atmosphere
/// height, which is the number a pilot actually thinks in.
enum WindLevel: String, CaseIterable, Identifiable {

    case fl050
    case fl100
    case fl180
    case fl300
    case fl340
    case fl390

    var id: String { rawValue }

    /// The pressure level Open-Meteo names this height by, e.g. `850hPa`.
    var pressureLevel: String {
        switch self {
        case .fl050: return "850hPa"
        case .fl100: return "700hPa"
        case .fl180: return "500hPa"
        case .fl300: return "300hPa"
        case .fl340: return "250hPa"
        case .fl390: return "200hPa"
        }
    }

    var label: String {
        switch self {
        case .fl050: return "050"
        case .fl100: return "100"
        case .fl180: return "180"
        case .fl300: return "300"
        case .fl340: return "340"
        case .fl390: return "390"
        }
    }

    var longLabel: String { "FL\(label)" }

    /// Roughly the altitude this level sits at, for saying which traffic it is
    /// the wind for.
    var approximateFeet: Int {
        switch self {
        case .fl050: return 5_000
        case .fl100: return 10_000
        case .fl180: return 18_000
        case .fl300: return 30_000
        case .fl340: return 34_000
        case .fl390: return 39_000
        }
    }

    /// The level closest to where an aircraft actually is, so opening a flight
    /// can put the barbs at its own height rather than at a default.
    static func nearest(toFeet feet: Double) -> WindLevel {
        allCases.min {
            abs(Double($0.approximateFeet) - feet) < abs(Double($1.approximateFeet) - feet)
        } ?? .fl340
    }

    /// The next model level *down*, and roughly how far below it sits.
    ///
    /// Only the shear layer wants this, and it wants it for the one reason
    /// shear exists: the difference in wind between two heights is not a number
    /// until you say how far apart they were. The gaps here are wildly uneven —
    /// four thousand feet between 250 and 300 hPa, twelve between 300 and 500 —
    /// so the difference has to be divided by the real spacing rather than
    /// treated as one step of a ladder.
    ///
    /// Standard-atmosphere heights, not the model's own geopotential. They are
    /// within a few hundred feet, and asking for two more series per point to
    /// improve a shear index by three per cent is not a trade worth making.
    var below: (pressureLevel: String, feet: Int) {
        switch self {
        case .fl050: return ("925hPa", 2_500)
        case .fl100: return ("850hPa", 5_000)
        case .fl180: return ("700hPa", 10_000)
        case .fl300: return ("500hPa", 18_300)
        case .fl340: return ("300hPa", 30_100)
        case .fl390: return ("250hPa", 34_000)
        }
    }

    /// The standard-atmosphere temperature at this level, in Celsius.
    ///
    /// What the temperature layer's colour scale is centred on, so the ramp
    /// says "warmer or colder than it should be here" at every level rather
    /// than drawing the whole flight levels in one blue and the whole lower
    /// airspace in one red. Fifteen degrees at sea level, less about two per
    /// thousand feet, and flat once you are in the stratosphere.
    var standardTemperature: Double {
        let feet = Double(approximateFeet)
        return max(15 - 1.98 * feet / 1_000, -56.5)
    }
}

/// A scalar field drawn as colour under the traffic.
///
/// ## Why a heat map rather than more numbers
///
/// The map already writes the wind at each marked field and draws an arrow
/// every few degrees. Both of those answer "what is it *here*", and neither
/// answers the question anybody watching traffic actually has, which is "where
/// is it". A jet stream is a shape. So is a band of shear, and so is the cold
/// pool an aircraft is about to fly into. A shape wants a picture.
///
/// One at a time, like the tile layers and for the same reason: two translucent
/// fields over each other are two fields you cannot read.
///
/// ## Everything here comes off one request
///
/// The winds fetch already asks a grid of points for wind at a pressure level.
/// Open-Meteo answers for as many variables as you name in the same call, so
/// temperature and the level below cost nothing but a longer URL — which is why
/// three fields exist rather than one, and why turning one on does not fetch
/// anything the barbs were not already fetching.
enum WeatherHeat: String, CaseIterable, Identifiable {

    case off

    /// Wind speed at the chosen level. The jet stream, drawn as the thing it
    /// is.
    case wind

    /// Temperature at the chosen level, against what the standard atmosphere
    /// says it should be there.
    case temperature

    /// Vertical wind shear between the chosen level and the one below it.
    ///
    /// Not a turbulence forecast, and the app never calls it one — clear-air
    /// turbulence needs stability as well as shear, and this has one of the
    /// two. What it is is the field every CAT index is built on top of, and
    /// where it is strong is where the bumps are.
    case shear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .wind: return "Wind"
        case .temperature: return "Temperature"
        case .shear: return "Shear"
        }
    }

    var symbol: String {
        switch self {
        case .off: return "slash.circle"
        case .wind: return "wind"
        case .temperature: return "thermometer.medium"
        case .shear: return "waveform.path.ecg"
        }
    }

    var detail: String {
        switch self {
        case .off:
            return "No field. The barbs, if they are on, are drawn over bare map."
        case .wind:
            return "Wind speed at the chosen level, as colour. Pulled back over an ocean this is the jet stream — where it is, how wide, and which side of it a flight is on."
        case .temperature:
            return "How far the air at the chosen level is from the standard atmosphere. Warm is thin: the same aircraft climbs worse and burns more in it."
        case .shear:
            return "How much the wind changes between this level and the one below, per thousand feet. Not a turbulence forecast — it is the field turbulence forecasts are built from, and the bumps are where it is strong."
        }
    }

    /// Whether this field needs the level below fetched as well.
    var needsLowerLevel: Bool { self == .shear }

    /// How the value reads under a finger, and on the legend.
    func reading(_ value: Double, wind unit: WindUnit, temperature: TemperatureUnit) -> String {
        switch self {
        case .off:
            return ""
        case .wind:
            return "\(Int(unit.convert(fromKnots: value).rounded())) \(unit.label)"
        case .temperature:
            // A *difference* in temperature, not a temperature — so Fahrenheit
            // is nine fifths of it and not nine fifths plus thirty-two.
            // Putting a deviation through the ordinary conversion is how a map
            // ends up reporting that the air everywhere is thirty-two degrees
            // warmer than standard.
            let degrees = temperature == .fahrenheit ? value * 9 / 5 : value
            let sign = degrees > 0 ? "+" : ""
            return "ISA \(sign)\(Int(degrees.rounded()))"
        case .shear:
            return String(format: "%.1f kt/1000ft", value)
        }
    }
}
