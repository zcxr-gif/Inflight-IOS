import Foundation

/// A WMO present-weather code, as a condition anybody can read.
///
/// This is the one thing a model gives you that a proprietary weather API used
/// to hand over already done: WeatherKit answered with a `condition` and a
/// `symbolName`, and losing it was the only real cost of leaving. Open-Meteo —
/// like every meteorological service that is not somebody's product — answers
/// with WMO code 4677, which is the international table the observations
/// themselves are written in.
///
/// So the table lives here. It is not a long one, and it is the same table for
/// every model and every provider, which is more than could be said for the
/// symbol names.
///
/// ## Why the codes are collapsed rather than listed
///
/// The published table distinguishes slight, moderate and heavy for each kind
/// of precipitation, and a forecast panel that draws three different symbols
/// for three intensities of the same rain is a panel with three symbols nobody
/// can tell apart. The *label* keeps the intensity, because "Heavy rain" and
/// "Slight rain" are worth different decisions; the symbol keeps the kind.
enum WeatherCode {

    /// What the sky is doing, in the words the panel writes.
    static func label(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mainly clear"
        case 2: return "Partly cloudy"
        case 3: return "Overcast"
        case 45, 48: return "Fog"
        case 51: return "Light drizzle"
        case 53: return "Drizzle"
        case 55: return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61: return "Light rain"
        case 63: return "Rain"
        case 65: return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71: return "Light snow"
        case 73: return "Snow"
        case 75: return "Heavy snow"
        case 77: return "Snow grains"
        case 80: return "Light showers"
        case 81: return "Showers"
        case 82: return "Violent showers"
        case 85: return "Snow showers"
        case 86: return "Heavy snow showers"
        case 95: return "Thunderstorms"
        case 96, 99: return "Thunderstorms with hail"
        default: return "Unsettled"
        }
    }

    /// The SF Symbol for it, which needs to know whether the sun is up.
    ///
    /// Only the three quiet codes care: rain at midnight looks like rain, but
    /// "mainly clear" is a sun or a moon and getting that wrong is the one
    /// mistake on this panel a reader notices instantly.
    ///
    /// The names are the ones `Metar.symbol(isDaylight:)` picks from, so a
    /// field's filed report and the model's answer for the field beside it draw
    /// the same weather the same way.
    static func symbol(_ code: Int, isDaylight: Bool) -> String {
        switch code {
        case 0: return isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55, 56, 57: return "cloud.drizzle.fill"
        case 61, 63, 65, 66, 67: return "cloud.rain.fill"
        case 71, 73, 75, 77, 85, 86: return "cloud.snow.fill"
        case 80, 81, 82: return isDaylight ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case 95, 96, 99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    /// What is falling, for the sentence over the near-term graph. Nil where
    /// nothing is.
    static func precipitation(_ code: Int) -> String? {
        switch code {
        case 51, 53, 55, 56, 57: return "Drizzle"
        case 61, 63, 65, 66, 67, 80, 81, 82: return "Rain"
        case 71, 73, 75, 77, 85, 86: return "Snow"
        case 95, 96, 99: return "Thunderstorms"
        default: return nil
        }
    }
}
