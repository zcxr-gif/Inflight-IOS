import CoreLocation
import Foundation

/// Everything the two instruments draw, gathered once so neither display has to
/// know where any of it came from.
///
/// Two sources feed this, and which one answered matters enough to be carried:
/// the live feed knows position, height, speed and heading for every aircraft
/// on the server, and the pilot's own simulator — when they are broadcasting it
/// through Connect — knows the things the feed cannot possibly know, which is
/// most of what a primary flight display is: attitude, indicated airspeed, the
/// wind, the configuration. `attitude` says which, and the displays label
/// themselves accordingly rather than presenting a guess as a measurement.
struct InstrumentReading: Equatable {

    /// Where the attitude on the ball came from.
    enum AttitudeSource: Equatable {

        /// Read out of the simulator. Real pitch and real bank.
        case simulator

        /// Worked out from what the aircraft is doing: the flight path angle
        /// from vertical speed against ground speed, and the bank a coordinated
        /// turn at the observed turn rate would need.
        case derived
    }

    var callsign: String

    /// What the speed tape shows, and whether it is indicated airspeed.
    ///
    /// The sim gives IAS, which is what a speed tape means. Everything else on
    /// the map only reports ground speed, and drawing that on the same tape
    /// without saying so would be quietly wrong at altitude — hence the flag,
    /// which the tape prints next to itself.
    var speedKnots: Double
    var speedIsIndicated: Bool

    var groundSpeedKnots: Double
    var trueAirspeedKnots: Double?

    var altitudeFeet: Double
    var altitudeAGLFeet: Double?
    var verticalSpeedFPM: Double

    /// Where the nose is pointing, 0..<360.
    var headingDegrees: Double

    /// Where the aeroplane is actually going. Equal to the heading unless the
    /// sim is reporting both and the wind is pushing it off.
    var trackDegrees: Double

    var pitchDegrees: Double
    var bankDegrees: Double
    var attitude: AttitudeSource

    var windDirectionDegrees: Double?
    var windSpeedKnots: Double?

    var phase: FlightPhase
    var isOnGround: Bool

    /// Gear, flaps and spoilers as one line, when the sim is reporting them.
    var configuration: String?

    var coordinate: CLLocationCoordinate2D

    static func == (lhs: InstrumentReading, rhs: InstrumentReading) -> Bool {
        lhs.callsign == rhs.callsign
            && lhs.speedKnots == rhs.speedKnots
            && lhs.speedIsIndicated == rhs.speedIsIndicated
            && lhs.groundSpeedKnots == rhs.groundSpeedKnots
            && lhs.trueAirspeedKnots == rhs.trueAirspeedKnots
            && lhs.altitudeFeet == rhs.altitudeFeet
            && lhs.altitudeAGLFeet == rhs.altitudeAGLFeet
            && lhs.verticalSpeedFPM == rhs.verticalSpeedFPM
            && lhs.headingDegrees == rhs.headingDegrees
            && lhs.trackDegrees == rhs.trackDegrees
            && lhs.pitchDegrees == rhs.pitchDegrees
            && lhs.bankDegrees == rhs.bankDegrees
            && lhs.attitude == rhs.attitude
            && lhs.windDirectionDegrees == rhs.windDirectionDegrees
            && lhs.windSpeedKnots == rhs.windSpeedKnots
            && lhs.phase == rhs.phase
            && lhs.isOnGround == rhs.isOnGround
            && lhs.configuration == rhs.configuration
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

// MARK: - Deriving one

extension InstrumentReading {

    /// The most this app can honestly say about one aircraft.
    ///
    /// `bankDegrees` is passed in rather than worked out here because it takes
    /// a memory of where the heading has been — see `InstrumentTurnEstimator`
    /// — and a value type is the wrong place to keep one.
    static func make(
        flight: Flight,
        sim: PilotLiveStatus?,
        derivedBankDegrees: Double
    ) -> InstrumentReading {
        let heading = normalisedDegrees(flight.heading)

        // Narrowed once. A row that exists but is no longer live is a row
        // about a flight that has finished, and reading numbers out of it
        // would be presenting last week's wind as this minute's.
        let live = sim?.isLive == true ? sim : nil

        // Pitch and bank come off the simulator together or not at all: half a
        // real attitude and half a guess would be the one presentation that
        // cannot be labelled honestly.
        let simulatedAttitude: (pitch: Double, bank: Double)? = {
            guard let pitch = live?.pitch, let bank = live?.bank else { return nil }
            return (Double(pitch), Double(bank))
        }()

        let onGround = FlightPhase.from(flight) == .ground
            && (live?.altitudeAGL.map({ $0 < 50 }) ?? true)

        let indicated = live?.indicatedAirspeedKnots.map({ Double($0) })

        // Every number below goes through `finite`. The feed parses its
        // telemetry leniently — a field can arrive as a string — and one NaN
        // reaching a tape becomes `Int(nan)`, which is not a wrong reading but
        // a crash.
        return InstrumentReading(
            callsign: flight.displayName,
            speedKnots: finite(indicated ?? flight.groundSpeedKnots),
            speedIsIndicated: indicated != nil,
            groundSpeedKnots: finite(flight.groundSpeedKnots),
            trueAirspeedKnots: live?.trueAirspeedKnots.map({ Double($0) }),
            altitudeFeet: finite(flight.altitudeFeet),
            altitudeAGLFeet: live?.altitudeAGL.map({ Double($0) }),
            verticalSpeedFPM: finite(flight.verticalSpeedFPM),
            headingDegrees: heading,
            // The simulator reports heading; the feed's `heading_deg` is the
            // same field, so with nothing better to go on track *is* heading
            // and the drift bar on the navigation display is simply zero.
            trackDegrees: heading,
            pitchDegrees: finite(simulatedAttitude?.pitch ?? derivedPitchDegrees(for: flight)),
            bankDegrees: finite(simulatedAttitude?.bank ?? derivedBankDegrees),
            attitude: simulatedAttitude == nil ? .derived : .simulator,
            windDirectionDegrees: live?.windDirection.map({ Double($0) }),
            windSpeedKnots: live?.windVelocityKnots.map({ Double($0) }),
            phase: FlightPhase.from(flight),
            isOnGround: onGround,
            configuration: configurationLine(for: live),
            coordinate: flight.coordinate
        )
    }

    /// Flight path angle, which is the honest stand-in for pitch.
    ///
    /// A real pitch attitude is the flight path angle plus the wing's angle of
    /// attack, and nothing outside the simulator knows the second term — so
    /// this deliberately under-reads in the climb rather than inventing a deck
    /// angle. Clamped because a stationary aircraft reporting a vertical speed
    /// would otherwise stand the horizon on end.
    static func derivedPitchDegrees(for flight: Flight) -> Double {
        let forwardFeetPerMinute = flight.groundSpeedKnots * 101.269
        guard forwardFeetPerMinute > 600 else { return 0 }
        let angle = atan2(flight.verticalSpeedFPM, forwardFeetPerMinute) * 180 / .pi
        return min(max(angle, -20), 20)
    }

    /// Gear, flaps and boards on one line, from whatever the sim reported.
    private static func configurationLine(for sim: PilotLiveStatus?) -> String? {
        guard let sim = sim else { return nil }

        var parts: [String] = []
        if let gear = sim.gearState {
            // Infinite Flight's gear state is 0 up, 1 down, with the two
            // transits in between; anything not fully up reads as down here,
            // because a display that says UP while the gear is travelling is
            // the wrong way to be wrong.
            parts.append(gear == 0 ? "GEAR UP" : "GEAR DOWN")
        }
        if let flaps = sim.flapsState, flaps > 0 {
            parts.append("FLAP \(flaps)")
        }
        if let spoilers = sim.spoilersState, spoilers > 0 {
            parts.append(spoilers > 1 ? "SPD BRK ARMED" : "SPD BRK")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The value, or zero when it is not a number the display could draw.
    static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    static func normalisedDegrees(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let wrapped = value.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}

// MARK: - Bank, from a memory of the heading

/// Turns a sequence of headings into the bank angle that would produce them.
///
/// The feed reports where an aeroplane is pointing, several seconds apart, and
/// never how far it is leaning. But a turn in the air is a banked turn: hold a
/// rate of turn ω at speed V and the wings must be at `atan(ωV/g)`, which is
/// the whole of this class. Straight out of the raw samples it is unusable —
/// packets arrive unevenly, headings come rounded, and an aircraft that has not
/// moved shows a turn rate of whatever the rounding did — so the rate is fitted
/// across a couple of seconds of samples rather than differenced between two,
/// and a rate under half a degree a second is read as wings level.
///
/// The same approach the web tracker took, and for the same reason: without it
/// the artificial horizon sits dead level through every turn, which is the one
/// thing that makes it obvious there is nothing behind the instrument.
final class InstrumentTurnEstimator {

    private struct Sample {
        let at: Date
        /// Continuous rather than 0..<360, so a turn through north is a turn
        /// rather than a 359-degree jump.
        let unwrappedHeading: Double
    }

    /// How much history the fit runs over. Long enough to smooth the feed's
    /// jitter, short enough that rolling out shows up promptly.
    private static let window: TimeInterval = 8

    /// Below this the aeroplane is treated as wings level. A degree every two
    /// seconds is inside what the feed's rounding alone can produce.
    private static let deadband: Double = 0.5

    /// A rate this high is a packet gap or a teleport, not a turn.
    private static let maximumRate: Double = 12

    /// Airliners do not hold more than this, and anything that says otherwise
    /// is an artefact of the sampling.
    private static let maximumBank: Double = 33

    private var samples: [Sample] = []
    private var unwrapped: Double?

    /// The flight these samples belong to, so opening a second aircraft cannot
    /// inherit the first one's turn.
    private var flightId: String?

    /// Feed one packet in. Cheap enough to call on every update.
    func ingest(flight: Flight, at date: Date = Date()) {
        if flightId != flight.id {
            flightId = flight.id
            samples.removeAll(keepingCapacity: true)
            unwrapped = nil
        }

        let heading = InstrumentReading.normalisedDegrees(flight.heading)

        let continuous: Double
        if let previous = unwrapped {
            var delta = heading - previous.truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            continuous = previous + delta
        } else {
            continuous = heading
        }
        unwrapped = continuous

        // A repeated timestamp would put two points at the same x and skew the
        // fit; the feed can deliver the same packet twice on a reconnect.
        if let last = samples.last, date.timeIntervalSince(last.at) < 0.25 {
            samples[samples.count - 1] = Sample(at: date, unwrappedHeading: continuous)
        } else {
            samples.append(Sample(at: date, unwrappedHeading: continuous))
        }

        let cutoff = date.addingTimeInterval(-Self.window)
        samples.removeAll { $0.at < cutoff }
    }

    /// Degrees per second, positive to the right.
    var turnRateDegreesPerSecond: Double {
        guard samples.count >= 3, let first = samples.first, let last = samples.last else { return 0 }
        let span = last.at.timeIntervalSince(first.at)
        guard span > 1 else { return 0 }

        // Least squares through (seconds, heading). The slope is the rate.
        let times = samples.map { $0.at.timeIntervalSince(first.at) }
        let headings = samples.map(\.unwrappedHeading)
        let count = Double(samples.count)

        let sumT = times.reduce(0, +)
        let sumH = headings.reduce(0, +)
        let sumTT = times.reduce(0) { $0 + $1 * $1 }
        let sumTH = zip(times, headings).reduce(0) { $0 + $1.0 * $1.1 }

        let denominator = count * sumTT - sumT * sumT
        guard abs(denominator) > 0.0001 else { return 0 }

        let slope = (count * sumTH - sumT * sumH) / denominator
        guard slope.isFinite, abs(slope) <= Self.maximumRate else { return 0 }
        return abs(slope) < Self.deadband ? 0 : slope
    }

    /// The bank a coordinated turn at the current rate and speed would need.
    ///
    /// Returns level for anything on the ground: an aeroplane turning off a
    /// runway is turning at a very healthy rate and is not leaning at all.
    func bankDegrees(groundSpeedKnots: Double, isOnGround: Bool) -> Double {
        guard !isOnGround, groundSpeedKnots > 60 else { return 0 }

        let rate = turnRateDegreesPerSecond
        guard rate != 0 else { return 0 }

        let metresPerSecond = groundSpeedKnots * 0.514444
        let radiansPerSecond = rate * .pi / 180
        let bank = atan(abs(radiansPerSecond) * metresPerSecond / 9.80665) * 180 / .pi

        return (rate < 0 ? -1 : 1) * min(bank, Self.maximumBank)
    }
}
