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
    let verticalSpeedFPM: Int?

    let phase: String?

    let gearState: Int?
    let flapsState: Int?
    let spoilersState: Int?
    let landingLights: Bool?
    let strobeLights: Bool?

    let windDirection: Int?
    let windVelocityKnots: Int?
    let temperatureC: Int?

    let nearestAirport: String?
    let nextWaypoint: String?
    let originIcao: String?
    let destinationIcao: String?

    let startedAt: Date?
    let updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case handle, phase, callsign, aircraft, livery, latitude, longitude, heading
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case isPro = "is_pro"
        case flightID = "flight_id"
        case serverName = "server_name"
        case altitudeMSL = "altitude_msl"
        case altitudeAGL = "altitude_agl"
        case groundSpeedKnots = "ground_speed_knots"
        case indicatedAirspeedKnots = "indicated_airspeed_knots"
        case verticalSpeedFPM = "vertical_speed_fpm"
        case gearState = "gear_state"
        case flapsState = "flaps_state"
        case spoilersState = "spoilers_state"
        case landingLights = "landing_lights"
        case strobeLights = "strobe_lights"
        case windDirection = "wind_direction"
        case windVelocityKnots = "wind_velocity_knots"
        case temperatureC = "temperature_c"
        case nearestAirport = "nearest_airport"
        case nextWaypoint = "next_waypoint"
        case originIcao = "origin_icao"
        case destinationIcao = "destination_icao"
        case startedAt = "started_at"
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
        verticalSpeedFPM = try? c.decode(Int.self, forKey: .verticalSpeedFPM)

        phase = try? c.decode(String.self, forKey: .phase)

        gearState = try? c.decode(Int.self, forKey: .gearState)
        flapsState = try? c.decode(Int.self, forKey: .flapsState)
        spoilersState = try? c.decode(Int.self, forKey: .spoilersState)
        landingLights = try? c.decode(Bool.self, forKey: .landingLights)
        strobeLights = try? c.decode(Bool.self, forKey: .strobeLights)

        windDirection = try? c.decode(Int.self, forKey: .windDirection)
        windVelocityKnots = try? c.decode(Int.self, forKey: .windVelocityKnots)
        temperatureC = try? c.decode(Int.self, forKey: .temperatureC)

        nearestAirport = try? c.decode(String.self, forKey: .nearestAirport)
        nextWaypoint = try? c.decode(String.self, forKey: .nextWaypoint)
        originIcao = try? c.decode(String.self, forKey: .originIcao)
        destinationIcao = try? c.decode(String.self, forKey: .destinationIcao)

        startedAt = (try? c.decode(String.self, forKey: .startedAt))
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
    /// The server already refuses to return anything stale, but a card can sit
    /// on screen for a while after it was fetched and should stop claiming to
    /// be live when it has.
    var isFresh: Bool {
        guard let updatedAt else { return false }
        return Date().timeIntervalSince(updatedAt) < 300
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

        return parts.isEmpty ? (aircraft ?? "Flying") : parts.joined(separator: " · ")
    }
}
