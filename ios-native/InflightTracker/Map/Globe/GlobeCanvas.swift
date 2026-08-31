import SwiftUI
import UIKit
import simd

/// The planet itself: the sky behind it, the sphere, every country, the
/// graticule, the night, and everything flying over it.
///
/// A `UIView` drawing into Core Graphics rather than a SwiftUI `Canvas`. Ten
/// thousand border points and a packet of traffic, redrawn while a finger is
/// moving, is more per-frame command recording than a `Canvas` wants to carry —
/// and all of it is stroked paths, which is what `CGContext` is fastest at.
///
/// ## Everything is drawn here, deliberately
///
/// The airports used to be SwiftUI views laid over this one, positioned by the
/// same camera — text and hit targets being what SwiftUI is good at and what a
/// `draw(_:)` is worst at. It was the wrong trade. A `.position()` per field
/// means SwiftUI re-laying out every marker on every frame of a drag, on the
/// other side of a view update from the coastlines underneath them, and the two
/// do not land together: the planet turns under fields that arrive a beat late
/// and slide into place, which is exactly the elastic wobble the globe had.
///
/// One `draw(_:)` cannot be out of step with itself. The labels are rendered
/// once into cached bitmaps and blitted, which costs a fraction of what the
/// layout did, and hit testing happens against the same projection the drawing
/// used — see `PlanetSurface`.
struct GlobeCanvas: UIViewRepresentable {

    var camera: GlobeCamera
    var palette: GlobePalette
    var backdrop: GlobeBackdropStyle

    /// The traffic, the fields and the route. A reference, compared by
    /// `revision` — see `GlobeScene` for why that matters so much here.
    var scene: GlobeScene
    var revision: Int

    /// Whether the traffic is drawn as aircraft rather than as dots.
    var showsPlanes: Bool
    var showsFields: Bool

    /// Where the sun is overhead, or nil to draw the planet evenly lit.
    var sun: SIMD3<Float>?

    /// Whether a finger is on the planet right now. Drops the cartography a
    /// level of detail for the duration, which is invisible while the world is
    /// moving and is most of the difference between sixty frames and thirty.
    var isInteracting: Bool

    func makeUIView(context: Context) -> GlobeCanvasView {
        let view = GlobeCanvasView()
        // The backdrop covers the view completely, so there is nothing behind
        // this to blend with and no reason to pay for the blend.
        view.isOpaque = true
        // Redrawn rather than scaled, so a border is a sharp hairline at any
        // zoom instead of a stretched bitmap.
        view.contentMode = .redraw
        return view
    }

    func updateUIView(_ view: GlobeCanvasView, context: Context) {
        view.apply(
            camera: camera,
            palette: palette,
            backdrop: backdrop,
            scene: scene,
            revision: revision,
            showsPlanes: showsPlanes,
            showsFields: showsFields,
            sun: sun,
            isInteracting: isInteracting
        )
    }
}

/// How large the things with labels on them are drawn.
///
/// Shared with the view that does the hit testing, so what you can tap is what
/// you can see rather than a second set of numbers that has to be kept in step
/// with the first by hand.
enum GlobeMarkMetrics {
    static let fieldRingRadius: CGFloat = 6.5
    static let fieldDotRadius: CGFloat = 3
    static let labelGap: CGFloat = 4
    static let fieldFontSize: CGFloat = 10.5

    /// How near a tap has to land, in points.
    static let touchRadius: CGFloat = 22

    /// Below this the planet is turning away and a marker is not something to
    /// tap by accident.
    static let tappableDepth: Float = 0.18
}

final class GlobeCanvasView: UIView {

    private var camera = GlobeCamera()
    private var palette = GlobeSkin.midnight.palette(scheme: .dark)
    private var backdrop = GlobeBackdropStyle.plain
    private var scene = GlobeScene()
    private var revision = -1
    private var showsPlanes = true
    private var showsFields = true
    private var sun: SIMD3<Float>?
    private var isInteracting = false

    /// Field codes, rendered once each. Cleared when the palette changes, which
    /// is the only thing that can make one wrong.
    private var labels: [String: UIImage] = [:]

    /// The starfield, in unit coordinates, generated once for a given size.
    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let alpha: CGFloat
    }
    private var stars: [Star] = []
    private var starsSize: CGSize = .zero

    func apply(
        camera: GlobeCamera,
        palette: GlobePalette,
        backdrop: GlobeBackdropStyle,
        scene: GlobeScene,
        revision: Int,
        showsPlanes: Bool,
        showsFields: Bool,
        sun: SIMD3<Float>?,
        isInteracting: Bool
    ) {
        let unchanged = camera == self.camera
            && revision == self.revision
            && scene === self.scene
            && showsPlanes == self.showsPlanes
            && showsFields == self.showsFields
            && sun == self.sun
            && isInteracting == self.isInteracting
            && palette == self.palette
            && backdrop == self.backdrop

        if palette != self.palette { labels.removeAll() }

        self.camera = camera
        self.palette = palette
        self.backdrop = backdrop
        self.scene = scene
        self.revision = revision
        self.showsPlanes = showsPlanes
        self.showsFields = showsFields
        self.sun = sun
        self.isInteracting = isInteracting

        // An opaque view has to have something behind the drawing during the
        // moment between a resize and the redraw, or the gap is undefined.
        backgroundColor = (backdrop.colors.first ?? .black).withAlphaComponent(1)

        guard !unchanged else { return }
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        drawBackdrop(in: context)
        guard camera.radius > 0 else { return }

        let basis = camera.basis
        let detail = self.detail

        drawHalo(in: context)
        drawSphere(in: context)

        if let land = palette.land {
            drawLand(in: context, basis: basis, detail: detail, color: land)
        }

        drawRings(GlobeGeometry.graticule, in: context, basis: basis,
                  color: palette.graticule, width: palette.graticuleWidth)
        drawRings(GlobeGeometry.borders(for: detail), in: context, basis: basis,
                  color: palette.border, width: palette.borderWidth)

        if let sun = sun {
            drawNight(in: context, basis: basis, sun: sun)
        }

        drawLines(in: context, basis: basis)
        drawLimb(in: context)
        drawTraffic(in: context, basis: basis)

        if showsFields {
            drawFields(in: context, basis: basis)
        }
    }

    /// How much border detail this frame is worth.
    ///
    /// Thresholds in points of sphere radius rather than in zoom multiples, so
    /// the answer is about how large the planet actually is on screen — which
    /// is the thing that decides whether a dropped point is visible — rather
    /// than about a phone's screen width.
    private var detail: GlobeGeometry.Detail {
        if isInteracting { return camera.radius > 1400 ? .medium : .coarse }
        if camera.radius > 1600 { return .full }
        if camera.radius > 700 { return .medium }
        return .coarse
    }

    private var discBox: CGRect {
        CGRect(
            x: camera.center.x - camera.radius,
            y: camera.center.y - camera.radius,
            width: camera.radius * 2,
            height: camera.radius * 2
        )
    }

    // MARK: - The sky

    private func drawBackdrop(in context: CGContext) {
        let box = bounds

        if backdrop.colors.count > 1,
           let gradient = CGGradient(
               colorsSpace: CGColorSpaceCreateDeviceRGB(),
               colors: backdrop.colors.map { $0.cgColor } as CFArray,
               locations: nil
           ) {
            context.saveGState()
            context.clip(to: box)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: box.midX, y: box.minY),
                end: CGPoint(x: box.midX, y: box.maxY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            context.restoreGState()
        } else {
            context.setFillColor((backdrop.colors.first ?? .black).withAlphaComponent(1).cgColor)
            context.fill(box)
        }

        if let colour = backdrop.stars {
            drawStars(in: context, color: colour)
        }

        if let colour = backdrop.vignette {
            drawVignette(in: context, color: colour)
        }
    }

    /// Stars, fixed to the screen rather than to the sky.
    ///
    /// Which is a choice and not a shortcut. A starfield that turned with the
    /// planet would be a second thing moving under your finger, competing with
    /// the one you are actually turning; held still, it reads as a window.
    ///
    /// Generated from a fixed seed, so the sky is the same sky between redraws,
    /// between rotations, and between launches. A random one would twinkle
    /// every frame.
    private func drawStars(in context: CGContext, color: UIColor) {
        if starsSize != bounds.size { makeStars(for: bounds.size) }
        guard !stars.isEmpty else { return }

        // Grouped into three brightnesses rather than set per star, so a
        // thousand stars is three fills.
        for band in 0..<3 {
            let path = CGMutablePath()
            var any = false
            for star in stars where Int(star.alpha * 3) == band {
                path.addEllipse(in: CGRect(
                    x: star.x - star.radius, y: star.y - star.radius,
                    width: star.radius * 2, height: star.radius * 2
                ))
                any = true
            }
            guard any else { continue }
            context.setFillColor(color.withAlphaComponent(0.25 + CGFloat(band) * 0.28).cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    private func makeStars(for size: CGSize) {
        starsSize = size
        stars = []
        guard size.width > 0, size.height > 0 else { return }

        // About one star per four thousand square points: dense enough to read
        // as a sky, sparse enough that it never competes with the traffic.
        let count = min(700, max(80, Int(size.width * size.height / 4000)))
        stars.reserveCapacity(count)

        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            // xorshift, which is a handful of instructions and repeatable
            // across platforms in a way `Double.random` is not.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return CGFloat(seed % 100_000) / 100_000
        }

        for _ in 0..<count {
            stars.append(Star(
                x: next() * size.width,
                y: next() * size.height,
                radius: 0.4 + next() * 0.9,
                alpha: next() * 0.999
            ))
        }
    }

    private func drawVignette(in context: CGContext, color: UIColor) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.withAlphaComponent(0).cgColor, color.cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        context.saveGState()
        context.clip(to: bounds)
        context.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: min(bounds.width, bounds.height) * 0.3,
            endCenter: centre,
            endRadius: max(bounds.width, bounds.height) * 0.75,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    // MARK: - The planet

    private func drawSphere(in context: CGContext) {
        context.setFillColor(palette.ocean.cgColor)
        context.fillEllipse(in: discBox)
    }

    /// A ring of atmosphere just outside the limb.
    ///
    /// Outside rather than over: it is the air the planet is wrapped in, and
    /// laying it over the cartography would fog the coastlines at the edge —
    /// which are the ones already hardest to read.
    private func drawHalo(in context: CGContext) {
        guard let colour = palette.halo else { return }

        let outer = camera.radius * 1.12
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [colour.cgColor, colour.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }

        context.saveGState()
        context.drawRadialGradient(
            gradient,
            startCenter: camera.center,
            startRadius: camera.radius * 0.98,
            endCenter: camera.center,
            endRadius: outer,
            options: []
        )
        context.restoreGState()
    }

    /// The thin bright edge where the planet meets space.
    ///
    /// Drawn over the cartography rather than under it, so outlines running to
    /// the limb are finished by a clean arc instead of by whatever the clipper
    /// left within half a pixel of it.
    private func drawLimb(in context: CGContext) {
        guard palette.limbWidth > 0 else { return }
        context.setStrokeColor(palette.limb.cgColor)
        context.setLineWidth(palette.limbWidth)
        context.strokeEllipse(
            in: discBox.insetBy(dx: palette.limbWidth / 2, dy: palette.limbWidth / 2)
        )
    }

    // MARK: - Land

    /// The continents, filled.
    ///
    /// Every ring in one path filled even-odd, which is what makes the holes
    /// work: Natural Earth gives a country's lakes and enclaves as interior
    /// rings, and a country that sits inside another's hole — Lesotho — comes
    /// out filled again because it is crossed a third time. One fill for the
    /// whole world rather than one per country.
    ///
    /// The horizon is handled by pushing points round the back out to the limb
    /// rather than by clipping. A silhouette only needs its outline to be right
    /// where you can see it, and a landmass wrapping over the edge then ends
    /// flush against the limb — where the clip would have to invent an arc to
    /// close it along, and would get the arc wrong for any ring crossing the
    /// horizon more than twice.
    private func drawLand(
        in context: CGContext,
        basis: GlobeCamera.Basis,
        detail: GlobeGeometry.Detail,
        color: UIColor
    ) {
        let path = CGMutablePath()
        for ring in GlobeGeometry.borders(for: detail) {
            appendSilhouette(ring, to: path, basis: basis)
        }

        context.saveGState()
        context.addEllipse(in: discBox)
        context.clip()
        context.setFillColor(color.cgColor)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    private func appendSilhouette(
        _ ring: GlobeGeometry.Ring,
        to path: CGMutablePath,
        basis: GlobeCamera.Basis
    ) {
        if isCulled(ring, basis: basis) { return }

        var started = false
        for point in ring.points {
            var x = CGFloat(simd_dot(point, basis.east))
            var y = CGFloat(simd_dot(point, basis.north))

            if simd_dot(point, basis.out) < 0 {
                let length = (x * x + y * y).squareRoot()
                // Exactly the antipode of the camera, where there is no
                // direction to push it in. One point of a ring, and skipping it
                // is a segment the neighbours draw between them anyway.
                guard length > 1e-5 else { continue }
                x /= length
                y /= length
            }

            let screen = CGPoint(
                x: camera.center.x + x * camera.radius,
                y: camera.center.y - y * camera.radius
            )
            if started {
                path.addLine(to: screen)
            } else {
                path.move(to: screen)
                started = true
            }
        }

        if started { path.closeSubpath() }
    }

    // MARK: - Lines on it

    /// Wholly round the back: one dot product for an entire country.
    ///
    /// Only sound for a ring that fits inside a hemisphere, which is what a
    /// positive `radiusCosine` means. A ring larger than that — a meridian,
    /// which wraps the planet — has no direction the camera can point away from
    /// far enough, and the test would cull it wrongly.
    private func isCulled(_ ring: GlobeGeometry.Ring, basis: GlobeCamera.Basis) -> Bool {
        guard ring.radiusCosine > 0 else { return false }
        let facing = simd_dot(ring.axis, basis.out)
        let reach = (1 - ring.radiusCosine * ring.radiusCosine).squareRoot()
        return facing < -reach
    }

    /// Every ring, clipped at the horizon.
    private func drawRings(
        _ rings: [GlobeGeometry.Ring],
        in context: CGContext,
        basis: GlobeCamera.Basis,
        color: UIColor,
        width: CGFloat
    ) {
        guard width > 0 else { return }

        let path = CGMutablePath()
        for ring in rings where !isCulled(ring, basis: basis) {
            append(ring.points, to: path, basis: basis)
        }

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func drawLines(in context: CGContext, basis: GlobeCamera.Basis) {
        guard !scene.lines.isEmpty else { return }

        for line in scene.lines {
            let path = CGMutablePath()
            append(line.points, to: path, basis: basis)

            context.saveGState()
            context.setStrokeColor(line.color.cgColor)
            context.setLineWidth(line.width)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            if let dash = line.dash { context.setLineDash(phase: 0, lengths: dash) }
            context.addPath(path)
            context.strokePath()
            context.restoreGState()
        }
    }

    /// A run of points on the sphere, as screen path, clipped at the horizon.
    ///
    /// The clipping is the part worth being careful about. A segment with one
    /// end on the near side and the other round the back has to stop at the
    /// limb; drawn straight through it becomes a chord across the planet, and
    /// with a coastline's worth of them the globe looks shattered.
    private func append(
        _ points: [SIMD3<Float>],
        to path: CGMutablePath,
        basis: GlobeCamera.Basis
    ) {
        var previousVector: SIMD3<Float>?
        var previous: GlobeCamera.Projected?
        var isDrawing = false

        for point in points {
            let now = camera.project(point, using: basis)

            guard let lastVector = previousVector, let last = previous else {
                if now.isVisible {
                    path.move(to: now.point)
                    isDrawing = true
                }
                previousVector = point
                previous = now
                continue
            }

            switch (last.isVisible, now.isVisible) {
            case (true, true):
                if !isDrawing {
                    path.move(to: last.point)
                    isDrawing = true
                }
                path.addLine(to: now.point)

            case (true, false):
                if !isDrawing {
                    path.move(to: last.point)
                    isDrawing = true
                }
                path.addLine(to: horizonCrossing(
                    near: last, far: now, nearVector: lastVector, farVector: point, basis: basis
                ))
                isDrawing = false

            case (false, true):
                path.move(to: horizonCrossing(
                    near: now, far: last, nearVector: point, farVector: lastVector, basis: basis
                ))
                path.addLine(to: now.point)
                isDrawing = true

            case (false, false):
                isDrawing = false
            }

            previousVector = point
            previous = now
        }
    }

    /// Where the segment between two directions crosses the horizon.
    ///
    /// The two directions are blended by their depths and renormalised, which
    /// is the point on the sphere between them at the crossing — accurate to
    /// well under a pixel at any radius the globe allows, and two multiplies
    /// rather than a great-circle solve.
    private func horizonCrossing(
        near: GlobeCamera.Projected,
        far: GlobeCamera.Projected,
        nearVector: SIMD3<Float>,
        farVector: SIMD3<Float>,
        basis: GlobeCamera.Basis
    ) -> CGPoint {
        let span = near.depth - far.depth
        guard span > 1e-6 else { return near.point }

        let t = near.depth / span
        let blended = simd_normalize(nearVector + (farVector - nearVector) * t)
        return camera.project(blended, using: basis).point
    }

    // MARK: - Night

    /// The half of the planet the sun is not on.
    ///
    /// The night region is a hemisphere, so its edge on screen is the visible
    /// half of one great circle — the terminator — closed along the limb. Both
    /// halves are found exactly rather than searched for:
    ///
    /// - the terminator meets the limb at `±normalize(sun × out)`, the two
    ///   directions perpendicular to both;
    /// - the visible half of the terminator runs between them through the point
    ///   nearest the camera, which is `out` with its sun component removed;
    /// - and a point *on* the limb is in darkness exactly when it lies in the
    ///   half centred on the anti-solar direction, because a limb point has no
    ///   depth for the sun's own depth to matter against.
    ///
    /// So the limb arc to close along is the half-circle centred on the
    /// anti-solar bearing, and its ends are the two crossings — which is the
    /// same pair, and the reason none of this needs a search or a winding rule.
    private func drawNight(in context: CGContext, basis: GlobeCamera.Basis, sun: SIMD3<Float>) {
        let radius = camera.radius
        let facing = simd_dot(sun, basis.out)

        // The sun straight ahead or straight behind: the terminator is the limb
        // itself, and the answer is all of it or none of it.
        let crossing = simd_cross(sun, basis.out)
        let crossingLength = simd_length(crossing)
        guard crossingLength > 1e-4 else {
            guard facing < 0 else { return }
            context.setFillColor(palette.night.cgColor)
            context.fillEllipse(in: discBox)
            return
        }

        let edge = crossing / crossingLength

        // The visible midpoint of the terminator, which is the view direction
        // with whatever of the sun is in it taken out.
        let towards = simd_normalize(basis.out - sun * facing)

        func screen(_ vector: SIMD3<Float>) -> CGPoint {
            CGPoint(
                x: camera.center.x + CGFloat(simd_dot(vector, basis.east)) * radius,
                y: camera.center.y - CGFloat(simd_dot(vector, basis.north)) * radius
            )
        }

        let path = CGMutablePath()
        let steps = 64
        for step in 0...steps {
            let angle = Float(step) / Float(steps) * .pi
            let point = edge * cos(angle) + towards * sin(angle)
            let screenPoint = screen(point)
            if step == 0 { path.move(to: screenPoint) } else { path.addLine(to: screenPoint) }
        }

        // Home along the limb, through the bearing of the anti-solar point.
        // `-edge` is where the terminator arc finished; the night's own bearing
        // is a quarter turn from it, and which quarter is the only thing left
        // to decide.
        let endAngle = atan2(
            screen(-edge).y - camera.center.y,
            screen(-edge).x - camera.center.x
        )
        let nightBearing = atan2(
            CGFloat(-simd_dot(-sun, basis.north)),
            CGFloat(simd_dot(-sun, basis.east))
        )
        let sweep: CGFloat = Self.isNearer(endAngle + .pi / 2, to: nightBearing,
                                           than: endAngle - .pi / 2) ? .pi : -.pi

        let limbSteps = 48
        for step in 1...limbSteps {
            let angle = endAngle + sweep * CGFloat(step) / CGFloat(limbSteps)
            path.addLine(to: CGPoint(
                x: camera.center.x + cos(angle) * radius,
                y: camera.center.y + sin(angle) * radius
            ))
        }
        path.closeSubpath()

        context.saveGState()
        context.addEllipse(in: discBox)
        context.clip()
        context.setFillColor(palette.night.cgColor)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    /// Whether the first angle is the closer of two to a third, going the short
    /// way round in both cases.
    private static func isNearer(_ first: CGFloat, to target: CGFloat, than second: CGFloat) -> Bool {
        func distance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            var delta = (a - b).truncatingRemainder(dividingBy: .pi * 2)
            if delta < 0 { delta += .pi * 2 }
            return min(delta, .pi * 2 - delta)
        }
        return distance(first, target) <= distance(second, target)
    }

    // MARK: - Traffic

    private func drawTraffic(in context: CGContext, basis: GlobeCamera.Basis) {
        let traffic = scene.traffic
        guard !traffic.isEmpty else { return }

        if showsPlanes && traffic.count <= Self.planeLimit && !(isInteracting && traffic.count > 400) {
            drawPlanes(traffic, in: context, basis: basis)
        } else {
            drawDots(traffic, in: context, basis: basis)
        }
    }

    /// Above this many aircraft the artwork stops being artwork.
    ///
    /// Not a performance floor — the icons are cached bitmaps and blitting
    /// three thousand of them is well within a frame. It is that three thousand
    /// aeroplane silhouettes on a disc four hundred points across is a texture
    /// rather than a picture of traffic, and dots at least say how many and
    /// where.
    private static let planeLimit = 1600

    private func drawPlanes(
        _ traffic: [GlobeTrafficDot],
        in context: CGContext,
        basis: GlobeCamera.Basis
    ) {
        let sprites = PlaneSprites.shared
        let size = palette.planeSize
        var open: [(CGPoint, CGFloat, GlobeTrafficDot)] = []

        for dot in traffic {
            let projected = camera.project(dot.position, using: basis)
            guard projected.isVisible else { continue }

            // Two dot products for the sprite's angle. The heading is a
            // direction on the surface, and an orthographic projection is
            // linear, so where that direction lands on screen is the projection
            // of the direction itself — no second point to project and
            // subtract.
            let dx = CGFloat(simd_dot(dot.heading, basis.east))
            let dy = -CGFloat(simd_dot(dot.heading, basis.north))
            let angle = atan2(dx, -dy)

            if dot.isOpen {
                open.append((projected.point, angle, dot))
                continue
            }

            draw(dot, at: projected.point, angle: angle, size: size, in: context, sprites: sprites)
        }

        // The open aircraft last and larger, with a ring round it, so it is
        // findable in a packet of three thousand.
        for (point, angle, dot) in open {
            let ring = size * 0.95
            context.setStrokeColor(palette.openTraffic.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(
                x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2
            ))
            draw(dot, at: point, angle: angle, size: size * 1.45, in: context, sprites: sprites)
        }
    }

    private func draw(
        _ dot: GlobeTrafficDot,
        at point: CGPoint,
        angle: CGFloat,
        size: CGFloat,
        in context: CGContext,
        sprites: PlaneSprites
    ) {
        let body = dot.isOpen ? palette.openTraffic : (dot.tint ?? palette.traffic)
        guard let image = sprites.planetIcon(
            forKey: dot.spriteKey,
            pointSize: size,
            body: body,
            outline: Self.outline(for: body)
        ) else { return }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        image.draw(at: CGPoint(x: -image.size.width / 2, y: -image.size.height / 2))
        context.restoreGState()
    }

    /// What an aircraft is outlined in, which is whatever its body is not.
    ///
    /// Derived rather than carried by the palette, because the body is not the
    /// palette's to decide either: a watched pilot's aeroplane wears the colour
    /// that pilot was given, and it still has to hold together on a pale
    /// planet.
    private static func outline(for body: UIColor) -> UIColor {
        body.relativeLuminance > 0.45
            ? UIColor(white: 0.06, alpha: 0.9)
            : UIColor(white: 1, alpha: 0.85)
    }

    private func drawDots(
        _ traffic: [GlobeTrafficDot],
        in context: CGContext,
        basis: GlobeCamera.Basis
    ) {
        // Grouped by colour, so a packet of three thousand aircraft is a
        // handful of fills rather than one state change apiece. An array rather
        // than a dictionary: there are rarely more than three colours on a
        // planet, and a linear walk of three beats hashing a `UIColor` per
        // aircraft.
        var groups: [(colour: UIColor, path: CGMutablePath)] = []
        var open: [CGPoint] = []
        let size = palette.dotRadius

        for dot in traffic {
            let projected = camera.project(dot.position, using: basis)
            guard projected.isVisible else { continue }

            if dot.isOpen {
                open.append(projected.point)
                continue
            }

            let colour = dot.tint ?? palette.traffic
            let box = CGRect(
                x: projected.point.x - size,
                y: projected.point.y - size,
                width: size * 2,
                height: size * 2
            )

            if let index = groups.firstIndex(where: { $0.colour == colour }) {
                groups[index].path.addEllipse(in: box)
            } else {
                let path = CGMutablePath()
                path.addEllipse(in: box)
                groups.append((colour, path))
            }
        }

        for group in groups {
            context.setFillColor(group.colour.cgColor)
            context.addPath(group.path)
            context.fillPath()
        }

        for point in open {
            let outer = size * 3
            context.setStrokeColor(palette.openTraffic.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(
                x: point.x - outer, y: point.y - outer,
                width: outer * 2, height: outer * 2
            ))
            context.setFillColor(palette.openTraffic.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - size * 1.4, y: point.y - size * 1.4,
                width: size * 2.8, height: size * 2.8
            ))
        }
    }

    // MARK: - Fields

    /// The fields: a ring, the code beside it, and nothing else.
    ///
    /// The ring rather than a pin, because a pin has a point and a point
    /// implies a direction — on a sphere that is a lie everywhere but the
    /// middle of the screen. A ring is the same shape from every angle.
    ///
    /// Faded as they approach the limb: a marker at the edge of the disc is on
    /// ground turning away from you, and drawing it at full strength makes the
    /// planet look flat.
    private func drawFields(in context: CGContext, basis: GlobeCamera.Basis) {
        let fields = scene.fields
        guard !fields.isEmpty else { return }

        let ring = GlobeMarkMetrics.fieldRingRadius
        let dot = GlobeMarkMetrics.fieldDotRadius

        // Rendered before the drawing starts rather than as each one is
        // reached. A label is drawn into an image renderer, which pushes a
        // context of its own, and doing that in the middle of a run of state
        // changes on this one is the kind of thing that works until it doesn't.
        for field in fields { _ = labelImage(field.icao) }

        for field in fields {
            let projected = camera.project(field.position, using: basis)
            guard projected.depth > 0.02 else { continue }

            // Full strength across most of the near side, falling away only in
            // the last stretch before the limb.
            let opacity = min(1, CGFloat(projected.depth) / 0.28)
            let point = projected.point

            context.saveGState()
            context.setAlpha(opacity)

            context.setStrokeColor(palette.fieldRing.cgColor)
            context.setLineWidth(1)
            context.strokeEllipse(in: CGRect(
                x: point.x - ring, y: point.y - ring, width: ring * 2, height: ring * 2
            ))

            context.setFillColor(
                (field.isControlled ? palette.fieldControlled : palette.fieldPlain).cgColor
            )
            context.fillEllipse(in: CGRect(
                x: point.x - dot, y: point.y - dot, width: dot * 2, height: dot * 2
            ))

            let label = labelImage(field.icao)
            label.draw(at: CGPoint(
                x: point.x + ring + GlobeMarkMetrics.labelGap,
                y: point.y - label.size.height / 2
            ))

            context.restoreGState()
        }
    }

    /// A field's code, rendered once into a bitmap.
    ///
    /// Text layout is the single most expensive thing that could happen inside
    /// a `draw(_:)` running at sixty frames a second, and the answer to a code
    /// that never changes is not to lay it out again. The halo is a shadow
    /// rather than a stroked outline: it costs one pass, and it keeps a white
    /// code legible where it crosses a coastline.
    private func labelImage(_ icao: String) -> UIImage {
        if let cached = labels[icao] { return cached }

        let font = Self.labelFont
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: palette.fieldLabel,
        ]

        let text = icao as NSString
        let measured = text.size(withAttributes: attributes)
        let inset: CGFloat = 3
        let size = CGSize(
            width: measured.width.rounded(.up) + inset * 2,
            height: measured.height.rounded(.up) + inset * 2
        )

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.setShadow(
                offset: .zero,
                blur: 2.5,
                color: palette.fieldLabelHalo.cgColor
            )
            text.draw(at: CGPoint(x: inset, y: inset), withAttributes: attributes)
        }

        labels[icao] = image
        return image
    }

    private static let labelFont: UIFont = {
        let base = UIFont.systemFont(ofSize: GlobeMarkMetrics.fieldFontSize, weight: .bold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: GlobeMarkMetrics.fieldFontSize)
    }()
}

extension UIColor {

    /// How light this colour reads, on the usual perceptual weighting. Used to
    /// decide what to outline something drawn in it with.
    var relativeLuminance: CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return 1 }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }
}
