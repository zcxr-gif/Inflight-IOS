import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// One size on screen, at every zoom: an A320 is `screenLength` points long
/// whether the map shows a continent or a gate, and every other aeroplane is
/// in proportion to it — an A380 twice as long, a regional jet two thirds.
/// Models are stored in metres (see `GLBNormaliser`) and scaled by a factor
/// that halves with every zoom in, exactly as the map doubles, which Mapbox's
/// exponential interpolation with base one half reproduces exactly between
/// just two stops — so a pinch never makes an aeroplane change size.
///
/// Light aircraft are drawn from their copy made 16 m long
/// (`GLBNormaliser.Detail.far`): in true proportion to an airliner a Cessna is
/// four points long, and an aeroplane nobody can see is not on the map.
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
/// be above it — and anything well up towards the camera is drawn bigger, by
/// perspective, which would undo the set size. So the height is capped at
/// `cameraShare` of the camera's own height at each zoom (`liftZooms`): no
/// aeroplane looks more than about 15% larger for being high, from a
/// country's width out nothing is capped, and over an airport only an
/// aeroplane well above it is.
///
/// ## Attitude
///
/// Mapbox turns a model by `[x, y, z]` degrees: heading about the vertical,
/// then pitch about the wings, then roll about the fuselage — checked in
/// Mapbox's renderer before it was written here. Nose up is a *negative* x;
/// right wing down is a positive y.
enum AircraftModelStyle {

    /// How long an A320 is on screen, in points, at every zoom. About the
    /// length of its flat icon.
    static let screenLength = 19.0

    /// The airliner `screenLength` is measured on.
    private static let referenceLength = 38.0

    /// Metres to a point at zoom zero, on Mapbox's 512-point world.
    private static let metresPerPointAtZoomZero = 40_075_016.686 / 512

    /// The factor every model is scaled by at a zoom.
    static func magnification(atZoom zoom: Double) -> Double {
        screenLength * metresPerPointAtZoomZero / pow(2, zoom) / referenceLength
    }

    /// The factor as a zoom ramp. Exponential with base one half between
    /// two stops is exactly `factor(0) / 2^zoom` at every zoom in between,
    /// which is what holds the size on screen still.
    static func scaleExpression() -> [Any] {
        let near = magnification(atZoom: 0)
        let far = magnification(atZoom: 24)
        return [
            "interpolate", ["exponential", 0.5], ["zoom"],
            0, ["literal", [near, near, near]] as [Any],
            24, ["literal", [far, far, far]] as [Any],
        ]
    }

    /// Which model each aeroplane is drawn from: `modelFar`, which is the
    /// light aircraft's 16 m copy and the model itself for everything else.
    static func modelIdExpression() -> [Any] {
        ["to-string", ["get", "modelFar"]]
    }

    /// The flat icon: drawn only for an aeroplane with no model yet.
    static func iconOpacityExpression() -> [Any] {
        ["case", ["has", "model"], 0, 1]
    }

    /// The zooms the height is written for, each with the most it may be
    /// there: `cameraShare` of the camera's height above the map, which is
    /// about 1,275 points' worth of map at any zoom. Mapbox blends between.
    private static let liftZooms: [Double] = [6, 9, 11, 13, 15, 17]
    private static let cameraShare = 0.13
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
