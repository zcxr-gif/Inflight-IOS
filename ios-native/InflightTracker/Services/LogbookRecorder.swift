import Combine
import CoreLocation
import Foundation

/// Writes down the flights you actually fly.
///
/// The tracker has always known when your aeroplane left the ground and when it
/// stopped moving — it draws both, several times a minute — and has always
/// thrown it away the moment the aircraft dropped out of the feed. This is
/// where it goes instead.
///
/// ## What counts as a flight
///
/// One that left the ground and came back to it. That sounds obvious and is the
/// whole difficulty: the feed sends position, not events, so "took off" and
/// "landed" have to be inferred, and both inferences have a way of being wrong
/// that would put rubbish in somebody's logbook.
///
///   * **Taking off** is easy enough — airborne, well clear of the ground,
///     having been on it. What it must not be is a spawn at cruise, which is
///     why the track has to have SEEN the ground first.
///   * **Landing** is the hard one. An aircraft that stops appearing in the
///     feed has not necessarily landed: it may have gone out of the packet for
///     a few seconds, or the pilot may have quit at FL350. So a flight is
///     closed on the ground, and a flight that simply vanishes is closed too —
///     but only if it was descending through something like an approach when
///     it went, and never at cruise. Somebody who quits mid-Atlantic has not
///     completed a flight and their logbook should not claim they did.
///
/// ## Why the numbers are measured rather than filed
///
/// Distance is accumulated between the samples the feed actually sent, not
/// computed great-circle from A to B. It is the difference between "how far
/// they flew" and "how far apart the airports are", and for anybody who takes
/// a scenic route or gets vectored it is a large difference. Nothing here is
/// typed by anybody, which is the point of it being on a public profile.
@MainActor
final class LogbookRecorder: ObservableObject {

    static let shared = LogbookRecorder()

    /// The flight currently being watched, for the profile panel to show as
    /// "in progress" rather than looking like nothing is happening.
    @Published private(set) var inProgress: Track?

    /// Everything gathered about one flight so far.
    struct Track: Equatable {

        let flightId: String
        let startedAt: Date

        var callsign: String?
        var aircraft: String?
        var livery: String?
        var originIcao: String?
        var destinationIcao: String?
        var server: String?

        /// When it first left the ground. Nil until it does — a track that
        /// never gets one is a taxi, and is not a flight.
        var departedAt: Date?

        var lastSeen: Date
        var lastCoordinate: CLLocationCoordinate2D?
        var lastAltitude: Double = 0

        var distanceMetres: Double = 0
        var maxAltitudeFeet: Double = 0
        var topGroundSpeedKnots: Double = 0

        /// Whether the aircraft has been seen on the ground at all. A track
        /// that starts at cruise — the app opened mid-flight — is watched and
        /// its numbers are kept, but it cannot claim a departure time it never
        /// saw.
        var sawGround = false

        /// Set once airborne, and never unset. This is what stops a long taxi
        /// being logged, and what makes the next touch of the ground a landing
        /// rather than the start of one.
        var wasAirborne = false

        static func == (lhs: Track, rhs: Track) -> Bool {
            lhs.flightId == rhs.flightId && lhs.lastSeen == rhs.lastSeen
        }
    }

    /// Below this, and slow, the aircraft is on the ground. The same rule
    /// `FlightPhase` uses, so the logbook and the window agree about what is
    /// happening.
    private static let groundAltitude: Double = 10_000
    private static let groundSpeed: Double = 40

    /// Clear of the ground by enough that a bounce on the runway is not a
    /// second flight.
    private static let airborneAltitude: Double = 1_500

    /// How long an aircraft can be missing from the feed before its track is
    /// closed. Generous — the backend drops an aircraft from the odd packet
    /// and has it back in the next one, which is the same reason
    /// `AppConfig.flightGracePeriod` exists for the map.
    private static let vanishGrace: TimeInterval = 150

    /// The ceiling under which a vanished flight is treated as having landed.
    ///
    /// Somebody who disappears at 2,000 feet on approach has landed and the
    /// feed simply stopped seeing them; somebody who disappears at FL350 has
    /// quit. The logbook records the first and not the second, because a
    /// logbook that credits abandoned flights is one nobody reading a profile
    /// has any reason to believe.
    private static let vanishAltitude: Double = 6_000

    /// The shortest thing worth writing down.
    private static let minimumMinutes = 3

    /// One formatter, because building an `ISO8601DateFormatter` is not free
    /// and this runs at the end of every flight.
    private static let timestamp = ISO8601DateFormatter()

    private init() {}

    // MARK: - Watching

    /// Called with every packet. Cheap: one pass to find the user's own
    /// aircraft, and nothing at all when they have not said who they are.
    func note(flights: [Flight], server: String) {
        guard AccountStore.shared.isSignedIn, ProfileStore.shared.hasProfile else {
            // Nothing to write it to. The logbook belongs to a profile, and a
            // profile is something somebody has chosen to have.
            inProgress = nil
            return
        }

        guard PilotIdentity.shared.isSet else {
            inProgress = nil
            return
        }

        let mine = flights.first { PilotIdentity.shared.isMe($0.username) }

        guard let flight = mine else {
            closeIfVanished()
            return
        }

        // A different aircraft: the previous flight ended, whether or not the
        // feed said so. Finish it before starting the new one, or the two
        // become one impossible flight.
        if let current = inProgress, current.flightId != flight.id {
            finish(current, landed: current.lastAltitude < Self.vanishAltitude)
            inProgress = nil
        }

        var track = inProgress ?? Track(
            flightId: flight.id,
            startedAt: Date(),
            lastSeen: Date()
        )

        let now = Date()
        let phase = FlightPhase.from(flight)
        let onGround = phase == .ground
            && flight.groundSpeedKnots < Self.groundSpeed

        // Distance between the two samples actually seen, which is what makes
        // this the distance flown rather than the distance between airports.
        if let previous = track.lastCoordinate {
            let from = CLLocation(latitude: previous.latitude, longitude: previous.longitude)
            let to = CLLocation(latitude: flight.latitude, longitude: flight.longitude)
            let step = to.distance(from: from)

            // A jump no aeroplane made: a re-spawn, or the feed handing back a
            // stale position. Roughly Mach 3 over the interval, which nothing
            // in Infinite Flight sustains.
            let elapsed = max(now.timeIntervalSince(track.lastSeen), 1)
            if step / elapsed < 1_000 { track.distanceMetres += step }
        }

        track.callsign = flight.callsign ?? track.callsign
        track.aircraft = flight.aircraftName.isEmpty ? track.aircraft : flight.aircraftName
        track.livery = flight.liveryName.isEmpty ? track.livery : flight.liveryName
        track.server = server
        track.lastSeen = now
        track.lastCoordinate = flight.coordinate
        track.lastAltitude = flight.altitudeFeet
        track.maxAltitudeFeet = max(track.maxAltitudeFeet, flight.altitudeFeet)
        track.topGroundSpeedKnots = max(track.topGroundSpeedKnots, flight.groundSpeedKnots)

        // The filed plan, taken whenever it appears. A pilot who files after
        // pushback still gets their route on the row.
        if let departure = flight.departureIcao, track.originIcao == nil {
            track.originIcao = departure.uppercased()
        }
        if let arrival = flight.arrivalIcao {
            track.destinationIcao = arrival.uppercased()
        }

        if onGround {
            track.sawGround = true

            // Back on the ground having been in the air: that is a landing, and
            // the flight is done. Written now rather than when the aircraft
            // leaves the feed, because a pilot who lands and immediately files
            // another leg should get two rows.
            if track.wasAirborne {
                // The field under the aircraft, which beats the filed
                // destination: a diversion landed where it landed.
                if let field = AirportStore.shared.nearestAirport(to: flight.coordinate) {
                    track.destinationIcao = field.icao.uppercased()
                }
                finish(track, landed: true)
                inProgress = nil
                return
            }

            // Still on the ground before departure. The field it is sitting at
            // is the origin, whatever was filed.
            if !track.wasAirborne,
               let field = AirportStore.shared.nearestAirport(to: flight.coordinate) {
                track.originIcao = field.icao.uppercased()
            }
        } else if flight.altitudeFeet > Self.airborneAltitude {
            if !track.wasAirborne {
                track.wasAirborne = true
                // Only claim a departure time if the ground was actually seen.
                // Opening the app mid-flight is a track worth keeping and a
                // departure time nobody witnessed.
                if track.sawGround { track.departedAt = now }
            }
        }

        inProgress = track
    }

    /// Closes a track whose aircraft has stopped appearing.
    private func closeIfVanished() {
        guard let track = inProgress else { return }
        guard Date().timeIntervalSince(track.lastSeen) > Self.vanishGrace else { return }

        inProgress = nil
        finish(track, landed: track.lastAltitude < Self.vanishAltitude)
    }

    /// Called when the app goes to the background or the feed disconnects, so
    /// a flight that ended while nobody was looking is still written.
    func flush() {
        guard let track = inProgress else { return }
        inProgress = nil
        finish(track, landed: track.lastAltitude < Self.vanishAltitude)
    }

    // MARK: - Writing

    private func finish(_ track: Track, landed: Bool) {
        // Never left the ground: a taxi, a spawn, or somebody sitting at a gate
        // with the app open.
        guard track.wasAirborne else { return }

        // Left the ground and then disappeared from the sky. Not a flight, and
        // pretending otherwise is how a logbook stops meaning anything.
        guard landed else { return }

        let started = track.departedAt ?? track.startedAt
        let minutes = Int(Date().timeIntervalSince(started) / 60)
        guard minutes >= Self.minimumMinutes else { return }

        // The same ceiling the column's check constraint carries. Anything past
        // it is a track that survived a re-spawn, not a flight, and one bad row
        // would sit at the top of every total forever.
        let capped = min(minutes, 1440)

        // Built by adding what is present rather than by writing nils and
        // filtering them out. `x as Any` on an optional boxes the nil rather
        // than dropping it, and `JSONSerialization` refuses an Optional — so
        // the tidy-looking version of this throws at runtime on the first
        // flight with no callsign.
        var row: [String: Any] = [
            "flight_id": track.flightId,
            "if_username": PilotIdentity.shared.username,
            "departed_at": Self.timestamp.string(from: started),
            "landed_at": Self.timestamp.string(from: Date()),
            "minutes": capped,
            "distance_nm": Int((track.distanceMetres / 1852).rounded()),
            "max_altitude_feet": Int(track.maxAltitudeFeet.rounded()),
            "top_ground_speed_knots": Int(track.topGroundSpeedKnots.rounded())
        ]

        if let server = track.server { row["server"] = server }
        if let callsign = track.callsign { row["callsign"] = callsign }
        if let aircraft = track.aircraft { row["aircraft"] = aircraft }
        if let livery = track.livery { row["livery"] = livery }
        if let origin = track.originIcao { row["origin_icao"] = origin }
        if let destination = track.destinationIcao { row["destination_icao"] = destination }

        Task { await write(row) }
    }

    private func write(_ row: [String: Any]) async {
        guard let token = await AccountStore.shared.currentAccessToken() else { return }

        var body = row
        if let account = AccountStore.shared.account { body["user_id"] = account.id }

        do {
            // Duplicates are ignored rather than merged: the same completed
            // flight can be offered twice — a retry, or a second device
            // watching the same pilot — and the unique index on
            // (user_id, flight_id) is what makes that harmless.
            try await SupabaseData.insertIgnoringDuplicates(
                table: "pilot_logbook",
                row: body,
                accessToken: token
            )
        } catch {
            // Not retried, and deliberately silent. A logbook entry is worth
            // having and not worth interrupting anybody about; the next flight
            // will be written, and the one that failed is genuinely gone
            // rather than being queued somewhere it would be written twice.
            print("[logbook] Flight not recorded: \(error.localizedDescription)")
        }
    }
}
