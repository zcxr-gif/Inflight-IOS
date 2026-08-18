import Foundation

/// The catalogue of everything one aircraft publishes, as the sim reported it.
///
/// State IDs are **not** constants. The manifest differs between aircraft — an
/// airliner publishes engine and slat states a Cessna has no concept of — and
/// is not promised to be stable across Infinite Flight releases. So nothing in
/// the app ever names a numeric id; every read goes through a path resolved
/// against the manifest fetched on this connection, and a state that is not in
/// it is a feature that quietly does not appear rather than a crash or, worse,
/// a plausible number read off the wrong id.
struct ConnectManifest {

    struct Entry: Equatable {
        let id: Int32
        let type: ConnectProtocol.ValueType
        let path: String
    }

    private(set) var byPath: [String: Entry] = [:]
    private(set) var byID: [Int32: Entry] = [:]

    var count: Int { byPath.count }
    var isEmpty: Bool { byPath.isEmpty }

    /// Parses the manifest string: one `id,type,path` record per line.
    ///
    /// Only the first two commas are structural. A path is free to contain one
    /// — nothing in the observed manifests does, but splitting on every comma
    /// would truncate it silently if one ever did, and a truncated path simply
    /// fails to resolve later with no clue as to why.
    init(raw: String) {
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            let record = line.trimmingCharacters(in: .whitespaces)
            guard !record.isEmpty else { continue }

            guard let firstComma = record.firstIndex(of: ",") else { continue }
            let afterFirst = record.index(after: firstComma)
            guard let secondComma = record[afterFirst...].firstIndex(of: ",") else { continue }

            guard let id = Int32(record[record.startIndex..<firstComma]),
                  let rawType = Int32(record[afterFirst..<secondComma]),
                  let type = ConnectProtocol.ValueType(rawValue: rawType) else { continue }

            let path = String(record[record.index(after: secondComma)...])
            guard !path.isEmpty else { continue }

            let entry = Entry(id: id, type: type, path: path)
            byPath[path] = entry
            byID[id] = entry
        }
    }

    init() {}

    subscript(path: String) -> Entry? { byPath[path] }
    func entry(for id: Int32) -> Entry? { byID[id] }

    /// The first of several candidate spellings that this aircraft actually
    /// publishes.
    ///
    /// The reason this takes a list rather than a path: the state names are
    /// documented in prose and observed from third-party manifest dumps, not
    /// published as a contract, so a handful of them are spelled more than one
    /// way across versions. Asking for every plausible spelling and taking
    /// what exists is the difference between a feature that survives an
    /// Infinite Flight update and one that needs an app release to keep
    /// working.
    func resolve(_ candidates: [String]) -> Entry? {
        for path in candidates {
            if let entry = byPath[path] { return entry }
        }
        return nil
    }

    /// Every path under a prefix, for diagnostics and for the manifest browser
    /// in the developer panel.
    func paths(under prefix: String) -> [String] {
        byPath.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    /// How many states each top-level namespace holds. Cheap shape report,
    /// shown when a connection is first made.
    var namespaceCounts: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for path in byPath.keys {
            let head = String(path.prefix(while: { $0 != "/" }))
            counts[head, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map { (name: $0.key, count: $0.value) }
    }
}

// MARK: - The states the tracker asks for

/// Every reading the app wants, named by what it means rather than by where it
/// lives.
///
/// Each case carries the paths it might be published under, most likely first.
/// Where only one spelling is known that list has one entry; where the naming
/// is uncertain it has several, and `tools/connect-probe` is what turns a guess
/// into a fact — run it against a real device and anything printed as missing
/// needs its spelling corrected here.
enum ConnectField: String, CaseIterable {

    // MARK: Session identity
    //
    // The reason any of this integrates rather than merely existing. The sim
    // knows which live flight it is, and that id is the same one the public
    // feed uses — so a Connect session can be matched to the aeroplane already
    // being drawn on the map, with no guessing from the pilot's name.

    case flightID
    case serverID
    case serverName
    case username
    case appState

    // MARK: Position and attitude

    case latitude
    case longitude
    case altitudeMSL
    case altitudeAGL
    case headingMagnetic
    case groundSpeed
    case indicatedAirspeed
    case trueAirspeed
    case verticalSpeed
    case pitch
    case bank

    // MARK: Configuration

    case gearState
    case flapsState
    case spoilersState
    case parkingBrake
    case fuelRemaining
    case engineCount

    // MARK: Landing statistics
    //
    // What the public feed can never produce. A touchdown lasts a fraction of
    // a second; the feed samples in seconds.

    case landingVerticalSpeed
    case landingScore
    case landingGForce
    case landingCentrelineOffset
    case landingAimingPointOffset
    case landingGroundSpeed
    case landingAirspeed
    case landingLatitude
    case landingLongitude
    case landingFlightTime

    /// The paths this field may be published under, in order of preference.
    var candidates: [String] {
        switch self {
        case .flightID:   return ["infiniteflight/live/current_flight/id"]
        case .serverID:   return ["infiniteflight/live/current_server/id"]
        case .serverName: return ["infiniteflight/live/current_server/name"]
        case .username:   return ["infiniteflight/current_user"]
        case .appState:   return ["infiniteflight/app_state"]

        // The position group is the one the sample manifest did not cover, so
        // each carries every spelling seen in the wild.
        case .latitude:
            return ["aircraft/0/latitude",
                    "aircraft/0/location/latitude",
                    "aircraft/0/systems/nav_sources/gps/location/latitude"]
        case .longitude:
            return ["aircraft/0/longitude",
                    "aircraft/0/location/longitude",
                    "aircraft/0/systems/nav_sources/gps/location/longitude"]
        case .altitudeMSL:
            return ["aircraft/0/altitude_msl",
                    "aircraft/0/altitude",
                    "aircraft/0/systems/nav_sources/gps/location/altitude"]
        case .altitudeAGL:
            return ["aircraft/0/altitude_agl"]
        case .headingMagnetic:
            return ["aircraft/0/heading_magnetic", "aircraft/0/heading"]
        case .groundSpeed:
            return ["aircraft/0/groundspeed", "aircraft/0/ground_speed"]
        case .indicatedAirspeed:
            return ["aircraft/0/indicated_airspeed", "aircraft/0/airspeed"]
        case .trueAirspeed:
            return ["aircraft/0/true_airspeed"]
        case .verticalSpeed:
            return ["aircraft/0/vertical_speed"]
        case .pitch:
            return ["aircraft/0/pitch"]
        case .bank:
            return ["aircraft/0/bank"]

        case .gearState:     return ["aircraft/0/systems/landing_gear/state"]
        case .flapsState:    return ["aircraft/0/systems/flaps/state"]
        case .spoilersState: return ["aircraft/0/systems/spoilers/state"]
        case .parkingBrake:  return ["aircraft/0/systems/parking_brake/state"]
        case .fuelRemaining: return ["aircraft/0/systems/fuel/fuel_remaining"]
        case .engineCount:   return ["aircraft/0/systems/engines/engine_count"]

        case .landingVerticalSpeed:
            return ["simulator/statistics/last_landing/vertical_speed"]
        case .landingScore:
            return ["simulator/statistics/last_landing/score"]
        case .landingGForce:
            return ["simulator/statistics/last_landing/max_g_force"]
        case .landingCentrelineOffset:
            return ["simulator/statistics/last_landing/distance_from_centerline"]
        case .landingAimingPointOffset:
            return ["simulator/statistics/last_landing/distance_from_1kft_marker"]
        case .landingGroundSpeed:
            return ["simulator/statistics/last_landing/ground_speed"]
        case .landingAirspeed:
            return ["simulator/statistics/last_landing/indicated_airspeed"]
        case .landingLatitude:
            return ["simulator/statistics/last_landing/location/latitude"]
        case .landingLongitude:
            return ["simulator/statistics/last_landing/location/longitude"]
        case .landingFlightTime:
            return ["simulator/statistics/last_landing/flight_time"]
        }
    }

    /// The fields read on every pass of the poll loop.
    ///
    /// Deliberately short. Each one is a round trip, they are issued strictly
    /// one at a time, and a poll that asks for sixty states takes sixty times
    /// as long to come round again — so this is only what changes second by
    /// second and is actually drawn or recorded.
    static let live: [ConnectField] = [
        .latitude, .longitude, .altitudeMSL, .altitudeAGL,
        .groundSpeed, .indicatedAirspeed, .verticalSpeed, .headingMagnetic
    ]

    /// Read once when the connection opens, and again when the flight changes.
    static let session: [ConnectField] = [
        .flightID, .serverID, .serverName, .username, .appState, .engineCount
    ]

    /// Read on a slower loop — these only change at a touchdown.
    static let landing: [ConnectField] = [
        .landingVerticalSpeed, .landingScore, .landingGForce,
        .landingCentrelineOffset, .landingAimingPointOffset,
        .landingGroundSpeed, .landingAirspeed,
        .landingLatitude, .landingLongitude, .landingFlightTime
    ]
}
