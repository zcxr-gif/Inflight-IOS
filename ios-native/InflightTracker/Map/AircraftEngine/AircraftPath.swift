import CoreLocation
import simd

/// The open aircraft's flown path, as the engine draws it: in the air, at the
/// heights it was flown at, ending on the aeroplane.
///
/// ## What it looks like
///
/// - **The line.** A ribbon a few points wide on screen whatever the zoom,
///   in the colour of the height each stretch was flown at, over a darker
///   halo so it reads against cloud, sea and city alike.
/// - **The curtain.** A translucent wall hanging from the line to the
///   ground, in the line's colour and fading to nothing at the bottom. It is
///   what makes a line in the air read as *in the air* from every angle —
///   how high, and over what — and it is what a line on its own cannot say
///   once the map is tilted.
/// - **On the aeroplane.** The last stretch is extended to the aeroplane on
///   every frame, to the middle of the model as it is drawn on that frame —
///   so the path leaves the aeroplane itself, however large it is drawn.
///
/// The ground track under it is still Mapbox's flat line, drawn as its
/// shadow.
///
/// ## How
///
/// Every point is put through the frame's projection on the CPU, in double
/// precision, and the ribbon is widened in screen space: each corner is
/// pushed out at right angles to the line *as it is seen*, by half the width,
/// and taken back into clip space. So the width is the same in every world,
/// at every tilt, and the GPU only fills triangles.
struct AircraftPath {

    struct Run {
        var coordinates: [CLLocationCoordinate2D]
        /// Height above the ground at each coordinate, in metres.
        var heights: [Double]
        /// Altitude above the sea at each coordinate, in metres — what is
        /// drawn over real terrain. See `AircraftFrame.altitude`.
        var seaHeights: [Double]
        var colour: SIMD4<Float>
    }

    /// The aircraft it belongs to, whose drawn position it ends on.
    var aircraftId: String
    var runs: [Run]
}

/// The path turned into triangles for one frame.
struct AircraftPathMesh {

    var vertices: [AircraftShaders.PathVertex] = []
    var curtain: [UInt32] = []
    var halo: [UInt32] = []
    var line: [UInt32] = []

    var isEmpty: Bool { curtain.isEmpty && halo.isEmpty && line.isEmpty }

    /// Width of the line and of the halo under it, in points.
    static let lineWidth = 3.4
    static let haloWidth = 7.0

    /// How strong the curtain is where it hangs from the line.
    static let curtainOpacity: Float = 0.24

    /// Where the path ends: the aeroplane, at the height of the middle of its
    /// model as drawn.
    struct Head {
        var coordinate: CLLocationCoordinate2D
        var altitude: Double
        var ground: Double
    }

    init() {}

    init(_ path: AircraftPath, head: Head?, frame: AircraftFrame, halo haloColour: SIMD4<Float>) {
        for (index, run) in path.runs.enumerated() {
            var points: [(coordinate: CLLocationCoordinate2D, altitude: Double, ground: Double)] = []
            points.reserveCapacity(run.coordinates.count + 1)
            for (i, coordinate) in run.coordinates.enumerated() {
                let ground = frame.elevation(at: coordinate)
                let height = i < run.heights.count ? max(run.heights[i], 0) : 0
                let sea = i < run.seaHeights.count ? run.seaHeights[i] : ground + height
                points.append((coordinate, frame.altitude(ground: ground, height: height, sea: sea), ground))
            }
            if index == path.runs.count - 1, let head {
                points.append((head.coordinate, head.altitude, head.ground))
            }
            add(points, colour: run.colour, halo: haloColour, frame: frame)
        }
    }

    private mutating func add(
        _ points: [(coordinate: CLLocationCoordinate2D, altitude: Double, ground: Double)],
        colour: SIMD4<Float>,
        halo haloColour: SIMD4<Float>,
        frame: AircraftFrame
    ) {
        guard points.count >= 2 else { return }
        let size = frame.screenSize
        guard size.x > 0, size.y > 0 else { return }

        let tops = points.map { frame.clip($0.coordinate, altitude: $0.altitude) }
        let bottoms = points.map { frame.clip($0.coordinate, altitude: $0.ground) }
        let screens = tops.map { frame.screen($0) }

        // The direction of the line on screen at each point, from its
        // neighbours either side that are on screen.
        func direction(_ i: Int) -> SIMD2<Double>? {
            guard let here = screens[i] else { return nil }
            let before = i > 0 ? screens[i - 1] : nil
            let after = i + 1 < screens.count ? screens[i + 1] : nil
            var d = SIMD2<Double>(0, 0)
            if let after { d += after - here }
            if let before { d += here - before }
            let length = simd_length(d)
            return length > 1e-6 ? d / length : nil
        }

        // A clip-space point pushed sideways by `points` on screen.
        func widened(_ clip: SIMD4<Double>, normal: SIMD2<Double>, by points: Double) -> SIMD4<Float> {
            let ndc = SIMD2<Double>(2 * normal.x * points / size.x, -2 * normal.y * points / size.y)
            return SIMD4<Float>(SIMD4<Double>(clip.x + ndc.x * clip.w, clip.y + ndc.y * clip.w, clip.z, clip.w))
        }

        // Each point's pair of corners for the line and for the halo, or nil
        // where the point is behind the camera.
        var lineCorners: [(left: UInt32, right: UInt32)?] = []
        var haloCorners: [(left: UInt32, right: UInt32)?] = []
        var curtainCorners: [(top: UInt32, bottom: UInt32)?] = []
        lineCorners.reserveCapacity(points.count)

        let curtainTop = SIMD4<Float>(colour.x, colour.y, colour.z, colour.w * Self.curtainOpacity)
        let curtainBottom = SIMD4<Float>(colour.x, colour.y, colour.z, 0)

        for i in points.indices {
            guard let normalDirection = direction(i), tops[i].w > 1e-9 else {
                lineCorners.append(nil)
                haloCorners.append(nil)
                curtainCorners.append(nil)
                continue
            }
            let normal = SIMD2<Double>(-normalDirection.y, normalDirection.x)
            let top = tops[i]

            let base = UInt32(vertices.count)
            vertices.append(.init(position: widened(top, normal: normal, by: Self.haloWidth / 2), colour: haloColour))
            vertices.append(.init(position: widened(top, normal: normal, by: -Self.haloWidth / 2), colour: haloColour))
            vertices.append(.init(position: widened(top, normal: normal, by: Self.lineWidth / 2), colour: colour))
            vertices.append(.init(position: widened(top, normal: normal, by: -Self.lineWidth / 2), colour: colour))
            haloCorners.append((base, base + 1))
            lineCorners.append((base + 2, base + 3))

            if bottoms[i].w > 1e-9 {
                vertices.append(.init(position: SIMD4<Float>(top), colour: curtainTop))
                vertices.append(.init(position: SIMD4<Float>(bottoms[i]), colour: curtainBottom))
                curtainCorners.append((base + 4, base + 5))
            } else {
                curtainCorners.append(nil)
            }
        }

        for i in 0..<(points.count - 1) {
            if let a = lineCorners[i], let b = lineCorners[i + 1] {
                line.append(contentsOf: [a.left, a.right, b.left, a.right, b.right, b.left])
            }
            if let a = haloCorners[i], let b = haloCorners[i + 1] {
                halo.append(contentsOf: [a.left, a.right, b.left, a.right, b.right, b.left])
            }
            if let a = curtainCorners[i], let b = curtainCorners[i + 1] {
                curtain.append(contentsOf: [a.top, a.bottom, b.top, a.bottom, b.bottom, b.top])
            }
        }
    }
}
