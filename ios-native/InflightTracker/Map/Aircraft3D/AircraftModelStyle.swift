import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// Three rules, together — see `magnification`. Every model is stored in
/// metres (see `GLBNormaliser`).
///
/// - **Close in, real size.** An aeroplane is exactly its real size, fixed to
///   the map the way the runway under it is. From about zoom 15 an airliner
///   is never rescaled at all.
/// - **Pulled back, a size curve.** Real size is a speck there, so the model
///   is drawn larger than life — but not at one fixed size: an A320 is about
///   six points long over the whole globe and grows gently to about
///   seventeen over a city (`farLengths`), so a zoomed-out map is a field of
///   small aeroplanes rather than a pile of large ones. Everything else is in
///   proportion to the A320, and nothing is drawn under `smallestShare` of it.
///   The curve meets real size where real size overtakes it, so the change
///   cannot be seen.
/// - **On the ground, never bigger than the airport.** A parked or taxiing
///   aeroplane is never drawn longer than `groundLongest` metres, so it stays
///   a small thing on its airfield at every zoom. The limit lifts smoothly
///   with height after take-off (doubling every `groundLiftDoubling` metres),
///   so nothing jumps at rotation.
///
/// Mapbox does not support a zoom-dependent `model-scale` on a GeoJSON
/// source — it bakes the value in when it lays a tile out — so the factor is
/// worked out here and written into each aeroplane's feature (`msc`), and
/// rewritten as the zoom moves for the aeroplanes whose factor changes: see
/// `TrackerMapView`'s `refreshModelScale`. Close in, where everything is real
/// size, nothing is rewritten at all.
///
/// The flat icon is only drawn for an aeroplane whose model has not arrived.
///
/// ## Height
///
/// Real height above the ground, as near as the feed allows (see
/// `AircraftAttitude.heightMetres`) — carried between packets at the
/// aeroplane's own vertical speed, so a climb is a climb rather than a stair.
///
/// That height is the same at every zoom: nothing about it depends on where
/// the camera is. Close in over a cruising airliner, the camera can be below
/// the aeroplane — which is where it really is.
///
/// ## Attitude
///
/// Mapbox turns a model by `[x, y, z]` degrees: heading about the vertical,
/// then pitch about the wings, then roll about the fuselage — checked in
/// Mapbox's renderer before it was written here. Nose up is a *negative* x;
/// right wing down is a positive y.
enum AircraftModelStyle {

    /// How long an A320 is drawn on screen, in points, at each zoom, while
    /// real size is smaller. Read between stops on a log scale, and held at
    /// the ends.
    private static let farLengths: [(zoom: Double, points: Double)] = [
        (3, 6), (6, 9), (9, 13), (12, 17), (15, 19),
    ]

    /// The airliner `farLengths` is measured on.
    private static let referenceLength = 38.0

    /// Nothing is drawn shorter than this share of an A320 — a light aircraft
    /// in true proportion would be a fifth of one, and lost.
    private static let smallestShare = 0.6

    /// The longest an aeroplane on the ground is ever drawn, in metres: a
    /// small thing on any airfield, whatever the zoom.
    private static let groundLongest = 150.0

    /// After take-off that limit doubles with every this many metres of
    /// height, and by cruise it is no limit at all.
    private static let groundLiftDoubling = 150.0

    /// Metres to a point at zoom zero, on Mapbox's 512-point world.
    private static let metresPerPointAtZoomZero = 40_075_016.686 / 512

    /// How long an A320 is drawn far out, in points, at a zoom.
    static func farLength(atZoom zoom: Double) -> Double {
        guard let first = farLengths.first, let last = farLengths.last else { return 19 }
        if zoom <= first.zoom { return first.points }
        if zoom >= last.zoom { return last.points }
        for index in 1..<farLengths.count where zoom <= farLengths[index].zoom {
            let low = farLengths[index - 1]
            let high = farLengths[index]
            let share = (zoom - low.zoom) / (high.zoom - low.zoom)
            return low.points * pow(high.points / low.points, share)
        }
        return last.points
    }

    /// The factor a model `lengthMetres` long is drawn at: one — real size —
    /// whenever real size is at least the size curve, just enough larger to
    /// reach the curve when it is not, and never so large on or near the
    /// ground that it outgrows the airfield. Mercator draws a metre bigger
    /// away from the equator, so the curve is measured in metres at the
    /// aeroplane's own latitude.
    static func magnification(
        lengthMetres: Double,
        latitude: Double,
        zoom: Double,
        heightMetres: Double
    ) -> Double {
        let length = max(lengthMetres, 1)
        let metresPerPoint = metresPerPointAtZoomZero * max(cos(latitude * .pi / 180), 0.01) / pow(2, zoom)
        let a320 = farLength(atZoom: zoom)
        let points = max(a320 * length / referenceLength, a320 * smallestShare)
        let curve = max(1, points * metresPerPoint / length)
        let longest = groundLongest * pow(2, min(max(heightMetres, 0), 3_000) / groundLiftDoubling)
        return min(curve, max(1, longest / length))
    }

    /// The scale, as each aeroplane's feature carries it.
    static func scaleExpression() -> [Any] {
        ["get", "msc"]
    }

    /// Which model each aeroplane is drawn from: its own, at real size.
    static func modelIdExpression() -> [Any] {
        ["to-string", ["get", "model"]]
    }

    /// The flat icon: drawn only for an aeroplane with no model yet.
    static func iconOpacityExpression() -> [Any] {
        ["case", ["has", "model"], 0, 1]
    }

    /// The height, as each aeroplane's feature carries it.
    static func liftExpression() -> [Any] {
        ["get", "mt"]
    }

    /// The height an aeroplane is drawn at: its real height above the
    /// ground, at every zoom. What is written into its feature, and what the
    /// flown path is drawn to meet (see `FlownPathProfile`).
    static func drawnLift(heightMetres: Double) -> Double {
        max(heightMetres, 0)
    }

    /// The per-aircraft half of the above, written into its feature.
    static func properties(
        heading: Double,
        pitch: Double,
        bank: Double,
        heightMetres: Double,
        scale: Double
    ) -> [String: [Double]] {
        [
            "mrot": [-pitch, bank, heading],
            "mt": [0, 0, drawnLift(heightMetres: heightMetres)],
            "msc": [scale, scale, scale],
        ]
    }
}

/// An aeroplane's attitude, worked out from what the feed says, for the model.
///
/// The feed carries a heading, a ground speed and a vertical speed; not a pitch
/// and not a bank. So, like the instruments: pitch is the flight path angle,
/// and bank is what a coordinated turn at the observed rate would need. Both
/// are eased towards each new packet's answer rather than jumped to it.
///
/// The aircraft flown on this phone does better — its own simulator's pitch
/// and bank, through Connect. See `TrackerMapView`.
struct AircraftAttitude {

    private var lastHeading: Double?
    private var lastSampleAt: CFTimeInterval = 0
    private var turnRate = 0.0

    private var easedBank = Eased()
    private var easedPitch = Eased()

    /// Height above the field, carried at the reported vertical speed between
    /// packets and eased onto each new report rather than jumped to it.
    private var height = Carried()

    /// The altitude this aircraft was last seen sitting on the ground at — the
    /// nearest thing the feed offers to the height of the field.
    private(set) var groundAltitudeFeet: Double?

    private static let maximumBank = 35.0
    private static let deadband = 0.4
    private static let maximumRate = 12.0

    mutating func report(_ flight: Flight, now: CFTimeInterval) {
        let onGround = FlightPhase.from(flight) == .ground
        if onGround { groundAltitudeFeet = flight.altitudeFeet }

        // Turn rate between packets, smoothed, with the feed's rounding read as
        // wings level.
        if let last = lastHeading {
            let elapsed = now - lastSampleAt
            if elapsed > 0.5, elapsed < 30 {
                var delta = flight.heading - last
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                let rate = delta / elapsed
                if abs(rate) <= Self.maximumRate {
                    turnRate = turnRate * 0.4 + rate * 0.6
                }
            }
        }
        lastHeading = flight.heading
        lastSampleAt = now

        let speed = flight.groundSpeedKnots * 0.514444
        var targetBank = 0.0
        if !onGround, abs(turnRate) >= Self.deadband {
            targetBank = atan(speed * turnRate * .pi / 180 / 9.81) * 180 / .pi
            targetBank = min(max(targetBank, -Self.maximumBank), Self.maximumBank)
        }
        easedBank.aim(at: targetBank, now: now)
        easedPitch.aim(at: onGround ? 0 : InstrumentReading.derivedPitchDegrees(for: flight), now: now)

        let reportedHeight = onGround ? 0 : max(flight.altitudeFeet - (groundAltitudeFeet ?? 0), 0) * 0.3048
        let climb = onGround ? 0 : flight.verticalSpeedFPM * 0.3048 / 60
        height.report(reportedHeight, rate: climb, now: now)
    }

    /// A field altitude from elsewhere — the track — used until the feed
    /// shows the aeroplane on the ground itself.
    mutating func adoptGroundAltitude(_ feet: Double) {
        guard groundAltitudeFeet == nil, feet.isFinite else { return }
        groundAltitudeFeet = feet
    }

    func bank(at now: CFTimeInterval) -> Double { easedBank.value(at: now) }
    func pitch(at now: CFTimeInterval) -> Double { easedPitch.value(at: now) }

    /// Height above the field, in metres, as well as the feed allows, now.
    func heightMetres(at now: CFTimeInterval) -> Double {
        max(height.value(at: now), 0)
    }

    /// A value reported with a rate: run forward at that rate for up to
    /// `maximumLead` seconds, with the gap to each new report closed over
    /// about a second rather than in a step.
    private struct Carried {
        private var base = 0.0
        private var rate = 0.0
        private var since: CFTimeInterval = 0
        private var correction = 0.0
        private var started = false
        private static let timeConstant = 1.0
        private static let maximumLead = 12.0

        func value(at now: CFTimeInterval) -> Double {
            let elapsed = max(now - since, 0)
            return base + rate * min(elapsed, Self.maximumLead) + correction * exp(-elapsed / Self.timeConstant)
        }

        mutating func report(_ value: Double, rate: Double, now: CFTimeInterval) {
            let drawn = started ? self.value(at: now) : value
            started = true
            base = value
            self.rate = rate
            since = now
            correction = drawn - value
        }
    }

    /// A value that settles on its target over about a second.
    private struct Eased {
        private var from = 0.0
        private var to = 0.0
        private var since: CFTimeInterval = 0
        private static let timeConstant = 1.2

        func value(at now: CFTimeInterval) -> Double {
            let elapsed = max(now - since, 0)
            return to + (from - to) * exp(-elapsed / Self.timeConstant)
        }

        mutating func aim(at target: Double, now: CFTimeInterval) {
            from = value(at: now)
            to = target
            since = now
        }
    }
}
