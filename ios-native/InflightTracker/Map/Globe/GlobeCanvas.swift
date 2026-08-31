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
    /// Where the planet has settled, and how much ground is across the short
    /// side of it in metres. What lets the layer above go and find the field
    /// the camera is over — see `PlanetSurface.syncGround`.
    var onCameraMoved: ((CLLocationCoordinate2D, Double) -> Void)? = nil

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
        view.onCameraMoved = onCameraMoved
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
    var onCameraMoved: ((CLLocationCoordinate2D, Double) -> Void)?

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

    /// What the fingers are doing.
    ///
    /// The pan is applied as the *change* since the last update rather than as
    /// the whole translation since the drag began, which is why there is no
    /// origin here any more. The old arrangement wound the heading back to the
    /// start of the drag on every frame and re-applied everything, and it had
    /// to hold a separate origin so that a pinch running alongside it was not
    /// undone sixty times a second. Deltas have no such problem: each one is
    /// applied to whatever the camera is now, so a pinch and a drag simply
    /// compose, and `GlobeCamera.drag` gets to use the latitude you are
    /// actually at when it decides what a point of screen is worth.
    private var isPanning = false

    /// Whether two fingers are running a pinch, and what was under them when
    /// it began — so the ground between them stays between them. The pinch
    /// tracks its own midpoint, which *is* a two-finger drag, so while it is
    /// live it owns the translation as well and the pan stands off. See
    /// `pin(_:at:)`.
    private var isPinching = false
    private var pinchAnchor: SIMD3<Float>?

    /// A flick, in points a second, decaying. Nil when the planet is still.
    private var momentum: CGVector?

    /// A zoom being animated by a tap: where it is going, and how far through.
    private var zoomFrom: CGFloat = 0
    private var zoomTo: CGFloat = 0
    private var zoomAnchor: SIMD3<Float>?
    private var zoomPoint: CGPoint = .zero
    private var zoomProgress: Double = 0

    private var isZooming: Bool { zoomProgress > 0 && zoomProgress < 1 }

    /// Drives the glide and the tap zoom. Nil whenever neither is running, so
    /// a still planet costs nothing.
    private var animator: CADisplayLink?

    /// Whether the planet is moving, by a finger or by its own momentum. What
    /// decides the drawing resolution.
    private var isInteracting: Bool {
        isPanning || isPinching || momentum != nil || isZooming
    }

    /// Whether this planet is one you can turn, rather than a swatch drawn
    /// from a camera it was handed.
    private var isLive: Bool { still == nil }

    // MARK: - Caches

    /// Field codes, rendered once each. Cleared when the palette changes, which
    /// is the only thing that can make one wrong.
    private var labels: [String: UIImage] = [:]

    /// Scratch for the land fill: one landmass projected, and the same one
    /// part way through being clipped. Held by the view rather than made per
    /// ring, so a frame that walks three hundred coastlines does not allocate
    /// six hundred arrays to throw all of them away — `removeAll(keepingCapacity:)`
    /// keeps whatever the largest country needed.
    private var outline: [CGPoint] = []
    private var trimmed: [CGPoint] = []

    /// The traffic, projected. Held by the view for the same reason the land
    /// scratch is: a packet is three thousand of these and they are rebuilt
    /// every frame of every gesture.
    private var marks: [(index: Int, point: CGPoint, angle: CGFloat)] = []

    /// The sky, rendered once per resolution it is drawn at.
    ///
    /// It is a gradient, up to seven hundred stars and a radial vignette, and
    /// none of it moves when the planet turns — so drawing it per frame was
    /// two full-screen per-pixel gradient composites and several hundred
    /// ellipses, every frame, for a picture that was identical each time. Now
    /// it is one bitmap and one blit.
    ///
    /// Keyed by scale, and that key is the whole difference between a blit and
    /// a resample. The view drops to two pixels a point while a finger is down
    /// (see `updateResolution`), and one bitmap held at the screen's three had
    /// to be scaled down into that context on *every frame of every gesture* —
    /// a three megapixel interpolation, on the CPU, at the one moment there is
    /// nothing spare. It is a straight copy when the two agree, so the two are
    /// made to agree: a second bitmap, built once the first time a finger
    /// lands, is a couple of megabytes against several milliseconds a frame.
    private var skies: [CGFloat: UIImage] = [:]
    private var skySize: CGSize = .zero
    private var skyStyle: GlobeBackdropStyle?

    // MARK: - Setting up

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestures()
        watchMemory()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addGestures()
        watchMemory()
    }

    /// Two full-screen backdrops is a few megabytes worth having and not worth
    /// keeping through a squeeze. Both rebuild themselves on the next frame,
    /// and the frame after a memory warning is not one anybody is pinching.
    private func watchMemory() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dropCaches),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func dropCaches() {
        skies.removeAll()
        labels.removeAll()
    }

    /// A `CADisplayLink` holds its target, and the runloop holds the link — so
    /// a planet taken off screen mid-glide would go on turning, and go on
    /// existing, for as long as the app did.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else { return }
        momentum = nil
        zoomProgress = 0
        zoomAnchor = nil
        stopAnimator()
    }

    deinit { animator?.invalidate() }

    /// The same set of gestures Maps has, because this is a map.
    private func addGestures() {
        // Two fingers as well as one. A pinch that has drifted into a drag is
        // one movement to a hand, and refusing the second finger is how a map
        // starts feeling like a diagram of a map.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        addGestureRecognizer(doubleTap)

        let twoFingerTap = UITapGestureRecognizer(
            target: self, action: #selector(handleTwoFingerTap)
        )
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self
        addGestureRecognizer(twoFingerTap)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.delegate = self
        // Opening an aircraft waits to find out whether a second tap is
        // coming. Which is the trade Maps makes as well, and the alternative
        // is a double tap that opens whatever was under the first of the two.
        tap.require(toFail: doubleTap)
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
            scale = clamped(wanted)
            camera.radius = fittedRadius * scale
        }
        reportCamera()
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
        // Re-clamped rather than carried over. The zoom is a multiple of the
        // fitted radius and the ceiling is a distance across the ground, so a
        // rotation or a split screen changes what the same multiple means.
        scale = clamped(scale)
        camera.radius = fittedRadius * scale

        if !isReady {
            camera.latitude = start.latitude
            camera.longitude = GlobeCamera.wrapped(start.longitude)
            isReady = true
        }
        reportCamera()
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

    /// How close the planet may be pushed in, as a zoom multiple.
    ///
    /// Worked out from a distance across the ground rather than stored, so the
    /// same rule gives the same closest approach on every screen. See
    /// `GlobeCamera.minimumSpanMetres`.
    private var maximumScale: CGFloat {
        let fitted = fittedRadius
        guard fitted > 0 else { return 1 }
        let across = max(120, min(bounds.width - trailingInset, bounds.height - bottomInset))
        let closest = GlobeCamera.radius(forSpan: GlobeCamera.minimumSpanMetres, across: across)
        return max(GlobeCamera.minimumScale, closest / fitted)
    }

    private func clamped(_ wanted: CGFloat) -> CGFloat {
        min(maximumScale, max(GlobeCamera.minimumScale, wanted))
    }

    /// The direction on the sphere under a point of screen, if the planet is
    /// there to be under it.
    ///
    /// The inverse of the orthographic projection: the screen offset is the
    /// sine of the angle from the middle, so the depth is what is left of the
    /// unit vector. Off the disc there is no ground under the finger and the
    /// answer is nothing.
    private func direction(at point: CGPoint) -> SIMD3<Float>? {
        guard camera.radius > 0 else { return nil }
        let u = Float((point.x - camera.center.x) / camera.radius)
        let v = Float((camera.center.y - point.y) / camera.radius)
        let flat = u * u + v * v
        guard flat < 0.9801 else { return nil }

        let basis = camera.basis
        let depth = (1 - flat).squareRoot()
        return simd_normalize(basis.east * u + basis.north * v + basis.out * depth)
    }

    /// Turns the camera so `anchor` sits under `point`.
    ///
    /// ## Why a zoom needs this at all
    ///
    /// A pinch used to change the radius and nothing else, which zooms about
    /// the middle of the screen — so whatever you had put your fingers on slid
    /// away from them, and to look at something off-centre you had to zoom,
    /// drag it back, and zoom again. Maps has never worked that way: the
    /// ground between your fingers is the one part of the map that does not
    /// move. This is what makes that true here, and it is what a double tap
    /// and a two-finger tap zoom about as well.
    ///
    /// ## Solved rather than searched for
    ///
    /// Stepping towards the answer with the same drag a finger uses does not
    /// work: `drag` is exact for the middle of the screen and the anchor is
    /// not in the middle, so near the limb — where the projection is most
    /// compressed — it converges slowly or overshoots, and a pinch that
    /// overshoots throws the planet across the screen.
    ///
    /// It does not need searching for. Writing the anchor in the camera's own
    /// frame, `A = u·east + v·north + w·out`, and taking the vertical
    /// component gives `A.z = v·cos φ + w·sin φ` — one equation in the
    /// latitude alone, because `east` is horizontal and contributes nothing to
    /// it. `A·east = u` then gives the longitude the same way. Two roots each,
    /// so four candidate cameras; the one that projects the anchor where it
    /// was asked for, and moves least doing it, is the answer. Exact, and the
    /// same handful of arithmetic every time.
    ///
    /// ## What cannot be done
    ///
    /// `east` being horizontal is also a real limit: `|A·east|` can never
    /// exceed the cosine of the anchor's own latitude, so a point near a pole
    /// cannot be pushed far off the middle of the screen by any camera that
    /// does not roll — and this one deliberately does not, so that north stays
    /// up. The target is clamped into what is reachable rather than refused,
    /// which makes the ground slide under the fingers instead of stopping
    /// dead. Zooming *in*, it never binds at all.
    private func pin(_ anchor: SIMD3<Float>, at point: CGPoint) {
        guard camera.radius > 0 else { return }

        let ax = Double(anchor.x), ay = Double(anchor.y), az = Double(anchor.z)

        // The cosine of the anchor's own latitude, which is how far off the
        // middle of the screen it can be put.
        let ring = (ax * ax + ay * ay).squareRoot()
        guard ring > 1e-6 else { return }

        var u = Double((point.x - camera.center.x) / camera.radius)
        var v = Double((camera.center.y - point.y) / camera.radius)

        // Onto the disc first, then into what this anchor can reach.
        let flat = u * u + v * v
        if flat > 0.9604 {
            let pull = 0.98 / flat.squareRoot()
            u *= pull
            v *= pull
        }
        if abs(u) > ring {
            u = u < 0 ? -ring : ring
            let room = max(0, 0.9604 - u * u).squareRoot()
            if abs(v) > room { v = v < 0 ? -room : room }
        }

        let depth = max(0, 1 - u * u - v * v).squareRoot()
        let column = max(1e-12, 1 - u * u).squareRoot()
        guard abs(az) <= column else { return }

        let phase = atan2(depth, v)
        let spread = acos(max(-1, min(1, az / column)))
        let swing = atan2(ax, ay)
        let offset = acos(max(-1, min(1, u / ring)))

        let target = CGPoint(
            x: camera.center.x + CGFloat(u) * camera.radius,
            y: camera.center.y - CGFloat(v) * camera.radius
        )

        var best: (latitude: Double, longitude: Double)?
        var least = Double.infinity

        for radians in [phase + spread, phase - spread] {
            let latitude = GlobeCamera.wrapped(radians * 180 / .pi)
            guard abs(latitude) <= 90.000001 else { continue }

            for turn in [offset - swing, -offset - swing] {
                var trial = camera
                trial.latitude = latitude
                trial.longitude = GlobeCamera.wrapped(turn * 180 / .pi)

                let landed = trial.project(anchor, using: trial.basis)
                guard landed.depth > 0 else { continue }

                let dx = Double(landed.point.x - target.x)
                let dy = Double(landed.point.y - target.y)
                guard dx * dx + dy * dy < 0.25 else { continue }

                let moved = abs(trial.latitude - camera.latitude)
                    + abs(GlobeCamera.wrapped(trial.longitude - camera.longitude))
                if moved < least {
                    least = moved
                    best = (trial.latitude, trial.longitude)
                }
            }
        }

        // Nothing landed, or the only answer is most of a planet away: leave
        // the camera where it is rather than have it jump.
        guard let best = best, least <= Self.pinLimit else { return }
        camera.latitude = best.latitude
        camera.longitude = best.longitude
    }

    /// How far the camera may be moved by a single pin, in degrees. A pinch
    /// step is a fraction of one; anything approaching this is the far root of
    /// the same equation, and taking it would be a teleport.
    private static let pinLimit: Double = 45

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            isPanning = true
            momentum = nil
            gesture.setTranslation(.zero, in: self)
            beginInteraction()

        case .changed:
            // Read and reset, so what arrives is the change since the last
            // frame rather than the whole drag re-applied.
            let moved = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)

            // A live pinch is already following the midpoint of the same two
            // fingers, and that midpoint moving is this translation. Applying
            // both would move the planet twice as far as the hand did.
            guard !isPinching else { return }

            camera.drag(by: CGSize(width: moved.x, height: moved.y))
            setNeedsDisplay()

        case .ended, .cancelled, .failed:
            isPanning = false
            // A flick keeps going. The planet used to stop dead under your
            // fingertip, which is the other half of what made this not feel
            // like a map — everything on iOS that scrolls, glides.
            let velocity = gesture.velocity(in: self)
            let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            if gesture.state == .ended, !isPinching, speed > Self.glideThreshold {
                momentum = CGVector(dx: velocity.x, dy: velocity.y)
                runAnimator()
            }
            endInteraction()

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            momentum = nil
            isPinching = true
            pinchAnchor = direction(at: gesture.location(in: self))
            gesture.scale = 1
            beginInteraction()

        case .changed:
            // Incremental, like the pan: the factor since the last frame,
            // applied to wherever the zoom is now.
            let factor = gesture.scale
            gesture.scale = 1
            guard factor > 0 else { return }

            scale = clamped(scale * factor)
            camera.radius = fittedRadius * scale

            // Two fingers name a point on the map, and that point stays under
            // them — through the zoom and as the midpoint itself moves.
            if let anchor = pinchAnchor {
                pin(anchor, at: gesture.location(in: self))
            }
            setNeedsDisplay()

        case .ended, .cancelled, .failed:
            isPinching = false
            pinchAnchor = nil
            endInteraction()

        default:
            break
        }
    }

    /// Double tap to come in, the way it does everywhere else on iOS.
    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        momentum = nil
        begin(zoomTo: scale * 2, around: gesture.location(in: self))
    }

    /// Two fingers, one tap, to go back out. The other half of the pair.
    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        momentum = nil
        begin(zoomTo: scale * 0.5, around: gesture.location(in: self))
    }

    private func begin(zoomTo wanted: CGFloat, around point: CGPoint) {
        let target = clamped(wanted)
        guard abs(target - scale) > 0.0001 else { return }

        zoomFrom = scale
        zoomTo = target
        zoomAnchor = direction(at: point)
        zoomPoint = point
        zoomProgress = 0.0001
        updateResolution()
        runAnimator()
    }

    /// How fast a flick has to be to keep going, in points a second.
    private static let glideThreshold: CGFloat = 90

    /// What is left of a flick after a second. Slower than a scroll view's,
    /// because a planet has more of itself to show you than a list does.
    private static let glideDecayPerSecond: CGFloat = 0.0015

    private static let zoomDuration: Double = 0.28

    private func runAnimator() {
        guard animator == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        animator = link
    }

    private func stopAnimator() {
        animator?.invalidate()
        animator = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let elapsed = max(1.0 / 120, min(1.0 / 20, link.targetTimestamp - link.timestamp))

        if isZooming {
            zoomProgress = min(1, zoomProgress + elapsed / Self.zoomDuration)
            // Eased, so a tap zoom arrives rather than stops.
            let t = zoomProgress
            let eased = CGFloat(t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2)
            scale = zoomFrom + (zoomTo - zoomFrom) * eased
            camera.radius = fittedRadius * scale
            if let anchor = zoomAnchor { pin(anchor, at: zoomPoint) }
            if zoomProgress >= 1 { zoomAnchor = nil }
        }

        if var flick = momentum {
            camera.drag(by: CGSize(
                width: flick.dx * CGFloat(elapsed),
                height: flick.dy * CGFloat(elapsed)
            ))
            let decay = CGFloat(pow(Double(Self.glideDecayPerSecond), elapsed))
            flick.dx *= decay
            flick.dy *= decay
            let speed = (flick.dx * flick.dx + flick.dy * flick.dy).squareRoot()
            momentum = speed > 12 ? flick : nil
        }

        setNeedsDisplay()

        if !isZooming && momentum == nil {
            stopAnimator()
            endInteraction()
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
        reportCamera()
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

    // MARK: - Saying where it is

    /// The last place reported, so a settle that has not moved says nothing.
    private var reported: (latitude: Double, longitude: Double, span: Double)?

    /// Tells whoever is listening where the planet is now pointed.
    ///
    /// Only when it has settled, and only when it has actually gone somewhere.
    /// The camera deliberately lives down here rather than in SwiftUI state,
    /// and reporting it per frame would put it straight back — so this is the
    /// one wire back up, and it carries a place rather than a camera.
    ///
    /// Asked for on the next runloop turn because a settle can happen inside a
    /// layout pass, and answering it there is a SwiftUI state change in the
    /// middle of a SwiftUI update.
    private func reportCamera() {
        guard let report = onCameraMoved, camera.radius > 0 else { return }

        let across = max(1, min(bounds.width - trailingInset, bounds.height - bottomInset))
        let span = camera.metresPerPoint * Double(across)
        let here = (latitude: camera.latitude, longitude: camera.longitude, span: span)

        if let last = reported {
            let metresPerDegree = GlobeCamera.earthRadiusMetres * .pi / 180
            let north = (here.latitude - last.latitude) * metresPerDegree
            let east = GlobeCamera.wrapped(here.longitude - last.longitude)
                * metresPerDegree * cos(here.latitude * .pi / 180)
            let moved = (north * north + east * east).squareRoot()

            // Less than a sixth of a screen, and less than a tenth of a zoom
            // step: nothing downstream would answer any differently.
            if moved < span * 0.16, abs(span - last.span) < last.span * 0.1 { return }
        }

        reported = here
        let centre = CLLocationCoordinate2D(latitude: here.latitude, longitude: here.longitude)
        DispatchQueue.main.async { report(centre, span) }
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
        let reach = visibleAngle

        drawHalo(in: context)
        drawSphere(in: context)

        if let land = palette.land {
            drawLand(in: context, basis: basis, detail: detail,
                     color: land, box: box, reach: reach)
        }

        drawRings(GlobeGeometry.graticule, in: context, basis: basis,
                  color: palette.graticule, width: palette.graticuleWidth,
                  box: box, reach: reach)
        drawRings(GlobeGeometry.borders(for: detail), in: context, basis: basis,
                  color: palette.border, width: palette.borderWidth,
                  box: box, reach: reach)

        // Pavement over the cartography and under everything that flies. It is
        // the ground, and at the zoom where it is drawn at all it is the only
        // thing on screen that is.
        drawGround(in: context, basis: basis, box: box)

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
    ///
    /// ## Lifting a finger does not change the picture
    ///
    /// This used to answer one level coarser for the whole zoom range while a
    /// gesture was running, and cross its thresholds at different radii than
    /// the resting answer did. Which meant every pinch redrew the cartography
    /// two or three times on the way — coastlines changing shape under your
    /// fingers, and changing again when you let go. That is the "it redraws
    /// parts of itself" the globe was doing, and none of it was a dropped
    /// frame.
    ///
    /// So the level now follows the radius and nothing else, except at the
    /// very bottom of the range: below about a third more than a fitted
    /// planet, a country is thirty points across and the sixth-point outline
    /// is the same drawing to within well under a pixel. Everywhere else,
    /// what you get while you are moving is what you get when you stop —
    /// which is affordable because the clipping in `appendSilhouette` and the
    /// culling in `isCulled` mean a zoomed-in frame walks the coastline you
    /// can see rather than the whole hemisphere.
    private var detail: GlobeGeometry.Detail {
        if camera.radius > 1400 { return .full }
        if camera.radius > 620 { return .medium }
        if camera.radius > 260 { return .coarse }
        return isInteracting ? .rough : .coarse
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
        // Zoomed in far enough that the planet is wider than the screen, there
        // is no sky on screen at all: `drawSphere` fills the whole view with
        // ocean a moment later, over every pixel of this. A full-screen
        // composite, per frame, entirely underneath an opaque fill — and it is
        // the frames at the top of the zoom range that have least to spare.
        //
        // On the radius as well as on the disc, because a view is inside a
        // sphere of no size and there would then be nothing drawn at all.
        if camera.radius > 0, isViewInsideDisc { return }

        if skySize != bounds.size || skyStyle != backdrop { skies.removeAll() }

        let scale = contentScaleFactor > 0 ? contentScaleFactor : displayScale
        if skies[scale] == nil {
            // Every resolution this view will ask for, built together. The
            // reduced one is wanted on the first frame of the first gesture,
            // and a full-screen gradient and a starfield built on *that* frame
            // is the hitch the cache exists to remove — so it is built now,
            // while nothing is moving, alongside the one being drawn.
            for wanted in Set([scale, displayScale, min(displayScale, 2)]) {
                makeSky(scale: wanted)
            }
        }

        guard let sky = skies[scale] else {
            context.setFillColor((backdrop.colors.first ?? .black).withAlphaComponent(1).cgColor)
            context.fill(bounds)
            return
        }
        sky.draw(at: .zero)
    }

    @discardableResult
    private func makeSky(scale: CGFloat) -> UIImage? {
        skySize = bounds.size
        skyStyle = backdrop

        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = true
        // The resolution this frame is actually being drawn at, so the blit is
        // a copy rather than an interpolation. There are two of them at most —
        // the screen's own, and the reduced one a gesture drops to.
        format.scale = scale

        let box = CGRect(origin: .zero, size: bounds.size)
        let sky = UIGraphicsImageRenderer(size: bounds.size, format: format).image { render in
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

        skies[scale] = sky
        return sky
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
        box: CGRect,
        reach: Float
    ) {
        let path = CGMutablePath()
        for ring in GlobeGeometry.borders(for: detail)
        where !isCulled(ring, basis: basis, box: box, reach: reach) {
            appendSilhouette(ring, to: path, basis: basis, box: box)
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

    /// One landmass, projected and then trimmed to the view.
    ///
    /// ## Why the trimming has to happen here
    ///
    /// The stroked cartography rejects segment by segment inside `append`, and
    /// a fill cannot: dropping a piece of an outline does not remove a piece
    /// of the shape, it changes which side of the remaining outline is inside.
    /// So the land was the one thing still paying the whole-hemisphere price
    /// at every zoom. At the top of the range the sphere is over two thousand
    /// points across on a four hundred point screen, and Russia, Canada,
    /// Antarctica and Asia are all far too large for `isCulled` to reject —
    /// their outlines went into the path in full, thousands of edges of them,
    /// to fill a screen showing one bay.
    ///
    /// ## Sutherland–Hodgman, against the view
    ///
    /// Clipping the closed polygon to the view rectangle is the answer that
    /// keeps the fill exactly right. Each of the four half-plane passes
    /// replaces the parts of the loop lying outside with a run along the
    /// boundary line itself — and an excursion together with the run that
    /// replaces it is a closed loop lying entirely on the far side, which any
    /// point inside the rectangle is outside of. So its winding about anything
    /// you can see is zero, and every point of the view is filled exactly as
    /// it was before. A country that surrounds the screen comes out as the
    /// rectangle, which is the truth: all of it is land.
    ///
    /// What it costs is four passes over a ring's points; what it saves is the
    /// path and the scan conversion, which is where the frame was going. A
    /// ring that lies entirely inside the view — which at the bottom of the
    /// zoom range is all of them — skips the whole thing on one flag.
    private func appendSilhouette(
        _ ring: GlobeGeometry.Ring,
        to path: CGMutablePath,
        basis: GlobeCamera.Basis,
        box: CGRect
    ) {
        outline.removeAll(keepingCapacity: true)
        var strays = false

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
            if screen.x < box.minX || screen.x > box.maxX
                || screen.y < box.minY || screen.y > box.maxY {
                strays = true
            }
            outline.append(screen)
        }

        if strays {
            trim(outline, into: &trimmed,
                 inside: { $0.x >= box.minX },
                 crossing: { Self.split($0, $1, atX: box.minX) })
            trim(trimmed, into: &outline,
                 inside: { $0.x <= box.maxX },
                 crossing: { Self.split($0, $1, atX: box.maxX) })
            trim(outline, into: &trimmed,
                 inside: { $0.y >= box.minY },
                 crossing: { Self.split($0, $1, atY: box.minY) })
            trim(trimmed, into: &outline,
                 inside: { $0.y <= box.maxY },
                 crossing: { Self.split($0, $1, atY: box.maxY) })
        }

        guard outline.count > 2 else { return }
        path.addLines(between: outline)
        path.closeSubpath()
    }

    /// One half-plane pass: everything on the wrong side of a line, replaced by
    /// a run along the line.
    private func trim(
        _ input: [CGPoint],
        into output: inout [CGPoint],
        inside: (CGPoint) -> Bool,
        crossing: (CGPoint, CGPoint) -> CGPoint
    ) {
        output.removeAll(keepingCapacity: true)
        guard var previous = input.last else { return }
        var wasInside = inside(previous)

        for point in input {
            let nowInside = inside(point)
            if nowInside != wasInside { output.append(crossing(previous, point)) }
            if nowInside { output.append(point) }
            previous = point
            wasInside = nowInside
        }
    }

    /// Where the segment between two points meets a vertical or a horizontal
    /// line. Only ever called for a pair straddling it, so the divisor is not
    /// zero — and guarded anyway, because a coastline is data.
    private static func split(_ a: CGPoint, _ b: CGPoint, atX x: CGFloat) -> CGPoint {
        let span = b.x - a.x
        guard abs(span) > .ulpOfOne else { return CGPoint(x: x, y: a.y) }
        return CGPoint(x: x, y: a.y + (b.y - a.y) * (x - a.x) / span)
    }

    private static func split(_ a: CGPoint, _ b: CGPoint, atY y: CGFloat) -> CGPoint {
        let span = b.y - a.y
        guard abs(span) > .ulpOfOne else { return CGPoint(x: a.x, y: y) }
        return CGPoint(x: a.x + (b.x - a.x) * (y - a.y) / span, y: y)
    }

    // MARK: - Lines on it

    /// How much of the sphere this frame can see, as an angle from the point
    /// facing the camera.
    ///
    /// The projection is a sine, so a screen offset of `d` from the middle of
    /// the disc is `asin(d/R)` of ground. Take the furthest corner of the view
    /// and that is the whole visible cap — which at the top of the zoom range
    /// is a couple of hundredths of a degree, and is the number that makes
    /// culling work at a zoom where nothing else does.
    private var visibleAngle: Float {
        guard camera.radius > 0 else { return .pi }
        let dx = max(abs(bounds.minX - camera.center.x), abs(bounds.maxX - camera.center.x))
        let dy = max(abs(bounds.minY - camera.center.y), abs(bounds.maxY - camera.center.y))
        let corner = (dx * dx + dy * dy).squareRoot() + 24
        guard corner < camera.radius else { return .pi / 2 }
        return Float(asin(corner / camera.radius))
    }

    /// Whether a ring is somewhere this frame cannot see, in two dot products
    /// and a rectangle test.
    ///
    /// ## Round the back, and off the side, in one test
    ///
    /// Every point of a ring lies within `radiusAngle` of its axis, and every
    /// point this frame can see lies within `reach` of the camera direction.
    /// So a ring has nothing on screen when its axis is further from the
    /// camera than the two of them added together — one dot product against
    /// one cosine, and it subsumes the old "is it round the back" test, which
    /// was the same comparison with `reach` fixed at a right angle.
    ///
    /// That fixed right angle is why the globe used to pay the whole
    /// hemisphere at every zoom. Half the planet is behind you at any zoom, so
    /// rejecting the far side is worth a flat half and no more — while what
    /// you can actually *see* falls away as the square of the zoom. At the top
    /// of the range this now rejects all but a handful of rings, where before
    /// it rejected a little under half of them and handed the rest to the
    /// clipper.
    ///
    /// ## The rectangle, still
    ///
    /// Kept underneath it because the cap is the circle *around* the view and
    /// the view is a tall rectangle: pulled back, where the cap is most of a
    /// hemisphere and rejects nothing, the corners of that circle are a lot of
    /// screen that is not there. The bound is exact — every point of a ring is
    /// within `R·√(2 − 2·cos θ)` of the projected axis, since an orthographic
    /// projection cannot stretch a chord — and a great circle comes out at 2R,
    /// which never culls, which is the truth about a line that wraps the
    /// planet.
    private func isCulled(
        _ ring: GlobeGeometry.Ring,
        basis: GlobeCamera.Basis,
        box: CGRect,
        reach: Float
    ) -> Bool {
        let span = ring.radiusAngle + reach
        if span < .pi, simd_dot(ring.axis, basis.out) < cos(span) { return true }

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
        box: CGRect,
        reach: Float
    ) {
        guard width > 0 else { return }

        let path = CGMutablePath()
        for ring in rings where !isCulled(ring, basis: basis, box: box, reach: reach) {
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

    // MARK: - The ground

    /// The pavement of the field the camera is over.
    ///
    /// The whole point of being able to zoom in this far. Runways, taxiways,
    /// aprons and terminals, in the same colours and at the same real widths
    /// the flat map draws them — `AirportGroundStyle` is shared rather than
    /// reimplemented, so a runway is the same runway whichever shape the world
    /// is.
    ///
    /// ## One projected point, and a plane
    ///
    /// Every point of a layout is drawn off a single projection of the field
    /// itself, plus its offset in metres through the projection's own
    /// derivative there — two multiplies and two adds a point. That is not
    /// only speed. At this zoom the sphere is hundreds of thousands of points
    /// across, and a unit vector in `Float` resolves to about half a metre,
    /// which is a runway centreline's worth of wobble on every vertex. Metres
    /// in a tangent plane have no such problem, and over the few kilometres a
    /// field covers the plane and the sphere differ by millimetres.
    private func drawGround(in context: CGContext, basis: GlobeCamera.Basis, box: CGRect) {
        guard let ground = scene.ground else { return }

        // Points per metre. Below this the field is a dot and the pavement is
        // a smudge on it, which the ring and the code say better.
        let perMetre = camera.radius / CGFloat(GlobeCamera.earthRadiusMetres)
        guard perMetre * 1000 > 6 else { return }

        let origin = camera.project(ground.anchor, using: basis)
        guard origin.depth > 0 else { return }

        // Off the side of the screen, field and all.
        let span = CGFloat(ground.reachMetres) * perMetre
        guard box.insetBy(dx: -span, dy: -span).contains(origin.point) else { return }

        // The projection's derivative at the field: where a metre east and a
        // metre north each land on screen.
        let ex = CGFloat(simd_dot(ground.east, basis.east)) * perMetre
        let ey = -CGFloat(simd_dot(ground.east, basis.north)) * perMetre
        let nx = CGFloat(simd_dot(ground.north, basis.east)) * perMetre
        let ny = -CGFloat(simd_dot(ground.north, basis.north)) * perMetre
        let anchor = origin.point

        func place(_ offset: SIMD2<Float>) -> CGPoint {
            CGPoint(
                x: anchor.x + CGFloat(offset.x) * ex + CGFloat(offset.y) * nx,
                y: anchor.y + CGFloat(offset.x) * ey + CGFloat(offset.y) * ny
            )
        }

        let paper: AirportGroundStyle.Ground = (palette.land ?? palette.ocean).isLight
            ? .light
            : .dark

        // Aprons first, runways last, so the pieces stack the way the concrete
        // does — the same order the flat map lays them down in.
        for kind in AirportLayout.drawingOrder {
            for piece in ground.pieces where piece.kind == kind {
                let points = piece.points.map(place)
                guard points.count > 1 else { continue }

                let path = CGMutablePath()
                path.addLines(between: points)

                if kind.isArea {
                    path.closeSubpath()
                    context.setFillColor(AirportGroundStyle.area(for: kind, on: paper).cgColor)
                    context.addPath(path)
                    context.fillPath()
                    continue
                }

                // Drawn to scale with a floor under it, which is what makes a
                // field look like an aerodrome rather than a diagram of one.
                let width = max(
                    AirportGroundStyle.minimumPoints(for: kind),
                    CGFloat(piece.widthMetres) * perMetre
                )

                context.setLineJoin(.round)
                context.setLineCap(kind == .holdShort ? .butt : .round)

                if kind == .holdShort {
                    context.setStrokeColor(AirportGroundStyle.holdBar.cgColor)
                    context.setLineWidth(width)
                    context.addPath(path)
                    context.strokePath()
                    continue
                }

                let edge = AirportGroundStyle.edgePoints(for: kind, on: paper)
                if edge > 0 {
                    context.setStrokeColor(AirportGroundStyle.edge(for: kind, on: paper).cgColor)
                    context.setLineWidth(width + edge * 2)
                    context.addPath(path)
                    context.strokePath()
                }

                context.setStrokeColor(AirportGroundStyle.fill(for: kind, on: paper).cgColor)
                context.setLineWidth(width)
                context.addPath(path)
                context.strokePath()

                // The dashed stripe down the middle, which is what makes a grey
                // slab read as a runway. Only once there is a slab to put it on.
                if kind == .runway, width > 7 {
                    context.saveGState()
                    context.setStrokeColor(AirportGroundStyle.centreline(on: paper).cgColor)
                    context.setLineWidth(max(0.8, width * 0.06))
                    context.setLineDash(phase: 0, lengths: [width * 0.9, width * 0.7])
                    context.addPath(path)
                    context.strokePath()
                    context.restoreGState()
                }
            }
        }
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

        // A rotated blit is a resampled one, and this is the only place in the
        // frame that asks for hundreds of them. The artwork is drawn at its own
        // size and only turned, so there is nothing for a better filter to
        // recover — bilinear is the whole of the answer, and the default costs
        // several times as much for it.
        context.saveGState()
        context.interpolationQuality = .low
        defer { context.restoreGState() }

        // Projected first, drawn second, and the reason is the budget below:
        // how far apart two aeroplanes have to be to both be worth drawing
        // depends on how many of them there are, which is not known until they
        // have all been looked at. Projecting is nine multiplies; the answers
        // are kept so it happens once rather than twice.
        //
        // Walked by index rather than by element, which is not a style choice.
        // A `GlobeTrafficDot` carries two `String`s and a `UIColor?`, so binding
        // one per iteration retains and releases three references — a packet of
        // three thousand at sixty frames a second is over half a million
        // retain/release pairs a second to read two vectors.
        marks.removeAll(keepingCapacity: true)
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
            marks.append((index: index, point: projected.point, angle: atan2(dx, -dy)))
        }

        startCrowding(mark: size, in: box)

        for mark in marks {
            let dot = traffic[mark.index]

            if dot.isOpen {
                // A playback is driving this aeroplane, so where the feed last
                // saw it is not where it is being shown. Dropped here and drawn
                // from the frame below.
                if replay == nil { open.append((mark.point, mark.angle, dot)) }
                continue
            }

            // Traffic that would land on top of traffic already drawn is not
            // drawn. See `startCrowding`. The ones the colouring has an opinion
            // about — your own, the pilots you watch — are never dropped:
            // they are the ones you are looking for.
            if dot.tint == nil, isCrowded(at: mark.point) { continue }

            draw(dot, at: mark.point, angle: mark.angle,
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

        // The open aircraft last and larger, so it is findable in a packet of
        // three thousand.
        //
        // Larger and amber, and nothing else. It used to carry a ring as well,
        // and the ring was the wrong mark twice over: the flat map does not
        // draw one, so the aeroplane you had just been watching grew a circle
        // when you changed the shape of the world; and a circle a hair wider
        // than the aircraft inside it reads as a crop of it rather than as a
        // ring around it — you see a nose and a tail cut off at the rim rather
        // than a highlighted aeroplane. The size and the colour say the same
        // thing without drawing over the artwork.
        for (point, angle, dot) in open {
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

    // MARK: - Crowding

    /// One cell per patch of screen, marked when an aeroplane has been drawn
    /// in it.
    private var crowd: [Bool] = []
    private var crowdColumns = 0
    private var crowdRows = 0
    private var crowdCell: CGFloat = 1
    private var crowdOrigin: CGPoint = .zero

    /// Stops drawing aeroplanes on top of aeroplanes.
    ///
    /// ## The arithmetic of a full planet
    ///
    /// Pulled all the way back, a packet is three thousand aircraft on a disc
    /// about three hundred and thirty points across, and half of those are
    /// round the back. What is left is fifteen hundred marks, thirteen points
    /// on a side, poured into forty thousand square points of planet — every
    /// part of the picture several aeroplanes deep, most of them painted over
    /// before the frame ends.
    ///
    /// They are not cheap to paint over. Each is a *rotated* blit, which is a
    /// resample rather than a copy, and at two or three pixels to the point
    /// fifteen hundred of them is several million pixels of interpolation a
    /// frame. That is the traffic still being heavy after all the cartography
    /// had been made cheap.
    ///
    /// ## A budget, not a spacing
    ///
    /// So the screen is a coarse grid and the first aeroplane into a cell is
    /// the one drawn. The cell is not fixed: it is opened up until the number
    /// that will be drawn comes under a budget, so the cost of a frame stops
    /// depending on how busy the server is. A quiet server and a zoomed-in
    /// view never reach the budget and nothing is dropped at all — which is
    /// every case except the one that was slow.
    ///
    /// What is dropped is only ever an aeroplane that would have been drawn on
    /// top of another one. It is not a judgement about which aircraft matter:
    /// anything the colouring has singled out skips the grid entirely, and the
    /// hit test still walks the whole packet, so one that was not drawn is
    /// still one you can tap.
    private func startCrowding(mark: CGFloat, in box: CGRect) {
        let natural = max(3, mark * 0.6)
        let ceiling = mark * 3
        prepareCrowd(cell: natural, in: box)

        let budget = isInteracting ? Self.movingBudget : Self.restingBudget
        guard marks.count > budget else { return }

        // Opened up until what would actually be *drawn* comes under budget,
        // measured rather than predicted.
        //
        // How many fill is not how many are on screen, and the difference is
        // the whole trick: a full planet is mostly aeroplanes on top of
        // aeroplanes, so opening the grid by the ratio of the packet to the
        // budget opens it far too far and leaves a lattice. It is not a closed
        // form either — the traffic is nothing like evenly spread, so how fast
        // the count falls as the cell grows depends on the shape of the
        // packet. Two or three passes of measure-and-open lands on it, and a
        // pass is one array index per aeroplane.
        var cell = natural
        for _ in 0..<3 {
            var filled = 0
            for candidate in marks where !isCrowded(at: candidate.point) { filled += 1 }

            guard filled > budget, cell < ceiling else {
                prepareCrowd(cell: cell, in: box)
                return
            }
            cell = min(ceiling, cell * (CGFloat(filled) / CGFloat(budget)).squareRoot())
            prepareCrowd(cell: cell, in: box)
        }
    }

    private func prepareCrowd(cell: CGFloat, in box: CGRect) {
        crowdCell = max(3, cell)
        crowdOrigin = box.origin
        crowdColumns = max(1, Int((box.width / crowdCell).rounded(.up)) + 1)
        crowdRows = max(1, Int((box.height / crowdCell).rounded(.up)) + 1)

        let wanted = crowdColumns * crowdRows
        if crowd.count < wanted {
            crowd = [Bool](repeating: false, count: wanted)
        } else {
            for index in 0..<wanted { crowd[index] = false }
        }
    }

    /// How many aircraft are worth drawing in one frame.
    ///
    /// Two numbers, because the two cases are not alike. While the planet is
    /// moving this is paid sixty times a second and it is competing with the
    /// cartography for the same frame; at rest it is paid once, when a packet
    /// lands, and there is a whole second before the next one.
    private static let movingBudget = 700
    private static let restingBudget = 2400

    private func isCrowded(at point: CGPoint) -> Bool {
        let column = Int((point.x - crowdOrigin.x) / crowdCell)
        let row = Int((point.y - crowdOrigin.y) / crowdCell)
        guard column >= 0, column < crowdColumns, row >= 0, row < crowdRows else { return false }

        let index = row * crowdColumns + column
        if crowd[index] { return true }
        crowd[index] = true
        return false
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
            // the last stretch before the limb — so on a zoomed-in frame every
            // field on screen is at full strength, and the whole save, set,
            // restore is skipped rather than paid three hundred times for an
            // alpha of one.
            let opacity = min(1, CGFloat(projected.depth) / 0.28)
            let fading = opacity < 1
            let point = projected.point

            if fading {
                context.saveGState()
                context.setAlpha(opacity)
            }

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

            if fading { context.restoreGState() }
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

    /// A planet handed a fixed camera is a swatch — a forty-eight point
    /// picture of a globe in a settings row. It is not something to turn, and
    /// nothing may move its camera off the one it was given.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isLive
    }
}

private extension UIColor {

    /// Whether this is light enough that something drawn on it should be dark.
    ///
    /// Rec. 709 luminance, which is close enough to how bright a colour looks
    /// for a question with two answers.
    var isLight: Bool {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue > 0.5
    }
}
