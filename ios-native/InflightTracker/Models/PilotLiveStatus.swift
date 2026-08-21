import CoreLocation
import Foundation

/// A pilot as their own simulator is reporting them, right now.
///
/// Different from a `Flight` off the live feed in a way that matters: the feed
/// is an observer describing an aeroplane from outside, and this is the sim
/// itself. Gear, flaps, lights and the wind hitting the wing are not in the
/// feed at any price, and the phase of flight here is worked out from the
/// configuration rather than guessed from altitude — which is the only way to
/// tell an aircraft on approach from one that has just taken off.
///
/// Present only while its pilot is flying with Connect attached, has chosen to
/// broadcast, and has let this viewer see it. All three are their decision, and
/// the absence of a status means any of the three is false — never which.
struct PilotLiveStatus: Decodable, Equatable {

    let handle: String
    let displayName: String
    let avatarPath: String?
    let isPro: Bool

    /// Whether a simulator is attached and reporting right now.
    ///
    /// False does not mean "no status". It means the position has expired or
    /// been stood down and what is left is the last reading of the flight —
    /// which is the whole point of the row surviving: somebody looking an hour
    /// later still gets the aircraft, the route and the fuel.
    let isLive: Bool

    let flightID: String?
    let serverName: String?
    let callsign: String?
    let aircraft: String?
    let livery: String?

    let latitude: Double?
    let longitude: Double?
    let altitudeMSL: Int?
    let altitudeAGL: Int?
    let heading: Int?
    let groundSpeedKnots: Int?
    let indicatedAirspeedKnots: Int?
    let trueAirspeedKnots: Int?
    let verticalSpeedFPM: Int?
    let pitch: Int?
    let bank: Int?

    let phase: String?

    let gearState: Int?
    let flapsState: Int?
    let spoilersState: Int?
    let landingLights: Bool?
    let strobeLights: Bool?
    let beaconLights: Bool?
    let navLights: Bool?
    let parkingBrake: Bool?
    let reverseThrust: Bool?
    let transponderCode: Int?

    /// Kilograms on board, as the aircraft's own sim reports it. Outlives the
    /// position: this is the number people ask about after somebody drops off.
    let fuelRemainingKg: Int?

    /// Kilograms an hour, smoothed, worked out on the server from consecutive
    /// readings rather than sent by the app — which only sees its own samples
    /// in bursts, because it is suspended behind Infinite Flight for most of a
    /// flight. Nil until there are two usable samples, and reset by a refuel.
    let fuelBurnKgh: Int?

    let engineCount: Int?
    let engineN1: Int?
    let engineThrust: Int?

    let isStalling: Bool?
    let isOverspeeding: Bool?

    let windDirection: Int?
    let windVelocityKnots: Int?
    let windGustKnots: Int?
    let temperatureC: Int?

    let nearestAirport: String?
    let nextWaypoint: String?
    let originIcao: String?
    let destinationIcao: String?

    /// Elapsed time as the sim counts it, which starts when the flight did
    /// rather than when the app happened to connect.
    let flightTimeSeconds: Int?

    let appVersion: String?

    /// What has been said on frequency, newest first, as this pilot's own
    /// simulator logged it. Already public in the game — everybody on the
    /// frequency heard it — and never stored anywhere permanent.
    let atcMessages: [ATCLine]

    let startedAt: Date?

    /// When a sample carrying a position last arrived. The freshness clock, and
    /// the "last seen" a card shows once `isLive` has gone false.
    let lastLiveAt: Date?
    let updatedAt: Date?

    struct ATCLine: Decodable, Equatable, Identifiable {
        let at: Date?
        let from: String?
        let text: String

        var id: String { "\(at?.timeIntervalSince1970 ?? 0)|\(text)" }

        enum CodingKeys: String, CodingKey { case at, from, text }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = (try? c.decode(String.self, forKey: .at))
                .flatMap(SupabaseAuth.Timestamp.date(from:))
            from = try? c.decode(String.self, forKey: .from)
            text = (try? c.decode(String.self, forKey: .text)) ?? ""
        }
    }

    enum CodingKeys: String, CodingKey {
        case handle, phase, callsign, aircraft, livery, latitude, longitude, heading
        case pitch, bank
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case isPro = "is_pro"
        case isLive = "is_live"
        case flightID = "flight_id"
        case serverName = "server_name"
        case altitudeMSL = "altitude_msl"
        case altitudeAGL = "altitude_agl"
        case groundSpeedKnots = "ground_speed_knots"
        case indicatedAirspeedKnots = "indicated_airspeed_knots"
        case trueAirspeedKnots = "true_airspeed_knots"
        case verticalSpeedFPM = "vertical_speed_fpm"
        case gearState = "gear_state"
        case flapsState = "flaps_state"
        case spoilersState = "spoilers_state"
        case landingLights = "landing_lights"
        case strobeLights = "strobe_lights"
        case beaconLights = "beacon_lights"
        case navLights = "nav_lights"
        case parkingBrake = "parking_brake"
        case reverseThrust = "reverse_thrust"
        case transponderCode = "transponder_code"
        case fuelRemainingKg = "fuel_remaining_kg"
        case fuelBurnKgh = "fuel_burn_kgh"
        case engineCount = "engine_count"
        case engineN1 = "engine_n1"
        case engineThrust = "engine_thrust"
        case isStalling = "is_stalling"
        case isOverspeeding = "is_overspeeding"
        case windDirection = "wind_direction"
        case windVelocityKnots = "wind_velocity_knots"
        case windGustKnots = "wind_gust_knots"
        case temperatureC = "temperature_c"
        case nearestAirport = "nearest_airport"
        case nextWaypoint = "next_waypoint"
        case originIcao = "origin_icao"
        case destinationIcao = "destination_icao"
        case flightTimeSeconds = "flight_time_seconds"
        case appVersion = "app_version"
        case atcMessages = "atc_messages"
        case startedAt = "started_at"
        case lastLiveAt = "last_live_at"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        // `try?` throughout, deliberately. Every column here is nullable and
        // several are only published by some aircraft, so a strict decode would
        // turn "this Cessna has no spoilers" into "this pilot is not flying".
        handle = (try? c.decode(String.self, forKey: .handle)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? handle
        avatarPath = try? c.decode(String.self, forKey: .avatarPath)
        isPro = (try? c.decode(Bool.self, forKey: .isPro)) ?? false
        isLive = (try? c.decode(Bool.self, forKey: .isLive)) ?? false

        flightID = try? c.decode(String.self, forKey: .flightID)
        serverName = try? c.decode(String.self, forKey: .serverName)
        callsign = try? c.decode(String.self, forKey: .callsign)
        aircraft = try? c.decode(String.self, forKey: .aircraft)
        livery = try? c.decode(String.self, forKey: .livery)

        latitude = try? c.decode(Double.self, forKey: .latitude)
        longitude = try? c.decode(Double.self, forKey: .longitude)
        altitudeMSL = try? c.decode(Int.self, forKey: .altitudeMSL)
        altitudeAGL = try? c.decode(Int.self, forKey: .altitudeAGL)
        heading = try? c.decode(Int.self, forKey: .heading)
        groundSpeedKnots = try? c.decode(Int.self, forKey: .groundSpeedKnots)
        indicatedAirspeedKnots = try? c.decode(Int.self, forKey: .indicatedAirspeedKnots)
        trueAirspeedKnots = try? c.decode(Int.self, forKey: .trueAirspeedKnots)
        verticalSpeedFPM = try? c.decode(Int.self, forKey: .verticalSpeedFPM)
        pitch = try? c.decode(Int.self, forKey: .pitch)
        bank = try? c.decode(Int.self, forKey: .bank)

        phase = try? c.decode(String.self, forKey: .phase)

        gearState = try? c.decode(Int.self, forKey: .gearState)
        flapsState = try? c.decode(Int.self, forKey: .flapsState)
        spoilersState = try? c.decode(Int.self, forKey: .spoilersState)
        landingLights = try? c.decode(Bool.self, forKey: .landingLights)
        strobeLights = try? c.decode(Bool.self, forKey: .strobeLights)
        beaconLights = try? c.decode(Bool.self, forKey: .beaconLights)
        navLights = try? c.decode(Bool.self, forKey: .navLights)
        parkingBrake = try? c.decode(Bool.self, forKey: .parkingBrake)
        reverseThrust = try? c.decode(Bool.self, forKey: .reverseThrust)
        transponderCode = try? c.decode(Int.self, forKey: .transponderCode)

        fuelRemainingKg = try? c.decode(Int.self, forKey: .fuelRemainingKg)
        fuelBurnKgh = try? c.decode(Int.self, forKey: .fuelBurnKgh)
        engineCount = try? c.decode(Int.self, forKey: .engineCount)
        engineN1 = try? c.decode(Int.self, forKey: .engineN1)
        engineThrust = try? c.decode(Int.self, forKey: .engineThrust)

        isStalling = try? c.decode(Bool.self, forKey: .isStalling)
        isOverspeeding = try? c.decode(Bool.self, forKey: .isOverspeeding)

        windDirection = try? c.decode(Int.self, forKey: .windDirection)
        windVelocityKnots = try? c.decode(Int.self, forKey: .windVelocityKnots)
        windGustKnots = try? c.decode(Int.self, forKey: .windGustKnots)
        temperatureC = try? c.decode(Int.self, forKey: .temperatureC)

        nearestAirport = try? c.decode(String.self, forKey: .nearestAirport)
        nextWaypoint = try? c.decode(String.self, forKey: .nextWaypoint)
        originIcao = try? c.decode(String.self, forKey: .originIcao)
        destinationIcao = try? c.decode(String.self, forKey: .destinationIcao)
        flightTimeSeconds = try? c.decode(Int.self, forKey: .flightTimeSeconds)
        appVersion = try? c.decode(String.self, forKey: .appVersion)

        atcMessages = ((try? c.decode([ATCLine].self, forKey: .atcMessages)) ?? [])
            .filter { !$0.text.isEmpty }
        startedAt = (try? c.decode(String.self, forKey: .startedAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        lastLiveAt = (try? c.decode(String.self, forKey: .lastLiveAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let candidate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(candidate) ? candidate : nil
    }

    /// How the phase reads on a card.
    var phaseLabel: String? {
        guard let phase else { return nil }
        switch phase {
        case "parked":   return "At the gate"
        case "taxiing":  return "Taxiing"
        case "takeoff":  return "Taking off"
        case "climb":    return "Climbing"
        case "cruise":   return "Cruising"
        case "descent":  return "Descending"
        case "approach": return "On approach"
        case "landed":   return "Landed"
        default:         return nil
        }
    }

    var routeLabel: String? {
        switch (originIcao, destinationIcao) {
        case let (origin?, destination?): return "\(origin) → \(destination)"
        case let (origin?, nil):          return "From \(origin)"
        case let (nil, destination?):     return "To \(destination)"
        default:                          return nil
        }
    }

    /// The configuration, as a sentence. Nil when the aircraft is clean and
    /// there is genuinely nothing to say — better than "gear up, flaps up",
    /// which is every aircraft in the cruise.
    var configurationLabel: String? {
        var parts: [String] = []
        if (gearState ?? 0) != 0 { parts.append("gear down") }
        if (flapsState ?? 0) != 0 { parts.append("flaps set") }
        if (spoilersState ?? 0) != 0 { parts.append("spoilers out") }
        if landingLights == true { parts.append("landing lights") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var windLabel: String? {
        guard let windDirection, let windVelocityKnots, windVelocityKnots > 0 else { return nil }
        return String(format: "%03d° / %d kt", windDirection, windVelocityKnots)
    }

    /// How long this has been in the air, as the sim has been reporting it.
    var elapsedLabel: String? {
        guard let startedAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(startedAt))
        guard seconds > 60 else { return nil }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// Whether this is recent enough to draw as live.
    ///
    /// Two tests, not one. The server decides `isLive` — it is the only thing
    /// that knows the TTL and it has the clock — and this adds the check the
    /// server cannot make: a card can sit on screen for a long time after it
    /// was fetched, and should stop claiming to be live when it has.
    ///
    /// Reads `lastLiveAt` rather than `updatedAt`, which now moves when a row
    /// is stood down and would make a pilot who has just closed the sim look
    /// like one who is still flying.
    var isFresh: Bool {
        guard isLive, let lastLiveAt else { return false }
        return Date().timeIntervalSince(lastLiveAt) < 300
    }

    // MARK: - Fuel
    //
    // The one number the public feed has never had and the sim always has.

    /// Fuel as a pilot says it: tonnes above one, kilos below.
    var fuelLabel: String? {
        guard let fuelRemainingKg, fuelRemainingKg > 0 else { return nil }
        if fuelRemainingKg >= 1000 {
            return String(format: "%.1f t", Double(fuelRemainingKg) / 1000)
        }
        return "\(fuelRemainingKg) kg"
    }

    /// What it is being burned at.
    var fuelBurnLabel: String? {
        guard let fuelBurnKgh, fuelBurnKgh > 0 else { return nil }
        if fuelBurnKgh >= 1000 {
            return String(format: "%.1f t/h", Double(fuelBurnKgh) / 1000)
        }
        return "\(fuelBurnKgh) kg/h"
    }

    /// How long the fuel lasts at the rate it is going.
    ///
    /// Not an endurance in the certified sense and not offered as one — it is
    /// the current smoothed burn extrapolated flat, which is pessimistic in the
    /// climb and optimistic on descent. Withheld below a few minutes' worth
    /// rather than counting somebody down to zero: an aircraft parked with the
    /// engines running burns very little and would otherwise read as days.
    var enduranceLabel: String? {
        guard let fuelRemainingKg, let fuelBurnKgh, fuelBurnKgh > 0 else { return nil }
        let minutes = Int((Double(fuelRemainingKg) / Double(fuelBurnKgh)) * 60)
        guard minutes >= 5, minutes <= 60 * 24 else { return nil }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }

    /// Elapsed time, preferring the sim's own clock over ours.
    ///
    /// `flight_time_seconds` starts when the flight did; `started_at` starts
    /// when the app connected, which on a flight somebody attached to halfway
    /// through is an hour of difference.
    var flightTimeLabel: String? {
        guard let seconds = flightTimeSeconds, seconds > 60 else { return elapsedLabel }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// How long ago the sim last reported, for a card that is no longer live.
    var lastSeenLabel: String? {
        guard !isLive, let lastLiveAt else { return nil }
        let seconds = Int(Date().timeIntervalSince(lastLiveAt))
        guard seconds > 0 else { return nil }
        if seconds < 90 { return "a moment ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        let hours = seconds / 3600
        return hours == 1 ? "an hour ago" : "\(hours) hours ago"
    }

    /// Whether there is anything worth drawing at all once the position has
    /// gone. A row with no aircraft, no route and no fuel is a row that expired
    /// before it ever carried anything.
    var hasLastKnown: Bool {
        fuelRemainingKg != nil || aircraft != nil
            || originIcao != nil || destinationIcao != nil
    }
}

/// A pilot you follow who is in the air, for the list of them.
///
/// A narrower shape than the full status on purpose: this is drawn as a row in
/// a list of many, and shipping wind and flap settings for forty pilots to
/// render four fields of each is a lot of nothing.
struct PilotLiveSummary: Decodable, Equatable, Identifiable {

    let handle: String
    let displayName: String
    let avatarPath: String?
    let isPro: Bool
    let callsign: String?
    let aircraft: String?
    let phase: String?
    let latitude: Double?
    let longitude: Double?
    let altitudeMSL: Int?
    let groundSpeedKnots: Int?
    let fuelRemainingKg: Int?
    let fuelBurnKgh: Int?
    let originIcao: String?
    let destinationIcao: String?
    let nearestAirport: String?
    let updatedAt: Date?

    var id: String { handle }

    enum CodingKeys: String, CodingKey {
        case handle, phase, callsign, aircraft, latitude, longitude
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case isPro = "is_pro"
        case altitudeMSL = "altitude_msl"
        case groundSpeedKnots = "ground_speed_knots"
        case fuelRemainingKg = "fuel_remaining_kg"
        case fuelBurnKgh = "fuel_burn_kgh"
        case originIcao = "origin_icao"
        case destinationIcao = "destination_icao"
        case nearestAirport = "nearest_airport"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = (try? c.decode(String.self, forKey: .handle)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? handle
        avatarPath = try? c.decode(String.self, forKey: .avatarPath)
        isPro = (try? c.decode(Bool.self, forKey: .isPro)) ?? false
        callsign = try? c.decode(String.self, forKey: .callsign)
        aircraft = try? c.decode(String.self, forKey: .aircraft)
        phase = try? c.decode(String.self, forKey: .phase)
        latitude = try? c.decode(Double.self, forKey: .latitude)
        longitude = try? c.decode(Double.self, forKey: .longitude)
        altitudeMSL = try? c.decode(Int.self, forKey: .altitudeMSL)
        groundSpeedKnots = try? c.decode(Int.self, forKey: .groundSpeedKnots)
        fuelRemainingKg = try? c.decode(Int.self, forKey: .fuelRemainingKg)
        fuelBurnKgh = try? c.decode(Int.self, forKey: .fuelBurnKgh)
        originIcao = try? c.decode(String.self, forKey: .originIcao)
        destinationIcao = try? c.decode(String.self, forKey: .destinationIcao)
        nearestAirport = try? c.decode(String.self, forKey: .nearestAirport)
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let candidate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(candidate) ? candidate : nil
    }

    /// Tonnes above one, kilos below — the same reading as on the full card.
    var fuelLabel: String? {
        guard let fuelRemainingKg, fuelRemainingKg > 0 else { return nil }
        if fuelRemainingKg >= 1000 {
            return String(format: "%.1f t", Double(fuelRemainingKg) / 1000)
        }
        return "\(fuelRemainingKg) kg"
    }

    /// One line under the name: what they are doing and where.
    var detail: String {
        var parts: [String] = []

        switch phase {
        case "parked":   parts.append("At the gate")
        case "taxiing":  parts.append("Taxiing")
        case "takeoff":  parts.append("Taking off")
        case "climb":    parts.append("Climbing")
        case "cruise":   parts.append("Cruising")
        case "descent":  parts.append("Descending")
        case "approach": parts.append("On approach")
        case "landed":   parts.append("Landed")
        default: break
        }

        if let altitude = altitudeMSL, altitude > 500 {
            parts.append("\(altitude.formatted()) ft")
        }

        switch (originIcao, destinationIcao) {
        case let (origin?, destination?): parts.append("\(origin) → \(destination)")
        case let (nil, destination?):     parts.append("to \(destination)")
        default:
            if let field = nearestAirport { parts.append("near \(field)") }
        }

        if let fuel = fuelLabel { parts.append(fuel) }

        return parts.isEmpty ? (aircraft ?? "Flying") : parts.joined(separator: " · ")
    }
}

/// A place on the landing board.
///
/// Derived on the server from the logbook rather than stored, like every badge:
/// a leaderboard that has to be maintained is a leaderboard that goes wrong,
/// and this one cannot disagree with the flights it is computed from.
///
/// Scoped to people you follow rather than global, which is a product decision.
/// A global board is won once by whoever flies most and is then a wall somebody
/// else is standing at; a board of the twenty people you actually fly with is
/// one you can be on.
/// One landing, as it reaches the world.
///
/// Distinct from `PilotLandingBoardEntry`, which is a pilot summarised over a
/// window. This is a single touchdown with the aeroplane it was made in, and it
/// carries two clocks: `landedAt`, when the wheels touched, and `recordedAt`,
/// when the measurement actually reached us. On a phone those are far apart —
/// iOS has the app suspended behind the simulator and the landing is collected
/// afterwards — and the feed is ordered by the second one, so a landing shows up
/// when it is news rather than buried under the hour it took to be read.
struct PilotRecentLanding: Decodable, Equatable, Identifiable {

    let handle: String
    let displayName: String
    let avatarPath: String?
    let isPro: Bool

    let aircraft: String?
    let callsign: String?
    let originIcao: String?
    let destinationIcao: String?

    let verticalSpeedFPM: Int
    let score: Int?
    let gForce: Double?

    let landedAt: Date?
    let recordedAt: Date?
    let isSelf: Bool

    /// Stable enough for a list that is re-fetched rather than mutated: one
    /// pilot cannot land twice at the same instant.
    var id: String { "\(handle)|\(recordedAt?.timeIntervalSince1970 ?? 0)" }

    /// What the number means, in the words pilots use. The thresholds match
    /// nothing on the server — this is presentation, and the rate is the fact.
    var verdict: String {
        switch abs(verticalSpeedFPM) {
        case ..<100:  return "Butter"
        case ..<200:  return "Smooth"
        case ..<400:  return "Firm"
        case ..<600:  return "Heavy"
        default:      return "Hard"
        }
    }

    var route: String? {
        guard let from = originIcao, let to = destinationIcao else { return destinationIcao ?? originIcao }
        return "\(from) → \(to)"
    }

    enum CodingKeys: String, CodingKey {
        case handle, aircraft, callsign, score
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case isPro = "is_pro"
        case originIcao = "origin_icao"
        case destinationIcao = "destination_icao"
        case verticalSpeedFPM = "vertical_speed_fpm"
        case gForce = "g_force"
        case landedAt = "landed_at"
        case recordedAt = "recorded_at"
        case isSelf = "is_self"
    }
}

struct PilotLandingBoardEntry: Decodable, Equatable, Identifiable {

    let handle: String
    let displayName: String
    let avatarPath: String?
    let isPro: Bool

    /// The softest touchdown in the window — closest to zero, not smallest.
    let bestFPM: Int
    let averageFPM: Int
    let landings: Int
    let greasers: Int
    let bestAt: Date?
    let isSelf: Bool

    var id: String { handle }

    enum CodingKeys: String, CodingKey {
        case handle, landings, greasers
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case isPro = "is_pro"
        case bestFPM = "best_fpm"
        case averageFPM = "average_fpm"
        case bestAt = "best_at"
        case isSelf = "is_self"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        handle = (try? c.decode(String.self, forKey: .handle)) ?? ""
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? handle
        avatarPath = try? c.decode(String.self, forKey: .avatarPath)
        isPro = (try? c.decode(Bool.self, forKey: .isPro)) ?? false
        bestFPM = (try? c.decode(Int.self, forKey: .bestFPM)) ?? 0
        averageFPM = (try? c.decode(Int.self, forKey: .averageFPM)) ?? 0
        landings = (try? c.decode(Int.self, forKey: .landings)) ?? 0
        greasers = (try? c.decode(Int.self, forKey: .greasers)) ?? 0
        bestAt = (try? c.decode(String.self, forKey: .bestAt))
            .flatMap(SupabaseAuth.Timestamp.date(from:))
        isSelf = (try? c.decode(Bool.self, forKey: .isSelf)) ?? false
    }

    /// The thresholds the Infinite Flight community uses, not ones we invented.
    var verdict: String {
        switch abs(bestFPM) {
        case ..<60:  return "Greased"
        case ..<150: return "Smooth"
        case ..<300: return "Firm"
        case ..<600: return "Hard"
        default:     return "Very hard"
        }
    }
}
