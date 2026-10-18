import CoreLocation
import Foundation

/// How long a flight has left to run, worked out the way a dispatcher would
/// rather than as one division.
///
/// What this replaces was remaining great-circle distance over the current
/// ground speed, and it was wrong in every phase but level cruise on a straight
/// route:
///
/// - **Climbing**, the ground speed is a long way under the cruise it is
///   heading for, so a jet at 250 kt below ten thousand feet read nearly twice
///   its real time to run.
/// - **Descending and on approach**, the aircraft is about to slow to
///   approach speed, so the last fifty miles read as if flown at cruise.
/// - **Routing**: a filed plan that doglegs round airspace or flies a STAR is
///   longer than the line between two points, sometimes by a lot.
/// - **Traffic**: twenty aircraft converging on one runway land one at a time,
///   and the twentieth does not land at its own pace.
///
/// So the estimate is built from four parts: the distance left along the filed
/// plan when there is one; a climb / cruise / descent speed profile, with the
/// cruise speed remembered from when the aircraft was last level up high; a
/// deceleration to approach speed over the last of the descent; and the delay
/// the arrival field's landing queue adds, from every other aircraft inbound
/// to it.
///
/// ## What it costs
///
/// The part that touches the whole packet — the cruise-speed memory and the
/// landing queues — runs once per packet on the feed's decode queue, alongside
/// the trail store, and is a dictionary lookup and a haversine per aircraft.
/// The per-flight estimate is a handful of arithmetic plus, for a flight with
/// a plan, one pass over its fixes; it is memoised for the packet, so the six
/// readouts that show the same flight's ETE pay for it once.
final class EnrouteEstimator {

    static let shared = EnrouteEstimator()

    private init() {}

    // MARK: - Tuning

    /// Below this an aircraft is not flying, and there is no time to run. Same
    /// line the rest of the app draws.
    private static let flyingSpeedKnots: Double = 40

    /// Vertical speed either side of which the aircraft counts as level.
    private static let levelFPM: Double = 300

    /// Above this, level flight is cruise rather than a circuit or a hold
    /// under a 250-knot limit, and its ground speed is worth remembering.
    private static let cruiseFloorFeet: Double = 10_000

    /// The descent the profile assumes: three miles per thousand feet, the
    /// rule pilots plan a top of descent with.
    private static let descentNMPerThousandFeet: Double = 3

    /// Added to the descent for the slowing-down a terminal area asks for —
    /// the level-off at 10,000 ft, the vectors, the intercept.
    private static let terminalNM: Double = 10

    /// Runway acceptance: one arrival every this many seconds. Three miles in
    /// trail at approach speed, which is what a controlled field on the expert
    /// server spaces arrivals at.
    private static let arrivalSeparation: TimeInterval = 75

    /// How far out an inbound aircraft joins its field's landing queue. Far
    /// enough to see a queue forming, near enough that the order it is worked
    /// out in is the order they will land in.
    private static let queueRadiusNM: Double = 120

    /// How much the cruise-speed memory moves towards each new level sample:
    /// enough to follow a change of wind within a few packets, not so much
    /// that a single gusty packet swings the estimate.
    private static let cruiseSmoothing: Double = 0.2

    // MARK: - State

    private let lock = NSLock()

    /// Ground speed each flight last held level at cruise, smoothed.
    private var cruiseSpeed: [String: Double] = [:]

    /// What the landing queue at its field adds to each flight's time.
    private var queueDelay: [String: TimeInterval] = [:]

    /// An answer, and the position it was worked out from. Checked against
    /// the position asked about rather than trusted by id alone: not every
    /// flight comes through the live feed — the real-world traffic layer does
    /// not — and one that never reaches `record` must not be answered from a
    /// position it has long since left.
    private struct Memo {
        let latitude: Double
        let longitude: Double
        let speed: Double
        let value: TimeInterval?
    }

    /// Bumped per packet; memoised answers from an older packet are discarded.
    private var generation = 0
    private var memo: [String: Memo] = [:]

    // MARK: - Per packet

    /// Takes one packet in. Called on the feed's decode queue, never the main
    /// thread.
    func record(_ flights: [Flight]) {
        lock.lock()
        let previousCruise = cruiseSpeed
        lock.unlock()

        var cruise: [String: Double] = [:]
        cruise.reserveCapacity(previousCruise.count)

        // Inbound aircraft near their field, by field, with the time each
        // would land in if it had the runway to itself.
        var queues: [String: [(id: String, eta: TimeInterval)]] = [:]

        for flight in flights {
            let speed = flight.groundSpeedKnots
            guard speed > Self.flyingSpeedKnots else { continue }

            // Only the flights still in the packet are carried over, so the
            // memory is exactly as big as the server.
            if let held = previousCruise[flight.id] { cruise[flight.id] = held }

            if flight.altitudeFeet > Self.cruiseFloorFeet,
               abs(flight.verticalSpeedFPM) < Self.levelFPM {
                let held = cruise[flight.id] ?? speed
                cruise[flight.id] = held + (speed - held) * Self.cruiseSmoothing
            }

            guard let icao = flight.arrivalIcao?.uppercased(), !icao.isEmpty,
                  let field = AirportStore.shared.airport(icao) else { continue }

            // A cheap box test first: almost everything on a busy server is
            // nowhere near its destination.
            let latitudeSpan = Self.queueRadiusNM / 60
            guard abs(flight.latitude - field.coordinate.latitude) <= latitudeSpan else { continue }

            let distance = FlightProgress.distanceNM(from: flight.coordinate, to: field.coordinate)
            guard distance <= Self.queueRadiusNM else { continue }

            // The same profile the readout uses, so the order worked out here
            // is the order the ETEs show.
            let hours = Self.profileHours(for: flight, distanceNM: distance, heldCruise: cruise[flight.id])
            queues[icao, default: []].append((id: flight.id, eta: hours * 3600))
        }

        // Each field's queue, worked as a single runway: everyone lands at
        // their own pace unless the aircraft ahead is still on it, in which
        // case they land one separation behind. The difference is the delay.
        var delays: [String: TimeInterval] = [:]
        for (_, queue) in queues where queue.count > 1 {
            var slot = -TimeInterval.infinity
            for entry in queue.sorted(by: { $0.eta < $1.eta }) {
                slot = max(entry.eta, slot + Self.arrivalSeparation)
                let delay = slot - entry.eta
                if delay > 0 { delays[entry.id] = delay }
            }
        }

        lock.lock()
        cruiseSpeed = cruise
        queueDelay = delays
        generation &+= 1
        memo.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Per flight

    /// Seconds left to the arrival field, or nil when the aircraft is too slow
    /// for any estimate to mean anything — which includes everything on the
    /// ground, and has to: a flight watched from the gate is not arriving.
    ///
    /// `directNM` is the great-circle distance to the field, the floor for any
    /// route and the fallback when there is no plan to follow.
    func timeEnroute(
        for flight: Flight,
        directNM: Double,
        arrival: CLLocationCoordinate2D
    ) -> TimeInterval? {
        guard flight.groundSpeedKnots > Self.flyingSpeedKnots, directNM > 0 else { return nil }

        lock.lock()
        if let cached = memo[flight.id],
           cached.latitude == flight.latitude,
           cached.longitude == flight.longitude,
           cached.speed == flight.groundSpeedKnots {
            lock.unlock()
            return cached.value
        }
        let held = cruiseSpeed[flight.id]
        let delay = queueDelay[flight.id] ?? 0
        let stamp = generation
        lock.unlock()

        let distance = Self.routeNM(for: flight, directNM: directNM, arrival: arrival)
        let airborne = Self.profileHours(for: flight, distanceNM: distance, heldCruise: held) * 3600

        let answer: TimeInterval? = airborne.isFinite && airborne > 0 ? airborne + delay : nil

        lock.lock()
        // Only kept if no packet has landed since this started; otherwise it
        // was worked out from a position that is already stale.
        if generation == stamp {
            memo[flight.id] = Memo(
                latitude: flight.latitude,
                longitude: flight.longitude,
                speed: flight.groundSpeedKnots,
                value: answer
            )
        }
        lock.unlock()

        return answer
    }

    // MARK: - Distance

    /// Distance left along the filed plan, or the great circle without one.
    ///
    /// Reads only what the plan store already holds — the map and the flight
    /// window fetch the plan of any flight being looked at — so asking for an
    /// ETE never starts a request.
    private static func routeNM(
        for flight: Flight,
        directNM: Double,
        arrival: CLLocationCoordinate2D
    ) -> Double {
        let plan = FlightPlanStore.shared.cachedWaypoints(for: flight.id)
        guard plan.count >= 2,
              let leg = PlanProgress.next(in: plan, from: flight.coordinate),
              plan.indices.contains(leg.waypoint.index) else { return directNM }

        var total = leg.distanceNM
        var index = leg.waypoint.index
        while index + 1 < plan.count {
            total += FlightProgress.distanceNM(from: plan[index].coordinate, to: plan[index + 1].coordinate)
            index += 1
        }
        if let last = plan.last {
            total += FlightProgress.distanceNM(from: last.coordinate, to: arrival)
        }

        // A plan can be stale or filed for somewhere else entirely, and then
        // following it is worse than ignoring it. Shorter than the straight
        // line is impossible; far longer than any sane routing is a plan that
        // isn't this flight's any more.
        guard total >= directNM, total <= directNM * 2.5 + 60 else { return directNM }
        return total
    }

    // MARK: - Speed profile

    /// Hours to fly `distance` from here, through what is left of the climb,
    /// the cruise and the descent.
    private static func profileHours(for flight: Flight, distanceNM distance: Double, heldCruise: Double?) -> Double {
        let speed = flight.groundSpeedKnots
        let altitude = max(flight.altitudeFeet, 0)
        let climbing = flight.verticalSpeedFPM > levelFPM
        let descending = flight.verticalSpeedFPM < -levelFPM

        // The ground speed it will cruise at. Remembered when it has been seen;
        // otherwise, while climbing, the type's typical cruise — bounded by a
        // multiple of what it is doing now, so a strong headwind or an
        // unusually slow type does not get a speed it will never reach.
        let cruise: Double = {
            if let held = heldCruise { return held }
            if climbing { return max(speed, min(typicalCruise(for: flight), speed * 1.8)) }
            return speed
        }()
        let approach = min(approachSpeed(for: flight), cruise, speed)

        var hours = 0.0
        var left = distance
        var topAltitude = altitude
        var speedAtTop = descending ? speed : cruise

        // What remains of the climb, flown at the mean of now and cruise.
        if climbing {
            let ceiling = typicalCeiling(for: flight)
            // Short hops don't go high: roughly a hundred feet per mile of
            // route, which is the step a dispatcher would plan.
            let planned = min(ceiling, max(altitude, (distance + flightNMFlown(flight)) * 100))
            if planned > altitude {
                let climbHours = (planned - altitude) / flight.verticalSpeedFPM / 60
                let climbNM = climbHours * (speed + cruise) / 2
                if climbNM < left {
                    hours += climbHours
                    left -= climbNM
                    topAltitude = planned
                } else {
                    // Too short a trip to reach it: the descent starts on the
                    // way up, at whatever it has worked up to by then.
                    speedAtTop = (speed + cruise) / 2
                }
            }
        }

        // Cruise to the top of descent, then slow to approach speed over the
        // descent and the terminal area.
        let descentNM = topAltitude / 1000 * descentNMPerThousandFeet + terminalNM
        if left > descentNM {
            hours += (left - descentNM) / speedAtTop
            left = descentNM
        }
        hours += decelerating(left, from: descending ? speed : speedAtTop, to: approach)

        return hours
    }

    /// Hours to cover `distance` while slowing steadily from one speed to
    /// another — the logarithmic mean, not the arithmetic one, since the slow
    /// end of the run takes longer per mile.
    private static func decelerating(_ distance: Double, from start: Double, to end: Double) -> Double {
        guard distance > 0 else { return 0 }
        let high = max(start, end), low = max(min(start, end), 1)
        guard high - low > 1 else { return distance / high }
        return distance * log(high / low) / (high - low)
    }

    /// The flown part of the route, for sizing the cruise altitude of a flight
    /// still climbing: the trip, not what is left of it, decides how high.
    private static func flightNMFlown(_ flight: Flight) -> Double {
        guard let departure = flight.departureIcao.flatMap({ AirportStore.shared.airport($0) }) else { return 0 }
        return FlightProgress.distanceNM(from: departure.coordinate, to: flight.coordinate)
    }

    // MARK: - Types

    /// Cruise ground speed for a type in still air, in knots.
    private static func typicalCruise(for flight: Flight) -> Double {
        switch flight.spriteKey {
        case "PRIVATEJET": return 430
        case "PC12": return 270
        case "TWINPROP": return 200
        case "DASH8", "AT42", "AT72": return 280
        case "C130", "A400": return 300
        case "SPIT", "LANC": return 220
        case "GLIDER", "BALLOON": return 60
        default: break
        }
        switch AircraftCategory.from(spriteKey: flight.spriteKey) {
        case .airliner: return 460
        case .regional: return 420
        case .light: return 120
        case .military: return 420
        case .helicopter: return 120
        }
    }

    /// The level a type cruises at on a long enough trip, in feet.
    private static func typicalCeiling(for flight: Flight) -> Double {
        switch flight.spriteKey {
        case "PRIVATEJET": return 41_000
        case "PC12": return 26_000
        case "TWINPROP", "DASH8", "AT42", "AT72": return 24_000
        default: break
        }
        switch AircraftCategory.from(spriteKey: flight.spriteKey) {
        case .airliner: return 37_000
        case .regional: return 35_000
        case .light: return 8_000
        case .military: return 30_000
        case .helicopter: return 3_000
        }
    }

    /// Speed over the threshold, roughly, in knots.
    static func approachSpeed(for flight: Flight) -> Double {
        switch flight.spriteKey {
        case "PRIVATEJET": return 125
        case "PC12", "TWINPROP": return 100
        case "GLIDER", "BALLOON": return 50
        default: break
        }
        switch AircraftCategory.from(spriteKey: flight.spriteKey) {
        case .airliner: return 145
        case .regional: return 125
        case .light: return 70
        case .military: return 150
        case .helicopter: return 60
        }
    }
}
