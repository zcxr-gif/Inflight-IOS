import CoreLocation
import UIKit
import simd
@_spi(Experimental) import MapboxMaps

/// One frame's camera, and where on it each aeroplane goes.
///
/// ## The two worlds
///
/// Mapbox hands a custom layer one projection and two ways into it:
///
/// - **The flat map.** x and y in world pixels — Web Mercator scaled to the
///   zoom — and z in metres, which the projection turns into pixels at the
///   latitude in the middle of the screen. Taken through the transition
///   matrix.
/// - **The globe.** Earth-centred coordinates on a sphere 8,192 units round,
///   taken through the globe's model matrix.
///
/// While the camera passes between the two, both are worked out and blended
/// by the transition phase, exactly as Mapbox blends its own layers; on the
/// flat map only the first is needed and on the whole globe only the second.
///
/// Everything is computed in double precision on the CPU, with the projection
/// folded in: a world-pixel coordinate at zoom 18 is a hundred million, and in
/// single precision an aeroplane would shimmer by metres. What reaches the GPU
/// is each aeroplane's own model-to-clip matrix, small numbers all.
///
/// ## An aeroplane's frame
///
/// The model is in metres with its nose along −Z, up along +Y and right wing
/// along +X (see `GLBNormaliser`). It is turned by its bank, then its pitch,
/// then its heading, into east, north and up, and those are laid on the map at
/// its position and height — on the ground's own elevation where the map has
/// terrain.
struct AircraftFrame {

    /// 0 on the flat map, 1 on the globe, between the two in between.
    let transition: Double

    private let mercatorToClip: simd_double4x4
    private let globeToClip: simd_double4x4
    private let zoom: Double
    private let zoomScale: Double
    private let centrePixelsPerMetre: Double
    private let width: Double
    private let height: Double
    private let terrainHeight: (CLLocationCoordinate2D) -> Double?

    /// Whether the map has real terrain under it on this frame.
    let hasTerrain: Bool

    init(_ parameters: CustomLayerRenderParameters) {
        let projection = Self.matrix(parameters.projectionMatrix)
        mercatorToClip = projection * Self.matrix(parameters.projection.getTransitionMatrix())
        globeToClip = projection * Self.matrix(parameters.projection.getModelMatrix())
        transition = min(max(Double(parameters.projection.getTransitionPhase()), 0), 1)
        zoom = Double(parameters.zoom)
        zoomScale = pow(2, zoom)
        let latitude = min(max(Double(parameters.latitude), -85), 85)
        centrePixelsPerMetre = 1 / Projection.metersPerPoint(for: latitude, zoom: CGFloat(zoom))
        width = Double(parameters.width)
        height = Double(parameters.height)
        let terrain = parameters.elevationData
        hasTerrain = terrain != nil
        terrainHeight = { coordinate in terrain?.getElevationFor(coordinate)?.doubleValue }
    }

    /// The ground's height above the sea under a point, where the map has
    /// terrain; zero where it has none.
    func elevation(at coordinate: CLLocationCoordinate2D) -> Double {
        let metres = terrainHeight(coordinate) ?? 0
        return metres.isFinite ? metres : 0
    }

    struct Placement {
        let instance: AircraftShaders.Instance
        /// Where the aeroplane is on screen, in points.
        let screenPoint: CGPoint
        /// How long it is drawn, in points.
        let screenLength: Double
        /// How many times its real size it is drawn.
        let magnification: Double
    }

    /// Where an aeroplane goes on this frame, how big, and which way up — or
    /// nil when it is behind the camera or well off the screen.
    func place(
        _ plane: AircraftEngine.Aircraft,
        groundMetres: Double,
        lengthMetres: Double
    ) -> Placement? {
        let latitude = min(max(plane.coordinate.latitude, -85), 85)
        let drawnAltitude = altitude(ground: groundMetres, height: plane.heightMetres, sea: plane.seaAltitudeMetres)
        let (mercator, globe) = frames(plane.coordinate, altitude: drawnAltitude)

        func clip(_ local: SIMD4<Double>) -> SIMD4<Double> {
            let flat = mercator * local
            guard transition > 0 else { return flat }
            return flat + (globe * local - flat) * transition
        }

        guard let centre = screen(clip(SIMD4<Double>(0, 0, 0, 1))) else { return nil }

        // How big a metre is on screen, here: measured along the ground both
        // ways, and the larger taken, so a view down the length of a tilted
        // map does not read one foreshortened direction as the scale.
        let probe = 100.0
        var pointsPerMetre = 0.0
        if let east = screen(clip(SIMD4<Double>(probe, 0, 0, 1))) {
            pointsPerMetre = max(pointsPerMetre, simd_distance(east, centre) / probe)
        }
        if let north = screen(clip(SIMD4<Double>(0, probe, 0, 1))) {
            pointsPerMetre = max(pointsPerMetre, simd_distance(north, centre) / probe)
        }
        guard pointsPerMetre.isFinite, pointsPerMetre > 0 else { return nil }

        let magnification = AircraftModelStyle.magnification(
            lengthMetres: lengthMetres,
            pointsPerMetre: pointsPerMetre,
            latitude: latitude,
            heightMetres: plane.heightMetres
        )
        let screenLength = lengthMetres * magnification * pointsPerMetre

        let margin = screenLength * 0.6 + 8
        guard centre.x > -margin, centre.x < width + margin,
              centre.y > -margin, centre.y < height + margin else { return nil }

        let rotation = Self.attitude(heading: plane.heading, pitch: plane.pitch, bank: plane.bank)
        let scaled = rotation * magnification
        let model = simd_double4x4(columns: (
            SIMD4<Double>(scaled.columns.0, 0),
            SIMD4<Double>(scaled.columns.1, 0),
            SIMD4<Double>(scaled.columns.2, 0),
            SIMD4<Double>(0, 0, 0, 1)
        ))

        let instance = AircraftShaders.Instance(
            mercator: Self.single(mercator * model),
            globe: Self.single(globe * model),
            rotation0: SIMD4<Float>(SIMD3<Float>(rotation.columns.0), 0),
            rotation1: SIMD4<Float>(SIMD3<Float>(rotation.columns.1), 0),
            rotation2: SIMD4<Float>(SIMD3<Float>(rotation.columns.2), 0),
            tint: plane.tint
        )
        return Placement(
            instance: instance,
            screenPoint: CGPoint(x: centre.x, y: centre.y),
            screenLength: screenLength,
            magnification: magnification
        )
    }

    // MARK: - Points

    /// East, north and up in metres at a point and height, to clip space
    /// through each world: the flat map's, and the globe's. Each is the other
    /// when only one world is on screen.
    private func frames(
        _ coordinate: CLLocationCoordinate2D,
        altitude: Double
    ) -> (mercator: simd_double4x4, globe: simd_double4x4) {
        let latitude = min(max(coordinate.latitude, -85), 85)
        let clamped = CLLocationCoordinate2D(latitude: latitude, longitude: coordinate.longitude)
        var mercator = matrix_identity_double4x4
        if transition < 1 {
            let pixelsPerMetre = 1 / Projection.metersPerPoint(for: latitude, zoom: CGFloat(zoom))
            let world = Projection.project(clamped, zoomScale: CGFloat(zoomScale))
            let upPerMetre = pixelsPerMetre / centrePixelsPerMetre
            let frame = simd_double4x4(columns: (
                SIMD4<Double>(pixelsPerMetre, 0, 0, 0),
                SIMD4<Double>(0, -pixelsPerMetre, 0, 0),
                SIMD4<Double>(0, 0, upPerMetre, 0),
                SIMD4<Double>(Double(world.x), Double(world.y), altitude * upPerMetre, 1)
            ))
            mercator = mercatorToClip * frame
        }
        var globe = mercator
        if transition > 0 {
            globe = globeToClip * Self.globeFrame(clamped, altitude: altitude)
            if transition >= 1 { mercator = globe }
        }
        return (mercator, globe)
    }

    /// A point at a height above the sea, in clip space.
    func clip(_ coordinate: CLLocationCoordinate2D, altitude: Double) -> SIMD4<Double> {
        let (mercator, globe) = frames(coordinate, altitude: altitude)
        let flat = mercator.columns.3
        guard transition > 0 else { return flat }
        return flat + (globe.columns.3 - flat) * transition
    }

    /// A clip-space point on screen, in points — or nil behind the camera.
    func screen(_ clip: SIMD4<Double>) -> SIMD2<Double>? {
        guard clip.w > 1e-9 else { return nil }
        return SIMD2<Double>(
            (clip.x / clip.w * 0.5 + 0.5) * width,
            (0.5 - clip.y / clip.w * 0.5) * height
        )
    }

    /// The altitude above the sea something is drawn at, from its height
    /// above the field it flew from and its altitude above the sea, over
    /// ground `ground` metres up.
    ///
    /// With no terrain the map is flat at sea level and the height is all
    /// there is. With terrain, height above a field added to the ground under
    /// each point would ride every ridge and valley a path crossed — and move
    /// as finer terrain loads — so in the air the true altitude is drawn,
    /// never below the ground. Close to the ground the height is added to the
    /// terrain under it instead, so a taxi and a take-off roll sit exactly on
    /// it, and the one gives way to the other between `hugBelow` and
    /// `trueAbove` metres up.
    func altitude(ground: Double, height: Double, sea: Double) -> Double {
        let height = max(height, 0)
        guard hasTerrain else { return ground + height }
        let hugging = ground + height
        let flown = max(sea, ground)
        let share = min(max((height - Self.hugBelow) / (Self.trueAbove - Self.hugBelow), 0), 1)
        return hugging + (flown - hugging) * share
    }

    private static let hugBelow = 30.0
    private static let trueAbove = 150.0

    /// The screen's size, in points.
    var screenSize: SIMD2<Double> { SIMD2<Double>(width, height) }

    // MARK: - Geometry

    /// Model directions to east, north and up: bank about the fuselage, then
    /// pitch about the wings, then heading about the vertical.
    static func attitude(heading: Double, pitch: Double, bank: Double) -> simd_double3x3 {
        let h = heading * .pi / 180
        let p = pitch * .pi / 180
        let b = bank * .pi / 180
        // Heading, clockwise from north seen from above.
        let yaw = simd_double3x3(rows: [
            SIMD3<Double>(cos(h), sin(h), 0),
            SIMD3<Double>(-sin(h), cos(h), 0),
            SIMD3<Double>(0, 0, 1),
        ])
        // The model's own axes laid on the map: right wing east, roof up,
        // nose (−Z) north.
        let base = simd_double3x3(rows: [
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, 0, -1),
            SIMD3<Double>(0, 1, 0),
        ])
        // Nose up for a positive pitch.
        let pitchUp = simd_double3x3(rows: [
            SIMD3<Double>(1, 0, 0),
            SIMD3<Double>(0, cos(p), -sin(p)),
            SIMD3<Double>(0, sin(p), cos(p)),
        ])
        // Right wing down for a positive bank.
        let roll = simd_double3x3(rows: [
            SIMD3<Double>(cos(b), sin(b), 0),
            SIMD3<Double>(-sin(b), cos(b), 0),
            SIMD3<Double>(0, 0, 1),
        ])
        return yaw * base * pitchUp * roll
    }

    /// East, north and up in metres to Mapbox's earth-centred globe
    /// coordinates, at a point and a height.
    private static func globeFrame(_ coordinate: CLLocationCoordinate2D, altitude: Double) -> simd_double4x4 {
        let units = 8_192.0
        let radius = units / (2 * .pi)
        let perMetre = units / 40_075_016.686
        let lat = coordinate.latitude * .pi / 180
        let lng = coordinate.longitude * .pi / 180

        let up = SIMD3<Double>(cos(lat) * sin(lng), -sin(lat), cos(lat) * cos(lng))
        let east = SIMD3<Double>(cos(lng), 0, -sin(lng))
        let north = SIMD3<Double>(-sin(lat) * sin(lng), -cos(lat), -sin(lat) * cos(lng))
        let position = up * (radius + altitude * perMetre)

        return simd_double4x4(columns: (
            SIMD4<Double>(east * perMetre, 0),
            SIMD4<Double>(north * perMetre, 0),
            SIMD4<Double>(up * perMetre, 0),
            SIMD4<Double>(position, 1)
        ))
    }

    private static func matrix(_ values: [NSNumber]) -> simd_double4x4 {
        guard values.count == 16 else { return matrix_identity_double4x4 }
        let v = values.map(\.doubleValue)
        return simd_double4x4(columns: (
            SIMD4<Double>(v[0], v[1], v[2], v[3]),
            SIMD4<Double>(v[4], v[5], v[6], v[7]),
            SIMD4<Double>(v[8], v[9], v[10], v[11]),
            SIMD4<Double>(v[12], v[13], v[14], v[15])
        ))
    }

    private static func single(_ m: simd_double4x4) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(m.columns.0),
            SIMD4<Float>(m.columns.1),
            SIMD4<Float>(m.columns.2),
            SIMD4<Float>(m.columns.3)
        ))
    }
}
