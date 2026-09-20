import CoreLocation
import Foundation

/// One aircraft on the map.
///
/// Usually one from an `all_flights_update` packet, which is what this was
/// written for and what almost every instance of it still is. Since real-world
/// traffic it is also one aeroplane from an ADS-B sweep — see `init(adsb:)`
/// and `origin`, which is the only thing that tells the two apart.
///
/// Built straight from the socket's dictionary rather than round-tripping
/// through `JSONSerialization` + `JSONDecoder` — that re-serialised and
/// re-parsed the entire payload on every update, which on a busy server is
/// megabytes of pointless work several times a minute.
///
/// Fields the app doesn't display aren't parsed at all, and the sprite key is
/// resolved once here instead of on every draw. Field names mirror the schema
/// documented in `old/www/SocketDataHub.js`.
struct Flight: Identifiable, Equatable {

    /// Which sky this aeroplane is in.
    ///
    /// Everything this app has ever drawn came from one place — Infinite
    /// Flight's servers — so nothing needed to say so. Real-world traffic is
    /// the second source, and the distinction has to travel *with the
    /// aircraft*: it decides what colour the mark is painted, whether tapping
    /// it opens a flight window (a real airliner has no pilot profile, no filed
    /// plan on our backend and no history to replay), and whether it is offered
    /// to the logbook, the widgets or a Live Activity. None of those can ask
    /// the feed after the fact, because by then it is one array.
    enum Origin: String, Equatable {

        /// The simulator. Everything the app was built around.
        case infiniteFlight

        /// The real sky, from ADS-B. See `RealWorldTraffic`.
        case realWorld
    }

    /// Where this aircraft came from, set by whichever initialiser built it.
    let origin: Origin

    let id: String
    let callsign: String?
    let username: String?

    /// The pilot's Infinite Flight account id, as the feed sends it.
    ///
    /// Not shown anywhere. It is the key every one of the backend's user
    /// routes is keyed by — grade, virtual organisation, career totals — and
    /// without it the only way to ask about a pilot is to resolve their name
    /// first, which is a second round trip for something the packet already
    /// carried and the parser was throwing away.
    let userId: String?

    /// The virtual airline Infinite Flight itself has this pilot down as
    /// flying for, sent alongside the position.
    ///
    /// The VA badges on a profile are a different thing and stay a different
    /// thing: those are Inflight's own listings, worn by choice and resolved
    /// against a roster. This is what the *server* says, it is not a claim
    /// anybody made here, and it is the line that belongs beside a name on a
    /// flight rather than on a profile.
    let virtualOrganization: String?

    let latitude: Double
    let longitude: Double
    let altitudeFeet: Double
    let groundSpeedKnots: Double
    let verticalSpeedFPM: Double
    let heading: Double

    let aircraftName: String
    let liveryName: String
    let registration: String?

    /// Whether anyone is actually flying it — sent alongside the position, and
    /// not something the telemetry could be made to tell us.
    let pilotState: PilotState

    /// Both ends of the route, when there is one.
    ///
    /// `var` rather than `let` for exactly one reason, and it is worth the
    /// exception: a real aeroplane's route does not arrive with its position.
    /// ADS-B has no field for an origin or a destination, so a contact is built
    /// with both nil and the layer resolves them from the callsign afterwards —
    /// see `RealWorldRoutes`, which writes them here so that everything drawing
    /// a route goes on reading one field rather than learning about a second
    /// kind of aircraft. The socket's own packets carry theirs and are built
    /// complete; nothing mutates those.
    var departureIcao: String?
    var arrivalIcao: String?

    /// Resolved once at parse time — the map re-reads this on every frame.
    let spriteKey: String

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// What a real aeroplane's id is namespaced with. See `init(adsb:)`.
    static let realWorldIdPrefix = "adsb:"

    /// Which sky an id belongs to, without an aeroplane to ask.
    ///
    /// The namespace is the answer, and it is the only one available to a view
    /// that has been handed a flight id and has to decide which of the two
    /// sources to resolve it against — the instruments, most of all, which are
    /// pointed at an id and fed an array. Keeping it here rather than spelling
    /// the prefix out at each of those means the id's shape is decided in the
    /// one file that makes them.
    static func isRealWorld(id: String) -> Bool {
        id.hasPrefix(realWorldIdPrefix)
    }

    /// The Mode S address this aircraft broadcasts, for real traffic.
    ///
    /// Recovered from the id rather than stored beside it: the id *is* the
    /// address, namespaced — see `init(adsb:)` — and a second field holding the
    /// same six characters is a second field that can disagree with the first.
    /// Nil for everything from the simulator, which has no such thing.
    var adsbHex: String? {
        guard origin == .realWorld else { return nil }
        guard id.hasPrefix(Self.realWorldIdPrefix) else { return nil }
        let hex = String(id.dropFirst(Self.realWorldIdPrefix.count))
        return hex.isEmpty ? nil : hex
    }

    var displayName: String {
        guard let callsign = callsign, !callsign.isEmpty else { return username ?? "Unknown" }
        return callsign
    }

    /// Fails when the payload has no usable identity or position, which drops
    /// a single bad aircraft instead of the whole packet.
    init?(payload: [String: Any]) {
        guard let id = Flight.text(payload["flightId"]),
              let position = payload["position"] as? [String: Any],
              let latitude = Flight.number(position["lat"]),
              let longitude = Flight.number(position["lon"]),
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }

        self.origin = .infiniteFlight
        self.id = id
        self.latitude = latitude
        self.longitude = longitude

        self.callsign = Flight.text(payload["callsign"])
        self.username = Flight.text(payload["username"])
        self.userId = Flight.text(payload["userId"])
        self.virtualOrganization = Flight.text(payload["virtualOrganization"])
        // Via `number` because the backend has sent it as both a number and a
        // string; `Int(_:)` traps on a non-finite double, so it is checked
        // rather than force-converted.
        self.pilotState = PilotState.from(
            Flight.number(payload["pilotState"]).flatMap { $0.isFinite ? Int($0) : nil }
        )
        self.departureIcao = Flight.text(payload["departureIcao"])
        self.arrivalIcao = Flight.text(payload["arrivalIcao"])

        self.altitudeFeet = Flight.number(position["alt_ft"]) ?? 0
        self.groundSpeedKnots = Flight.number(position["gs_kt"]) ?? 0
        self.verticalSpeedFPM = Flight.number(position["vs_fpm"]) ?? 0
        self.heading = Flight.number(position["heading_deg"]) ?? 0

        let aircraft = payload["aircraft"] as? [String: Any]
        self.aircraftName = Flight.text(aircraft?["aircraftName"]) ?? ""
        self.liveryName = Flight.text(aircraft?["liveryName"]) ?? ""
        self.registration = Flight.text(aircraft?["registration"])

        self.spriteKey = AircraftCatalog.spriteKey(for: aircraftName)
    }

    // MARK: - The real sky

    /// One aircraft from an ADS-B feed, in the shape the map already draws.
    ///
    /// Deliberately the same type rather than a second one. Everything that
    /// puts an aeroplane on either map — the sprite cache, the culling, the
    /// dead-reckoning between updates, the callsign plates, the planet's own
    /// projection — is written against `Flight`, and a parallel pipeline for a
    /// second kind of aircraft would be a second copy of all of it that could
    /// drift from the first. `origin` is what keeps the two apart where they
    /// genuinely differ, which is a much shorter list: the colour, the tap, and
    /// which of them the logbook is allowed to see.
    ///
    /// The payload is one entry of `aircraft` from the readsb-shaped JSON the
    /// open ADS-B aggregators serve — see `RealWorldTraffic` for the endpoint
    /// and the terms. Fields are read leniently for the same reason the socket
    /// payload is: a receiver that has a position but no type, or a type but no
    /// ground speed, is an ordinary aircraft rather than a bad one.
    ///
    /// Fails without a usable identity or position, which drops one aeroplane
    /// rather than the sweep it arrived in.
    init?(adsb payload: [String: Any]) {
        guard let hex = Flight.text(payload["hex"])?.lowercased(),
              let latitude = Flight.number(payload["lat"]),
              let longitude = Flight.number(payload["lon"]),
              latitude.isFinite, longitude.isFinite,
              abs(latitude) <= 90, abs(longitude) <= 180,
              !(latitude == 0 && longitude == 0) else { return nil }

        self.origin = .realWorld
        // Namespaced, and it has to be. The rest of the app keys aircraft by
        // id — annotations, the grace period, the open window — and a bare
        // 24-bit ICAO address shares that space with Infinite Flight's own
        // flight ids. Six hex characters colliding with one is unlikely and
        // "unlikely" is not a thing to leave in a dictionary key.
        self.id = Self.realWorldIdPrefix + hex

        self.latitude = latitude
        self.longitude = longitude

        let registration = Flight.text(payload["r"])?.uppercased()
        // The broadcast callsign, and the registration when there is none —
        // which is what every real-world tracker shows for the business jets
        // and light aircraft that fly under their tail number. A mark with no
        // name at all would be the one aeroplane on the map you cannot refer
        // to.
        self.callsign = Flight.text(payload["flight"])?.uppercased() ?? registration
        // No pilot behind a real aeroplane, as far as this app is concerned.
        // Left nil rather than filled with the registration: `username` is what
        // the highlighting, the watchlist and every profile lookup key on, and
        // a value there would put real traffic into all three.
        self.username = nil
        self.userId = nil
        self.virtualOrganization = nil

        // `alt_baro` is a number in feet, or the literal string "ground".
        if let text = payload["alt_baro"] as? String,
           text.caseInsensitiveCompare("ground") == .orderedSame {
            self.altitudeFeet = 0
        } else {
            self.altitudeFeet = Flight.number(payload["alt_baro"])
                ?? Flight.number(payload["alt_geom"])
                ?? 0
        }

        self.groundSpeedKnots = Flight.number(payload["gs"]) ?? 0
        // Barometric first: it is what the aircraft itself is flying, and the
        // geometric rate is a GPS derivative that is noisier on the ground.
        self.verticalSpeedFPM = Flight.number(payload["baro_rate"])
            ?? Flight.number(payload["geom_rate"])
            ?? 0
        // The track over the ground, which is the angle the mark is turned to.
        // A heading is the fallback rather than the first choice: in any wind
        // the two differ, and the map is drawing where the aeroplane is going.
        self.heading = Flight.number(payload["track"])
            ?? Flight.number(payload["true_heading"])
            ?? Flight.number(payload["mag_heading"])
            ?? 0

        // The ICAO type designator — "B738", "A20N", "E75L". Kept as the
        // aircraft name because that is the only name a receiver knows: there
        // is no model name and no livery in an ADS-B message.
        let type = Flight.text(payload["t"])?.uppercased() ?? ""
        self.aircraftName = type
        self.liveryName = ""
        self.registration = registration

        // Nobody is at the controls of one of these in any sense this app
        // means, but the field is not optional and `.active` is what every
        // unknown value already reads as.
        self.pilotState = .active

        // A receiver sees a position, not a route. Nothing is inferred from
        // the callsign — "BAW117" is not a promise about where it is going.
        self.departureIcao = nil
        self.arrivalIcao = nil

        // The designator table first, then the catalog.
        //
        // The two answer the same question in different languages. The catalog
        // scans Infinite Flight's *names* for substrings, and a few ICAO codes
        // happen to fall inside those substrings — "B738" contains "B73" and
        // lands correctly by luck. A great many do not: "B06" is a Bell 206 and
        // matches nothing at all, so every helicopter in the sky was being
        // drawn as an airliner, along with most business jets and turboprops.
        // See `AircraftTypeDesignators`.
        self.spriteKey = AircraftTypeDesignators.spriteKey(for: type)
            ?? AircraftCatalog.spriteKey(for: type)
    }

    // MARK: - Lenient readers

    /// The backend has sent numbers as both JSON numbers and strings.
    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    /// Empty and whitespace-only strings read as absent, and an id sent as a
    /// number still resolves.
    private static func text(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
