import MapboxMaps
import SwiftUI
import UIKit

/// The drawn map, edited: what time of day it is lit for, what colour its
/// water and land are, what its names are set in, and which of them it draws.
///
/// Pro, all of it — see `ProFeature.mapCustomise`. Everybody chooses which map
/// they look at; this is changing the one they chose.
///
/// Every setting here is configuration on Mapbox Standard rather than a style
/// of the app's own, which is the whole reason it is cheap: Mapbox applies a
/// change of configuration to the style already loaded, cross-faded, without
/// reloading anything — see `MapLook.mapStyle(isLight:)`. The imagery has none
/// of these to set but the light, the names and the borders, and the drawn
/// planet is not Mapbox at all.
struct MapCustomisation: Equatable {

    var light: MapLight = .auto
    var tint: MapTint = .standard
    var font: MapFont = .standard
    var showsPlaceNames = true
    var showsRoadNames = true
    var showsBorders = true

    /// Buildings and landmarks standing up out of the map.
    ///
    /// Off unless asked for, and the default the map has always had: this is a
    /// traffic map, and a city's worth of extrusions is both something else
    /// standing up besides the aeroplanes and a real share of the GPU a pinch
    /// would otherwise have.
    var shows3DBuildings = false

    /// The map as everybody gets it.
    static let standard = MapCustomisation()

    var isStandard: Bool { self == .standard }

    /// A short stamp of everything here, for caching pictures of it.
    var key: String {
        [
            light.rawValue,
            tint.rawValue,
            font.rawValue,
            showsPlaceNames ? "p" : "-",
            showsRoadNames ? "r" : "-",
            showsBorders ? "b" : "-",
            shows3DBuildings ? "3" : "-"
        ].joined()
    }
}

/// The time of day the map is lit for.
///
/// Auto is what the map has always done: day when the map is light, night
/// when it is dark. The rest pin it, whatever the palette says — a dusk-lit
/// map at cruise is the one thing the four palettes could never draw.
enum MapLight: String, CaseIterable, Identifiable {
    case auto
    case dawn
    case day
    case dusk
    case night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .dawn: return "Dawn"
        case .day: return "Day"
        case .dusk: return "Dusk"
        case .night: return "Night"
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .dawn: return "sunrise"
        case .day: return "sun.max"
        case .dusk: return "sunset"
        case .night: return "moon.stars"
        }
    }

    /// Mapbox's own preset, or nil to follow the map's light and dark.
    var preset: StandardLightPreset? {
        switch self {
        case .auto: return nil
        case .dawn: return .dawn
        case .day: return .day
        case .dusk: return .dusk
        case .night: return .night
        }
    }
}

/// What colour the water, the land and the green spaces are.
///
/// A handful of sets rather than three free colour wells: a map is legible
/// because its colours are chosen to sit together, and three independent
/// pickers are mostly a way of finding the combinations that do not. Each set
/// is one idea, and Mapbox's lighting still takes it through the night.
enum MapTint: String, CaseIterable, Identifiable {
    case standard
    case chart
    case ocean
    case forest
    case sand
    case slate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .chart: return "Chart"
        case .ocean: return "Ocean"
        case .forest: return "Forest"
        case .sand: return "Sand"
        case .slate: return "Slate"
        }
    }

    /// Water, land and green, or nil for Mapbox's own.
    private var colours: (water: UIColor, land: UIColor, green: UIColor)? {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
            UIColor(red: r, green: g, blue: b, alpha: 1)
        }
        switch self {
        case .standard:
            return nil
        case .chart:
            // A sectional chart's: pale blue water on cream, with the low
            // ground green.
            return (rgb(0.60, 0.80, 0.93), rgb(0.98, 0.96, 0.88), rgb(0.80, 0.90, 0.70))
        case .ocean:
            return (rgb(0.20, 0.52, 0.84), rgb(0.93, 0.94, 0.96), rgb(0.70, 0.85, 0.74))
        case .forest:
            return (rgb(0.42, 0.60, 0.64), rgb(0.86, 0.89, 0.82), rgb(0.42, 0.66, 0.44))
        case .sand:
            return (rgb(0.52, 0.74, 0.80), rgb(0.96, 0.91, 0.82), rgb(0.78, 0.83, 0.64))
        case .slate:
            return (rgb(0.40, 0.47, 0.56), rgb(0.80, 0.82, 0.85), rgb(0.64, 0.71, 0.69))
        }
    }

    var water: StyleColor? { colours.map { StyleColor($0.water) } }
    var land: StyleColor? { colours.map { StyleColor($0.land) } }
    var green: StyleColor? { colours.map { StyleColor($0.green) } }

    /// The swatch drawn for this choice: land, with its water across it.
    var swatch: (land: Color, water: Color)? {
        colours.map { (Color(uiColor: $0.land), Color(uiColor: $0.water)) }
    }
}

/// What the names on the map are set in.
///
/// A short list of Mapbox's own faces, picked to be different from each other
/// rather than to be exhaustive: a sans, a geometric, a slab, a serif and a
/// monospace are five distinct maps, and a list of thirty is mostly the same
/// one.
enum MapFont: String, CaseIterable, Identifiable {
    case standard
    case inter
    case montserrat
    case robotoMono
    case garamond
    case rubik

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .inter: return "Inter"
        case .montserrat: return "Montserrat"
        case .robotoMono: return "Mono"
        case .garamond: return "Garamond"
        case .rubik: return "Rubik"
        }
    }

    var standardFont: StandardFont? {
        switch self {
        case .standard: return nil
        case .inter: return .inter
        case .montserrat: return .montserrat
        case .robotoMono: return .robotoMono
        case .garamond: return .ebGaramond
        case .rubik: return .rubik
        }
    }

    /// A system face that suggests this one, for the chip that offers it. Not
    /// the font itself — that lives in Mapbox's glyph server, not in the app —
    /// but enough to tell a serif from a monospace at a glance.
    var preview: Font.Design {
        switch self {
        case .standard, .inter, .montserrat: return .default
        case .robotoMono: return .monospaced
        case .garamond: return .serif
        case .rubik: return .rounded
        }
    }
}
