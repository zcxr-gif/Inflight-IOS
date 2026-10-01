import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// Real size, always. Every model is stored in metres (see `GLBNormaliser`)
/// and drawn at scale one, so an aeroplane is fixed to the map the way the
/// runway under it is: zooming in makes it bigger on screen exactly as much as
/// it makes the runway bigger, and an A380 is always twice an A320.
///
/// Pulled back, real size is too small to see, so there the aeroplane is its
/// flat icon, and the model takes over once it is big enough to read — about
/// sixteen points long. That happens at a different zoom for different
/// aeroplanes: an A380 is ready long before a Cessna, so each one changes
/// over on its own, with a short fade, by its real length.
///
/// ## Height
///
/// Drawn at its true height, an aeroplane at cruise would float kilometres off
/// its own track the moment the map tilts — above the camera, at the zooms
/// models are drawn at. So it is lifted by a small, shrinking share of its
/// height instead (see `lift`). An aircraft on the ground sits on it.
///
/// ## Attitude
///
/// Mapbox turns a model by `[x, y, z]` degrees: heading about the vertical,
/// then pitch about the wings, then roll about the fuselage — checked in
/// Mapbox's renderer before it was written here. Nose up is a *negative* x;
/// right wing down is a positive y.
enum AircraftModelStyle {

    /// Below this zoom no model is drawn at all; every aeroplane is an icon.
    static let firstModelZoom = 15.0

    /// When each size of aeroplane changes from icon to model: from `zoom`
    /// on, everything at least `length` metres long is a model. Each change
    /// fades in over the half zoom before it.
    private static let handover: [(zoom: Double, length: Double)] = [
        (15.5, 30),
        (16.5, 15),
        (17.5, 7),
        (18, 0),
    ]

    private static var length: [Any] { ["to-number", ["get", "mlen"], 0] }

    /// The flat icon's opacity: gone for an aeroplane whose model has taken
    /// over at this zoom.
    static func iconOpacityExpression() -> [Any] {
        handoverExpression(before: 1) { length in
            ["case", ["all", ["has", "model"], [">=", Self.length, length]], 0, 1]
        }
    }

    /// The model's opacity: the other half of the same handover.
    static func modelOpacityExpression() -> [Any] {
        handoverExpression(before: 0) { length in
            ["case", [">=", Self.length, length], 1, 0]
        }
    }

    /// A zoom ramp through `handover`: `before` until the first model zoom,
    /// then at each stop the value for that length, faded in over the half
    /// zoom before it. Stops are kept strictly increasing, as Mapbox requires.
    private static func handoverExpression(before: Any, at value: (Double) -> [Any]) -> [Any] {
        var expression: [Any] = ["interpolate", ["linear"], ["zoom"], firstModelZoom, before]
        var lastZoom = firstModelZoom
        var previous = before
        for stop in handover {
            let fadeStart = stop.zoom - 0.5
            if fadeStart > lastZoom {
                expression.append(fadeStart)
                expression.append(previous)
            }
            let now = value(stop.length)
            expression.append(stop.zoom)
            expression.append(now)
            previous = now
            lastZoom = stop.zoom
        }
        return expression
    }

    /// The share of its height an aeroplane is lifted by, per zoom.
    ///
    /// Models only appear from zoom 15, where an aeroplane is real size, so
    /// the lift is kept to a few of its own lengths: enough to show it is in
    /// the air and climbing or descending, never so much that it parts from
    /// its own track. A cruising airliner sits about 65 m up at zoom 15 and
    /// 9 m at zoom 18.
    private static let lift: [(zoom: Double, share: Double, key: String)] = [
        (15, 0.006, "mt15"),
        (16.5, 0.0025, "mt16"),
        (18, 0.0008, "mt18"),
    ]

    static func liftExpression() -> [Any] {
        var expression: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for stop in lift {
            expression.append(stop.zoom)
            expression.append(["get", stop.key])
        }
        return expression
    }

    /// The per-aircraft half of the above, written into its feature.
    static func properties(
        heading: Double,
        pitch: Double,
        bank: Double,
        heightMetres: Double
    ) -> [String: [Double]] {
        var out: [String: [Double]] = ["mrot": [-pitch, bank, heading]]
        for stop in lift {
            out[stop.key] = [0, 0, max(heightMetres, 0) * stop.share]
        }
        return out
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
    }

    func bank(at now: CFTimeInterval) -> Double { easedBank.value(at: now) }
    func pitch(at now: CFTimeInterval) -> Double { easedPitch.value(at: now) }

    /// Height above the field, in metres, as well as the feed allows.
    func heightMetres(of flight: Flight) -> Double {
        guard FlightPhase.from(flight) != .ground else { return 0 }
        return max(flight.altitudeFeet - (groundAltitudeFeet ?? 0), 0) * 0.3048
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
