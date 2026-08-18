import Combine
import Foundation

/// Broadcasts what the sim is reporting, so other pilots can see it.
///
/// The live feed already tells everybody where every aeroplane is. This is the
/// aircraft as its *own pilot's sim* reports it — gear, flaps, lights, the wind
/// actually hitting the wing, the phase of flight worked out from configuration
/// rather than guessed from altitude. None of that is derivable from the public
/// feed, and none of it can be collected server-side, because Connect is local
/// to the pilot's own network. The app is the only thing that can see it, so
/// the app is what publishes it.
///
/// ## What it will not do
///
/// Broadcast without being asked. Three things have to be true — an account, a
/// profile, and this switch — and turning the switch off **deletes** the row
/// rather than hiding it, so there is nothing left to leak later. Who may then
/// read it is a separate decision again, held on the profile as
/// `live_visibility`, and it defaults to followers rather than to everybody:
/// where somebody *is* is a different category from where they have *been*.
@MainActor
final class LiveStatusPublisher: ObservableObject {

    static let shared = LiveStatusPublisher()

    /// Whether the pilot has asked to broadcast at all.
    @Published var isSharing: Bool {
        didSet {
            defaults.set(isSharing, forKey: Self.key)
            if isSharing { schedule() } else { Task { await clear() } }
        }
    }

    /// The last time a row was written, for the settings screen to show that
    /// this is actually doing something.
    @Published private(set) var lastPublished: Date?
    @Published private(set) var problem: String?

    private static let key = "connect.share"

    /// How often a status is written while nothing much is changing.
    ///
    /// Deliberately slow. A row every few seconds for the whole of a fourteen
    /// hour flight is a lot of writes to say "still cruising"; the server's TTL
    /// is four minutes, so this only has to be comfortably inside that.
    private static let heartbeat: TimeInterval = 45

    /// How often a status is written while something interesting is happening.
    /// Somebody watching a friend on approach wants better than every 45
    /// seconds, and an approach does not last fourteen hours.
    private static let activeHeartbeat: TimeInterval = 15

    private let defaults: UserDefaults
    private var timer: Task<Void, Never>?
    private var lastPhase: ConnectTelemetry.Phase?

    private init() {
        defaults = UserDefaults(suiteName: SharedStore.appGroupIdentifier) ?? .standard
        isSharing = defaults.bool(forKey: Self.key)
    }

    // MARK: - Driving

    func start() {
        guard isSharing else { return }
        schedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        Task { await clear() }
    }

    private func schedule() {
        guard timer == nil else { return }

        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                await self.publishIfAble()

                let interval = self.currentInterval()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func currentInterval() -> TimeInterval {
        switch ConnectSession.shared.telemetry.phase {
        case .approach, .takeoff, .landed, .taxiing: return Self.activeHeartbeat
        default: return Self.heartbeat
        }
    }

    // MARK: - Writing

    private func publishIfAble() async {
        guard isSharing else { return }

        // Three gates, and all three are the pilot's own decisions rather than
        // ours: they signed in, they claimed a handle, and they turned this on.
        guard AccountStore.shared.isSignedIn,
              ProfileStore.shared.hasProfile else { return }

        let session = ConnectSession.shared
        guard session.status.isLive else {
            // Connected a moment ago and not now. Whatever is on the server is
            // about to go stale on its own, but clearing it is instant and
            // truthful, and costs one request.
            if lastPublished != nil { await clear() }
            return
        }

        let telemetry = session.telemetry

        // A snapshot with no position is a connection that has not finished its
        // first pass. Publishing it would put a pilot at nowhere in particular.
        guard telemetry.hasPosition else { return }

        guard let token = await AccountStore.shared.currentAccessToken() else { return }
        guard let account = AccountStore.shared.account else { return }

        var row: [String: Any] = [
            "user_id": account.id,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]

        // Two helpers rather than one generic one. `Any`-returning closures put
        // the type checker to work for no benefit, and a heterogeneous ternary
        // in the middle of a dictionary literal is how a build fails on a
        // machine you do not have.
        func putWhole(_ column: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            row[column] = Int(value.rounded())
        }

        func putExact(_ column: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            row[column] = value
        }

        if let flight = telemetry.flightID { row["flight_id"] = flight }
        if let server = telemetry.serverName { row["server_name"] = server }
        if let aircraft = LogbookRecorder.shared.inProgress?.aircraft { row["aircraft"] = aircraft }
        if let livery = LogbookRecorder.shared.inProgress?.livery { row["livery"] = livery }
        if let callsign = LogbookRecorder.shared.inProgress?.callsign { row["callsign"] = callsign }
        if let origin = LogbookRecorder.shared.inProgress?.originIcao { row["origin_icao"] = origin }
        if let destination = LogbookRecorder.shared.inProgress?.destinationIcao {
            row["destination_icao"] = destination
        }

        putExact("latitude", telemetry.latitude)
        putExact("longitude", telemetry.longitude)
        putWhole("altitude_msl", telemetry.altitudeMSL)
        putWhole("altitude_agl", telemetry.altitudeAGL)
        putWhole("ground_speed_knots", telemetry.groundSpeed)
        putWhole("indicated_airspeed_knots", telemetry.indicatedAirspeed)
        putWhole("vertical_speed_fpm", telemetry.verticalSpeed)
        putWhole("wind_velocity_knots", telemetry.windVelocity)
        putWhole("temperature_c", telemetry.temperature)

        // Headings and wind directions wrap, and the column's check constraint
        // does not. A sim reporting 359.7 rounds to 360, which is legal here and
        // would be rejected as 361 the moment it read 360.6.
        if let heading = telemetry.headingMagnetic, heading.isFinite {
            row["heading"] = Int(heading.rounded()) % 360
        }
        if let wind = telemetry.windDirection, wind.isFinite {
            row["wind_direction"] = Int(wind.rounded()) % 360
        }

        if let phase = telemetry.phase { row["phase"] = phase.rawValue }
        if let gear = telemetry.gearState { row["gear_state"] = gear }
        if let flaps = telemetry.flapsState { row["flaps_state"] = flaps }
        if let spoilers = telemetry.spoilersState { row["spoilers_state"] = spoilers }
        if let brake = telemetry.parkingBrake { row["parking_brake"] = brake }
        if let reverse = telemetry.reverseThrust { row["reverse_thrust"] = reverse }
        if let landing = telemetry.landingLights { row["landing_lights"] = landing }
        if let strobe = telemetry.strobeLights { row["strobe_lights"] = strobe }

        // The sim gives the nearest airport as a name or a code depending on
        // what it knows; the column takes an ICAO code and nothing else.
        if let field = telemetry.nearestAirport, Self.isIcao(field) {
            row["nearest_airport"] = field.uppercased()
        }
        if let waypoint = telemetry.nextWaypoint { row["next_waypoint"] = waypoint }

        // The ATC exchange, newest first and hard-capped.
        //
        // Twelve because that is what the column's check constraint accepts;
        // sending thirteen would have the server reject the whole write, which
        // would cost the position update as well as the transcript. The cap is
        // enforced in both places on purpose — this one keeps the write valid,
        // and the server's keeps it valid whatever version of the app is
        // running.
        let log = ConnectSession.shared.atcLog.prefix(12).map(\.wireRepresentation)
        if log.isEmpty {
            row["atc_messages"] = NSNull()
        } else {
            row["atc_messages"] = log
        }

        do {
            _ = try await SupabaseData.upsert(
                table: "pilot_live_status",
                row: row,
                accessToken: token,
                onConflict: "user_id"
            )
            lastPublished = Date()
            lastPhase = telemetry.phase
            problem = nil
        } catch let failure as SupabaseData.Failure {
            problem = failure.message
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Stops being "flying now", immediately.
    ///
    /// Deletes rather than marks. A row that is merely hidden is a row that can
    /// be un-hidden by a bug, and this is real-time location.
    func clear() async {
        guard let token = await AccountStore.shared.currentAccessToken() else {
            lastPublished = nil
            return
        }

        _ = try? await SupabaseData.perform(
            "pilot_live_clear",
            accessToken: token
        )
        lastPublished = nil
        lastPhase = nil
    }

    private static func isIcao(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard (3...4).contains(trimmed.count) else { return false }
        return trimmed.allSatisfy { $0.isLetter || $0.isNumber } && trimmed.allSatisfy(\.isASCII)
    }
}
