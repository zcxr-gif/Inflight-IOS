import Foundation

/// Whether the map draws 3D aircraft, and where they come from.
///
/// One collection: FlightAirMap's, free FlightGear aircraft converted to glTF.
/// Off is the flat sprites the map has always drawn. Earlier builds offered
/// Skytrails and Flightradar24 as well; a setting naming either is read as
/// FlightAirMap — see `AircraftModelStore.recoverFromCrashIfNeeded`.
///
/// Every model is GPL, and none of them is shipped with the app. Each one is
/// downloaded from the FlightAirMap repository the first time an aeroplane of
/// that type is on screen, and adapted on the phone so Mapbox can draw it —
/// see `GLBNormaliser`. Each model's authors and licence are in
/// `AircraftModelCatalog.credits`, and shown in Settings › Acknowledgements.
enum AircraftModelSource: String, CaseIterable, Identifiable {

    case off
    case flightAirMap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .flightAirMap: return "FlightAirMap"
        }
    }

    /// Prefix for the style model ids.
    var key: String {
        switch self {
        case .off: return "off"
        case .flightAirMap: return "fam"
        }
    }

    // MARK: - Credits

    /// The collection, which is also where every model's source files and
    /// licence are.
    static let repository = URL(string: "https://github.com/Ysurac/FlightAirMap-3dmodels")!

    /// Where FlightAirMap took the models from, as its README says.
    static let upstream = [
        URL(string: "https://github.com/FGMEMBERS")!,
        URL(string: "https://github.com/kalmykov/fr24-3d-models")!,
    ]

    static let credit = """
        The 3D aircraft are from the FlightAirMap 3D models collection by \
        Ysurac (FlightAirMap), converted to glTF from FlightGear aircraft \
        published by FGMEMBERS and from kalmykov/fr24-3d-models, by the \
        authors named for each model below.
        """
}
