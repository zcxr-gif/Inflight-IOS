import CoreLocation
import Foundation

/// Where an aircraft is *between* packets.
///
/// The feed reports a position every few seconds. Drawn straight from it, an
/// aeroplane at cruise does not fly across the map — it sits still, jumps a
/// centimetre, and sits still again. At the zoom somebody actually watches one
/// aircraft at, that jump is the only movement there is, and it reads as the
/// app stuttering rather than as an aeroplane travelling.
///
/// So the position is carried forward between packets, at the heading and
/// ground speed the aircraft last reported. That is a prediction, and it is
/// worth being explicit about the difference from `InstrumentAnimator`, which
/// deliberately *lags* the feed rather than running ahead of it: an artificial
/// horizon is a claim about attitude, which nothing can predict, while a
/// position at a known heading and speed is arithmetic — an aeroplane at 450
/// knots is half a mile further on a second later, and drawing it where it was
/// four seconds ago is no more honest than drawing it where it is.
///
/// ## The part that is not arithmetic
///
/// The prediction will be a little wrong, and a packet landing is the moment it
/// finds out. Snapping to the new truth is exactly the jank this exists to
/// remove — and so is closing the gap quickly, which was the first version:
/// a correction spent over a second is a surge or a stall every few seconds,
/// on every aeroplane, and reads as exactly the jerkiness it was hiding.
///
/// So a packet starts a *leg*: a straight line, flown at one constant speed,
/// from where the aeroplane is drawn to where the new packet says it will be
/// two packets later (`legSpan`). The next packet normally lands halfway along
/// and starts the next leg from wherever the aeroplane has got to; if packets
/// stop, the leg ends exactly on the prediction and dead reckoning carries on
/// at the reported speed. The error is spread over seconds instead of a
/// fraction of one, so the speed changes only a little, once, when a packet
/// lands — and never surges, stalls or reverses.
struct FlightMotion {

    // MARK: - Tuning

    /// The gap between packets assumed before two have been seen: the
    /// simulator's feed every few seconds, the real-world sweep every fifteen.
    private static let simulatorInterval: Double = 4
    private static let realWorldInterval: Double = 15

    /// How many packet-gaps a leg spans. Two halves the change of pace a
    /// packet causes compared with one, at no cost in accuracy — tried
    /// against a feed with jittered timing and noisy positions before it was
    /// written here.
    private static let legSpan: Double = 2

    /// The shortest leg. A burst of packets close together should not make
    /// the aeroplane lurch to catch each one.
    private static let shortestLeg: Double = 1

    /// The same, for the heading the sprite is turned to. Matched to the
    /// instruments, which have been settling headings at this rate for as long
    /// as there have been instruments.
    private static let headingTimeConstant: Double = 0.7

    /// How far ahead of the last packet the prediction is allowed to run.
    ///
    /// The feed skips an aircraft for a packet or two, and a reconnect can cost
    /// longer than that. Extrapolating a heading and a speed for six seconds is
    /// arithmetic; extrapolating them for two minutes is fiction, and produces
    /// an aeroplane confidently flying a straight line somewhere it is not. Past
    /// this the prediction simply stops and waits to be told.
    private static let simulatorLead: Double = 12

    /// The same, for real-world traffic — and longer, because the gap it has to
    /// cover is longer.
    ///
    /// ADS-B is *swept* on a fifteen-second clock rather than pushed every few
    /// seconds, and a lead shorter than the gap between reports is the one
    /// setting that guarantees the artefact this whole file exists to remove:
    /// the prediction runs out, the aeroplane coasts to a halt, and three
    /// seconds later the sweep lands and it jumps. Once per cycle, on every
    /// real aeroplane on the map, forever. So this clears the sweep with room
    /// for one that arrives late.
    private static let realWorldLead: Double = 20

    /// The furthest a lead can carry an aeroplane past its last packet, in
    /// metres, at a speed nothing in the sim exceeds.
    ///
    /// For a caller that has to decide whether an aircraft is worth advancing
    /// *before* it has advanced it — the planet culls the packet against the
    /// screen first, and an aeroplane reported just off the edge may well have
    /// flown onto it since. Widening that test by this is what stops one
    /// arriving late, at the edge, having jumped.
    ///
    /// The longer of the two leads, because the caller is testing a screen
    /// rather than an aircraft: a box cut to the simulator's lead would clip
    /// exactly the real-world traffic that had furthest to travel.
    static let maximumLeadMetres: Double = realWorldLead * 340

    /// Beyond this, a correction is a cut rather than a slide.
    ///
    /// An aircraft that has been repositioned, respawned, or restored from a
    /// stale annotation is not off by a bit — it is somewhere else. Sliding it
    /// across four kilometres of map at cruise speed would take a minute and
    /// would be a lie for every second of it.
    private static let snapMetres: Double = 4_000

    // MARK: - What the feed said

    private var reported: CLLocationCoordinate2D
    private var reportedAt: CFTimeInterval
    private var headingDegrees: Double
    private var metresPerSecond: Double

    /// How long this aircraft's packets have been apart, smoothed — the
    /// length of the next leg.
    private var interval: Double

    // MARK: - What is on the map

    /// The leg being flown: from where the aeroplane was drawn when the last
    /// packet landed to where that packet puts it `legDuration` later. Zero
    /// duration is no leg, and the prediction is drawn as it is.
    private var legFrom: CLLocationCoordinate2D
    private var legTo: CLLocationCoordinate2D
    private var legStart: CFTimeInterval
    private var legDuration: Double = 0

    /// What the annotation is actually set to.
    private(set) var drawn: CLLocationCoordinate2D

    /// The bearing the sprite is turned to, kept on a continuous line so a turn
    /// through north sweeps rather than spinning the long way round.
    private var unwrappedHeading: Double

    /// That bearing, as a compass heading.
    var drawnHeading: Double {
        let wrapped = unwrappedHeading.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    private var lastStep: CFTimeInterval

    /// How far ahead of its last report *this* aircraft may be flown. Fixed
    /// when the motion is made, because it is a fact about where the aeroplane
    /// came from rather than about the moment — see the two leads above.
    private let maximumLead: Double

    // MARK: - Life

    /// Starts from where the aircraft is already drawn, not from where it has
    /// just been reported — beginning is a moment like any other, and an
    /// aeroplane that jumped the instant smoothing was switched on would be
    /// advertising the very thing it is here to hide.
    init(flight: Flight, drawnAt coordinate: CLLocationCoordinate2D, now: CFTimeInterval) {
        let isRealWorld = flight.origin == .realWorld
        self.maximumLead = isRealWorld ? Self.realWorldLead : Self.simulatorLead
        self.interval = isRealWorld ? Self.realWorldInterval : Self.simulatorInterval
        self.reported = flight.coordinate
        self.reportedAt = now
        self.headingDegrees = flight.heading
        self.metresPerSecond = Self.metresPerSecond(knots: flight.groundSpeedKnots)
        let start = CLLocationCoordinate2DIsValid(coordinate) ? coordinate : flight.coordinate
        self.drawn = start
        self.legFrom = start
        self.legTo = start
        self.legStart = now
        self.unwrappedHeading = flight.heading
        self.lastStep = now
        startLeg(from: start, now: now)
    }

    /// A fresh packet. The drawn position is left exactly where it is, and a
    /// new leg starts from there — see the notes at the top.
    ///
    /// ## A packet already told about is not a fresh one
    ///
    /// This is handed the aircraft by whatever is diffing the map against the
    /// feed, and that is not only the feed: the map re-culls its annotations
    /// through a pan or a pinch, four times a second, against whichever packet
    /// happens to be the current one. The aeroplane in it is the same
    /// aeroplane, at the same position, from the same packet — but the moment
    /// arriving with it is *now*.
    ///
    /// Taken as a report, that moment is a claim that the aircraft is at the
    /// old position right now, which throws away every second of prediction
    /// since the packet actually landed and hands `advance(to:)` a correction
    /// pointing backwards. The aeroplane is hauled back along its own track,
    /// then runs forward again, then is hauled back — for as long as the
    /// gesture lasts. Which is precisely what a zoom looked like.
    ///
    /// So the same fix twice is nothing at all. The clock is only restarted by
    /// a packet that actually says something new.
    mutating func report(_ flight: Flight, now: CFTimeInterval) {
        guard !isSameFix(as: flight) else { return }

        // Where it is drawn at this moment, under the leg being replaced.
        let from = position(at: now)

        // How far apart this aircraft's packets come, eased so one late
        // packet does not stretch the next leg out of shape.
        let gap = now - reportedAt
        if gap > 0.25, gap < maximumLead {
            interval = interval * 0.6 + gap * 0.4
        }

        reported = flight.coordinate
        reportedAt = now
        headingDegrees = flight.heading
        metresPerSecond = Self.metresPerSecond(knots: flight.groundSpeedKnots)

        // Unless it is not a gap at all but a different place. See `snapMetres`.
        if Self.metres(from: from, to: reported) > Self.snapMetres {
            drawn = reported
            legDuration = 0
            unwrappedHeading = flight.heading
            return
        }
        startLeg(from: from, now: now)
    }

    /// A straight leg, at one speed, from `from` to where the last packet puts
    /// the aeroplane `legSpan` packet-gaps from now.
    private mutating func startLeg(from: CLLocationCoordinate2D, now: CFTimeInterval) {
        let duration = min(max(interval * Self.legSpan, Self.shortestLeg), maximumLead)
        legFrom = from
        legTo = predictedNow(at: now + duration)
        legStart = now
        legDuration = duration
    }

    /// Where the aeroplane is drawn at a moment: along the leg while it lasts,
    /// and the prediction itself after — the two meet where the leg ends.
    private func position(at now: CFTimeInterval) -> CLLocationCoordinate2D {
        guard legDuration > 0 else { return predictedNow(at: now) }
        let share = (now - legStart) / legDuration
        guard share < 1 else { return predictedNow(at: now) }
        let leg = Self.offset(from: legFrom, to: legTo)
        let along = max(share, 0)
        return Self.moved(legFrom, north: leg.north * along, east: leg.east * along)
    }

    /// Whether this is the packet already being flown forward.
    ///
    /// Compared exactly, and exactly is the right test: these are the same
    /// `Double`s copied out of the same decoded packet, not two measurements of
    /// one thing. An aircraft that genuinely reports an identical position,
    /// heading and speed in a *new* packet is one that has not moved, and
    /// leaving the prediction where it is — running on, or stopped at
    /// `maximumLead` — is what should happen to it anyway.
    private func isSameFix(as flight: Flight) -> Bool {
        flight.latitude == reported.latitude
            && flight.longitude == reported.longitude
            && flight.heading == headingDegrees
            && Self.metresPerSecond(knots: flight.groundSpeedKnots) == metresPerSecond
    }

    /// Advances one frame. Returns the position to draw.
    @discardableResult
    mutating func advance(to now: CFTimeInterval) -> CLLocationCoordinate2D {
        let elapsed = now - lastStep
        lastStep = now

        let here = position(at: now)
        drawn = CLLocationCoordinate2DIsValid(here) ? here : reported

        // Not a frame: a resume from the background, or a clock that has gone
        // backwards. The heading is taken whole rather than eased.
        guard elapsed > 0, elapsed < 1 else {
            unwrappedHeading = Self.unwrap(unwrappedHeading, towards: headingDegrees)
            return drawn
        }

        let target = Self.unwrap(unwrappedHeading, towards: headingDegrees)
        let turned = 1 - exp(-elapsed / Self.headingTimeConstant)
        unwrappedHeading += (target - unwrappedHeading) * turned

        return drawn
    }

    /// How far apart two coordinates are, in points on the map as it is
    /// currently scaled.
    ///
    /// The unit is the point rather than the metre because the question is
    /// always the same one — is this worth drawing — and a kilometre is a
    /// gesture at one zoom and nothing at all at another.
    static func pointsApart(
        _ origin: CLLocationCoordinate2D,
        _ destination: CLLocationCoordinate2D,
        pointsPerMetre: Double
    ) -> Double {
        guard pointsPerMetre.isFinite, pointsPerMetre > 0 else { return 0 }
        return metres(from: origin, to: destination) * pointsPerMetre
    }

    // MARK: - Geometry

    private func predictedNow(at now: CFTimeInterval) -> CLLocationCoordinate2D {
        let lead = min(max(now - reportedAt, 0), maximumLead)
        guard lead > 0, metresPerSecond > 0 else { return reported }
        return GreatCircle.coordinate(
            from: reported,
            bearing: headingDegrees,
            metres: metresPerSecond * lead
        )
    }

    private static func metresPerSecond(knots: Double) -> Double {
        guard knots.isFinite, knots > 0 else { return 0 }
        return knots * 0.514444
    }

    /// Metres north and east from one coordinate to another.
    ///
    /// A flat approximation, and deliberately so: this is only ever used for
    /// the gap between where an aeroplane is drawn and where it is predicted to
    /// be, which is metres to a few kilometres. The prediction itself, which
    /// can run for miles, goes the long way round on a sphere.
    private static func offset(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> (north: Double, east: Double) {
        let north = (destination.latitude - origin.latitude) * metresPerDegreeLatitude

        var deltaLongitude = destination.longitude - origin.longitude
        // The date line: the short way round, not three hundred and fifty
        // degrees of the long one.
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }

        let east = deltaLongitude * metresPerDegreeLatitude
            * cos(origin.latitude * .pi / 180)

        return (north.isFinite ? north : 0, east.isFinite ? east : 0)
    }

    private static func moved(
        _ origin: CLLocationCoordinate2D,
        north: Double,
        east: Double
    ) -> CLLocationCoordinate2D {
        guard north.isFinite, east.isFinite else { return origin }

        let latitude = origin.latitude + north / metresPerDegreeLatitude

        // At the pole the scaling blows up, so it is floored rather than
        // divided by nothing. Nobody flies there; a NaN coordinate would take
        // the annotation with it.
        let shrink = max(cos(origin.latitude * .pi / 180), 0.01)
        var longitude = origin.longitude + east / (metresPerDegreeLatitude * shrink)

        if longitude > 180 { longitude -= 360 }
        if longitude < -180 { longitude += 360 }

        return CLLocationCoordinate2D(
            latitude: min(max(latitude, -89.9), 89.9),
            longitude: longitude
        )
    }

    private static func metres(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) -> Double {
        let offset = offset(from: origin, to: destination)
        return hypot(offset.north, offset.east)
    }

    private static let metresPerDegreeLatitude: Double = 111_320

    /// The reported bearing expressed on the same continuous line the drawn one
    /// is on, so the shorter way round is the way it goes. The same trick the
    /// instruments' tapes use, and for the same reason.
    private static func unwrap(_ continuous: Double, towards reported: Double) -> Double {
        guard reported.isFinite else { return continuous }
        var delta = reported - continuous.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return continuous + delta
    }
}

// MARK: - Sphere

/// Walking a bearing and a distance across the planet.
///
/// Shared rather than sitting private inside the map: the sprite rotation
/// probes with it, and dead reckoning flies with it, and two copies of a
/// haversine is one copy too many.
enum GreatCircle {

    static let earthRadius: Double = 6_371_000

    static func coordinate(
        from origin: CLLocationCoordinate2D,
        bearing degrees: Double,
        metres: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        guard metres.isFinite, degrees.isFinite,
              CLLocationCoordinate2DIsValid(origin) else { return origin }

        let angular = metres / earthRadius
        let bearing = degrees * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180

        let destinationLatitude = asin(
            sin(latitude) * cos(angular) + cos(latitude) * sin(angular) * cos(bearing)
        )
        let destinationLongitude = longitude + atan2(
            sin(bearing) * sin(angular) * cos(latitude),
            cos(angular) - sin(latitude) * sin(destinationLatitude)
        )

        return CLLocationCoordinate2D(
            latitude: destinationLatitude * 180 / .pi,
            longitude: (destinationLongitude * 180 / .pi).remainder(dividingBy: 360)
        )
    }
}

// MARK: - Which aircraft this is for

extension Flight {

    /// Whether this aircraft's position is worth carrying between packets.
    ///
    /// Moving fast enough for a heading to mean something: flying, or taxiing.
    /// An aeroplane at a gate reports a heading that is whichever way the nose
    /// happens to be pointing and a ground speed that is noise, and dead
    /// reckoning from those would have it creeping through the terminal
    /// building — so one parked or barely moving is drawn exactly where its
    /// packets put it.
    var isWorthSmoothing: Bool {
        guard heading.isFinite, groundSpeedKnots.isFinite else { return false }
        if FlightPhase.from(self) == .ground { return groundSpeedKnots >= Self.taxiSmoothingKnots }
        return groundSpeedKnots >= 40
    }

    /// On the ground, an aeroplane taxiing faster than this is carried too:
    /// drawn straight from its packets it hops along the taxiway. Below it is
    /// one parked or pushing back, whose heading and speed are noise.
    private static let taxiSmoothingKnots = 5.0

    /// Whether carrying this aircraft forward is a preference or a requirement.
    ///
    /// For the simulator's traffic it is a preference, and a reasonable one to
    /// switch off: positions arrive every few seconds, so an aeroplane drawn
    /// straight from the feed jumps by a small amount often — which some people
    /// would rather have than a prediction, and which Reduce Motion asks for.
    ///
    /// Real-world traffic is not the same case. It is *swept* every fifteen
    /// seconds rather than pushed, so the same aeroplane drawn straight from
    /// the data does not jump a little often — it stands perfectly still for
    /// fifteen seconds and then teleports two miles. That is not the raw truth
    /// with the smoothing taken off; it is an artefact of the polling interval,
    /// and there is no setting under which it is the better picture. So it is
    /// carried whatever the preference says, and `isWorthSmoothing` still
    /// decides whether *this* aeroplane is one that should be carried at all.
    var requiresSmoothing: Bool { origin == .realWorld }
}
