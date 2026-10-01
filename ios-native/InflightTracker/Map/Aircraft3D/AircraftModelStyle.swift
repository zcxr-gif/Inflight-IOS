import Foundation

/// How a 3D aircraft sits on the map: how big, how high, and which way up.
///
/// ## Size
///
/// One size on screen, at every zoom: an A320 is `screenLength` points long
/// whether the map shows a continent or a gate, and every other aeroplane is
/// in proportion to it — an A380 twice as long, a regional jet two thirds.
/// Models are stored in metres (see `GLBNormaliser`) and scaled by a factor
/// that halves with every zoom in, exactly as the map doubles.
///
/// That factor is worked out here and written into each aeroplane's feature
/// (`msc`), never left to a zoom expression. Mapbox does not support a
/// zoom-dependent `model-scale` on a GeoJSON source: it bakes the value in
/// when it lays a tile out, so the models grew with the map through a pinch
/// and snapped back whenever a tile was rebuilt. The map rewrites the factor
/// as the zoom moves — see `TrackerMapView`'s `refreshModelView`.
///
/// The factor also carries the two things that would otherwise change an
/// aeroplane's size on screen without the zoom moving at all:
///
/// - Latitude. A model is drawn in real metres where it is, and Mercator
///   draws a metre bigger the further it is from the equator — twice as big
///   at 60°. The factor shrinks by the same cosine.
/// - Height. An aeroplane lifted towards the camera is drawn bigger, by
///   perspective. The factor shrinks by exactly that much, so a cruising
///   airliner is the same size as one on the stand.
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
/// be above it. So the height is capped at `cameraShare` of the camera's own
/// height at each zoom (`liftZooms`): from a country's width out nothing is
/// capped, and over an airport only an aeroplane well above it is. Like the
/// scale, the height is worked out for the zoom here and written into the
/// feature (`mt`).
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

    /// Mapbox's camera is this many view heights from the middle of the map:
    /// half the height over the tangent of half its 36.87° field of view.
    private static let cameraDistanceInViewHeights = 1.5

    /// What the camera is doing, as far as the size of a model on screen
    /// goes. Every model on the map is written for one of these.
    struct View: Equatable {
        var zoom: Double
        /// Degrees from looking straight down.
        var pitch: Double
        /// The map's height on screen, in points.
        var height: Double

        /// Whether models written for `other` would be drawn a visibly
        /// different size from ones written for this — a quarter of a
        /// percent of zoom, or a quarter of a degree of tilt.
        func differs(from other: View) -> Bool {
            abs(zoom - other.zoom) > 0.004 || abs(pitch - other.pitch) > 0.25 || abs(height - other.height) > 0.5
        }
    }

    /// Metres to a point at a zoom, where the map is at `latitude`.
    private static func metresPerPoint(atZoom zoom: Double, latitude: Double) -> Double {
        metresPerPointAtZoomZero * max(cos(latitude * .pi / 180), 0.01) / pow(2, zoom)
    }

    /// The factor a model is scaled by: `screenLength` for an A320 at every
    /// zoom and every latitude, made smaller by as much as being `lift`
    /// metres nearer the camera makes it bigger.
    static func magnification(latitude: Double, lift: Double, in view: View) -> Double {
        let perPoint = metresPerPoint(atZoom: view.zoom, latitude: latitude)
        let factor = screenLength * perPoint / referenceLength
        let cameraDistance = cameraDistanceInViewHeights * max(view.height, 1) * perPoint
        let nearer = lift * cos(view.pitch * .pi / 180)
        return factor * min(max(1 - nearer / cameraDistance, 0.3), 1)
    }

    /// The scale, as each aeroplane's feature carries it. Deliberately not a
    /// function of the zoom — see the type's notes on size.
    static func scaleExpression() -> [Any] {
        ["get", "msc"]
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

    /// The zooms the height cap is set at, each with the most it may be
    /// there: `cameraShare` of the camera's height above the map, which is
    /// about 1,275 points' worth of map at any zoom. Blended between.
    private static let liftZooms: [Double] = [6, 9, 11, 13, 15, 17]
    private static let cameraShare = 0.13
    private static let cameraHeightPoints = 1_275.0

    private static func liftCeiling(atZoom zoom: Double) -> Double {
        cameraShare * cameraHeightPoints * metresPerPointAtZoomZero / pow(2, zoom)
    }

    /// The height, as each aeroplane's feature carries it — like the scale,
    /// not a function of the zoom.
    static func liftExpression() -> [Any] {
        ["get", "mt"]
    }

    /// The height an aeroplane is drawn at, at a zoom — what is written into
    /// its feature, and what the flown path is drawn to meet (see
    /// `FlownPathProfile`).
    static func drawnLift(heightMetres: Double, atZoom zoom: Double) -> Double {
        let height = max(heightMetres, 0)
        func at(_ index: Int) -> Double { min(height, liftCeiling(atZoom: liftZooms[index])) }
        guard zoom > liftZooms[0] else { return at(0) }
        for index in 1..<liftZooms.count where zoom <= liftZooms[index] {
            let low = liftZooms[index - 1]
            let share = (zoom - low) / (liftZooms[index] - low)
            return at(index - 1) + (at(index) - at(index - 1)) * share
        }
        return at(liftZooms.count - 1)
    }

    /// The per-aircraft half of the above, written into its feature.
    static func properties(
        heading: Double,
        pitch: Double,
        bank: Double,
        heightMetres: Double,
        latitude: Double,
        in view: View
    ) -> [String: [Double]] {
        let lift = drawnLift(heightMetres: heightMetres, atZoom: view.zoom)
        let scale = magnification(latitude: latitude, lift: lift, in: view)
        return [
            "mrot": [-pitch, bank, heading],
            "mt": [0, 0, lift],
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
