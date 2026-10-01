import Foundation

/// Where the 3D aircraft on the map come from — or that they are off.
///
/// Three open collections, for comparing side by side: switch between them
/// from the map's control stack and every aeroplane on the map is redrawn
/// from the one chosen. Off is the flat sprites the map has always drawn.
///
/// Every model is GPL, and none of them is shipped with the app. Each one is
/// downloaded from the repository its authors publish it in, the first time
/// an aeroplane of that type is on screen, and adapted on the phone so Mapbox
/// can draw it — see `GLBNormaliser`. The credits for all three are in
/// Settings › Acknowledgements.
enum AircraftModelSource: String, CaseIterable, Identifiable {

    case off
    case skytrails
    case flightAirMap
    case flightradar24

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .skytrails: return "Skytrails"
        case .flightAirMap: return "FlightAirMap"
        case .flightradar24: return "Flightradar24"
        }
    }

    var detail: String {
        switch self {
        case .off: return "The flat aircraft icons."
        case .skytrails: return "Small, plain, made for Mapbox."
        case .flightAirMap: return "Detailed, some in house colours."
        case .flightradar24: return "Detailed, mostly plain white."
        }
    }

    var symbol: String {
        switch self {
        case .off: return "airplane"
        case .skytrails, .flightAirMap, .flightradar24: return "cube.fill"
        }
    }

    /// Prefix for the style model ids, so two sources' A320s never collide.
    var key: String {
        switch self {
        case .off: return "off"
        case .skytrails: return "sky"
        case .flightAirMap: return "fam"
        case .flightradar24: return "fr24"
        }
    }

    // MARK: - Credits

    /// Where the models are published — and where their source is, which is
    /// the same place.
    var repository: URL? {
        switch self {
        case .off: return nil
        case .skytrails: return URL(string: "https://github.com/stagworksde/skytrails-aircraft-models")
        case .flightAirMap: return URL(string: "https://github.com/Ysurac/FlightAirMap-3dmodels")
        case .flightradar24: return URL(string: "https://github.com/Flightradar24/fr24-3d-models")
        }
    }

    var licence: String {
        switch self {
        case .off: return ""
        case .skytrails: return "GNU GPL v2"
        case .flightAirMap: return "GNU GPL v2 (ATR 72, Boeing 707 and PC-21: GNU GPL v3)"
        case .flightradar24: return "GNU GPL v2"
        }
    }

    var credit: String {
        switch self {
        case .off:
            return ""
        case .skytrails:
            return "Models built by skytrails-aircraft-models from FlightGear's AI aircraft (fgdata), by the "
                + "FlightGear contributors named in each model."
        case .flightAirMap:
            return "Models collected by FlightAirMap from the Flightradar24 3D models and the FGMEMBERS "
                + "FlightGear aircraft, by their respective authors."
        case .flightradar24:
            return "Models from the Flightradar24 3D view, built from FlightGear and FGMEMBERS aircraft by "
                + "their respective authors."
        }
    }
}
