import Foundation

/// How a temperature is written. Reports arrive in Celsius either way — this
/// is a display choice, made once and applied everywhere weather is shown.
enum TemperatureUnit: String, CaseIterable, Identifiable {

    case celsius
    case fahrenheit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }

    func convert(fromCelsius celsius: Double) -> Double {
        switch self {
        case .celsius: return celsius
        case .fahrenheit: return celsius * 9 / 5 + 32
        }
    }
}

/// How a wind speed is written. METARs are in knots; the other two are for
/// reading rather than for flying.
enum WindUnit: String, CaseIterable, Identifiable {

    case knots
    case mph
    case kmh

    var id: String { rawValue }

    var label: String {
        switch self {
        case .knots: return "kt"
        case .mph: return "mph"
        case .kmh: return "km/h"
        }
    }

    func convert(fromKnots knots: Double) -> Double {
        switch self {
        case .knots: return knots
        case .mph: return knots * 1.15078
        case .kmh: return knots * 1.852
        }
    }
}

/// Weather settings, from the toolbar's weather panel.
///
/// Most of it is presentation — which units a report is written in, and how
/// much of it the chip on the map shows — and all of that is free to flip,
/// because nothing about it changes what is fetched.
///
/// The map layers at the bottom are the exception, and they are here rather
/// than under the filters because this is where somebody looks for weather.
/// Those do cost network: tiles while a layer is on, and a grid of model wind
/// while the barbs are. Both are off by default for that reason.
final class WeatherPreferences: ObservableObject {

    static let shared = WeatherPreferences()

    private static let temperatureKey = "weatherTemperatureUnit"
    private static let windKey = "weatherWindUnit"
    private static let chipKey = "weatherChipVisible"
    private static let routeEndsKey = "weatherShowsRouteEnds"
    private static let layerKey = "weather.mapLayer"
    private static let animateKey = "weather.animatesRadar"
    private static let windsKey = "weather.showsWinds"
    private static let windLevelKey = "weather.windLevel"
    private static let fieldsKey = "weather.showsFieldConditions"

    @Published var temperatureUnit: TemperatureUnit {
        didSet { UserDefaults.standard.set(temperatureUnit.rawValue, forKey: Self.temperatureKey) }
    }

    @Published var windUnit: WindUnit {
        didSet { UserDefaults.standard.set(windUnit.rawValue, forKey: Self.windKey) }
    }

    /// Whether the chip appears over the map at all while an aircraft is open.
    @Published var isChipVisible: Bool {
        didSet { UserDefaults.standard.set(isChipVisible, forKey: Self.chipKey) }
    }

    /// Whether opening the chip adds the route's two ends to the field being
    /// passed. Off, the chip is only ever about where the aircraft is now.
    @Published var showsRouteEnds: Bool {
        didSet { UserDefaults.standard.set(showsRouteEnds, forKey: Self.routeEndsKey) }
    }

    /// Which weather tiles are drawn under the traffic, if any.
    @Published var mapLayer: MapWeatherLayer {
        didSet { UserDefaults.standard.set(mapLayer.rawValue, forKey: Self.layerKey) }
    }

    /// Whether the radar runs through its two hours of frames instead of
    /// sitting on the newest one.
    ///
    /// The frames are already fetched either way — the index lists all of them
    /// — so this costs tiles rather than requests, and only for the frames it
    /// actually reaches.
    @Published var animatesRadar: Bool {
        didSet { UserDefaults.standard.set(animatesRadar, forKey: Self.animateKey) }
    }

    /// Whether wind barbs are drawn across the visible map.
    @Published var showsWinds: Bool {
        didSet { UserDefaults.standard.set(showsWinds, forKey: Self.windsKey) }
    }

    /// The height those barbs are for.
    @Published var windLevel: WindLevel {
        didSet { UserDefaults.standard.set(windLevel.rawValue, forKey: Self.windLevelKey) }
    }

    /// Whether a marked field carries its wind and temperature on the map
    /// once the map is close enough to read them.
    ///
    /// Free: the reports are already fetched for the flight categories the
    /// ICAOs are coloured in, so this only decides whether they are drawn.
    @Published var showsFieldConditions: Bool {
        didSet { UserDefaults.standard.set(showsFieldConditions, forKey: Self.fieldsKey) }
    }

    private init() {
        let defaults = UserDefaults.standard

        // Both layers default off: each is a request the app would otherwise
        // never make, and a map that starts covered in someone else's weather
        // is not the map anybody asked for.
        mapLayer = MapWeatherLayer(rawValue: defaults.string(forKey: Self.layerKey) ?? "") ?? .off
        showsWinds = defaults.bool(forKey: Self.windsKey)
        windLevel = WindLevel(rawValue: defaults.string(forKey: Self.windLevelKey) ?? "") ?? .fl340
        // On, but only meaningful while a layer is: it animates what is
        // already there.
        animatesRadar = defaults.object(forKey: Self.animateKey) as? Bool ?? true
        // On by default, because it costs nothing and it is the one piece of
        // weather that is already on the device.
        showsFieldConditions = defaults.object(forKey: Self.fieldsKey) as? Bool ?? true

        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Self.temperatureKey) ?? "")
            ?? .celsius
        windUnit = WindUnit(rawValue: defaults.string(forKey: Self.windKey) ?? "") ?? .knots

        // Both default on: no stored value means the user has never chosen,
        // and the chip is what the map has always shown.
        isChipVisible = defaults.object(forKey: Self.chipKey) as? Bool ?? true
        showsRouteEnds = defaults.object(forKey: Self.routeEndsKey) as? Bool ?? true
    }
}
