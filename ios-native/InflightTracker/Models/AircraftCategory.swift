import Foundation

/// What kind of aeroplane it is, for narrowing the map to one.
///
/// Derived from the sprite key rather than from the type name again. That key
/// is already resolved once per aircraft at parse time, by the catalogue that
/// knows every name Infinite Flight sends — so this is a dictionary lookup on
/// a string the app has anyway, and a type the catalogue learns to recognise
/// lands in the right group here for free.
///
/// Coarse on purpose. The point is "hide the fighters" or "airliners only",
/// which is five choices; a filter with one row per airframe would be a list to
/// read rather than a control to use.
enum AircraftCategory: String, CaseIterable, Identifiable, Hashable {

    case airliner
    case regional
    case light
    case military
    case helicopter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .airliner: return "Airliners"
        case .regional: return "Regional"
        case .light: return "Light & private"
        case .military: return "Military"
        case .helicopter: return "Helicopters"
        }
    }

    var symbol: String {
        switch self {
        case .airliner: return "airplane"
        case .regional: return "airplane.departure"
        case .light: return "paperplane"
        case .military: return "shield"
        case .helicopter: return "fan.desk"
        }
    }

    /// The group a sprite key belongs to.
    ///
    /// Anything unrecognised counts as an airliner, which is the same call the
    /// catalogue itself makes: an unknown type already draws the generic 737
    /// icon, so grouping it anywhere else would put an aircraft in a category
    /// its own icon contradicts.
    static func from(spriteKey: String) -> AircraftCategory {
        bySpriteKey[spriteKey] ?? .airliner
    }

    /// Written out rather than matched by prefix: these are the catalogue's own
    /// keys, a closed set of about thirty, and a table is both faster per
    /// lookup and impossible to get subtly wrong the way a run of `contains`
    /// checks can be.
    private static let bySpriteKey: [String: AircraftCategory] = [
        // Airliners — everything an airline flies on a jet.
        "B737": .airliner, "A320": .airliner, "B757": .airliner, "B767": .airliner,
        "B777": .airliner, "B787": .airliner, "A330": .airliner, "A340": .airliner,
        "A350": .airliner, "A380": .airliner, "B747": .airliner, "A300": .airliner,
        "MD80": .airliner, "FOKKER100": .airliner, "RJ100": .airliner,

        // Regional — the short hops, jet and turboprop alike.
        "E190": .regional, "DASH8": .regional, "AT42": .regional, "AT72": .regional,

        // Light and private — business jets, general aviation, and the two
        // things that are neither but are certainly not airline traffic.
        "PRIVATEJET": .light, "SINGLEPROP": .light, "PA28": .light,
        "TWINPROP": .light, "PC12": .light, "GLIDER": .light, "BALLOON": .light,

        // Military — fast jets, transports, tankers, and the warbirds, which
        // are military airframes whatever they are flown as now.
        "F16": .military, "C130": .military, "C17": .military, "B52": .military,
        "U2": .military, "T38": .military, "TOR": .military, "KC35R": .military,
        "E3CF": .military, "HAWK": .military, "A400": .military,
        "SPIT": .military, "LANC": .military,

        "EUROCOPTER": .helicopter
    ]
}
