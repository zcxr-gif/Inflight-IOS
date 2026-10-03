import CoreLocation
import simd

/// Everything the engine draws around the models: the sun on them, their
/// lights, their shadows and their contrails.
///
/// ## The sun
///
/// Each aeroplane is lit by the real sun where it is, at this moment —
/// `SolarPosition`, turned into a direction in its own east, north and up —
/// so an aeroplane over the Pacific at dawn is lit low from the east while one
/// over Europe at noon is lit from high in the south, and one at night is dark
/// but for the dim light of the night. How much daylight there is eases in
/// and out through twilight rather than switching (`daylight`).
///
/// ## Lights
///
/// As an airliner wears them: red on the left wingtip, green on the right,
/// white at the tail, a red beacon on top flashing once a second, white
/// strobes double-flashing on both wingtips, and landing lights at the nose
/// below 3,000 m. Each sits where that part of the model is — found from the
/// model's own geometry (`AircraftAnchors`) and carried through the same
/// matrices that draw it, so they stay on the wingtips however the aeroplane
/// banks and however large it is drawn. Brightest at night; in daylight only
/// the strobes are much use, as on the real thing. Each aeroplane flashes on
/// its own phase, so a crowded sky does not blink in unison.
///
/// ## Shadows
///
/// A soft, cross-shaped shadow — fuselage and wings — on the ground under each
/// aeroplane, cast away from the sun and stretched as the sun gets low. Dark
/// and sharp on the ground, fainter, larger and softer the higher it flies,
/// gone above a few kilometres and at night. The best single cue there is to
/// how high something is.
///
/// ## Contrails
///
/// Behind every aeroplane above 26,000 ft: a white trail from its tail, a
/// moment behind it, spreading and fading over 45 seconds. Kept as a short
/// history of where each aeroplane has been (`AircraftEngine.TrailPoint`).
enum AircraftEffects {

    // MARK: - The sun

    struct Sunlight {
        /// Towards the sun, in east, north and up.
        var direction: SIMD3<Double>
        /// 1 in full day, 0 at night, eased through twilight.
        var daylight: Double

        var shaderValue: SIMD4<Float> {
            SIMD4<Float>(SIMD3<Float>(direction), Float(daylight))
        }
    }

    /// The sun at a place, for a sun already worked out for this frame.
    static func sunlight(at coordinate: CLLocationCoordinate2D, sun: SolarPosition.Sun) -> Sunlight {
        let degrees = Double.pi / 180
        let latitude = coordinate.latitude * degrees
        let hourAngle = (coordinate.longitude - sun.subsolarLongitude) * degrees
        let east = -cos(sun.declination) * sin(hourAngle)
        let north = cos(latitude) * sin(sun.declination) - sin(latitude) * cos(sun.declination) * cos(hourAngle)
        let up = sin(latitude) * sin(sun.declination) + cos(latitude) * cos(sun.declination) * cos(hourAngle)
        let elevation = asin(min(max(up, -1), 1)) / degrees
        // From 8° below the horizon to 4° above it.
        let t = min(max((elevation + 8) / 12, 0), 1)
        return Sunlight(direction: SIMD3<Double>(east, north, up), daylight: t * t * (3 - 2 * t))
    }

    // MARK: - Lights

    private static let red = SIMD3<Float>(1.0, 0.16, 0.10)
    private static let green = SIMD3<Float>(0.15, 1.0, 0.35)
    private static let white = SIMD3<Float>(1.0, 1.0, 1.0)
    private static let landing = SIMD3<Float>(1.0, 0.94, 0.78)

    /// Lights only on aeroplanes drawn at least this long on screen, in
    /// points: on a speck they are noise.
    static let lightsFromPoints = 12.0

    static func lights(
        for plane: AircraftEngine.Aircraft,
        on placement: AircraftFrame.Placement,
        anchors: AircraftAnchors,
        sunlight: Sunlight,
        time: Double,
        frame: AircraftFrame,
        into batch: inout GlowBatch
    ) {
        guard placement.screenLength >= lightsFromPoints else { return }
        let night = Float(1 - sunlight.daylight)
        let size = placement.screenLength

        // Steady lights: strong at night, faint by day.
        let steady = 0.25 + 0.75 * night
        let navigation = min(max(size * 0.05, 3), 9)
        batch.sprite(frame.clip(SIMD3<Double>(anchors.leftTip), on: placement), radius: navigation,
                     colour: SIMD4<Float>(red, steady), frame: frame)
        batch.sprite(frame.clip(SIMD3<Double>(anchors.rightTip), on: placement), radius: navigation,
                     colour: SIMD4<Float>(green, steady), frame: frame)
        batch.sprite(frame.clip(SIMD3<Double>(anchors.tail), on: placement), radius: navigation * 0.8,
                     colour: SIMD4<Float>(white, steady * 0.8), frame: frame)

        // Each aeroplane on its own phase.
        let phase = Double(UInt(bitPattern: plane.id.hashValue) % 997) / 997

        // Beacon: one red flash a second.
        let beaconTime = (time / 1.1 + phase).truncatingRemainder(dividingBy: 1)
        if beaconTime < 0.12 {
            batch.sprite(frame.clip(SIMD3<Double>(anchors.top), on: placement),
                         radius: min(max(size * 0.07, 4), 13),
                         colour: SIMD4<Float>(red, 0.55 + 0.45 * night), frame: frame)
        }

        // Strobes: a double flash on both wingtips, bright day or night.
        let strobeTime = (time / 1.3 + phase * 0.73).truncatingRemainder(dividingBy: 1) * 1.3
        if strobeTime < 0.05 || (strobeTime > 0.13 && strobeTime < 0.18) {
            let radius = min(max(size * 0.11, 6), 22)
            let colour = SIMD4<Float>(white, 0.75 + 0.25 * night)
            batch.sprite(frame.clip(SIMD3<Double>(anchors.leftTip), on: placement), radius: radius, colour: colour, frame: frame)
            batch.sprite(frame.clip(SIMD3<Double>(anchors.rightTip), on: placement), radius: radius, colour: colour, frame: frame)
        }

        // Landing lights, low down — and on the ground, as taxi lights.
        if plane.heightMetres < 3_000, night > 0.05 {
            let low = Float(1 - plane.heightMetres / 3_000)
            batch.sprite(frame.clip(SIMD3<Double>(anchors.nose), on: placement),
                         radius: min(max(size * 0.13, 6), 26),
                         colour: SIMD4<Float>(landing, night * (0.35 + 0.65 * low)), frame: frame)
        }
    }

    // MARK: - Shadows

    /// No shadow above this height, in metres.
    private static let shadowCeiling = 4_000.0

    static func shadow(
        for plane: AircraftEngine.Aircraft,
        on placement: AircraftFrame.Placement,
        anchors: AircraftAnchors,
        sunlight: Sunlight,
        ground: Double,
        frame: AircraftFrame,
        into batch: inout GlowBatch
    ) {
        let height = max(plane.heightMetres, 0)
        guard sunlight.daylight > 0.05, height < shadowCeiling else { return }
        let strength = Float(sunlight.daylight * exp(-height / 1_200) * (1 - height / shadowCeiling))
        guard strength > 0.01 else { return }

        let magnification = placement.magnification
        let length = Double(anchors.length) * magnification
        let span = Double(anchors.span) * magnification
        // Softer and larger the further it falls.
        let spread = 1 + height / 900

        // Away from the sun, by as far as the sun is low — within reason.
        var centre = SIMD2<Double>(0, 0)
        let sun = sunlight.direction
        if sun.z > 0.05 {
            centre = -SIMD2<Double>(sun.x, sun.y) / sun.z * height
            let reach = max(length * 3, 600)
            let distance = simd_length(centre)
            if distance > reach { centre *= reach / distance }
        }

        let heading = plane.heading * .pi / 180
        let forward = SIMD2<Double>(sin(heading), cos(heading))
        let right = SIMD2<Double>(cos(heading), -sin(heading))

        // Fuselage and wings, as two soft ellipses.
        let pieces: [(along: Double, across: Double)] = [
            (length * 0.55 * spread, length * 0.09 * spread),
            (length * 0.13 * spread, span * 0.52 * spread),
        ]
        let colour = SIMD4<Float>(0, 0, 0, 0.42 * strength)
        for piece in pieces {
            let a = forward * piece.along
            let b = right * piece.across
            let corners = [centre - a - b, centre + a - b, centre + a + b, centre - a + b].map {
                SIMD3<Double>($0.x, $0.y, 0)
            }
            let clips = frame.clip(plane.coordinate, altitude: ground + 0.5, offsets: corners)
            batch.quad(clips, colour: colour)
        }
    }

    // MARK: - Contrails

    /// Contrails above this altitude above the sea, in metres: 26,000 ft.
    static let contrailFloor = 7_925.0

    /// How long a contrail lasts, in seconds.
    static let contrailLife = 45.0

    static func contrail(
        _ history: [AircraftEngine.TrailPoint],
        for plane: AircraftEngine.Aircraft,
        on placement: AircraftFrame.Placement,
        anchors: AircraftAnchors,
        sunlight: Sunlight,
        now: Double,
        frame: AircraftFrame,
        into mesh: inout AircraftPathMesh
    ) {
        guard history.count >= 1 else { return }
        let size = frame.screenSize
        guard size.x > 0, size.y > 0 else { return }

        // From the tail as drawn, back through where it has been.
        var clips: [SIMD4<Double>] = [frame.clip(SIMD3<Double>(anchors.tail), on: placement)]
        var ages: [Double] = [0]
        for point in history.reversed() {
            let altitude = frame.altitude(ground: 0, height: point.heightMetres, sea: point.seaAltitudeMetres)
            clips.append(frame.clip(point.coordinate, altitude: altitude))
            ages.append(now - point.time)
        }
        guard clips.count >= 2 else { return }

        let base = min(max(placement.screenLength * 0.06, 1.0), 3.5)
        let light = Float(0.35 + 0.65 * sunlight.daylight)
        let screens = clips.map { frame.screen($0) }

        var corners: [(UInt32, UInt32)?] = []
        for i in clips.indices {
            guard let here = screens[i] else { corners.append(nil); continue }
            var direction = SIMD2<Double>(0, 0)
            if i + 1 < screens.count, let next = screens[i + 1] { direction += next - here }
            if i > 0, let previous = screens[i - 1] { direction += here - previous }
            let length = simd_length(direction)
            guard length > 1e-6 else { corners.append(nil); continue }
            let normal = SIMD2<Double>(-direction.y, direction.x) / length

            let age = ages[i]
            let life = max(1 - age / contrailLife, 0)
            let alpha = Float(0.5 * pow(life, 1.5) * min(age / 1.2, 1)) * light
            let width = base * (1 + age / 15)
            let colour = SIMD4<Float>(0.96, 0.97, 1.0, alpha)

            let clip = clips[i]
            func pushed(_ by: Double) -> SIMD4<Float> {
                let ndc = SIMD2<Double>(2 * normal.x * by / size.x, -2 * normal.y * by / size.y)
                return SIMD4<Float>(SIMD4<Double>(clip.x + ndc.x * clip.w, clip.y + ndc.y * clip.w, clip.z, clip.w))
            }
            let first = UInt32(mesh.vertices.count)
            mesh.vertices.append(.init(position: pushed(width / 2), colour: colour))
            mesh.vertices.append(.init(position: pushed(-width / 2), colour: colour))
            corners.append((first, first + 1))
        }
        for i in 0..<(corners.count - 1) {
            guard let a = corners[i], let b = corners[i + 1] else { continue }
            mesh.line.append(contentsOf: [a.0, a.1, b.0, a.1, b.1, b.0])
        }
    }
}

// MARK: - Where things are on a model

/// The points on a model its lights hang from, found from its own geometry:
/// the outermost point of each wing, the aftmost and foremost points, and
/// the top of the fuselage over the middle.
struct AircraftAnchors {

    var leftTip: SIMD3<Float>
    var rightTip: SIMD3<Float>
    var tail: SIMD3<Float>
    var nose: SIMD3<Float>
    var top: SIMD3<Float>
    var span: Float
    var length: Float

    init(_ data: AircraftMeshData) {
        var left = SIMD3<Float>(repeating: 0)
        var right = SIMD3<Float>(repeating: 0)
        var aft = SIMD3<Float>(repeating: 0)
        var fore = SIMD3<Float>(repeating: 0)
        var first = true
        for part in data.parts {
            for p in part.positions {
                if first {
                    left = p; right = p; aft = p; fore = p
                    first = false
                    continue
                }
                if p.x < left.x { left = p }
                if p.x > right.x { right = p }
                if p.z > aft.z { aft = p }
                if p.z < fore.z { fore = p }
            }
        }
        let span = max(right.x - left.x, 1)
        let middle = (aft.z + fore.z) / 2
        let length = max(aft.z - fore.z, 1)

        // The roof over the middle of the fuselage, where the beacon is.
        var roof: Float = 0
        for part in data.parts {
            for p in part.positions where abs(p.x) < span * 0.06 && abs(p.z - middle) < length * 0.1 {
                roof = max(roof, p.y)
            }
        }

        leftTip = left
        rightTip = right
        tail = aft
        nose = SIMD3<Float>(0, fore.y, fore.z)
        top = SIMD3<Float>(0, roof > 0 ? roof : length * 0.08, middle)
        self.span = span
        self.length = data.lengthMetres
    }
}

// MARK: - Glows

/// Lights and shadows for one frame, as soft quads.
struct GlowBatch {

    var vertices: [AircraftShaders.GlowVertex] = []

    /// A round glow `radius` points across on screen, at a point in clip
    /// space.
    mutating func sprite(_ clip: SIMD4<Double>, radius: Double, colour: SIMD4<Float>, frame: AircraftFrame) {
        guard clip.w > 1e-9, colour.w > 0.005 else { return }
        let size = frame.screenSize
        guard size.x > 0, size.y > 0 else { return }
        let dx = 2 * radius / size.x * clip.w
        let dy = 2 * radius / size.y * clip.w
        let corners: [SIMD2<Double>] = [[-1, -1], [1, -1], [1, 1], [-1, -1], [1, 1], [-1, 1]]
        for c in corners {
            vertices.append(.init(
                position: SIMD4<Float>(SIMD4<Double>(clip.x + c.x * dx, clip.y + c.y * dy, clip.z, clip.w)),
                colour: colour,
                corner: SIMD4<Float>(Float(c.x), Float(c.y), 0, 0)
            ))
        }
    }

    /// A soft quad whose four corners are already in clip space, in order
    /// round it.
    mutating func quad(_ clips: [SIMD4<Double>], colour: SIMD4<Float>) {
        guard clips.count == 4, clips.allSatisfy({ $0.w > 1e-9 }) else { return }
        let corners: [SIMD2<Float>] = [[-1, -1], [1, -1], [1, 1], [-1, 1]]
        for index in [0, 1, 2, 0, 2, 3] {
            vertices.append(.init(
                position: SIMD4<Float>(clips[index]),
                colour: colour,
                corner: SIMD4<Float>(corners[index].x, corners[index].y, 0, 0)
            ))
        }
    }
}
