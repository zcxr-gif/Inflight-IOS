import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// Every model is stored in metres (see `GLBNormaliser`), and every aeroplane
/// on the map is scaled by the *same* factor at a given zoom — so an A380 is
/// always twice an A320 and a Cessna a fifth of one.
///
/// Pulled back, that factor holds an aeroplane at one size on screen however
/// the map is zoomed: an A320 about the size of its flat icon, everything else
/// in proportion. Closing in, real size eventually overtakes it — around zoom
/// 15.3 — and from there every aeroplane is exactly its real size, fixed to the
/// map like the runway under it. The factor has a stop every quarter zoom, so
/// a pinch never makes an aeroplane swell or shrink on screen before that.
///
/// ## Every zoom
///
/// Every aeroplane is its full model at every zoom. Light aircraft are drawn
/// from a copy made larger than life (`GLBNormaliser.Detail.far`) until zoom
/// 18: in true proportion to an airliner a Cessna is four points long, and an
/// aeroplane nobody can see is not on the map.
///
/// The flat icon is only drawn for an aeroplane whose model has not arrived.
///
/// ## Height
///
/// Real height above the ground, as near as the feed allows (see
/// `AircraftAttitude.heightMetres`) — carried between packets at the
/// aeroplane's own vertical speed, so a climb is a climb rather than a stair.
///
/// The one limit is the camera. Close in over a cruising airliner, the camera
/// is itself only a few kilometres up, and an aeroplane drawn at 11 km would
/// be above it, or filling the screen. So the height is capped at a share of
/// the camera's own height at each zoom (`liftZooms`): from a country's width
/// out nothing is capped, and over an airport only an aeroplane at cruise is.
///
/// ## Attitude
///
/// Mapbox turns a model by `[x, y, z]` degrees: heading about the vertical,
/// then pitch about the wings, then roll about the fuselage — checked in
/// Mapbox's renderer before it was written here. Nose up is a *negative* x;
/// right wing down is a positive y.
enum AircraftModelStyle {

    /// Light aircraft are drawn from their larger-than-life copy until this
    /// zoom (`GLBNormaliser.farMinimumLength` decides which those are).
    static let lightDetailZoom = 18.0

    /// How long an A320 is on screen, in points, until real size is larger.
    /// About the length of its flat icon.
    static let screenLength = 19.0

    /// The airliner `screenLength` is measured on.
    private static let referenceLength = 38.0

    /// Metres to a point at zoom zero, on Mapbox's 512-point world.
    private static let metresPerPointAtZoomZero = 40_075_016.686 / 512

    /// The factor every model is scaled by at a zoom: real size, or larger
    /// when real size would be smaller than `screenLength`.
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

    /// Which model each aeroplane is drawn from: `modelFar` until
    /// `lightDetailZoom`, then `model`. Only light aircraft have a separate
    /// far copy; for everything else the two name the same model.
    static func modelIdExpression() -> [Any] {
        [
            "step", ["zoom"],
            ["to-string", ["get", "modelFar"]],
            lightDetailZoom, ["to-string", ["get", "model"]],
        ]
    }

    /// The flat icon: drawn only for an aeroplane with no model yet.
    static func iconOpacityExpression() -> [Any] {
        ["case", ["has", "model"], 0, 1]
    }

    /// The zooms the height is written for, each with the most it may be
    /// there: `cameraShare` of the camera's height above the map, which is
    /// about 1,275 points' worth of map at any zoom. Mapbox blends between.
    private static let liftZooms: [Double] = [6, 9, 11, 13, 15, 17]
    private static let cameraShare = 0.3
    private static let cameraHeightPoints = 1_275.0

    private static func liftKey(_ zoom: Double) -> String { "mt\(Int(zoom))" }

    private static func liftCeiling(atZoom zoom: Double) -> Double {
        cameraShare * cameraHeightPoints * metresPerPointAtZoomZero / pow(2, zoom)
    }

    static func liftExpression() -> [Any] {
        var expression: [Any] = ["interpolate", ["linear"], ["zoom"]]
        for zoom in liftZooms {
            expression.append(zoom)
            expression.append(["get", liftKey(zoom)])
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
        let height = max(heightMetres, 0)
        for zoom in liftZooms {
            out[liftKey(zoom)] = [0, 0, min(height, liftCeiling(atZoom: zoom))]
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
