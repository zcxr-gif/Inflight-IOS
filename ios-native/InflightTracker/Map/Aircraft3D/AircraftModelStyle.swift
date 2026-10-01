import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// Every model is stored at its real size, in metres (see `GLBNormaliser`), and
/// every aeroplane on the map is scaled by the *same* factor at a given zoom —
/// so an A380 is always twice an A320 and a Cessna a fifth of one, however far
/// out the map is. Pulled back, that factor holds a typical airliner at about
/// the size of the flat icon; closing in, it falls away to one and stays there,
/// so from about zoom 16 every aeroplane is exactly its real size on the map.
///
/// The factor is written as a stop every quarter zoom so it shrinks exactly as
/// fast as the map grows, which is what keeps an aeroplane's size on screen
/// steady through a pinch rather than swelling between stops.
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

    /// How long a typical airliner is on screen, in points, when the map is
    /// too far out for its real size to be seen. Everything else is drawn in
    /// proportion to it.
    static let screenLength = 30.0

    /// The airliner that `screenLength` is measured on: an A320 or a 737.
    private static let referenceLength = 40.0

    /// Metres to a point at zoom zero, on Mapbox's 512-point world.
    private static let metresPerPointAtZoomZero = 40_075_016.686 / 512

    /// The factor every model is scaled by at a zoom: real size, or larger
    /// when real size would be too small to see.
    static func magnification(atZoom zoom: Double) -> Double {
        max(1, screenLength * metresPerPointAtZoomZero / pow(2, zoom) / referenceLength)
    }

    static func scaleExpression() -> [Any] {
        var expression: [Any] = ["interpolate", ["linear"], ["zoom"]]
        var zoom = 0.0
        while true {
            let factor = magnification(atZoom: zoom)
            expression.append(zoom)
            expression.append(["literal", [factor, factor, factor]] as [Any])
            // One stop past the point where real size takes over, and done.
            if factor == 1 { break }
            zoom += 0.25
        }
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
