import CoreLocation
import Foundation

/// What the sim is doing right now, as of the last completed poll.
///
/// Every field is optional and means "the sim did not publish this", never
/// zero. A Cessna has no slats and an aircraft on the ground has no landing to
/// report; a struct of non-optional doubles would render all of those as `0.0`
/// and there would be no way to tell a real zero from an absent one — which
/// matters most for exactly the number this whole feature exists to capture,
/// where a missing landing rate and a perfect one would look identical.
struct ConnectTelemetry: Equatable {

    // MARK: Session

    /// The live flight id, which is the same id the public feed uses. This is
    /// the join: with it the app knows, rather than infers, which aeroplane on
    /// the map is the one being flown here.
    var flightID: String?
    var serverID: String?
    var serverName: String?

    /// The Infinite Flight handle, read out of the running sim rather than
    /// typed into a settings field.
    var username: String?

    /// What the app is doing — playing, paused, in a menu. Used to tell a
    /// genuinely stationary aircraft from one whose pilot is in the settings
    /// screen.
    var appState: String?
    var appVersion: String?

    // MARK: Position

    var latitude: Double?
    var longitude: Double?
    var altitudeMSL: Double?
    var altitudeAGL: Double?
    var headingMagnetic: Double?
    var groundSpeed: Double?
    var indicatedAirspeed: Double?
    var trueAirspeed: Double?
    var verticalSpeed: Double?
    var pitch: Double?
    var bank: Double?

    // MARK: Configuration
    //
    // Individually small, collectively the difference between "an aircraft at
    // 3,000 feet" and "an aircraft configured to land" — which is what a person
    // watching actually wants to know.

    /// Infinite Flight publishes gear and flaps as enums whose numbering is not
    /// documented and differs by aircraft, so they are carried as the raw value
    /// and interpreted only where it is safe to: a flap setting of 0 is clean
    /// on every aircraft, and anything else is "some flap".
    var gearState: Int?
    var flapsState: Int?
    var spoilersState: Int?
    var parkingBrake: Bool?
    var reverseThrust: Bool?
    var transponderCode: Int?

    var beaconLights: Bool?
    var landingLights: Bool?
    var navLights: Bool?
    var strobeLights: Bool?

    var fuelRemainingKg: Double?
    var engineCount: Int?
    var engineN1: Double?
    var engineThrust: Double?

    var isStalling: Bool?
    var isOverspeeding: Bool?

    // MARK: Outside
    //
    // The sim's own weather at the aircraft, which is a different and better
    // thing than the METAR at the field below: it is what is actually hitting
    // the aeroplane.

    var windDirection: Double?
    var windVelocity: Double?
    var windGust: Double?
    var temperature: Double?

    // MARK: Navigation

    var nearestAirport: String?
    var nextWaypoint: String?

    /// Seconds since the flight began, as the sim counts it.
    var flightTimeSeconds: Double?

    /// When this snapshot was completed. A snapshot is only ever published
    /// once every field in the pass has been answered, so this is the age of
    /// the whole thing rather than of its newest member.
    var sampledAt: Date = .distantPast

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        guard CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else {
            return nil
        }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Whether the sim has enough of a fix for this snapshot to be worth using.
    var hasPosition: Bool { coordinate != nil }

    /// What the aeroplane is doing, worked out from the sim rather than guessed
    /// from altitude alone.
    ///
    /// The feed can only ever say "low and slow", which is true of an aircraft
    /// on approach, an aircraft that has just taken off, and one taxiing to the
    /// gate. Gear, flaps and vertical speed tell the three apart.
    enum Phase: String {
        case parked, taxiing, takeoff, climb, cruise, descent, approach, landed

        var label: String {
            switch self {
            case .parked:   return "At the gate"
            case .taxiing:  return "Taxiing"
            case .takeoff:  return "Taking off"
            case .climb:    return "Climbing"
            case .cruise:   return "Cruising"
            case .descent:  return "Descending"
            case .approach: return "On approach"
            case .landed:   return "Landed"
            }
        }
    }

    var phase: Phase? {
        guard let height = altitudeAGL ?? altitudeMSL else { return nil }
        let speed = groundSpeed ?? 0
        let rate = verticalSpeed ?? 0

        if height < 50 {
            if parkingBrake == true || speed < 1 { return .parked }
            if speed < 40 { return .taxiing }
            return rate > 100 ? .takeoff : .landed
        }

        // Gear down well above the ground and coming down is an approach
        // whatever the altitude says — which is the whole reason this reads the
        // configuration rather than the height.
        let gearDown = (gearState ?? 0) != 0
        if rate < -200 {
            return (gearDown && height < 10_000) ? .approach : .descent
        }
        if rate > 300 { return height < 10_000 ? .takeoff : .climb }
        return .cruise
    }

    /// A one-line configuration summary, for the profile card.
    var configurationSummary: String? {
        var parts: [String] = []
        if (gearState ?? 0) != 0 { parts.append("gear down") }
        if (flapsState ?? 0) != 0 { parts.append("flaps set") }
        if (spoilersState ?? 0) != 0 { parts.append("spoilers") }
        if reverseThrust == true { parts.append("reverse") }
        if strobeLights == true { parts.append("strobes on") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Wind as a pilot reads it: direction, speed, and the gust if there is one.
    var windSummary: String? {
        guard let direction = windDirection, let speed = windVelocity else { return nil }
        let base = String(format: "%03.0f° / %.0f kt", direction, speed)
        if let gust = windGust, gust > speed + 1 {
            return base + String(format: " G%.0f", gust)
        }
        return base
    }

    static func == (lhs: ConnectTelemetry, rhs: ConnectTelemetry) -> Bool {
        lhs.sampledAt == rhs.sampledAt && lhs.flightID == rhs.flightID
    }
}

/// One touchdown, as Infinite Flight scored it.
///
/// The sim measures this itself and keeps the result until the next landing.
/// Nothing in the public feed comes close: a touchdown lasts a fraction of a
/// second and the feed samples several seconds apart, so a landing rate derived
/// from it is an average over an interval that mostly does not contain the
/// landing.
struct ConnectLanding: Equatable {

    /// Feet per minute at the moment the wheels touched. Negative going down,
    /// which is the convention every pilot reads it in — a greaser is a small
    /// negative number.
    var verticalSpeedFPM: Double?

    /// The sim's own grade for the touchdown.
    var score: Double?

    /// Peak g through the flare and the touchdown.
    var maxGForce: Double?

    /// Metres off the runway centreline.
    var centrelineOffsetMetres: Double?

    /// Metres from the 1,000ft aiming point — long is positive.
    var aimingPointOffsetMetres: Double?

    var groundSpeedKnots: Double?
    var indicatedAirspeedKnots: Double?

    var latitude: Double?
    var longitude: Double?

    /// Block time as the sim measured it, in seconds.
    var flightTimeSeconds: Double?

    /// When the app noticed the values had changed. Not the sim's own clock —
    /// the sim does not publish when the landing happened, only what it was —
    /// so this is within one slow-poll interval of the truth.
    var noticedAt: Date = .distantPast

    /// Whether this is a real reading rather than the empty struct.
    ///
    /// A vertical speed of exactly zero is the sim saying "no landing yet", not
    /// a perfect one: an aircraft that has genuinely touched down has some
    /// measurable rate, and one that has never landed reports nothing at all.
    var isRecorded: Bool {
        guard let rate = verticalSpeedFPM else { return false }
        return rate != 0
    }

    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// How the rate reads to a pilot. The thresholds are the ones the Infinite
    /// Flight community uses when it argues about landings, not ours.
    var verdict: String? {
        guard let rate = verticalSpeedFPM, rate != 0 else { return nil }
        let descent = abs(rate)
        switch descent {
        case ..<60:   return "Greased"
        case ..<150:  return "Smooth"
        case ..<300:  return "Firm"
        case ..<600:  return "Hard"
        default:      return "Very hard"
        }
    }

    /// What the columns on `pilot_logbook` are called, so the recorder can
    /// merge this into a row without knowing the field names twice.
    var logbookColumns: [String: Any] {
        var row: [String: Any] = [:]
        if let verticalSpeedFPM { row["landing_vertical_speed_fpm"] = Int(verticalSpeedFPM.rounded()) }
        if let score { row["landing_score"] = Int(score.rounded()) }
        if let maxGForce { row["landing_g_force"] = (maxGForce * 100).rounded() / 100 }
        if let centrelineOffsetMetres {
            row["landing_centreline_offset_m"] = Int(centrelineOffsetMetres.rounded())
        }
        if let aimingPointOffsetMetres {
            row["landing_aiming_point_offset_m"] = Int(aimingPointOffsetMetres.rounded())
        }
        if let groundSpeedKnots { row["landing_ground_speed_knots"] = Int(groundSpeedKnots.rounded()) }
        if let indicatedAirspeedKnots {
            row["landing_airspeed_knots"] = Int(indicatedAirspeedKnots.rounded())
        }
        return row
    }
}
