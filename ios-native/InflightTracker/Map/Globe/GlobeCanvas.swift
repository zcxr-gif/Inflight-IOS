import CoreLocation
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
/// A one-shot request to point the planet somewhere.
///
/// The map's own `MapCommand` in the terms this renderer understands. Kept
/// separate because the canvas has no business knowing about MapKit spans, and
/// because a token it can compare is what makes the move happen once rather
/// than on every update that follows it.
struct GlobeCommand: Equatable {
    var latitude: Double
    var longitude: Double
    /// Nil leaves the zoom where it is.
    var scale: CGFloat?
    var token: UUID
}

struct GlobeCanvas: UIViewRepresentable {

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
    var sun: SIMD3<Float>? = nil

    /// Where a running playback has put the open aircraft, or nil when nothing
    /// is playing.
    var replay: GlobeReplayMark? = nil

    /// Which face is turned towards you the first time this is laid out.
    var start: CLLocationCoordinate2D = CLLocationCoordinate2D(latitude: 20, longitude: 0)

    /// How much of the bottom and the right the chrome over this is standing
    /// on. The planet is centred in what is left.
    var bottomInset: CGFloat = 0
    var trailingInset: CGFloat = 0

    var command: GlobeCommand? = nil

    /// A fixed camera, for a preview. Set it and the planet cannot be turned,
    /// which is what a forty-eight point swatch wants.
    var still: GlobeCamera? = nil

    /// Answered with the id of whatever was tapped. The view does the hit test
    /// itself, against the same scene and the same camera it drew — so what you
    /// can tap is exactly what you can see, rather than a second projection
    /// that has to be kept in step with the first.
    var onSelectFlight: ((String) -> Void)? = nil
    var onSelectField: ((String) -> Void)? = nil

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
        view.onSelectFlight = onSelectFlight
        view.onSelectField = onSelectField
        view.apply(
            palette: palette,
            backdrop: backdrop,
            scene: scene,
            revision: revision,
            showsPlanes: showsPlanes,
            showsFields: showsFields,
            sun: sun,
            replay: replay,
            start: start,
            bottomInset: bottomInset,
            trailingInset: trailingInset,
            still: still,
            command: command
        )
    }
}

/// The open aircraft as a replay is putting it, which is not where the feed
/// says it is.
///
/// Handed separately from the scene rather than folded into it, because it
/// moves at the frame rate of a playback and the scene moves at the rate of a
/// packet. Rebuilding three thousand aircraft to move one of them would undo
/// the whole reason the scene exists.
struct GlobeReplayMark: Equatable {
    let position: SIMD3<Float>
    let heading: SIMD3<Float>
    let spriteKey: String
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

    // MARK: - What the view is handed

    private var palette = GlobeSkin.midnight.palette(scheme: .dark)
    private var backdrop = GlobeBackdropStyle.plain
    private var scene = GlobeScene()
    private var revision = -1
    private var showsPlanes = true
    private var showsFields = true
    private var sun: SIMD3<Float>?
    private var replay: GlobeReplayMark?
    private var start = CLLocationCoordinate2D(latitude: 20, longitude: 0)
    private var bottomInset: CGFloat = 0
    private var trailingInset: CGFloat = 0
    private var still: GlobeCamera?
    private var lastCommand: UUID?

    var onSelectFlight: ((String) -> Void)?
    var onSelectField: ((String) -> Void)?

    // MARK: - What the view owns
    //
    // The camera lives here rather than in SwiftUI state, and that is the whole
    // difference between a globe that turns and one that drags behind your
    // finger. Held above, every pan update was a `@State` write: a SwiftUI body
    // evaluation, a fresh representable, an `updateUIView`, and only then a
    // redraw — sixty times a second, for a value nothing in SwiftUI reads. Held
    // here, a pan is a struct mutation and a `setNeedsDisplay`, and SwiftUI is
    // not involved in the gesture at all.

    private(set) var camera = GlobeCamera()

    /// How far zoomed in, as a multiple of the radius that fits the viewport.
    private var scale: CGFloat = 1

    /// Whether the camera has been put where it was asked to start. Once, on
    /// the first layout — after that the camera is wherever it has been turned
    /// to, and a rotation must not fly it back to where the map was.
    private var isReady = false

    /// Where the planet was pointed when the current drag began.
    ///
    /// Two numbers rather than the whole camera, and that is not tidiness. Held
    /// as a `GlobeCamera` it carried the *radius* too, and a pan applies its
    /// whole translation from the start each update — so every frame of a drag
    /// wrote back the radius from when that drag began. With pan and pinch
    /// recognised simultaneously, which they must be for a hand to turn and
    /// zoom in one movement, that meant the pan spent the entire pinch undoing
    /// it: the zoom snapped back to where it was a finger-touch ago, sixty
    /// times a second. A drag turns the planet. It has no opinion about how far
    /// away it is.
    private var panOrigin: (latitude: Double, longitude: Double)?
    private var pinchStart: CGFloat?

    private var isInteracting: Bool { panOrigin != nil || pinchStart != nil }

    // MARK: - Caches

    /// Field codes, rendered once each. Cleared when the palette changes, which
    /// is the only thing that can make one wrong.
    private var labels: [String: UIImage] = [:]

    /// The sky, rendered once.
    ///
    /// It is a gradient, up to seven hundred stars and a radial vignette, and
    /// none of it moves when the planet turns — so drawing it per frame was
    /// two full-screen per-pixel gradient composites and several hundred
    /// ellipses, every frame, for a picture that was identical each time. Now
    /// it is one bitmap and one blit.
    private var sky: UIImage?
    private var skySize: CGSize = .zero
    private var skyScale: CGFloat = 0
    private var skyStyle: GlobeBackdropStyle?

    // MARK: - Setting up

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestures()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestures()
    }

    private func addGestures() {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        addGestureRecognizer(tap)
    }

    func apply(
        palette: GlobePalette,
        backdrop: GlobeBackdropStyle,
        scene: GlobeScene,
        revision: Int,
        showsPlanes: Bool,
        showsFields: Bool,
        sun: SIMD3<Float>?,
        replay: GlobeReplayMark?,
        start: CLLocationCoordinate2D,
        bottomInset: CGFloat,
        trailingInset: CGFloat,
        still: GlobeCamera?,
        command: GlobeCommand?
    ) {
        var changed = revision != self.revision
            || scene !== self.scene
            || showsPlanes != self.showsPlanes
            || showsFields != self.showsFields
            || sun != self.sun
            || replay != self.replay
            || palette != self.palette
            || backdrop != self.backdrop
            || still != self.still

        if palette != self.palette { labels.removeAll() }

        let insetsMoved = bottomInset != self.bottomInset || trailingInset != self.trailingInset

        self.palette = palette
        self.backdrop = backdrop
        self.scene = scene
        self.revision = revision
        self.showsPlanes = showsPlanes
        self.showsFields = showsFields
        self.sun = sun
        self.replay = replay
        self.start = start
        self.bottomInset = bottomInset
        self.trailingInset = trailingInset
        self.still = still

        // An opaque view has to have something behind the drawing during the
        // moment between a resize and the redraw, or the gap is undefined.
        backgroundColor = (backdrop.colors.first ?? .black).withAlphaComponent(1)

        if insetsMoved || still != nil { layoutCamera(); changed = true }
        if carryOut(command) { changed = true }

        guard changed else { return }
        setNeedsDisplay()
    }

    /// Points the planet where the chrome asked, once.
    private func carryOut(_ command: GlobeCommand?) -> Bool {
        guard let command = command, command.token != lastCommand else { return false }
        lastCommand = command.token

        camera.latitude = min(90, max(-90, command.latitude))
        camera.longitude = GlobeCamera.wrapped(command.longitude)

        if let wanted = command.scale {
            scale = min(GlobeCamera.maximumScale, max(GlobeCamera.minimumScale, wanted))
            camera.radius = fittedRadius * scale
        }
        return true
    }

    // MARK: - Laying it out

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutCamera()
    }

    /// Sizes the planet to the viewport and puts it in the middle of whatever
    /// the chrome is not standing on.
    ///
    /// The zoom is kept as a *multiple* rather than as a radius precisely so a
    /// resize survives it: turning the phone sideways keeps you as close to the
    /// ground as you were, rather than as many points from the middle as you
    /// were.
    private func layoutCamera() {
        if let still = still {
            camera = still
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }

        camera.center = CGPoint(
            x: (bounds.width - trailingInset) / 2,
            y: (bounds.height - bottomInset) / 2
        )
        camera.radius = fittedRadius * scale

        if !isReady {
            camera.latitude = start.latitude
            camera.longitude = GlobeCamera.wrapped(start.longitude)
            isReady = true
        }
        setNeedsDisplay()
    }

    /// The radius at which the whole planet sits inside the screen with room
    /// for the chrome over it.
    ///
    /// Floored, because the insets are heights of chrome measured independently
    /// of this view and nothing says they cannot add up to more than a short
    /// split screen — which would otherwise be a negative radius and a planet
    /// that is not drawn.
    private var fittedRadius: CGFloat {
        max(60, min(bounds.width - trailingInset, bounds.height - bottomInset) * 0.42)
    }

    // MARK: - Turning it

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            panOrigin = (camera.latitude, camera.longitude)
            beginInteraction()

        case .changed:
            guard let origin = panOrigin else { return }
            let moved = gesture.translation(in: self)

            // Started from the live camera, so the radius and the centre are
            // whatever a pinch running alongside this has made them, and only
            // the heading is wound back to where the drag began. `turn` scales
            // by the radius as well, so the ground keeps up with the fingertip
            // as the zoom changes under it.
            var turned = camera
            turned.latitude = origin.latitude
            turned.longitude = origin.longitude
            turned.turn(by: CGSize(width: moved.x, height: moved.y))
            camera = turned
            setNeedsDisplay()

        case .ended, .cancelled, .failed:
            panOrigin = nil
            endInteraction()

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStart = scale
            beginInteraction()

        case .changed:
            guard let base = pinchStart else { return }
            scale = min(
                GlobeCamera.maximumScale,
                max(GlobeCamera.minimumScale, base * gesture.scale)
            )
            camera.radius = fittedRadius * scale
            setNeedsDisplay()

        case .ended, .cancelled, .failed:
            pinchStart = nil
            endInteraction()

        default:
            break
        }
    }

    /// What was under the finger. Fields before aircraft: a field carries a
    /// label, so it is the larger target and the one somebody aiming at a
    /// cluster meant.
    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)

        if showsFields, let icao = field(near: point) {
            onSelectField?(icao)
            return
        }
        if let id = flight(near: point) {
            onSelectFlight?(id)
        }
    }

    private func beginInteraction() {
        updateResolution()
    }

    private func endInteraction() {
        guard !isInteracting else { return }
        updateResolution()
        setNeedsDisplay()
    }

    /// Draws at fewer pixels while a finger is down.
    ///
    /// The planet is rasterised on the CPU, so the cost of a frame is very
    /// nearly linear in its pixel count — and on a 3x phone that is nine pixels
    /// per point. Two thirds of them can go for as long as the world is
    /// actually moving, which is exactly when nobody is looking at the
    /// sharpness of a coastline, and come back the moment it stops.
    private func updateResolution() {
        let wanted = isInteracting ? min(displayScale, 2) : displayScale
        guard contentScaleFactor != wanted else { return }
        contentScaleFactor = wanted
    }

    private var displayScale: CGFloat {
        traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
    }

    // MARK: - What was tapped

    /// The aircraft nearest a tap, if one is near enough to have been meant.
    ///
    /// Against the projected position rather than the coordinate, because
    /// "near" means near on the screen: two aircraft a hundred miles apart at
    /// the limb are a couple of points apart, and the one that looks closest to
    /// the finger is the one that was aimed at.
    private func flight(near point: CGPoint) -> String? {
        let basis = camera.basis
        let reach = GlobeMarkMetrics.touchRadius

        var best: String?
        var bestDistance = reach * reach

        for dot in scene.traffic {
            let projected = camera.project(dot.position, using: basis)
            guard projected.isVisible else { continue }

            let dx = projected.point.x - point.x
            let dy = projected.point.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = dot.id
            }
        }
        return best
    }

    /// The field nearest a tap. Only the ones far enough onto the near side to
    /// have been drawn at something like full strength — a marker on ground
    /// turning away is not something to open by accident.
    private func field(near point: CGPoint) -> String? {
        let basis = camera.basis
        let reach = GlobeMarkMetrics.touchRadius

        var best: String?
        var bestDistance = reach * reach

        for field in scene.fields {
            let projected = camera.project(field.position, using: basis)
            guard projected.depth > GlobeMarkMetrics.tappableDepth else { continue }

            // Biased towards the label, which sits to the right of the ring and
            // is most of what there is to aim at.
            let dx = projected.point.x + GlobeMarkMetrics.fieldRingRadius - point.x
            let dy = projected.point.y - point.y
            let distance = dx * dx + dy * dy
            if distance < bestDistance {
                bestDistance = distance
                best = field.icao
            }
        }
        return best
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        drawSky(in: context)
        guard camera.radius > 0 else { return }

        let basis = camera.basis
        let detail = self.detail
        // Everything is rejected against this rather than against the disc: at
        // the top of the zoom range the planet is six times the width of the
        // screen, so most of the hemisphere facing you is still nowhere you can
        // see it. Inflated a little so a shape whose centre is just outside
        // still draws the part of it that is inside.
        let box = bounds.insetBy(dx: -24, dy: -24)

        drawHalo(in: context)
        drawSphere(in: context)

        if let land = palette.land {
            drawLand(in: context, basis: basis, detail: detail, color: land, box: box)
        }

        drawRings(GlobeGeometry.graticule, in: context, basis: basis,
                  color: palette.graticule, width: palette.graticuleWidth, box: box)
        drawRings(GlobeGeometry.borders(for: detail), in: context, basis: basis,
                  color: palette.border, width: palette.borderWidth, box: box)

        if let sun = sun {
            drawNight(in: context, basis: basis, sun: sun)
        }

        drawLines(in: context, basis: basis, box: box)
        drawLimb(in: context)
        drawTraffic(in: context, basis: basis, box: box)

        if showsFields {
            drawFields(in: context, basis: basis, box: box)
        }
    }

    /// How much border detail this frame is worth.
    ///
    /// Thresholds in points of sphere radius rather than in zoom multiples, so
    /// the answer is about how large the planet actually is on screen — which
    /// is the thing that decides whether a dropped point is visible — rather
    /// than about a phone's screen width.
    private var detail: GlobeGeometry.Detail {
        if isInteracting {
            if camera.radius > 1400 { return .medium }
            if camera.radius > 700 { return .coarse }
            return .rough
        }
        if camera.radius > 1600 { return .full }
        if camera.radius > 700 { return .medium }
        return .coarse
    }

    /// Whether the edge of the planet is anywhere the screen can see it.
    ///
    /// Past about four times zoom it is not: the disc is wider than the view,
    /// so the limb, the atmosphere round it and the whole radial gradient that
    /// draws them are outside the context entirely. Core Graphics would clip
    /// all of it away for nothing, having first built the gradient — and a
    /// full-screen radial gradient is one of the more expensive things there
    /// is to ask it for.
    ///
    /// True when the furthest corner of the view is beyond the inner edge of
    /// the halo, which is the only case where any part of either is visible.
    /// Whether the disc covers the whole view — so there is nothing to clip to
    /// it, and no edge of it to draw. The other side of the same question.
    private var isViewInsideDisc: Bool { !isLimbNearScreen }

    private var isLimbNearScreen: Bool {
        let dx = max(abs(bounds.minX - camera.center.x), abs(bounds.maxX - camera.center.x))
        let dy = max(abs(bounds.minY - camera.center.y), abs(bounds.maxY - camera.center.y))
        return (dx * dx + dy * dy).squareRoot() > camera.radius * 0.97
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

    /// Blits the sky, rendering it first if the size, the resolution or the
    /// backdrop has moved.
    ///
    /// Nothing behind the planet moves when the planet turns, so none of it
    /// belongs in a per-frame path. What used to happen here every frame was a
    /// full-screen linear gradient, up to seven hundred ellipses and a
    /// full-screen radial vignette — three per-pixel passes over the whole view
    /// to produce a picture identical to the one already on screen.
    private func drawSky(in context: CGContext) {
        if sky == nil || skySize != bounds.size || skyScale != displayScale
            || skyStyle != backdrop {
            makeSky()
        }

        guard let sky = sky else {
            context.setFillColor((backdrop.colors.first ?? .black).withAlphaComponent(1).cgColor)
            context.fill(bounds)
            return
        }
        sky.draw(at: .zero)
    }

    private func makeSky() {
        skySize = bounds.size
        skyScale = displayScale
        skyStyle = backdrop
        sky = nil

        guard bounds.width > 0, bounds.height > 0 else { return }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        // The screen's resolution rather than the view's current one. The view
        // drops to fewer pixels while a finger is down, and keying the sky to
        // that would throw this bitmap away and rebuild it — a full-screen
        // gradient and a starfield — at the exact moment a drag begins, which
        // is the one moment there is nothing spare. Drawing a 3x image into a
        // 2x context resamples it, which costs nothing and looks the same.
        format.scale = displayScale

        let box = CGRect(origin: .zero, size: bounds.size)
        sky = UIGraphicsImageRenderer(size: bounds.size, format: format).image { render in
            let context = render.cgContext

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

            if let colour = backdrop.stars { drawStars(in: context, over: box, color: colour) }
            if let colour = backdrop.vignette { drawVignette(in: context, over: box, color: colour) }
        }
    }

    /// Stars, fixed to the screen rather than to the sky.
    ///
    /// Which is a choice and not a shortcut. A starfield that turned with the
    /// planet would be a second thing moving under your finger, competing with
    /// the one you are actually turning; held still, it reads as a window.
    ///
    /// Generated from a fixed seed, so the sky is the same sky between
    /// rotations and between launches. A random one would twinkle.
    private func drawStars(in context: CGContext, over box: CGRect, color: UIColor) {
        // About one star per four thousand square points: dense enough to read
        // as a sky, sparse enough that it never competes with the traffic.
        let count = min(700, max(80, Int(box.width * box.height / 4000)))

        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
            // xorshift, which is a handful of instructions and repeatable
            // across platforms in a way `Double.random` is not.
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            return CGFloat(seed % 100_000) / 100_000
        }

        // Three brightnesses, three fills, rather than a state change per star.
        var bands: [CGMutablePath] = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
        for _ in 0..<count {
            let x = next() * box.width
            let y = next() * box.height
            let radius = 0.4 + next() * 0.9
            let band = min(2, Int(next() * 3))
            bands[band].addEllipse(in: CGRect(
                x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
            ))
        }

        for (band, path) in bands.enumerated() where !path.isEmpty {
            context.setFillColor(color.withAlphaComponent(0.25 + CGFloat(band) * 0.28).cgColor)
            context.addPath(path)
            context.fillPath()
        }
    }

    private func drawVignette(in context: CGContext, over box: CGRect, color: UIColor) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [color.withAlphaComponent(0).cgColor, color.cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }

        let centre = CGPoint(x: box.midX, y: box.midY)
        context.saveGState()
        context.clip(to: box)
        context.drawRadialGradient(
            gradient,
            startCenter: centre,
            startRadius: min(box.width, box.height) * 0.3,
            endCenter: centre,
            endRadius: max(box.width, box.height) * 0.75,
            options: [.drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    // MARK: - The planet

    private func drawSphere(in context: CGContext) {
        context.setFillColor(palette.ocean.cgColor)
        // Past a few times zoom the planet is wider than the screen, and the
        // ocean is then a rectangle. Asking Core Graphics for a two thousand
        // point antialiased ellipse to fill a view entirely inside it is a
        // full-resolution edge mask computed and thrown away.
        if isViewInsideDisc {
            context.fill(bounds)
        } else {
            context.fillEllipse(in: discBox)
        }
    }

    /// A ring of atmosphere just outside the limb.
    ///
    /// Outside rather than over: it is the air the planet is wrapped in, and
    /// laying it over the cartography would fog the coastlines at the edge —
    /// which are the ones already hardest to read.
    private func drawHalo(in context: CGContext) {
        guard let colour = palette.halo, isLimbNearScreen else { return }

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
        guard palette.limbWidth > 0, isLimbNearScreen else { return }
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
        color: UIColor,
        box: CGRect
    ) {
        let path = CGMutablePath()
        for ring in GlobeGeometry.borders(for: detail) where !isCulled(ring, basis: basis, box: box) {
            appendSilhouette(ring, to: path, basis: basis)
        }

        context.saveGState()
        if !isViewInsideDisc {
            context.addEllipse(in: discBox)
            context.clip()
        }
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

    /// Whether a ring is somewhere this frame cannot see, in two dot products
    /// and a rectangle test.
    ///
    /// ## Round the back
    ///
    /// One dot product for an entire country. Only sound for a ring that fits
    /// inside a hemisphere, which is what a positive `radiusCosine` means. A
    /// ring larger than that — a meridian, which wraps the planet — has no
    /// direction the camera can point away from far enough, and the test would
    /// cull it wrongly.
    ///
    /// ## Off the side of the screen
    ///
    /// The half that was missing, and the one that matters most. At the top of
    /// the zoom range the sphere is over two thousand points across on a screen
    /// four hundred wide, so nearly everything on the hemisphere facing you is
    /// still nowhere you can see it — and every one of those coastlines was
    /// being projected point by point and pathed anyway.
    ///
    /// The bound is exact rather than estimated. Every point of a ring lies
    /// within its cone's angular radius θ of the axis, so the straight-line
    /// distance between any two of them is at most 2·sin(θ/2); an orthographic
    /// projection cannot stretch that, so on screen the whole ring is inside a
    /// circle of radius R·√(2 − 2·cos θ) about the projected axis. A great
    /// circle has a cosine of −1, which gives 2R and never culls — which is the
    /// truth about a line that wraps the planet.
    private func isCulled(_ ring: GlobeGeometry.Ring, basis: GlobeCamera.Basis, box: CGRect) -> Bool {
        if ring.radiusCosine > 0 {
            let facing = simd_dot(ring.axis, basis.out)
            let reach = (1 - ring.radiusCosine * ring.radiusCosine).squareRoot()
            if facing < -reach { return true }
        }

        let spread = CGFloat((2 - 2 * ring.radiusCosine).squareRoot()) * camera.radius
        let centre = CGPoint(
            x: camera.center.x + CGFloat(simd_dot(ring.axis, basis.east)) * camera.radius,
            y: camera.center.y - CGFloat(simd_dot(ring.axis, basis.north)) * camera.radius
        )
        return !box.insetBy(dx: -spread, dy: -spread).contains(centre)
    }

    /// Every ring, clipped at the horizon.
    private func drawRings(
        _ rings: [GlobeGeometry.Ring],
        in context: CGContext,
        basis: GlobeCamera.Basis,
        color: UIColor,
        width: CGFloat,
        box: CGRect
    ) {
        guard width > 0 else { return }

        let path = CGMutablePath()
        for ring in rings where !isCulled(ring, basis: basis, box: box) {
            append(ring.points, to: path, basis: basis, box: box)
        }

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func drawLines(in context: CGContext, basis: GlobeCamera.Basis, box: CGRect) {
        guard !scene.lines.isEmpty else { return }

        for line in scene.lines {
            let path = CGMutablePath()
            append(line.points, to: path, basis: basis, box: box)

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
        basis: GlobeCamera.Basis,
        box: CGRect
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
                // A segment with nothing in the view. The ring-level cull
                // cannot catch these: a meridian is a great circle, so its
                // bounding cone reaches everywhere and it is never rejected as
                // a whole — and zoomed in, eleven of the twelve are off the
                // side of the screen with all ninety-one of their points being
                // projected and pathed regardless. The same goes for any
                // coastline long enough to straddle the view.
                //
                // Compared as boxes rather than as a proper segment-rectangle
                // intersection: it keeps the occasional diagonal that misses
                // the corner, which costs one line, where getting the crossing
                // test subtly wrong costs a coastline.
                if max(last.point.x, now.point.x) < box.minX
                    || min(last.point.x, now.point.x) > box.maxX
                    || max(last.point.y, now.point.y) < box.minY
                    || min(last.point.y, now.point.y) > box.maxY {
                    isDrawing = false
                    previousVector = point
                    previous = now
                    continue
                }

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
        if !isViewInsideDisc {
            context.addEllipse(in: discBox)
            context.clip()
        }
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

    private func drawTraffic(in context: CGContext, basis: GlobeCamera.Basis, box: CGRect) {
        guard !scene.traffic.isEmpty || replay != nil else { return }

        // The setting, and nothing else.
        //
        // This used to fall back to dots above sixteen hundred aircraft in the
        // packet, and again above four hundred while a finger was down. Both
        // were counts of the *server*, not of what is on screen — so on any
        // busy server the artwork never appeared at all, and on a quiet one it
        // turned into dots the moment you touched the planet. Which is a
        // setting that says "aircraft shapes" and draws dots, and it is the
        // reason the planet did not look like the map.
        //
        // What actually bounds the work is the screen rejection below: only
        // aircraft you can see are drawn, at any zoom.
        if showsPlanes {
            drawPlanes(in: context, basis: basis, box: box)
        } else {
            drawDots(in: context, basis: basis, box: box)
        }
    }

    /// How large an aircraft is drawn.
    ///
    /// The map's own size once there is room for it, and smaller with the whole
    /// planet on screen — where a full-size silhouette is a third the width of
    /// a country and a packet of them is a texture rather than traffic. It is
    /// also the blit: two thirds of the width is half the pixels, several
    /// hundred times a frame, at exactly the zoom where there are most of them.
    ///
    /// Two sizes rather than a curve, so the icon cache holds two entries per
    /// airframe instead of a fresh one per zoom level.
    private var spriteSize: CGFloat {
        camera.radius > 520 ? palette.planeSize : palette.planeSize * 0.72
    }

    private func drawPlanes(
        in context: CGContext,
        basis: GlobeCamera.Basis,
        box: CGRect
    ) {
        let sprites = PlaneSprites.shared
        let size = spriteSize
        var open: [(CGPoint, CGFloat, GlobeTrafficDot)] = []

        // Walked by index rather than by element, which is not a style choice.
        // A `GlobeTrafficDot` carries two `String`s and a `UIColor?`, so binding
        // one per iteration retains and releases three references — a packet of
        // three thousand at sixty frames a second is over half a million
        // retain/release pairs a second to read two vectors. Reading the fields
        // individually touches the reference-counted ones only for the aircraft
        // that survive the cull, which when zoomed in is a handful of them.
        let traffic = scene.traffic
        for index in traffic.indices {
            let projected = camera.project(traffic[index].position, using: basis)
            guard projected.isVisible, box.contains(projected.point) else { continue }

            // Two dot products for the sprite's angle. The heading is a
            // direction on the surface, and an orthographic projection is
            // linear, so where that direction lands on screen is the projection
            // of the direction itself — no second point to project and
            // subtract.
            let dx = CGFloat(simd_dot(traffic[index].heading, basis.east))
            let dy = -CGFloat(simd_dot(traffic[index].heading, basis.north))
            let angle = atan2(dx, -dy)

            if traffic[index].isOpen {
                // A playback is driving this aeroplane, so where the feed
                // last saw it is not where it is being shown. Dropped here
                // and drawn from the frame below.
                if replay == nil { open.append((projected.point, angle, traffic[index])) }
                continue
            }

            draw(traffic[index], at: projected.point, angle: angle,
                 size: size, in: context, sprites: sprites)
        }

        if let replay = replay {
            let projected = camera.project(replay.position, using: basis)
            if projected.isVisible {
                let dx = CGFloat(simd_dot(replay.heading, basis.east))
                let dy = -CGFloat(simd_dot(replay.heading, basis.north))
                open.append((projected.point, atan2(dx, -dy), GlobeTrafficDot(
                    id: "replay",
                    position: replay.position,
                    heading: replay.heading,
                    spriteKey: replay.spriteKey,
                    tint: nil,
                    isOpen: true
                )))
            }
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
        // The map's own aircraft, in the map's own colours.
        //
        // These used to be painted in `palette.traffic` against a derived
        // outline, which made a planet full of aeroplanes that were the same
        // colour as the coastlines and a different colour from the ones on the
        // map you had just come from. The whole point of drawing artwork rather
        // than dots is that it is the artwork you already recognise, so the
        // colours are the map's too: light body, dark outline, and the same
        // amber for the aircraft whose window is open.
        //
        // The palette still gets its say where it has one to have: a watched
        // pilot's tint is a fact about that pilot, not about the map.
        guard let image = sprites.planetIcon(
            forKey: dot.spriteKey,
            pointSize: size,
            body: dot.tint,
            selected: dot.isOpen
        ) else { return }

        context.saveGState()
        context.translateBy(x: point.x, y: point.y)
        context.rotate(by: angle)
        image.draw(at: CGPoint(x: -image.size.width / 2, y: -image.size.height / 2))
        context.restoreGState()
    }

    private func drawDots(
        in context: CGContext,
        basis: GlobeCamera.Basis,
        box: CGRect
    ) {
        // Grouped by colour, so a packet of three thousand aircraft is a
        // handful of fills rather than one state change apiece. An array rather
        // than a dictionary: there are rarely more than three colours on a
        // planet, and a linear walk of three beats hashing a `UIColor` per
        // aircraft.
        var groups: [(colour: UIColor, path: CGMutablePath)] = []
        var open: [CGPoint] = []
        let size = palette.dotRadius

        let traffic = scene.traffic
        for index in traffic.indices {
            let projected = camera.project(traffic[index].position, using: basis)
            guard projected.isVisible, box.contains(projected.point) else { continue }

            if traffic[index].isOpen {
                if replay == nil { open.append(projected.point) }
                continue
            }

            let colour = traffic[index].tint ?? palette.traffic
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

        if let replay = replay {
            let projected = camera.project(replay.position, using: basis)
            if projected.isVisible { open.append(projected.point) }
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
    private func drawFields(in context: CGContext, basis: GlobeCamera.Basis, box: CGRect) {
        let fields = scene.fields
        guard !fields.isEmpty else { return }

        let ring = GlobeMarkMetrics.fieldRingRadius
        let dot = GlobeMarkMetrics.fieldDotRadius

        // Rendered before the drawing starts rather than as each one is
        // reached. A label is drawn into an image renderer, which pushes a
        // context of its own, and doing that in the middle of a run of state
        // changes on this one is the kind of thing that works until it doesn't.
        // Cached across frames, so this is a dictionary lookup after the first.
        for field in fields { _ = labelImage(field.icao) }

        for field in fields {
            let projected = camera.project(field.position, using: basis)
            guard projected.depth > 0.02, box.contains(projected.point) else { continue }

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

extension GlobeCanvasView: UIGestureRecognizerDelegate {

    /// Turning and zooming are one movement as far as a hand is concerned, and
    /// a planet that stopped turning the moment a second finger landed would be
    /// a planet that fights you.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
