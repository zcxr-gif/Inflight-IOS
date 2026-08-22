import Foundation

/// The weather drawn *under* the traffic, as tiles.
///
/// One at a time rather than a set of switches. Radar and satellite cover the
/// same sky from two directions — radar sees what is falling, infrared sees
/// what is up there — and stacked they are two translucent images competing
/// for the same pixels with the map underneath them both. Picking one is also
/// half the tiles fetched, which matters on a metered API.
enum MapWeatherLayer: String, CaseIterable, Identifiable {

    case off

    /// Composite radar reflectivity — where it is raining or snowing.
    case radar

    /// Infrared satellite — where the cloud is, including the vast majority of
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
            return "Infrared cloud cover. Reads at cruise and out over the ocean, where there is no radar to see with."
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
}
