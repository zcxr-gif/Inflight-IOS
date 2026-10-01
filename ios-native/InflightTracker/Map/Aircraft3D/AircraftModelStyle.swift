import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// Every model is stored one unit long (see `GLBNormaliser`), so its scale *is*
/// its length in metres. Pulled back, that is a few pixels, so the scale is
/// lifted to keep the aeroplane about the size of the flat icon it replaces;
/// in close it settles on the aeroplane's real length, so an A380 at the gate
/// is the size of an A380 at the gate.
///
/// ## Height
///
/// Drawn at its true height, an aeroplane at cruise would float kilometres off
/// its own track the moment the map tilts, and loom at the camera in close.
/// So the lift shrinks as the map closes in: the whole height when the map
/// shows a country, a few hundredths of it over an airport. An aircraft on the
/// ground sits on it.
///
/// ## Attitude
///
/// Mapbox turns a model by `[x, y, z]` degrees: heading about the vertical,
/// then pitch about the wings, then roll about the fuselage — checked in
/// Mapbox's renderer before it was written here. Nose up is a *negative* x;
/// right wing down is a positive y.
enum AircraftModelStyle {

    /// The aeroplane's length on screen, in points, when the map is too far
    /// out to show its real size. A little longer than the flat icon, which
    /// only has to be read from above.
    static let screenLength = 30.0

    /// Metres to a point at zoom zero, on Mapbox's 512-point world.
    private static let metresPerPointAtZoomZero = 40_075_016.686 / 512

    /// Below this zoom the scale is the screen size; from `trueSizeZoom` on it
    /// is the real one; Mapbox blends between.
    private static let lastScreenSizeZoom = 15
    private static let trueSizeZoom = 18.0

    static func scaleExpression() -> [Any] {
        var expression: [Any] = ["interpolate", ["exponential", 2], ["zoom"]]
        // Every whole zoom, because the size has to halve with each one and
        // Mapbox blends linearly between stops.
        for zoom in 0...lastScreenSizeZoom {
            let metres = screenLength * metresPerPointAtZoomZero / pow(2, Double(zoom))
            expression.append(Double(zoom))
            expression.append(["literal", [metres, metres, metres]] as [Any])
        }
        expression.append(trueSizeZoom)
        expression.append(["get", "mlen"])
        return expression
    }

    /// The share of its height an aeroplane is lifted by, per zoom.
    private static let lift: [(zoom: Double, share: Double, key: String)] = [
        (6, 1, "mt6"),
        (10, 0.35, "mt10"),
        (13, 0.06, "mt13"),
        (16, 0.008, "mt16"),
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
        lengthMetres: Double,
        heading: Double,
        pitch: Double,
        bank: Double,
        heightMetres: Double
    ) -> [String: [Double]] {
        var out: [String: [Double]] = [
            "mlen": [lengthMetres, lengthMetres, lengthMetres],
            "mrot": [-pitch, bank, heading],
        ]
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
