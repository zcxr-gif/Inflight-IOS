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
        return resolveByLeaf(candidates)
    }

    /// Last resort: the right leaf in the right namespace.
    ///
    /// Every candidate list in `ConnectField` is a list of exact spellings, and
    /// an exact spelling is a bet that Infinite Flight has not moved a state
    /// since somebody wrote it down. When that bet loses, the field is simply
    /// never read — the panel lists it as unpublished and the pilot sees an
    /// empty flight window with nothing to explain it. That is a bad way to
    /// fail, because the state is usually *there*, one directory along:
    /// `aircraft/0/latitude` becoming
    /// `aircraft/0/systems/nav_sources/gps/location/latitude` is a rename, not
    /// a removal.
    ///
    /// So a miss falls back to the last path component, scoped to the
    /// namespace the candidate named — and for `aircraft`, to aircraft **0**,
    /// which is the one being flown. Without that scope a latitude could be
    /// answered by another aeroplane's.
    ///
    /// The shortest match wins, so the canonical `aircraft/0/latitude` is
    /// preferred over a copy buried in a subsystem, and ties break
    /// alphabetically so the choice is at least stable between connections.
    private func resolveByLeaf(_ candidates: [String]) -> Entry? {
        for candidate in candidates {
            guard let slash = candidate.lastIndex(of: "/") else { continue }
            let leaf = String(candidate[candidate.index(after: slash)...])

            // Short leaves match far too much. `on`, `id`, `name` and `state`
            // appear under dozens of subsystems, and a wrong number is worse
            // than a missing one.
            guard leaf.count >= 5 else { continue }

            let root = String(candidate.prefix(while: { $0 != "/" }))
            let scope = root == "aircraft" ? "aircraft/0/" : root + "/"
            let suffix = "/" + leaf

            let best = byPath
                .filter { $0.key.hasPrefix(scope) && $0.key.hasSuffix(suffix) }
                .min { ($0.key.count, $0.key) < ($1.key.count, $1.key) }

            if let best { return best.value }
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
    case appVersion

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
    case turnRate

    // MARK: Configuration
    //
    // What the aeroplane is set up to do. Individually small, collectively the
    // difference between "an aircraft at 3,000 feet" and "an aircraft
    // configured for landing" — which is the thing a person watching actually
    // wants to know.

    case gearState
    case flapsState
    case flapsAngle
    case spoilersState
    case parkingBrake
    case reverseThrust
    case transponderCode
    case seatbeltSign

    // MARK: Lights
    //
    // Cheap to read and unusually informative: strobes on means lined up, and
    // landing lights below ten thousand feet means somebody flying properly.

    case beaconLights
    case landingLights
    case navLights
    case strobeLights

    // MARK: Fuel and engines

    case fuelRemaining
    case engineCount
    case engineN1
    case engineThrust

    // MARK: What the aeroplane is complaining about

    case warningStalling
    case warningOverspeed

    // MARK: Outside
    //
    // The sim's own weather at the aircraft, which is a different and better
    // thing than the METAR at the field below: it is what is actually hitting
    // the aeroplane.

    case windDirection
    case windVelocity
    case windGust
    case temperature
    case turbulence

    // MARK: Navigation

    case nearestAirport
    case nextWaypoint
    case flightTime

    // MARK: ATC
    //
    // Not in the state manifest this was built against, and named from the
    // Infinite Flight developer reference rather than observed — so both carry
    // several spellings and the feature simply does not appear if none of them
    // resolves. `tools/connect-probe` is what settles it.
    //
    // This is the sim's own log: what THIS aircraft sent and heard on
    // frequency. Not a global ATC feed, and not something the server could ever
    // fetch.

    /// Written, not read: turning the stream on.
    case atcStreamEnable

    /// The messages themselves, which arrive as frames nobody asked for — see
    /// the note on `ConnectTransport.Waiter`.
    case atcMessage

    /// Who this aeroplane is tuned to, by name — "Los Angeles Tower".
    ///
    /// Not a transcript and not a substitute for one. It is the single state
    /// the comm radio publishes, it is polled like any other, and it changes
    /// when the pilot changes frequency. Worth having on its own: it is the
    /// half of "on frequency" that is actually in the manifest, where the
    /// message stream may well not be in this build at all.
    case atcFacility

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
        // More than one spelling, unlike the two above, because this one now
        // does something rather than being displayed: it fills in the join
        // between this account and an aeroplane on the map. A rename that costs
        // a line in a panel is a nuisance; a rename that silently costs the
        // join is a pilot who is told nothing about their own flight.
        case .username:   return [
            "infiniteflight/current_user",
            "infiniteflight/live/current_user",
            "infiniteflight/current_user/name",
            "infiniteflight/live/current_user/username",
            "infiniteflight/username",
        ]
        case .appState:   return ["infiniteflight/app_state"]
        case .appVersion: return ["infiniteflight/app_version"]

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
        case .turnRate:
            return ["aircraft/0/turn_rate"]

        case .gearState:       return ["aircraft/0/systems/landing_gear/state"]
        case .flapsState:      return ["aircraft/0/systems/flaps/state"]
        case .flapsAngle:      return ["aircraft/0/systems/flaps/left_flap_angle"]
        case .spoilersState:   return ["aircraft/0/systems/spoilers/state"]
        case .parkingBrake:    return ["aircraft/0/systems/parking_brake/state"]
        case .reverseThrust:   return ["aircraft/0/systems/reverse/state"]
        case .transponderCode: return ["aircraft/0/systems/transponder/1/code"]
        case .seatbeltSign:    return ["aircraft/0/systems/signs/seatbelt"]

        case .beaconLights:
            return ["aircraft/0/systems/light_controller/beacon_lights_controller/state"]
        case .landingLights:
            return ["aircraft/0/systems/light_controller/landing_lights_controller/state"]
        case .navLights:
            return ["aircraft/0/systems/light_controller/nav_lights_controller/state"]
        case .strobeLights:
            return ["aircraft/0/systems/light_controller/strobe_lights_controller/state"]

        case .fuelRemaining: return ["aircraft/0/systems/fuel/fuel_remaining"]
        case .engineCount:   return ["aircraft/0/systems/engines/engine_count"]
        case .engineN1:      return ["aircraft/0/systems/engines/1/n1"]
        case .engineThrust:  return ["aircraft/0/systems/engines/1/thrust_percentage"]

        case .warningStalling:  return ["aircraft/0/warning_stalling"]
        case .warningOverspeed: return ["aircraft/0/warning_overspeed"]

        case .windDirection: return ["environment/wind_direction_true"]
        case .windVelocity:  return ["environment/wind_velocity"]
        case .windGust:      return ["environment/wind_gust_velocity"]
        case .temperature:   return ["environment/temperature"]
        case .turbulence:    return ["environment/turbulence_factor"]

        case .atcStreamEnable:
            return ["api/stream/enable_atc_messages",
                    "stream/enable_atc_messages",
                    "infiniteflight/stream/enable_atc_messages"]
        case .atcMessage:
            return ["upstream/atc/message_received",
                    "api/upstream/atc/message_received",
                    "atc/message_received"]
        // Observed in a real manifest rather than guessed from the developer
        // reference, which is why it leads. com_2 is the standby radio and is
        // read only if com_1 is absent.
        case .atcFacility:
            return ["aircraft/0/systems/comm_radios/com_1/atc_name",
                    "aircraft/0/systems/comm_radios/com_2/atc_name",
                    "aircraft/0/comm_radios/com_1/atc_name"]

        case .nearestAirport: return ["infiniteflight/nearest_airport"]
        case .nextWaypoint:
            return ["aircraft/0/systems/nav_sources/gps/next_waypoint_name"]
        case .flightTime:     return ["simulator/flight_time"]

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

    /// A readable name, for the panel and for the list of what an aircraft did
    /// not publish.
    var label: String {
        switch self {
        case .flightID:          return "Flight"
        case .serverID:          return "Server id"
        case .serverName:        return "Server"
        case .username:          return "Pilot"
        case .appState:          return "App state"
        case .appVersion:        return "App version"
        case .latitude:          return "Latitude"
        case .longitude:         return "Longitude"
        case .altitudeMSL:       return "Altitude"
        case .altitudeAGL:       return "Height above ground"
        case .headingMagnetic:   return "Heading"
        case .groundSpeed:       return "Ground speed"
        case .indicatedAirspeed: return "Indicated airspeed"
        case .trueAirspeed:      return "True airspeed"
        case .verticalSpeed:     return "Vertical speed"
        case .pitch:             return "Pitch"
        case .bank:              return "Bank"
        case .turnRate:          return "Turn rate"
        case .gearState:         return "Gear"
        case .flapsState:        return "Flaps"
        case .flapsAngle:        return "Flap angle"
        case .spoilersState:     return "Spoilers"
        case .parkingBrake:      return "Parking brake"
        case .reverseThrust:     return "Reverse"
        case .transponderCode:   return "Squawk"
        case .seatbeltSign:      return "Seatbelt sign"
        case .beaconLights:      return "Beacon"
        case .landingLights:     return "Landing lights"
        case .navLights:         return "Nav lights"
        case .strobeLights:      return "Strobes"
        case .fuelRemaining:     return "Fuel"
        case .engineCount:       return "Engines"
        case .engineN1:          return "N1"
        case .engineThrust:      return "Thrust"
        case .warningStalling:   return "Stall warning"
        case .warningOverspeed:  return "Overspeed warning"
        case .windDirection:     return "Wind direction"
        case .windVelocity:      return "Wind speed"
        case .windGust:          return "Gusting"
        case .temperature:       return "Temperature"
        case .turbulence:        return "Turbulence"
        case .atcStreamEnable:   return "ATC message stream"
        case .atcMessage:        return "ATC messages"
        case .atcFacility:       return "ATC frequency name"
        case .nearestAirport:    return "Nearest airport"
        case .nextWaypoint:      return "Next waypoint"
        case .flightTime:        return "Flight time"
        case .landingVerticalSpeed:     return "Landing rate"
        case .landingScore:             return "Landing score"
        case .landingGForce:            return "Landing g"
        case .landingCentrelineOffset:  return "Off centreline"
        case .landingAimingPointOffset: return "From aiming point"
        case .landingGroundSpeed:       return "Touchdown ground speed"
        case .landingAirspeed:          return "Touchdown airspeed"
        case .landingLatitude:          return "Landing latitude"
        case .landingLongitude:         return "Landing longitude"
        case .landingFlightTime:        return "Measured block time"
        }
    }

    // MARK: - Polling groups
    //
    // Each read is a round trip and they are issued strictly one at a time, so
    // a group that asks for forty states takes forty times as long to come
    // round again. What changes every second is read every pass; what changes
    // every few minutes is read every few seconds; what changes once a flight
    // is read once.

    /// Read every pass — the numbers that move continuously.
    static let live: [ConnectField] = [
        .latitude, .longitude, .altitudeMSL, .altitudeAGL,
        .groundSpeed, .indicatedAirspeed, .verticalSpeed, .headingMagnetic
    ]

    /// Read every few passes — configuration and the world outside, which
    /// change on the scale of a phase of flight rather than a second.
    static let periodic: [ConnectField] = [
        .pitch, .bank, .trueAirspeed,
        .gearState, .flapsState, .spoilersState, .parkingBrake, .reverseThrust,
        .beaconLights, .landingLights, .navLights, .strobeLights,
        .fuelRemaining, .engineN1, .engineThrust,
        .warningStalling, .warningOverspeed,
        .windDirection, .windVelocity, .windGust, .temperature,
        .nearestAirport, .nextWaypoint, .flightTime, .transponderCode,
        .atcFacility,
        // Also in `session` below, and read here as well on purpose.
        //
        // Which flight this is changes about as rarely as anything in the
        // manifest, so five seconds is plenty for the logbook. It is not plenty
        // for anything *attributed* to the flight id, and the controller two
        // lines up is read every two seconds. Reading them on different clocks
        // meant a window of a second or three, every time a pilot ended one
        // flight and spawned another, in which the app held the new aeroplane's
        // frequency under the old aeroplane's id — and would show it against the
        // old flight, which is still on the map for its grace period.
        //
        // Read in the same pass, they land in the same snapshot and cannot
        // disagree by more than one. The cost is one extra state read every two
        // seconds.
        .flightID
    ]

    /// Read once when the connection opens, and again when the flight changes.
    static let session: [ConnectField] = [
        .flightID, .serverID, .serverName, .username,
        .appState, .appVersion, .engineCount
    ]

    /// Read on the landing loop — these only change at a touchdown.
    static let landing: [ConnectField] = [
        .landingVerticalSpeed, .landingScore, .landingGForce,
        .landingCentrelineOffset, .landingAimingPointOffset,
        .landingGroundSpeed, .landingAirspeed,
        .landingLatitude, .landingLongitude, .landingFlightTime
    ]
}
