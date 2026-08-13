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

/// Weather display settings, from the toolbar's weather panel.
///
/// Everything here is presentation: which units a report is written in, and how
/// much of it the chip on the map shows. Nothing changes what is fetched, so
/// flipping any of it is instant and costs no network.
final class WeatherPreferences: ObservableObject {

    static let shared = WeatherPreferences()

    private static let temperatureKey = "weatherTemperatureUnit"
    private static let windKey = "weatherWindUnit"
    private static let chipKey = "weatherChipVisible"
    private static let routeEndsKey = "weatherShowsRouteEnds"

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

    private init() {
        let defaults = UserDefaults.standard

        temperatureUnit = TemperatureUnit(rawValue: defaults.string(forKey: Self.temperatureKey) ?? "")
            ?? .celsius
        windUnit = WindUnit(rawValue: defaults.string(forKey: Self.windKey) ?? "") ?? .knots

        // Both default on: no stored value means the user has never chosen,
        // and the chip is what the map has always shown.
        isChipVisible = defaults.object(forKey: Self.chipKey) as? Bool ?? true
        showsRouteEnds = defaults.object(forKey: Self.routeEndsKey) as? Bool ?? true
    }
}
