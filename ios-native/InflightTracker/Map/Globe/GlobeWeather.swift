import CoreGraphics
import CoreLocation
import Foundation
import MapKit
import UIKit
import simd

/// The weather layers, on the drawn planet.
///
/// ## Why this file exists at all
///
/// `MapProjection.planet` is not MapKit. It is a `CGContext` and an
/// orthographic projection, and for as long as it has existed the argument
/// against offering it as a projection at all was written down in `MapLook`:
/// "a renderer which is not MapKit cannot reach the map's weather tiles". So it
/// didn't, and switching to the planet quietly took the radar, the satellite,
/// the barbs, the coloured field and the moving air off the map — with every
/// one of those switches still on, and nothing on screen to say why. The globe
/// kept all of it, because the globe *is* MapKit; the planet, which is the one
/// people choose on purpose, lost the lot.
///
/// ## How a mercator tile gets onto a sphere
///
/// It doesn't, not by any transform. `MKTileOverlay` works because a flat map
/// and a tile are the same projection, so a tile is a rectangle you place. On
/// an orthographic sphere a tile is a curved quadrilateral whose curvature
/// changes across itself, and Core Graphics has no mesh primitive to draw that
/// with.
///
/// So the picture is built backwards. Every pixel of the output is unprojected
/// through `GlobeCamera.unproject` to the place on the planet it is looking at,
/// and whatever is there — a tile's pixel, or the wind field's value — is what
/// that pixel becomes. One square root and two inverse trigonometric functions
/// a pixel, at reduced resolution, off the main thread. It is a small software
/// raytracer and it is the only honest way to do this without a GPU.
///
/// Which is also why it is built on the settle rather than per frame: see
/// `GlobeWeatherRaster.scale` for what it costs.

// MARK: - What the planet is asked to draw

/// The wind the planet should draw, and everything it draws of it.
///
/// One value for all three layers, for exactly the reason `WindsAloftStore`
/// serves all three from one request: an arrow pointing one way with a particle
/// drifting the other beside it is the map arguing with itself, and it cannot
/// happen if there is only one set of numbers.
struct GlobeWind {

    /// The interpolable field the wash and the particles are drawn from.
    ///
    /// Optional, because barbs on their own ask the store for the sparse
    /// lattice and a sparse lattice carries no field — there is nothing between
    /// twenty points worth interpolating. Those draw the arrows and nothing
    /// else, which is exactly what they cost on the flat map too.
    let field: WeatherField?
    let barbs: [WindsAloftStore.Barb]

    /// Which of the three are actually switched on.
    let showsBarbs: Bool
    let showsParticles: Bool
    let product: WeatherHeat

    let level: WindLevel

    /// The identity of the grid and of what is being drawn from it.
    ///
    /// Compared instead of the numbers: a `WeatherField` is a few hundred
    /// doubles and an interpolable, and walking it for equality on every layout
    /// pass to discover it is the same grid as last time is a great deal of
    /// work for an answer the key already has.
    let key: String
}

extension GlobeWind: Equatable {
    static func == (lhs: GlobeWind, rhs: GlobeWind) -> Bool { lhs.key == rhs.key }
}

// MARK: - Mercator, backwards

/// Web mercator, as the two conversions the raster needs and nothing else.
enum GlobeMercator {

    /// The latitude the projection stops at. Past it the arithmetic runs away
    /// to infinity, and no tile service serves anything there anyway.
    static let limit: Double = 85.05112878

    /// Where a place falls in the unit square, y down from the north.
    static func normalised(latitude: Double, longitude: Double) -> (x: Double, y: Double)? {
        guard latitude.isFinite, longitude.isFinite else { return nil }
        guard abs(latitude) <= limit else { return nil }

        var lon = longitude
        while lon < -180 { lon += 360 }
        while lon > 180 { lon -= 360 }

        let x = (lon + 180) / 360
        // asinh(tan φ) is the same number as the log-of-tangent form and is one
        // call rather than three.
        let y = (1 - asinh(tan(latitude * .pi / 180)) / .pi) / 2
        return (x, y)
    }

    /// The zoom whose tiles are about the size the sphere is being drawn at.
    ///
    /// A tile is 256 pixels of a world `256 · 2^z` across, so the zoom that
    /// matches the planet is the one whose world is as wide as the sphere's own
    /// circumference in points. One below that, deliberately: the raster is
    /// built at reduced resolution and then smoothed up, so fetching the
    /// sharper level would be four times the tiles for detail the output cannot
    /// hold.
    static func zoom(forRadius radius: CGFloat, limit maximum: Int) -> Int {
        guard radius > 0 else { return 0 }
        let circumference = Double(radius) * 2 * .pi
        let raw = (log2(circumference / 256) - 1).rounded(.down)
        return max(0, min(maximum, Int(raw.isFinite ? raw : 0)))
    }
}

// MARK: - Tiles, decoded

/// One frame of tiles, decoded to pixels, ready to be read by coordinate.
///
/// Held as raw premultiplied RGBA rather than as `CGImage`s because the whole
/// point is to sample individual pixels: going through Core Graphics for that
/// would mean a draw call per pixel.
final class GlobeTileMosaic {

    /// The tiles that have landed, by their `x` and `y` at this zoom.
    ///
    /// Behind a lock of its own rather than the store's: tiles land on whatever
    /// queue the loader answers on and are read by the raster builder on
    /// another, and those two are never the same one.
    private var tiles: [Int: [UInt8]] = [:]
    private let lock = NSLock()

    let z: Int

    /// The identity of the frame these are of, so a mosaic for one frame of the
    /// radar is never read as another's.
    let key: String

    /// How wide the world is at this zoom, in pixels.
    private let worldPixels: Double

    private static let side = 256

    init(z: Int, key: String) {
        self.z = z
        self.key = key
        self.worldPixels = Double(Self.side) * pow(2, Double(z))
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return tiles.isEmpty
    }

    /// How many tiles are in it, for the caller deciding whether it is worth
    /// drawing yet.
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return tiles.count
    }

    /// The number of tiles across the world at this zoom.
    var span: Int { Int(pow(2, Double(z))) }

    private func slot(x: Int, y: Int) -> Int { y * span + x }

    func has(x: Int, y: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return tiles[slot(x: x, y: y)] != nil
    }

    func put(_ pixels: [UInt8], x: Int, y: Int) {
        lock.lock(); defer { lock.unlock() }
        tiles[slot(x: x, y: y)] = pixels
    }

    /// The pixel over a place, or nil where no tile for it has arrived.
    ///
    /// Nearest neighbour, and that is not a compromise: the output raster is
    /// built at about half resolution and drawn back up under Core Graphics'
    /// own smoothing, so a bilinear filter here would be a second blur under a
    /// blur. Radar is smoothed by the service before it is ever a tile.
    func sample(latitude: Double, longitude: Double) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8)? {
        guard let unit = GlobeMercator.normalised(latitude: latitude, longitude: longitude) else {
            return nil
        }

        let px = unit.x * worldPixels
        let py = unit.y * worldPixels

        var tileX = Int(px) / Self.side
        let tileY = Int(py) / Self.side
        // The world wraps in x and does not in y.
        let across = span
        tileX = ((tileX % across) + across) % across
        guard tileY >= 0, tileY < across else { return nil }

        lock.lock()
        let pixels = tiles[slot(x: tileX, y: tileY)]
        lock.unlock()
        guard let pixels = pixels else { return nil }

        let inX = min(Self.side - 1, max(0, Int(px) - tileX * Self.side))
        let inY = min(Self.side - 1, max(0, Int(py) - tileY * Self.side))
        let at = (inY * Self.side + inX) * 4
        guard at + 3 < pixels.count else { return nil }

        return (pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3])
    }

    /// Decodes one tile's bytes into the buffer this holds them in.
    ///
    /// Straight into premultiplied RGBA, which is what the output raster is and
    /// what Core Graphics wants to be handed — so the sample is a copy of four
    /// bytes and no arithmetic at all.
    static func decode(_ data: Data) -> [UInt8]? {
        guard let image = UIImage(data: data)?.cgImage else { return nil }

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: side,
                    height: side,
                    bitsPerComponent: 8,
                    bytesPerRow: side * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                  )
            else { return false }

            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }

        return ok ? pixels : nil
    }
}

// MARK: - Fetching them

/// Keeps the decoded tiles for whatever frame the planet is showing.
///
/// One frame at a time. The animation moves through frames and each is a whole
/// screen of tiles; holding several would be the memory of the entire loop for
/// a picture only one of them is ever in.
final class GlobeTileStore {

    static let shared = GlobeTileStore()

    private let lock = NSLock()
    private var mosaic: GlobeTileMosaic?
    private var asked = Set<Int>()

    /// Told whenever a tile lands, so the planet can redraw with more of the
    /// picture on it than it had.
    var onTile: (() -> Void)?

    private init() {}

    /// The mosaic for a frame, whatever has arrived of it so far.
    ///
    /// Asks for anything missing that the given region needs, and answers
    /// immediately with what is already decoded — the same shape as
    /// `AirportLayoutStore` and for the same reason: the canvas asks while it
    /// is laying out and cannot wait.
    func mosaic(
        for tiles: MapWeatherTiles,
        z: Int,
        needing wanted: [(x: Int, y: Int)]
    ) -> GlobeTileMosaic? {
        let key = "\(tiles.key)|\(z)"

        lock.lock()
        if mosaic?.key != key {
            mosaic = GlobeTileMosaic(z: z, key: key)
            asked.removeAll(keepingCapacity: true)
        }
        let held = mosaic
        lock.unlock()

        guard let held = held else { return nil }

        // The overlay is used purely as a URL builder and a cached loader here.
        // Its session, its tile cache and its reporting of a service that has
        // stopped serving are all things this would otherwise have to write
        // again — and write differently, which is how two layers of the same
        // app end up disagreeing about whether the radar is up.
        let loader = RainViewerTileOverlay(tiles: tiles)
        let across = held.span

        for tile in wanted {
            let x = ((tile.x % across) + across) % across
            guard tile.y >= 0, tile.y < across else { continue }

            let slot = tile.y * across + x

            lock.lock()
            let already = held.has(x: x, y: tile.y) || asked.contains(slot)
            if !already { asked.insert(slot) }
            lock.unlock()

            if already { continue }

            loader.loadTile(
                at: MKTileOverlayPath(x: x, y: tile.y, z: z, contentScaleFactor: 1)
            ) { [weak self] data, _ in
                guard let self = self else { return }
                guard let data = data, let pixels = GlobeTileMosaic.decode(data) else {
                    // Left out of `asked` so a later pass may try again — a
                    // refused tile is usually the service throttling rather
                    // than a tile that does not exist.
                    self.lock.lock()
                    self.asked.remove(slot)
                    self.lock.unlock()
                    return
                }

                self.lock.lock()
                let current = self.mosaic?.key == key ? self.mosaic : nil
                current?.put(pixels, x: x, y: tile.y)
                self.lock.unlock()

                guard current != nil else { return }
                DispatchQueue.main.async { self.onTile?() }
            }
        }

        return held
    }

    /// Forget everything. For the layer going off, so a frame nobody is looking
    /// at is not a screen of pixels the app is still holding.
    func clear() {
        lock.lock()
        mosaic = nil
        asked.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}

// MARK: - The picture

/// The newest raster asked for, readable from the queue that builds them.
///
/// The build queue is serial, so three requests made in quick succession — a
/// scrubber being dragged, a run of tiles landing — sit on it in order and,
/// without this, all three are built and two are thrown away. Each job checks
/// that it is still the one wanted *before* it starts, which turns a backlog
/// into one build of the newest state.
final class GlobeRasterToken {

    private let lock = NSLock()
    private var value = 0

    /// Claims the next job, invalidating every one before it.
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value &+= 1
        return value
    }

    var current: Int {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}

/// What a raster is a picture *of*.
enum GlobeWeatherSource {

    /// The coloured wash, read out of the wind field.
    case heat(WeatherField, WeatherHeat, WindLevel)

    /// Radar or satellite, read out of decoded tiles.
    case tiles(GlobeTileMosaic)
}

/// A finished picture of one weather layer, in the screen's own coordinates.
struct GlobeWeatherRaster {

    let image: CGImage

    /// Where on the view it goes.
    let frame: CGRect

    /// The camera it was built for.
    ///
    /// Kept because a raster is only true for one: the sphere shows different
    /// ground the moment it turns, and there is no transform of a flat picture
    /// that follows a rotation. See `GlobeWeatherRaster.canRedraw(at:)`.
    let camera: GlobeCamera

    /// What it is a picture of, so an unchanged layer is not built again.
    let key: String

    /// How opaque it is drawn.
    let opacity: CGFloat

    /// Whether this picture is still true for a camera.
    ///
    /// A **zoom** it survives exactly: the projection is orthographic, so
    /// pulling back scales the whole disc and the picture scales with it — the
    /// same ground is under the same pixel. A **turn** it does not survive at
    /// all, by any transform, because the ground under a pixel has changed.
    ///
    /// So a pinch keeps the layer on screen and a spin drops it until the next
    /// build, which lands a frame or two after the planet stops. The
    /// alternative to dropping it is drawing Africa over the Pacific, which is
    /// worse than drawing nothing.
    func canRedraw(at other: GlobeCamera) -> Bool {
        abs(camera.latitude - other.latitude) < 0.0001
            && abs(camera.longitude - other.longitude) < 0.0001
    }

    /// Where the picture goes for a camera that has only zoomed since.
    ///
    /// The disc is the frame of reference: the raster was built against one
    /// disc, so it is placed against the new one in the same proportion.
    func frame(at other: GlobeCamera) -> CGRect {
        guard camera.radius > 0 else { return frame }
        let scale = other.radius / camera.radius
        return CGRect(
            x: other.center.x + (frame.minX - camera.center.x) * scale,
            y: other.center.y + (frame.minY - camera.center.y) * scale,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }
}

extension GlobeWeatherRaster {

    /// How many pixels the raster is allowed, whatever the screen's size.
    ///
    /// Every one of them is an unprojection and a sample — a square root, an
    /// arcsine and an arctangent — so this is the whole cost of the layer and
    /// the only dial worth having. A hundred and forty thousand is about a
    /// half-scale phone screen and lands in single-digit milliseconds; the
    /// source underneath is a dozen model samples or a smoothed radar tile, so
    /// there is nothing sharper in it for more pixels to find.
    static let pixelBudget = 140_000

    /// Builds one. Off the main thread — see the file's own note.
    ///
    /// Returns nil when there is nothing of the layer on screen at all, which
    /// is the ordinary answer for a wind grid over somewhere the planet is not
    /// currently showing.
    static func make(
        _ source: GlobeWeatherSource,
        camera: GlobeCamera,
        bounds: CGRect,
        key: String,
        opacity: CGFloat
    ) -> GlobeWeatherRaster? {
        guard camera.radius > 0, bounds.width > 1, bounds.height > 1 else { return nil }

        // Only where the sphere and the screen actually overlap. Zoomed in the
        // disc is many screens wide, and zoomed out it is a coin in the middle
        // of one — either way most of the product of the two is nowhere.
        let disc = CGRect(
            x: camera.center.x - camera.radius,
            y: camera.center.y - camera.radius,
            width: camera.radius * 2,
            height: camera.radius * 2
        )
        let frame = disc.intersection(bounds).integral
        guard frame.width >= 2, frame.height >= 2 else { return nil }

        // The scale that spends the budget and no more, never sharper than the
        // screen itself.
        let area = Double(frame.width * frame.height)
        let scale = min(1, (Double(pixelBudget) / max(area, 1)).squareRoot())
        let width = max(2, Int((Double(frame.width) * scale).rounded()))
        let height = max(2, Int((Double(frame.height) * scale).rounded()))

        let basis = camera.basis

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var drew = false

        let stepX = Double(frame.width) / Double(width)
        let stepY = Double(frame.height) / Double(height)

        /// Walks the output once, handing each pixel the place it looks at.
        ///
        /// A closure rather than the switch inside the loop, and that is not
        /// tidiness: binding a `WeatherField` out of the enum a hundred and
        /// forty thousand times is a hundred and forty thousand retains and
        /// releases of the arrays inside it, which costs more than the
        /// arithmetic the loop exists for. Bound once, out here.
        func walk(_ sample: (CLLocationCoordinate2D, Int) -> Bool) {
            for row in 0..<height {
                let y = Double(frame.minY) + (Double(row) + 0.5) * stepY

                for column in 0..<width {
                    let x = Double(frame.minX) + (Double(column) + 0.5) * stepX

                    guard let vector = camera.unproject(
                        CGPoint(x: x, y: y),
                        using: basis
                    ) else { continue }

                    if sample(
                        GlobeGeometry.coordinate(of: vector),
                        (row * width + column) * 4
                    ) {
                        drew = true
                    }
                }
            }
        }

        switch source {
        case .heat(let field, let product, let level):
            let stops = WeatherRamp.stops(for: product)
            guard !stops.isEmpty, !field.isEmpty else { return nil }

            walk { place, at in
                guard let value = WeatherHeatOverlay.value(
                    of: product,
                    at: place,
                    in: field,
                    level: level
                ) else { return false }

                let colour = WeatherRamp.colour(value, in: stops)
                guard colour.a > 0 else { return false }

                pixels[at] = UInt8(min(max(colour.r, 0), 1) * 255)
                pixels[at + 1] = UInt8(min(max(colour.g, 0), 1) * 255)
                pixels[at + 2] = UInt8(min(max(colour.b, 0), 1) * 255)
                pixels[at + 3] = UInt8(min(max(colour.a, 0), 1) * 255)
                return true
            }

        case .tiles(let mosaic):
            walk { place, at in
                guard let pixel = mosaic.sample(
                    latitude: place.latitude,
                    longitude: place.longitude
                ), pixel.a > 0 else { return false }

                pixels[at] = pixel.r
                pixels[at + 1] = pixel.g
                pixels[at + 2] = pixel.b
                pixels[at + 3] = pixel.a
                return true
            }
        }

        guard drew else { return nil }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { return nil }

        return GlobeWeatherRaster(
            image: image,
            frame: frame,
            camera: camera,
            key: key,
            opacity: opacity
        )
    }

    /// Which tiles a camera needs, at a zoom.
    ///
    /// Worked out by walking the edge and the middle of the visible disc rather
    /// than by inverting a bounding box, because on a sphere there is no
    /// bounding box: a view containing a pole contains every longitude, and one
    /// across the antimeridian has a west edge east of its east edge. Sampling
    /// the face and taking the tiles the samples land in has neither problem
    /// and misses nothing at the density used here.
    static func tilesNeeded(camera: GlobeCamera, bounds: CGRect, z: Int) -> [(x: Int, y: Int)] {
        guard camera.radius > 0 else { return [] }

        let disc = CGRect(
            x: camera.center.x - camera.radius,
            y: camera.center.y - camera.radius,
            width: camera.radius * 2,
            height: camera.radius * 2
        )
        let frame = disc.intersection(bounds)
        guard frame.width >= 2, frame.height >= 2 else { return [] }

        let basis = camera.basis
        let across = Int(pow(2, Double(z)))
        let world = Double(across) * 256

        // Dense enough that no tile between two samples is missed: the samples
        // are at most a third of a tile apart on screen.
        let pitch = max(4.0, Double(camera.radius) * 2 * .pi / (Double(across) * 3))
        let columns = max(2, Int((Double(frame.width) / pitch).rounded(.up)) + 1)
        let rows = max(2, Int((Double(frame.height) / pitch).rounded(.up)) + 1)

        var seen = Set<Int>()
        var wanted: [(x: Int, y: Int)] = []

        for row in 0...rows {
            let y = Double(frame.minY) + Double(row) / Double(rows) * Double(frame.height)
            for column in 0...columns {
                let x = Double(frame.minX)
                    + Double(column) / Double(columns) * Double(frame.width)

                guard let vector = camera.unproject(
                    CGPoint(x: x, y: y),
                    using: basis
                ) else { continue }

                let place = GlobeGeometry.coordinate(of: vector)
                guard let unit = GlobeMercator.normalised(
                    latitude: place.latitude,
                    longitude: place.longitude
                ) else { continue }

                var tileX = Int(unit.x * world) / 256
                let tileY = Int(unit.y * world) / 256
                tileX = ((tileX % across) + across) % across
                guard tileY >= 0, tileY < across else { continue }

                let slot = tileY * across + tileX
                if seen.insert(slot).inserted {
                    wanted.append((x: tileX, y: tileY))
                }
            }
        }

        return wanted
    }
}

// MARK: - The moving air

/// The wind particles, on a sphere.
///
/// The flat map's `WindParticleOverlay` advects in map points, which is the
/// right frame for a map that *is* a plane. Here the frame is the planet:
/// particles carry a latitude and a longitude, are stepped through the field in
/// degrees, and are projected only when they are drawn. Which means they follow
/// the ground round the limb and over a pole rather than off the edge of a
/// rectangle, and the same particle is in the same place whichever way the
/// planet is turned.
///
/// `WindParticleStyle` is shared with the flat map rather than reimplemented,
/// so the density, the trail length, the lifetimes, the colour and the one
/// deliberate lie about speed are the same on both.
final class GlobeWindParticles {

    private struct Particle {
        var latitude: Double
        var longitude: Double
        /// Where it has been, newest last, in degrees.
        var trail: [SIMD2<Double>]
        var life: Int
        var age: Int
    }

    private var particles: [Particle] = []
    private let field: WeatherField
    private var generator = SystemRandomNumberGenerator()

    /// What the field covers, which is where particles are seeded and where
    /// they are retired for leaving.
    private let south: Double
    private let north: Double
    private let west: Double
    private let east: Double

    /// Degrees of latitude a second at a hundred knots, which is the scaled
    /// clock `WindParticleStyle` explains. Set against the camera, so the
    /// streaks read the same at every zoom.
    private var degreesPerSecondAt100kt: Double = 1

    init?(field: WeatherField) {
        guard !field.isEmpty else { return nil }
        self.field = field
        self.south = field.south
        self.north = field.north
        self.west = field.west
        self.east = field.east
    }

    /// Told where the camera is, which sets how many particles there are and
    /// how fast the clock runs.
    ///
    /// Both are questions about the camera rather than about the weather, so
    /// this is called on every pass and the field is not rebuilt for it.
    func look(at camera: GlobeCamera, bounds: CGRect) {
        guard camera.radius > 0 else { return }

        // How much of the planet a screen is worth, in degrees. The sphere's
        // radius in points is a quarter of its circumference, so a point is
        // this many degrees at the middle of the disc.
        let degreesPerPoint = 90 / Double(camera.radius)
        let acrossDegrees = Double(min(bounds.width, bounds.height)) * degreesPerPoint

        degreesPerSecondAt100kt = acrossDegrees * WindParticleStyle.screensPerSecondAt100kt

        let area = Double(bounds.width * bounds.height)
        let wanted = min(
            WindParticleStyle.mostParticles,
            max(
                WindParticleStyle.fewestParticles,
                Int(area / WindParticleStyle.pointsPerParticle)
            )
        )

        if particles.count > wanted {
            particles.removeLast(particles.count - wanted)
        } else if particles.count < wanted {
            for _ in particles.count..<wanted { particles.append(seed()) }
        }
    }

    /// One step of the field.
    ///
    /// Mutated in place through the array rather than copied out and back: a
    /// particle carries eight points of history, and taking a copy of one to
    /// append to it is a copy-on-write of that trail for every particle on
    /// every step — a thousand small allocations a frame to add one point each.
    func step(_ elapsed: Double) {
        guard elapsed > 0, !particles.isEmpty else { return }

        for index in particles.indices {
            particles[index].age += 1

            let place = CLLocationCoordinate2D(
                latitude: particles[index].latitude,
                longitude: particles[index].longitude
            )

            guard particles[index].age < particles[index].life,
                  let wind = field.wind(at: place) else {
                particles[index] = seed()
                continue
            }

            // Metres a second to the scaled clock, through knots, because that
            // is the unit the one deliberate lie is calibrated in.
            let knots = (wind.u * wind.u + wind.v * wind.v).squareRoot()
                * WeatherField.knotsPerMetrePerSecond
            guard knots > 0.01 else {
                particles[index] = seed()
                continue
            }

            let degrees = knots / 100 * degreesPerSecondAt100kt * elapsed
            // `u` is eastward and `v` northward, so this is the direction the
            // air is going — which is the opposite of the direction a barb
            // points, and deliberately so: a barb says where the wind is *from*
            // and a streak shows where it is headed.
            let bearing = atan2(wind.u, wind.v)

            // A degree of longitude is shorter than a degree of latitude
            // everywhere but the equator, so a particle drifting due east near
            // a pole covers more of them. Clamped for the same reason the drag
            // is: the factor runs away at the pole itself.
            let shrink = max(0.15, cos(particles[index].latitude * .pi / 180))

            let latitude = particles[index].latitude + degrees * cos(bearing)
            let longitude = particles[index].longitude + degrees * sin(bearing) / shrink

            guard latitude >= south, latitude <= north,
                  longitude >= west, longitude <= east else {
                particles[index] = seed()
                continue
            }

            particles[index].latitude = latitude
            particles[index].longitude = longitude
            particles[index].trail.append(SIMD2(latitude, longitude))
            if particles[index].trail.count > WindParticleStyle.trail {
                particles[index].trail.removeFirst(
                    particles[index].trail.count - WindParticleStyle.trail
                )
            }
        }
    }

    /// Draws the streaks for a camera.
    ///
    /// Each segment is projected and rejected on its own: a streak that runs
    /// over the limb has the part of it you can see drawn and the rest dropped,
    /// which is what makes the layer look like it is on the planet rather than
    /// over it.
    func draw(in context: CGContext, camera: GlobeCamera, colour: UIColor, box: CGRect) {
        guard !particles.isEmpty else { return }

        let basis = camera.basis

        context.saveGState()
        defer { context.restoreGState() }

        context.setStrokeColor(colour.cgColor)
        context.setLineWidth(WindParticleStyle.width)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        let path = CGMutablePath()

        for particle in particles where particle.trail.count > 1 {
            var previous: CGPoint?

            for step in particle.trail {
                let projected = camera.project(
                    GlobeGeometry.preciseVector(latitude: step.x, longitude: step.y),
                    using: basis
                )

                guard projected.depth > 0, box.contains(projected.point) else {
                    previous = nil
                    continue
                }

                if let from = previous {
                    path.move(to: from)
                    path.addLine(to: projected.point)
                }
                previous = projected.point
            }
        }

        guard !path.isEmpty else { return }
        context.addPath(path)
        context.strokePath()
    }

    private func seed() -> Particle {
        let latitude = Double.random(in: south...north, using: &generator)
        let longitude = Double.random(in: west...east, using: &generator)
        return Particle(
            latitude: latitude,
            longitude: longitude,
            trail: [SIMD2(latitude, longitude)],
            life: Int.random(
                in: WindParticleStyle.shortestLife...WindParticleStyle.longestLife,
                using: &generator
            ),
            age: 0
        )
    }
}
