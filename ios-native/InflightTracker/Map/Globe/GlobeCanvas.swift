import CoreLocation
import QuartzCore
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

    /// Whether the traffic is carried between packets rather than jumping to
    /// each one. See `GlobeCanvasView.isFlyingTraffic`.
    var smoothsTraffic: Bool = true

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
            smoothsTraffic: smoothsTraffic,
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

/// The planet, over the sky.
///
/// Two layers rather than one, and the split is the whole point. The sky — a
/// gradient, seven hundred stars, a vignette — does not change when the planet
/// turns, and it covers the entire screen. Drawn into the same bitmap as the
/// planet, it had to be laid down again on *every frame of every gesture*: a
/// full-screen composite, sixty times a second, to reproduce the picture that
/// was already there.
///
/// Now it is a layer of its own, painted when the backdrop or the size changes
/// and composited by the GPU after that, which is the thing GPUs are for. The
/// planet draws into a transparent layer above it — a memset and a blend over
/// the quarter of the screen the disc actually covers, against a full-screen
/// copy.
///
/// It also unties the resolution from the sky. `updateResolution` drops the
/// planet's pixel count while a finger is down; when the sky shared that
/// bitmap, every step of that meant either resampling a three-megapixel image
/// per frame or rebuilding it mid-gesture. The sky is simply always sharp now,
/// and costs nothing for being so.
private final class GlobePlanetView: UIView {

    weak var owner: GlobeCanvasView?

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        owner?.drawPlanet(in: context)
    }
}

final class GlobeCanvasView: UIView {

    /// Everything that moves. See `GlobePlanetView`.
    private let planetView = GlobePlanetView()

    // MARK: - What the view is handed

    private var palette = GlobeSkin.midnight.palette(scheme: .dark)
    private var backdrop = GlobeBackdropStyle.plain
    private var scene = GlobeScene()
    private var revision = -1
    private var showsPlanes = true
    private var showsFields = true
    private var sun: SIMD3<Float>?
    private var replay: GlobeReplayMark?
    private var smoothsTraffic = true
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

    /// Whether a pinch ran at any point during the drag now ending.
    private var wasPinched = false

    /// Where the pan's fingers were last frame, and how many of them there
    /// were.
    ///
    /// The planet is dragged by the movement of this point rather than by the
    /// recognizer's own `translation`, and the difference is the touch count
    /// changing. A pan measures from the *centroid* of whatever touches it has,
    /// so a finger leaving moves that centroid to the finger still down — half
    /// the distance between them, in one step. Read as a translation that is a
    /// drag nobody made; sampled here, alongside the count that explains it, it
    /// is a frame to re-anchor on and nothing more.
    private var panCentre: CGPoint?
    private var panTouches = 0

    /// Whether the number of fingers changed at any point in the drag now
    /// ending, which is what disqualifies it as a flick: the recognizer's
    /// velocity is a velocity of the centroid, and a centroid that has just
    /// jumped to one finger carries a speed no hand was moving at.
    private var panTouchesChanged = false

    /// Whether two fingers are running a pinch, and what was under them when
    /// it began — so the ground between them stays between them. The pinch
    /// tracks its own midpoint, which *is* a two-finger drag, so while it is
    /// live it owns the translation as well and the pan stands off. See
    /// `pin(_:at:)`.
    private var isPinching = false
    private var pinchAnchor: SIMD3<Double>?

    /// A flick, in points a second, decaying. Nil when the planet is still.
    private var momentum: CGVector?

    /// A zoom being animated by a tap: where it is going, and how far through.
    private var zoomFrom: CGFloat = 0
    private var zoomTo: CGFloat = 0
    private var zoomAnchor: SIMD3<Double>?
    private var zoomPoint: CGPoint = .zero
    private var zoomProgress: Double = 0

    private var isZooming: Bool { zoomProgress > 0 && zoomProgress < 1 }

    /// Drives the glide and the tap zoom. Nil whenever neither is running, so
    /// a still planet costs nothing.
    private var animator: CADisplayLink?

    /// Whether the planet is moving, by a finger or by its own momentum.
    private var isInteracting: Bool {
        isPanning || isPinching || momentum != nil || isZooming
    }

    /// When the chrome over the planet last moved — a flight window opening,
    /// a sheet dragged between its stops, a panel closing.
    private var chromeMovedAt: CFTimeInterval = -.greatestFiniteMagnitude

    /// A guess at how long that movement lasts, which is a sheet animation.
    private static let chromeSettle: CFTimeInterval = 0.45

    /// Generation of the settle now pending, so that the last inset change is
    /// the one that decides when the planet sharpens up again.
    private var chromeGeneration = 0

    /// Whether the chrome is in the middle of moving.
    private var isChromeMoving: Bool {
        CACurrentMediaTime() - chromeMovedAt < Self.chromeSettle
    }

    /// Whether the picture is changing for any reason, which is what decides
    /// the resolution it is drawn at. A finger is one of those reasons; a
    /// window sliding up over the planet is another, and used not to be.
    private var isMoving: Bool { isInteracting || isChromeMoving }

    /// Notes that the chrome has moved, drops the resolution for as long as it
    /// is moving, and puts it back afterwards.
    ///
    /// The whole reason this exists is that a flight window is an expensive
    /// piece of SwiftUI to lay out and the planet is rasterised on the CPU, so
    /// the two of them are spending the same main thread. Every inset change
    /// through that animation was a *full resolution* redraw of the entire
    /// planet — nine pixels a point on a 3x phone — landing between the frames
    /// of the animation that was causing it, which is exactly the stutter you
    /// feel opening and closing the window. The gesture path has dropped
    /// resolution while the world moves since the globe was written; this is
    /// the same trade for the one kind of movement no finger is behind.
    private func noteChromeMoved() {
        chromeMovedAt = CACurrentMediaTime()
        updateResolution()

        chromeGeneration &+= 1
        let generation = chromeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.chromeSettle) { [weak self] in
            guard let self = self, self.chromeGeneration == generation else { return }
            self.updateResolution()
            self.redrawPlanet()
        }
    }

    /// Whether this planet is one you can turn, rather than a swatch drawn
    /// from a camera it was handed.
    private var isLive: Bool { still == nil }

    // MARK: - Keeping up

    /// How long the planet has been taking to draw, in seconds, smoothed over
    /// the last several frames.
    private var frameCost: Double = 0

    /// The resolution the planet is drawn at while it is moving, found rather
    /// than assumed. See `tuneResolution`.
    private var interactiveScale: CGFloat = 2

    /// Frames in a row on the wrong side of a threshold, so that one slow
    /// frame does not soften the map and one quick one does not sharpen it.
    private var slowFrames = 0
    private var quickFrames = 0

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
    private var marks: [(index: Int, position: SIMD3<Float>, point: CGPoint, angle: CGFloat)] = []

    /// Where the open aircraft was put this frame, if it is on screen at all.
    /// What the flown path's live segment is drawn out to, so the track stays
    /// attached to an aeroplane that is moving between packets.
    private var openPlace: SIMD3<Float>?


    // MARK: - Setting up

    override init(frame: CGRect) {
        super.init(frame: frame)
        addPlanet()
        addGestures()
        watchMemory()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addPlanet()
        addGestures()
        watchMemory()
    }

    private func addPlanet() {
        planetView.owner = self
        planetView.isOpaque = false
        planetView.backgroundColor = .clear
        // Redrawn rather than stretched, so a coastline is a hairline at any
        // zoom instead of a scaled bitmap.
        planetView.contentMode = .redraw
        // The gestures belong to the container, which is what the recognizers
        // are attached to and what the hit test should find.
        planetView.isUserInteractionEnabled = false
        addSubview(planetView)
    }

    /// The field codes are the only bitmaps left here worth giving back, and
    /// they redraw themselves the next time a field is on screen.
    private func watchMemory() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dropCaches),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
    }

    @objc private func dropCaches() {
        labels.removeAll()
    }

    /// A `CADisplayLink` holds its target, and the runloop holds the link — so
    /// a planet taken off screen mid-glide would go on turning, and go on
    /// existing, for as long as the app did.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window == nil else {
            // Back on screen, and the traffic goes back to flying.
            updateTrafficClock()
            return
        }
        momentum = nil
        zoomProgress = 0
        zoomAnchor = nil
        stopAnimator()
    }

    deinit { animator?.invalidate() }

    /// The same set of gestures Maps has, because this is a map.
    /// A planet handed a fixed camera is a swatch — a forty-eight point
    /// picture of a globe in a settings row. It is not something to turn, and
    /// nothing may move its camera off the one it was given.
    ///
    /// `UIView` declares this itself rather than only picking it up from
    /// `UIGestureRecognizerDelegate`, so it is an override and lives here with
    /// the other overrides rather than down in the delegate extension.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        isLive
    }

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
        // Two fingers that pinched are not two fingers that tapped.
        //
        // Everything here recognises simultaneously, which is what lets a zoom
        // drift into a drag — and it also let this fire off the back of every
        // pinch. A tap allows a little movement, and a pinch is a *ratio*:
        // fingers fifty points apart that spread by fifteen have zoomed by a
        // third while each of them moved less than the tap's own tolerance. So
        // the planet zoomed in under your fingers and then, the moment you
        // lifted them, animated itself back out to half the zoom around the
        // point they left — which is the elastic snap, and the jump to the
        // last finger, both out of one line.
        //
        // Failure rather than a flag: a pinch that recognised is one this must
        // not follow, and a pair of fingers that only tapped never gets the
        // pinch going, so it fails and this fires as it always did.
        twoFingerTap.require(toFail: pinch)
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
        smoothsTraffic: Bool,
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
            || smoothsTraffic != self.smoothsTraffic
            || palette != self.palette
            || backdrop != self.backdrop
            || still != self.still

        if palette != self.palette { labels.removeAll() }
        let skyMoved = backdrop != self.backdrop

        let insetsMoved = bottomInset != self.bottomInset || trailingInset != self.trailingInset

        self.palette = palette
        self.backdrop = backdrop
        self.scene = scene
        self.revision = revision
        self.showsPlanes = showsPlanes
        self.showsFields = showsFields
        self.sun = sun
        self.replay = replay
        self.smoothsTraffic = smoothsTraffic
        self.start = start
        self.bottomInset = bottomInset
        self.trailingInset = trailingInset
        self.still = still

        // An opaque view has to have something behind the drawing during the
        // moment between a resize and the redraw, or the gap is undefined.
        backgroundColor = (backdrop.colors.first ?? .black).withAlphaComponent(1)
        // The sky is repainted only when the sky changes.
        if skyMoved { setNeedsDisplay() }

        if insetsMoved || still != nil {
            layoutCamera(keepingGround: insetsMoved)
            if insetsMoved { noteChromeMoved() }
            changed = true
        }
        if carryOut(command) { changed = true }

        // A packet may have brought the first aeroplane worth carrying, or
        // taken the last one away.
        updateTrafficClock()

        guard changed else { return }
        redrawPlanet()
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
        planetView.frame = bounds
        layoutCamera()
    }

    /// Sizes the planet to the viewport and puts it in the middle of whatever
    /// the chrome is not standing on.
    ///
    /// The zoom is kept as a *multiple* rather than as a radius precisely so a
    /// resize survives it: turning the phone sideways keeps you as close to the
    /// ground as you were, rather than as many points from the middle as you
    /// were.
    private func layoutCamera(keepingGround: Bool = false) {
        if let still = still {
            camera = still
            return
        }
        guard bounds.width > 0, bounds.height > 0 else { return }

        camera.center = CGPoint(
            x: (bounds.width - trailingInset) / 2,
            y: (bounds.height - bottomInset) / 2
        )

        // A window standing on the map is not a change of zoom.
        //
        // The zoom is held as a multiple of the radius that *fits* the space
        // the chrome leaves, which is the right thing to carry across a
        // rotation — a phone turned sideways should leave you as close to the
        // ground as you were, rather than as many points from the middle as you
        // were. It is the wrong thing to carry across a window opening. The
        // fitted radius shrinks by whatever the window covers, so the same
        // multiple is a smaller planet: open a flight and the ground you were
        // looking at pulled away from you, and closing it pushed you back in.
        //
        // So when it is only the chrome that moved, the ground keeps its size
        // and the disc simply recentres in what is left — which is what the
        // flat map's layout margins have always done. Re-clamped either way,
        // because both the floor and the ceiling are distances across a screen
        // that has just changed shape.
        if keepingGround, isReady, camera.radius > 0 {
            scale = clamped(camera.radius / fittedRadius)
        } else {
            scale = clamped(scale)
        }
        camera.radius = fittedRadius * scale

        if !isReady {
            camera.latitude = start.latitude
            camera.longitude = GlobeCamera.wrapped(start.longitude)
            isReady = true
        }
        reportCamera()
        // The zoom decides whether carrying the traffic between packets is
        // something anybody could see. See `isFlyingTraffic`.
        updateTrafficClock()
        redrawPlanet()
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
    /// Full precision, because this is the point a pinch promises to keep
    /// under your fingers.
    ///
    /// A `Float` direction resolves to about forty centimetres of ground,
    /// which at the closest zoom is three quarters of a point — so the anchor
    /// itself was landing on a lattice, and `pin` was then solving exactly for
    /// a slightly wrong place. The solve was always double precision inside;
    /// this stops the answer being thrown away on the way in.
    private func direction(at point: CGPoint) -> SIMD3<Double>? {
        guard camera.radius > 0 else { return nil }
        let u = Double((point.x - camera.center.x) / camera.radius)
        let v = Double((camera.center.y - point.y) / camera.radius)
        let flat = u * u + v * v
        guard flat < 0.9801 else { return nil }

        let basis = camera.basis
        let depth = (1 - flat).squareRoot()
        return simd_normalize(
            basis.preciseEast * u + basis.preciseNorth * v + basis.preciseOut * depth
        )
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
    private func pin(_ anchor: SIMD3<Double>, at point: CGPoint) {
        guard camera.radius > 0 else { return }

        let ax = anchor.x, ay = anchor.y, az = anchor.z

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
            wasPinched = false
            panTouchesChanged = false
            momentum = nil
            panTouches = gesture.numberOfTouches
            panCentre = gesture.location(in: self)
            beginInteraction()

        case .changed:
            // Where the fingers are, and how many of them, read together.
            //
            // Together is the point. The recognizer's own `translation` is a
            // running total kept on the other side of a touch ending, so a
            // frame can arrive carrying a centroid that has jumped to the one
            // finger still down — and nothing in the number itself says so.
            // Sampled here, the count that explains the jump comes with it, and
            // the frame it happens on is spent re-anchoring rather than drawn.
            let touches = gesture.numberOfTouches
            let centre = gesture.location(in: self)

            guard touches == panTouches, let last = panCentre else {
                panTouchesChanged = panTouchesChanged || touches != panTouches
                panTouches = touches
                panCentre = centre
                return
            }
            panCentre = centre

            // A live pinch is already following the midpoint of the same two
            // fingers, and that midpoint moving is this movement. Applying both
            // would move the planet twice as far as the hand did. Kept up to
            // date all the same, so the first frame after the pinch ends is a
            // step from where the fingers actually are.
            guard !isPinching else { wasPinched = true; return }

            camera.drag(by: CGSize(
                width: centre.x - last.x,
                height: centre.y - last.y
            ))
            redrawPlanet()

        case .ended, .cancelled, .failed:
            isPanning = false
            panCentre = nil
            // A flick keeps going. The planet used to stop dead under your
            // fingertip, which is the other half of what made this not feel
            // like a map — everything on iOS that scrolls, glides.
            let velocity = gesture.velocity(in: self)
            let speed = (velocity.x * velocity.x + velocity.y * velocity.y).squareRoot()
            // Never off the back of a pinch, and never off a drag that
            // changed hands. Two fingers coming off a zoom are not a flick, and
            // the velocity of their midpoint is not one either — it would sail
            // the planet away from what you had just zoomed in on.
            if gesture.state == .ended, !isPinching, !wasPinched, !panTouchesChanged,
               speed > Self.glideThreshold {
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
            pinchedAt = CACurrentMediaTime()
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
            redrawPlanet()

        case .ended, .cancelled, .failed:
            isPinching = false
            pinchedAt = CACurrentMediaTime()
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
    /// When a pinch was last live, so a tap made of the same two fingers can
    /// be told from one made on its own.
    ///
    /// The failure requirement in `addGestures` is the real answer and this is
    /// the belt to its braces: it costs one comparison, and what it guards
    /// against — a zoom that throws itself back out when you let go — is bad
    /// enough to be worth guarding twice.
    private var pinchedAt: CFTimeInterval = -.greatestFiniteMagnitude

    /// How long after a pinch two fingers are still that pinch's.
    private static let tapAfterPinch: CFTimeInterval = 0.35

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard CACurrentMediaTime() - pinchedAt > Self.tapAfterPinch else { return }
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
        let wasMoving = isZooming || momentum != nil

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

        // The camera is moving, so every frame is a frame. Otherwise the clock
        // is only running to carry the traffic forward, and that is worth half
        // as many: an aeroplane crossing the screen in a minute is the same
        // aeroplane at thirty frames a second as at sixty, and the planet under
        // it is a full redraw either way.
        if wasMoving {
            redrawPlanet()
        } else if isChromeMoving {
            // A window is animating over the planet and wants the main thread
            // more than the traffic does. Nobody is watching an aeroplane creep
            // across the screen while a sheet is sliding over it.
            lastTrafficFrame = link.timestamp
        } else if link.timestamp - lastTrafficFrame >= Self.trafficFrameInterval {
            lastTrafficFrame = link.timestamp
            redrawPlanet()
        }

        guard !isZooming, momentum == nil else { return }

        // Settling happens once, on the frame the movement stops, whether or
        // not the clock keeps running for the traffic.
        if wasMoving { endInteraction() }
        if !isFlyingTraffic { stopAnimator() }
    }

    /// Thirty frames a second for traffic alone. The flat map redraws the head
    /// of a flown path at the same rate, for the same reason.
    private static let trafficFrameInterval: CFTimeInterval = 1.0 / 30

    /// When the last traffic-only frame was drawn.
    private var lastTrafficFrame: CFTimeInterval = 0

    /// Whether the traffic is being carried between packets *and* it would
    /// show.
    ///
    /// The second half is not a saving so much as the honest answer. Dead
    /// reckoning moves an aeroplane at its ground speed, and how far that is on
    /// screen depends entirely on how close the camera is: with the whole
    /// planet in view a jet covers about a hundredth of a point a second, so
    /// the prediction is invisible, the jump it exists to hide is invisible,
    /// and all a frame clock would do is redraw a planet nobody can see move —
    /// several hundred coastlines and three thousand aeroplanes, thirty times
    /// a second, for a picture identical to the last one.
    ///
    /// So it is switched on by how much ground a point is worth. At a thousand
    /// metres a point a jet moves about a quarter of a point a second, which is
    /// a point and a bit between packets: the first zoom at which the jump is
    /// something you can see, and therefore the first at which smoothing it is
    /// something you can see. Closer than that it is the difference between an
    /// aeroplane flying and an aeroplane teleporting.
    private static let flyingMetresPerPoint: Double = 1_000

    private var isFlyingTraffic: Bool {
        guard smoothsTraffic, isLive, window != nil, scene.hasMotion else { return false }
        return camera.metresPerPoint <= Self.flyingMetresPerPoint
    }

    /// Starts or stops the frame clock that carries the traffic.
    ///
    /// Called when a packet lands and when the zoom settles — the two things
    /// that can change the answer. A gesture does not need it: the clock is
    /// already running for the glide, and `step` asks again when that ends.
    private func updateTrafficClock() {
        if isFlyingTraffic {
            lastTrafficFrame = CACurrentMediaTime()
            runAnimator()
        } else if !isInteracting {
            stopAnimator()
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
        // Whatever the last frame cost, it was drawn at the resting
        // resolution and says nothing about what this gesture will cost.
        frameCost = 0
        slowFrames = 0
        quickFrames = 0
        updateResolution()
    }

    private func endInteraction() {
        guard !isInteracting else { return }
        updateResolution()
        reportCamera()
        // A pinch that has just finished may have brought the traffic close
        // enough to be worth flying, or taken it out of range.
        updateTrafficClock()
        redrawPlanet()
    }

    /// Draws at fewer pixels while a finger is down.
    ///
    /// The planet is rasterised on the CPU, so the cost of a frame is very
    /// nearly linear in its pixel count — and on a 3x phone that is nine pixels
    /// per point. Two thirds of them can go for as long as the world is
    /// actually moving, which is exactly when nobody is looking at the
    /// sharpness of a coastline, and come back the moment it stops.
    private func updateResolution() {
        let wanted = isMoving ? min(interactiveScale, displayScale) : displayScale
        guard planetView.contentScaleFactor != wanted else { return }
        planetView.contentScaleFactor = wanted
    }

    /// Finds the resolution this phone can actually hold sixty frames at.
    ///
    /// The planet is rasterised on the CPU, so a frame costs very nearly what
    /// its pixel count costs — and how many pixels that is depends on the
    /// screen, and how much work each one is depends on how much traffic is on
    /// the server, how much coastline is on screen, and which phone this is.
    /// A fixed number cannot be right for all of that: two pixels a point is
    /// wasteful on a quiet server and still too many on a busy one on an older
    /// device.
    ///
    /// So it is measured. The planet times its own drawing, and while a finger
    /// is down the resolution walks up and down a short ladder to keep that
    /// under a frame. It falls quickly — three slow frames and it is down a
    /// step, because the whole point is not to drop frames — and climbs back
    /// slowly, so a single quick stretch cannot start it oscillating. At rest
    /// it is always the screen's own resolution, however low it fell.
    /// Smoothed, because a single frame is mostly noise — a packet landing, a
    /// label being laid out for the first time, another app waking up.
    private func record(frame seconds: Double) {
        frameCost = frameCost > 0 ? frameCost * 0.75 + seconds * 0.25 : seconds
    }

    private func tuneResolution() {
        guard isInteracting, isLive else { return }

        let ladder = Self.resolutionLadder
        let ceiling = min(displayScale, 2)
        guard let step = ladder.lastIndex(where: { $0 <= interactiveScale }) else { return }

        if frameCost > Self.slowFrame {
            quickFrames = 0
            slowFrames += 1
            guard slowFrames >= 3, step > 0 else { return }
            interactiveScale = ladder[step - 1]
            settle()
        } else if frameCost < Self.quickFrame {
            slowFrames = 0
            quickFrames += 1
            guard quickFrames >= 20, step + 1 < ladder.count,
                  ladder[step + 1] <= ceiling else { return }
            interactiveScale = ladder[step + 1]
            settle()
        } else {
            slowFrames = 0
            quickFrames = 0
        }
    }

    /// Applies a new resolution and forgets what the old one cost, so the next
    /// decision is made on frames actually drawn at it. Without this the
    /// average still carries the expensive frames that caused the step, and
    /// the planet walks all the way down the ladder for one slow moment.
    private func settle() {
        slowFrames = 0
        quickFrames = 0
        frameCost = 0
        updateResolution()
    }

    /// Pixels a point, coarsest first. The floor is one — below that a
    /// coastline stops being a line — and the ceiling is two, which is where
    /// the reduction started life.
    private static let resolutionLadder: [CGFloat] = [1, 1.25, 1.5, 2]

    /// A frame worth stepping down for, and one worth stepping back up for.
    /// Sixty frames a second is sixteen and a half milliseconds all in, and
    /// this measures only the drawing — the rest of it is the backing store
    /// going to the GPU and Core Animation putting the two layers together.
    private static let slowFrame: Double = 0.010
    private static let quickFrame: Double = 0.0045

    /// Invalidates the planet, and takes the chance to notice whether the
    /// frames are landing.
    private func redrawPlanet() {
        tuneResolution()
        planetView.setNeedsDisplay()
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

    /// The sky, and nothing else.
    ///
    /// Reached only when the size or the backdrop changes — the planet turning
    /// invalidates `planetView`, not this.
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        drawSky(in: context)
    }

    fileprivate func drawPlanet(in context: CGContext) {
        let began = CACurrentMediaTime()
        defer { record(frame: CACurrentMediaTime() - began) }

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

        // Before anything that reads where an aeroplane is, because that is no
        // longer only the traffic: the flown path is drawn out to the open
        // aircraft, and the aircraft is somewhere between packets.
        flyTraffic(basis: basis, box: box)

        drawLines(in: context, basis: basis, box: box)
        drawFlownPath(in: context, basis: basis, box: box)
        drawLimb(in: context)
        drawTraffic(in: context, basis: basis)

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

    /// Paints the sky.
    ///
    /// Not per frame, and not into a cache. It used to be both: drawn into the
    /// same bitmap as the planet, it had to be laid down again every frame, so
    /// it was rendered once into an image and blitted — and then the image had
    /// to be held at every resolution the planet might be drawn at, or every
    /// blit was a three megapixel resample.
    ///
    /// A layer of its own removes all of that. This runs when the view is
    /// resized or the backdrop is changed, and Core Animation composites it
    /// under the planet from then on. The bitmaps, and the twenty megabytes
    /// they cost, are gone with it.
    private func drawSky(in context: CGContext) {
        let box = bounds
        guard box.width > 0, box.height > 0 else { return }

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
        let bands: [CGMutablePath] = [CGMutablePath(), CGMutablePath(), CGMutablePath()]
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
        // Round joins and caps on a hairline are several thousand arcs a frame
        // for a difference nothing can see. A round join is a circle drawn at
        // every vertex of every coastline, and at three quarters of a point
        // wide the circle is a third of a pixel across — the same handful of
        // pixels a bevel puts there, at several times the price. Kept for a
        // line thick enough to have a visible corner.
        let soft = width >= 1.5
        context.setLineJoin(soft ? .round : .bevel)
        context.setLineCap(soft ? .round : .butt)
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

    // MARK: - The flown path

    /// How wide the flown track is drawn, in points.
    ///
    /// The flat map's own ramp — see `FlownPathStyle`, which is where the
    /// argument for it lives — keyed on how much ground is across the screen
    /// rather than on a MapKit camera distance, because that is the same
    /// question asked of a globe. Wide at an aerodrome, where the track is read
    /// against runway edges; narrow with a continent in view, where a long-haul
    /// is a tangle of switchbacks and a wide stroke stops being a line and
    /// becomes a shape.
    private var flownWidth: CGFloat {
        let across = max(120, min(bounds.width - trailingInset, bounds.height - bottomInset))
        return FlownPathStyle.width(
            forCameraDistance: camera.metresPerPoint * Double(across)
        )
    }

    /// Where the open aircraft is being drawn, which is where its track has to
    /// end. A playback owns the aeroplane when one is running.
    private var flownHead: SIMD3<Float>? { replay?.position ?? openPlace }

    /// How far the aeroplane may be from the newest fix and still have the gap
    /// drawn, as the cosine of an angle at the centre of the planet.
    ///
    /// A degree and a half, which is a hundred and sixty kilometres. The gap
    /// this covers is the few miles between the last breadcrumb and the
    /// aeroplane; anything on that scale is not a gap but a different place —
    /// a respawn, a reposition, a track held over from a flight that has ended
    /// — and joining the two would draw a line across a country that was never
    /// flown.
    private static let flownHeadReach = cos(1.5 * Double.pi / 180)

    /// The open aircraft's track: where it has been, in the colours of the
    /// heights it was at.
    ///
    /// ## Built once, stroked twice
    ///
    /// The halo and the core are the same geometry at two widths, and the
    /// geometry is the expensive half — a few thousand points projected and
    /// clipped at the horizon. So the paths are built once and stroked twice,
    /// which is not something the flat map's renderer can do: it is handed a
    /// tile at a time and has to walk the track for each.
    ///
    /// ## The halo, inside a layer
    ///
    /// A wide translucent stroke composites twice wherever a track crosses
    /// itself — a hold, a circuit, a taxi back down the same line — and every
    /// crossing comes out darker than the line either side of it. Drawn opaque
    /// into a transparency layer and faded as a whole, the overlap happens
    /// inside the layer where it is opaque-on-opaque, and the wash comes out
    /// even. The layer is clipped to the track's own bounds first, so what it
    /// costs is the strip the track covers rather than the screen.
    private func drawFlownPath(in context: CGContext, basis: GlobeCamera.Basis, box: CGRect) {
        guard let flown = scene.flown, !flown.runs.isEmpty else { return }

        var strokes: [(path: CGPath, color: UIColor)] = []
        strokes.reserveCapacity(flown.runs.count + 1)
        var covered = CGRect.null

        for run in flown.runs {
            let path = CGMutablePath()
            append(
                flown.points,
                from: run.first,
                through: run.last,
                to: path,
                basis: basis,
                box: box
            )
            guard !path.isEmpty else { continue }
            covered = covered.union(path.boundingBox)
            strokes.append((path, run.color))
        }

        // The piece the feed has not caught up with: the newest fix out to
        // wherever the aeroplane is this frame. It carries the fix's colour,
        // because that is the height the aircraft was last known to be at and
        // inventing a different one for a few miles of track would be a claim
        // about a climb nobody reported.
        if let head = flownHead {
            let tip = SIMD3<Double>(Double(head.x), Double(head.y), Double(head.z))
            if simd_dot(flown.tail, tip) > Self.flownHeadReach {
                let path = CGMutablePath()
                append([flown.tail, tip], to: path, basis: basis, box: box)
                if !path.isEmpty {
                    covered = covered.union(path.boundingBox)
                    strokes.append((path, flown.headColor))
                }
            }
        }

        guard !strokes.isEmpty, !covered.isNull else { return }

        let core = flownWidth
        let halo = core * FlownPathStyle.glowSpread

        context.saveGState()
        defer { context.restoreGState() }

        context.setLineCap(.round)
        context.setLineJoin(.round)

        let room = covered.insetBy(dx: -halo, dy: -halo).intersection(bounds)
        guard !room.isEmpty else { return }
        context.clip(to: room)

        context.setAlpha(FlownPathStyle.glowOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        stroke(strokes, width: halo, in: context)
        context.endTransparencyLayer()
        context.setAlpha(1)

        stroke(strokes, width: core, in: context)
    }

    private func stroke(
        _ strokes: [(path: CGPath, color: UIColor)],
        width: CGFloat,
        in context: CGContext
    ) {
        context.setLineWidth(width)
        for run in strokes {
            context.setStrokeColor(run.color.cgColor)
            context.addPath(run.path)
            context.strokePath()
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

    /// The same walk, for the lines that are held to full precision.
    ///
    /// A second copy rather than one made generic over the scalar. What the
    /// two share is the *shape* of the problem — visible, hidden, and the two
    /// crossings between — and what they do not share is the arithmetic: the
    /// cartography is ten thousand `Float` points a frame and these are a few
    /// hundred `Double` ones. A generic over `SIMD3` would put a witness table
    /// between the border clipper and its dot product for the sake of removing
    /// thirty lines that are not going to change independently.
    private func append(
        _ points: [SIMD3<Double>],
        from first: Int = 0,
        through last: Int = .max,
        to path: CGMutablePath,
        basis: GlobeCamera.Basis,
        box: CGRect
    ) {
        // A range rather than a slice, so that one run of a flown path — which
        // is a stretch of one colour inside an array of a few thousand points —
        // is walked in place instead of copied out to be walked.
        let end = min(last, points.count - 1)
        guard first >= 0, first <= end else { return }

        var previousVector: SIMD3<Double>?
        var previous: GlobeCamera.Projected?
        var isDrawing = false

        for index in first...end {
            let point = points[index]
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

    private func horizonCrossing(
        near: GlobeCamera.Projected,
        far: GlobeCamera.Projected,
        nearVector: SIMD3<Double>,
        farVector: SIMD3<Double>,
        basis: GlobeCamera.Basis
    ) -> CGPoint {
        let span = Double(near.depth) - Double(far.depth)
        guard span > 1e-9 else { return near.point }

        let t = Double(near.depth) / span
        let blended = simd_normalize(nearVector + (farVector - nearVector) * t)
        return camera.project(blended, using: basis).point
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

    /// The half of the planet the sun is not on, and the dusk before it.
    ///
    /// ## Why this is eight shapes and not one
    ///
    /// It used to be one: the dark hemisphere, filled flat, with the
    /// terminator as its edge. Which put a hard line across the Atlantic —
    /// full night on one side of it and full daylight on the other, a step
    /// no photograph of the earth has ever shown. The flat map stopped
    /// drawing that some time ago and the planet went on doing it.
    ///
    /// So it is the map's own fade now, out of the map's own numbers: eight
    /// caps, from the sunset line down to astronomical night, each one
    /// everything darker than a chosen sun elevation. See `Terminator`, which
    /// owns the elevations and the ramp so that the two maps cannot disagree
    /// about the same evening.
    ///
    /// Cut into rings rather than stacked, for the reason the map cuts them:
    /// nested caps paint the deep night eight times over, which on a planet
    /// redrawn every frame of every gesture is eight full-screen composites
    /// for a picture one of them could draw. Each ring instead carries the
    /// darkness the stack would have accumulated to, so every pixel of the
    /// wash is painted once.
    private func drawNight(in context: CGContext, basis: GlobeCamera.Basis, sun: SIMD3<Float>) {
        let full = palette.night.cgColor.alpha
        guard full > 0, Terminator.bandCount > 0 else { return }

        // Lightest first: the sunset line, then each step down from it.
        var caps: [CGPath?] = []
        caps.reserveCapacity(Terminator.bandCount)
        for index in 0..<Terminator.bandCount {
            caps.append(cap(
                belowElevation: Terminator.elevation(atIndex: index),
                basis: basis,
                sun: sun
            ))
        }

        context.saveGState()
        defer { context.restoreGState() }

        if !isViewInsideDisc {
            context.addEllipse(in: discBox)
            context.clip()
        }

        for index in 0..<Terminator.bandCount {
            // The caps only shrink, so once one has nothing in view neither
            // has anything darker than it.
            guard let outer = caps[index] else { return }

            let ring = CGMutablePath()
            ring.addPath(outer)
            // The innermost band has nothing under it: past astronomical night
            // the ground is as dark as this draws it, so that one is solid.
            if index + 1 < caps.count, let inner = caps[index + 1] {
                ring.addPath(inner)
            }

            let depth = CGFloat(Terminator.depth(atIndex: index))
            context.setFillColor(palette.night.withAlphaComponent(full * depth).cgColor)
            context.addPath(ring)
            // Even-odd, so the cap inside this one is a hole rather than a
            // second coat.
            context.fillPath(using: .evenOdd)
        }
    }

    /// Everything on the face you can see where the sun is at or below one
    /// elevation, as a path to fill. Nil where there is none of it in view.
    ///
    /// ## The shape
    ///
    /// The ground darker than a given sun elevation is a cap of the sphere
    /// centred on the antisolar point — its edge the small circle where the
    /// sun's own direction has a fixed, negative component. What you can see is
    /// another cap, centred on the camera. So the region is the overlap of two
    /// caps, and every case of that is here rather than searched for:
    ///
    /// - the edge crosses the limb, which is the ordinary evening: the visible
    ///   arc of it, closed along the piece of limb the dark is on;
    /// - the edge is round the back, so the whole face is one side of it —
    ///   all of it or none of it;
    /// - the edge is wholly on the near side, and the region is the closed
    ///   curve itself: the dark cap sitting inside the disc, which is what the
    ///   small hours look like from over the night side.
    ///
    /// The discriminant is one comparison. Every point of the edge has depth
    /// `spin·across·cos φ − h·facing`, so the edge reaches the limb exactly
    /// when `|h| ≤ across` — and when it does not, the sign of `−h·facing`
    /// says which side of the planet it is round.
    private func cap(
        belowElevation degrees: Double,
        basis: GlobeCamera.Basis,
        sun: SIMD3<Float>
    ) -> CGPath? {
        let radius = camera.radius
        guard radius > 0 else { return nil }

        // How far the sun is below the horizon on the edge of this cap, as the
        // sine that a dot product against the sun's direction can be compared
        // to directly.
        let h = Float(-sin(degrees * .pi / 180))

        // How much of the sun's direction points at the camera, and how much
        // of it lies across the view — the second of which is also the sine of
        // the deepest the sun gets anywhere on the limb, and so the whole of
        // what decides whether this cap's edge reaches it.
        let facing = simd_dot(sun, basis.out)
        let across = simd_length(simd_cross(sun, basis.out))

        func screen(_ vector: SIMD3<Float>) -> CGPoint {
            CGPoint(
                x: camera.center.x + CGFloat(simd_dot(vector, basis.east)) * radius,
                y: camera.center.y - CGFloat(simd_dot(vector, basis.north)) * radius
            )
        }

        func disc() -> CGPath {
            let path = CGMutablePath()
            path.addEllipse(in: discBox)
            return path
        }

        // The sun straight ahead or straight behind. The cap is then centred on
        // the middle of the view, so its edge is a plain circle and the frame
        // the general case is built in — the direction in the cap's plane that
        // leans furthest towards the camera — does not exist.
        guard across > 1e-4 else {
            guard facing < 0 else { return nil }
            let spread = radius * CGFloat((1 - h * h).squareRoot())
            let path = CGMutablePath()
            path.addEllipse(in: CGRect(
                x: camera.center.x - spread,
                y: camera.center.y - spread,
                width: spread * 2,
                height: spread * 2
            ))
            return path
        }

        // The edge, as a circle in its own plane: the antisolar direction taken
        // in by `h`, plus a radius spun about it. `towards` is the way that
        // leans furthest towards the camera, so the angle runs outwards from
        // the middle of what you can see in both directions.
        let spin = (1 - h * h).squareRoot()
        let towards = (basis.out - sun * facing) / across
        let sideways = simd_cross(sun, towards)

        func edge(_ angle: Float) -> SIMD3<Float> {
            sun * (-h) + (towards * cos(angle) + sideways * sin(angle)) * spin
        }

        // The edge never reaches the limb.
        guard abs(h) <= across else {
            guard h * facing < 0 else {
                // Round the back: the whole face is on one side of it, and
                // which side is one comparison at the middle of the view.
                return facing <= -h ? disc() : nil
            }

            // Wholly on the near side: the cap is a closed curve in the disc.
            let path = CGMutablePath()
            for step in 0...Self.nightEdgeSteps {
                let angle = Float(step) / Float(Self.nightEdgeSteps) * 2 * .pi
                let point = screen(edge(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        }

        // The ordinary evening. The edge is visible out to where its depth
        // runs out, which is the angle either side of `towards` at which the
        // two terms of it cancel.
        let reach = acos(min(1, max(-1, h * facing / (spin * across))))

        let path = CGMutablePath()
        for step in 0...Self.nightEdgeSteps {
            let angle = -reach + 2 * reach * Float(step) / Float(Self.nightEdgeSteps)
            let point = screen(edge(angle))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }

        // Home along the limb. Both ends of the arc sit on it, and the piece to
        // close along is the piece the dark is on — which is the one containing
        // the bearing of the antisolar point, since a point on the limb has no
        // depth for anything else to decide it.
        let from = limbAngle(of: screen(edge(reach)))
        let to = limbAngle(of: screen(edge(-reach)))
        let darkest = atan2(
            CGFloat(simd_dot(sun, basis.north)),
            CGFloat(-simd_dot(sun, basis.east))
        )

        var sweep = Self.turn(from: from, to: to)
        if Self.turn(from: from, to: darkest) > sweep { sweep -= 2 * .pi }

        for step in 1...Self.limbSteps {
            let angle = from + sweep * CGFloat(step) / CGFloat(Self.limbSteps)
            path.addLine(to: CGPoint(
                x: camera.center.x + cos(angle) * radius,
                y: camera.center.y + sin(angle) * radius
            ))
        }
        path.closeSubpath()
        return path
    }

    /// How finely a cap's edge and the limb it closes along are walked.
    ///
    /// The edges are nearly parallel to each other and sampled at the same
    /// angles, so whatever a chord loses, every band loses identically and they
    /// stay the even width they should be.
    private static let nightEdgeSteps = 64
    private static let limbSteps = 48

    /// The bearing of a point on the limb, about the middle of the disc.
    private func limbAngle(of point: CGPoint) -> CGFloat {
        atan2(point.y - camera.center.y, point.x - camera.center.x)
    }

    /// The turn from one bearing to another, going the way angles increase.
    /// Always in `[0, 2π)`, so a caller can ask whether a third bearing is
    /// inside it by comparing two of these.
    private static func turn(from: CGFloat, to: CGFloat) -> CGFloat {
        var delta = (to - from).truncatingRemainder(dividingBy: .pi * 2)
        if delta < 0 { delta += .pi * 2 }
        return delta
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

        // Points per metre, and the zoom this layer starts at.
        //
        // A kilometre has to be worth a dozen points, which puts a three and a
        // half kilometre aerodrome at about forty across — a shape you can
        // read, rather than a smudge the ring and the code already say better.
        // That is a view some thirty kilometres wide, well inside the range
        // and well outside the two hundred metres the zoom now runs to.
        let perMetre = camera.radius / CGFloat(GlobeCamera.earthRadiusMetres)
        guard perMetre * 1000 > 12 else { return }

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

    /// Carries every aeroplane this frame is going to draw forward to now, and
    /// works out where each of them lands on screen.
    ///
    /// One pass for the whole frame, before anything is drawn, and both of
    /// those matter.
    ///
    /// *One*, because `FlightMotion` measures the step it takes from the last
    /// time it was asked. Asked twice in a frame it sees no elapsed time at
    /// all, takes the raw prediction, and the aeroplane snaps to it — which is
    /// precisely the jump the smoothing exists to remove. So the traffic, the
    /// dots and the head of the flown path all read the answers from here
    /// rather than each asking for their own.
    ///
    /// *Before*, because the flown path is drawn under the traffic and has to
    /// end where the aeroplane is going to be drawn, not where it was.
    ///
    /// Walked by index rather than by element, which is not a style choice. A
    /// `GlobeTrafficDot` carries two `String`s and a `UIColor?`, so binding one
    /// per iteration retains and releases three references — a packet of three
    /// thousand at sixty frames a second is over half a million retain/release
    /// pairs a second to read two vectors.
    private func flyTraffic(basis: GlobeCamera.Basis, box: CGRect) {
        marks.removeAll(keepingCapacity: true)
        openPlace = nil
        guard !scene.traffic.isEmpty else { return }

        let flying = isFlyingTraffic
        let now = CACurrentMediaTime()

        // An aeroplane whose last packet put it just off the edge may well
        // have flown onto it since, and it is the one arriving that a jump
        // would be most obvious on. So the screen test is widened by as far as
        // a prediction can reach — a few points at the zoom this runs at, and
        // nothing at all when it is switched off.
        let lead = flying
            ? CGFloat(FlightMotion.maximumLeadMetres / camera.metresPerPoint)
            : 0
        let reach = lead > 0.5 ? box.insetBy(dx: -lead, dy: -lead) : box

        for index in 0..<scene.traffic.count {
            var projected = camera.project(scene.traffic[index].position, using: basis)
            guard projected.isVisible, reach.contains(projected.point) else { continue }

            if flying, scene.flyForward(index, to: now) {
                projected = camera.project(scene.traffic[index].position, using: basis)
                guard projected.isVisible else { continue }
            }
            guard box.contains(projected.point) else { continue }

            // Two dot products for the sprite's angle. The heading is a
            // direction on the surface, and an orthographic projection is
            // linear, so where that direction lands on screen is the projection
            // of the direction itself — no second point to project and
            // subtract.
            let dx = CGFloat(simd_dot(scene.traffic[index].heading, basis.east))
            let dy = -CGFloat(simd_dot(scene.traffic[index].heading, basis.north))
            let place = scene.traffic[index].position
            marks.append((
                index: index,
                position: place,
                point: projected.point,
                angle: atan2(dx, -dy)
            ))
            if scene.traffic[index].isOpen { openPlace = place }
        }
    }

    private func drawTraffic(in context: CGContext, basis: GlobeCamera.Basis) {
        guard !marks.isEmpty || replay != nil else { return }

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
            drawPlanes(in: context, basis: basis)
        } else {
            drawDots(in: context, basis: basis)
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
        basis: GlobeCamera.Basis
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

        // Where everything is was worked out once for the whole frame, before
        // any of it was drawn — see `flyTraffic`.
        startCrowding(mark: size)

        for mark in marks {
            let dot = scene.traffic[mark.index]

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
            if dot.tint == nil, isCrowded(at: mark.position) { continue }

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

    /// Patches of the *sphere* already spoken for this frame, and how many of
    /// them there are to a radian.
    private var crowd: Set<SIMD3<Int32>> = []
    private var crowdScale: Double = 0

    /// Stops drawing marks on top of marks.
    ///
    /// ## The arithmetic of a full planet
    ///
    /// Pulled all the way back, a packet is three thousand aircraft on a disc
    /// about three hundred and thirty points across, and half of those are
    /// round the back. What is left is fifteen hundred marks, thirteen points
    /// on a side, poured into forty thousand square points of planet — every
    /// part of the picture several aeroplanes deep, most of them painted over
    /// before the frame ends. Each one is a *rotated* blit, which is a
    /// resample rather than a copy, so at two or three pixels to the point
    /// that is the frame.
    ///
    /// ## Cells on the sphere, not on the screen
    ///
    /// The first version of this laid a grid over the *view*, and that grid
    /// made the traffic flicker. An aeroplane does not move relative to its
    /// neighbours when the planet turns — but the cell edges do, sweeping
    /// across the screen with the camera, so a pair straddling one would share
    /// a cell on one frame and hold two on the next, and the loser blinked on
    /// and off at the rate the boundary crossed it.
    ///
    /// The cells are patches of the sphere instead. An aeroplane's cell is a
    /// function of its own position and the zoom and nothing else, so turning
    /// the planet, dragging it, or letting it glide cannot change who wins:
    /// the positions do not move and neither do the cells. The size is snapped
    /// to a power of two of a radian, so a pinch does not resize them
    /// continuously either — it steps, once an octave, while everything on
    /// screen is already changing size.
    ///
    /// What is dropped is only ever a mark that would have been drawn on top
    /// of another. Anything the colouring has singled out skips the grid, and
    /// the hit test still walks the whole packet, so an aeroplane that was not
    /// drawn is still one you can tap.
    private func beginCrowding(points: CGFloat) {
        crowd.removeAll(keepingCapacity: true)
        guard camera.radius > 0 else { crowdScale = 0; return }

        // Points of screen into an angle on the sphere, then up to the next
        // power of two so that it only ever changes in steps.
        let wanted = Double(max(3, points) / camera.radius)
        let cell = exp2(log2(wanted).rounded(.up))
        // Capped so that a cell index can never leave `Int32`, whatever the
        // radius: converting a Double that does not fit is a trap, and a crash
        // is a poor way to declutter a map.
        crowdScale = cell > 0 ? min(1 / cell, 1e8) : 0
    }

    /// Sizes the traffic's cells so that what will actually be *drawn* comes
    /// under the budget.
    ///
    /// How many fill is not how many are on screen, and the difference is the
    /// whole trick: a full planet is mostly aeroplanes on top of aeroplanes,
    /// so opening the grid by the ratio of the packet to the budget opens it
    /// far too far and leaves a lattice. One measured pass says how many the
    /// natural spacing draws; each doubling of the cell quarters that, so the
    /// number of doublings is arithmetic rather than a search.
    private func startCrowding(mark: CGFloat) {
        let natural = mark * 0.6
        beginCrowding(points: natural)
        guard marks.count > Self.trafficBudget else { return }

        var filled = 0
        for candidate in marks where !isCrowded(at: candidate.position) { filled += 1 }

        guard filled > Self.trafficBudget else {
            beginCrowding(points: natural)
            return
        }

        let doublings = (log2(Double(filled) / Double(Self.trafficBudget)) / 2).rounded(.up)
        beginCrowding(points: natural * CGFloat(exp2(max(1, min(6, doublings)))))
    }

    /// How many aircraft are worth drawing in one frame.
    ///
    /// One number rather than one for moving and one for resting. Two of them
    /// meant the traffic thinned out the moment a finger landed and thickened
    /// again when it lifted, which is the same "it redraws itself when you let
    /// go" the level of detail used to do. What a frame can afford is handled
    /// by `tuneResolution` instead, which changes how many *pixels* each of
    /// these costs rather than how many of them there are.
    private static let trafficBudget = 1200

    private func isCrowded(at position: SIMD3<Float>) -> Bool {
        guard crowdScale > 0 else { return false }
        let cell = SIMD3<Int32>(
            Int32((Double(position.x) * crowdScale).rounded(.down)),
            Int32((Double(position.y) * crowdScale).rounded(.down)),
            Int32((Double(position.z) * crowdScale).rounded(.down))
        )
        return !crowd.insert(cell).inserted
    }

    private func drawDots(
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

        for mark in marks {
            let dot = scene.traffic[mark.index]

            if dot.isOpen {
                if replay == nil { open.append(mark.point) }
                continue
            }

            let colour = dot.tint ?? palette.traffic
            let box = CGRect(
                x: mark.point.x - size,
                y: mark.point.y - size,
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

        // The same grid the traffic uses, at about the width of a code.
        //
        // Pulled back, every field the map has ranked lands on a disc three
        // hundred points across, and a couple of hundred four-letter codes in
        // that space is not a list of aerodromes, it is a texture — nothing in
        // it can be read, and each one costs a stroked ring and a blit. One
        // code to a patch of screen, in the order the map ranked them, so what
        // survives is what it thought mattered.
        //
        // A field somebody is working skips the grid, the way a coloured
        // aircraft does. It is the one thing about a field you cannot work out
        // by looking at the traffic, and it is never the thing to drop.
        beginCrowding(points: 30)

        // Rendered before the drawing starts rather than as each one is
        // reached. A label is drawn into an image renderer, which pushes a
        // context of its own, and doing that in the middle of a run of state
        // changes on this one is the kind of thing that works until it doesn't.
        // Cached across frames, so this is a dictionary lookup after the first.
        for field in fields { _ = labelImage(field.icao) }

        for field in fields {
            let projected = camera.project(field.position, using: basis)
            guard projected.depth > 0.02, box.contains(projected.point) else { continue }

            if !field.isControlled, isCrowded(at: field.position) { continue }

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
