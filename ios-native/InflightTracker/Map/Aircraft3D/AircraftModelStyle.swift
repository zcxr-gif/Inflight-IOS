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
/// ## Every zoom, without the cost
///
/// Every aeroplane is a model at every zoom. What keeps that cheap is that a
/// zoomed-out map draws each one from its *far* model (`GLBNormaliser.Detail`):
/// the same aeroplane reduced to a few hundred triangles with small textures,
/// against tens of thousands up close. At twenty points long nobody can tell
/// the two apart. The detailed model takes over from zoom 15, where it starts
/// being drawn at real size.
///
/// Light aircraft keep the far model, which draws them longer than life, until
/// zoom 18: in true proportion to an airliner a Cessna is four points long,
/// and an aeroplane nobody can see is not on the map.
///
/// The flat icon is only drawn for an aeroplane whose model has not arrived.
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

    /// From this zoom the detailed model is drawn instead of the far one.
    static let detailZoom = 15.0

    /// And from this one, light aircraft too — anything shorter than
    /// `lightAircraftLength`.
    static let lightDetailZoom = 18.0
    static let lightAircraftLength = 14.0

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

    /// Which model each aeroplane is drawn from: far, then detailed from
    /// `detailZoom`, light aircraft from `lightDetailZoom`. `model` is only
    /// ever the detailed model once it has been put on the map, and is the
    /// far one until then — see `TrackerMapView`.
    static func modelIdExpression() -> [Any] {
        let near: [Any] = ["to-string", ["get", "model"]]
        let far: [Any] = ["to-string", ["get", "modelFar"]]
        let length: [Any] = ["to-number", ["get", "mlen"], 0]
        return [
            "step", ["zoom"],
            far,
            detailZoom, ["case", [">=", length, lightAircraftLength], near, far],
            lightDetailZoom, near,
        ]
    }

    /// The flat icon: drawn only for an aeroplane with no model yet.
    static func iconOpacityExpression() -> [Any] {
        ["case", ["has", "model"], 0, 1]
    }

    /// The share of its height an aeroplane is lifted by, per zoom.
    ///
    /// Kept to a few of the aeroplane's own lengths where it is drawn at real
    /// size: enough to show it is in the air, never so much that it parts
    /// from its own track. A cruising airliner sits about 65 m up at zoom 15
    /// and 9 m at zoom 18; further out, where the model is drawn larger than
    /// life, the same 65 m is too little to see and the model sits on its
    /// position.
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
