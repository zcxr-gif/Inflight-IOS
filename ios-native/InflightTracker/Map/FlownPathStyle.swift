import CoreLocation
import MapKit
import UIKit

/// How the flown path is drawn: how wide, and in what.
///
/// ## Why the width is not one number
///
/// A stroke set in points is that many points wide at every zoom, which sounds
/// like what you want and is why the path looked like rope from any distance. A
/// track is not a road. Zoomed in, the line follows a wide gap between samples
/// and its width reads as the width of the line. Pulled back to the whole
/// flight, the same track is a tangle of switchbacks compressed into a couple
/// of hundred pixels, and a stroke that stays wide while the gaps between its
/// own turns fall below a point stops being a line and becomes a filled shape.
/// So: narrower the further back you stand.
///
/// Interpolated on the log of the camera distance rather than on the distance
/// itself, because that is how zoom works — each step out doubles what is on
/// screen, so a linear ramp would spend almost all of its travel in the first
/// aerodrome-sized fraction of the range and then sit at its minimum across
/// every view that actually shows a flight.
///
/// ## And why it is not as thin as it was
///
/// The taper used to run to a little over two points, which put the flown track
/// *narrower than the filed plan's casing* across every view that shows a whole
/// flight. That is the wrong way round, and obviously so. The plan is a
/// statement of intent; the track is what the aeroplane actually did. Pulled
/// back over an ocean the map was drawing the intention louder than the fact,
/// and the one line somebody had zoomed out to look at was the fainter of the
/// two.
///
/// So the floor came up, and the filed plan learnt to taper as well — see
/// `PlanStyle.lineWidth(forCameraDistance:)`, which is written against these
/// numbers so the track stays the heavier of the two at every zoom rather than
/// only at the one somebody checked.
enum FlownPathStyle {

    /// Wide enough to read as a drawn line over cartography and imagery both.
    ///
    /// This is the width at the field, where the track is read against runway
    /// edges and taxiway centrelines — things Apple draws a couple of points
    /// wide. A track thinner than the pavement it crosses reads as part of the
    /// basemap rather than as the flight.
    static let closeWidth: CGFloat = 4.6

    /// Narrow enough that a long-haul's turns are still separate lines rather
    /// than one shape, and no narrower.
    ///
    /// The old floor of 2.1 was chosen against the switchbacks of a track that
    /// has been holding, which at this distance are a few pixels across and
    /// unreadable at any width. What it cost was every ordinary case: a cruise
    /// track pulled back to the whole flight is one smooth line, and a smooth
    /// line two points wide over satellite imagery is a scratch.
    static let farWidth: CGFloat = 3.2

    /// The camera distances the two widths belong to, in metres. Below the
    /// first you are looking at a circuit, above the second at the planet.
    static let closeDistance: CLLocationDistance = 150_000
    static let farDistance: CLLocationDistance = 8_000_000

    static func width(forCameraDistance distance: CLLocationDistance) -> CGFloat {
        guard distance.isFinite, distance > 0 else { return closeWidth }
        if distance <= closeDistance { return closeWidth }
        if distance >= farDistance { return farWidth }

        let travel = log(distance / closeDistance) / log(farDistance / closeDistance)
        return closeWidth + (farWidth - closeWidth) * CGFloat(travel)
    }

    /// How far the halo stands out past the core, as a multiple of the core's
    /// width.
    ///
    /// A halo rather than a second line: far enough out that its edge is
    /// nowhere near the core's, so the two read as one soft-edged thing rather
    /// than as a stripe with a border.
    static let glowSpread: CGFloat = 2.2

    /// And how much of it there is.
    ///
    /// Low, and it has to be: this is a wash of the path's own colour laid over
    /// the map, so every point of opacity is a point of cartography lost. At
    /// about a quarter it lifts the line off a dark map and is very nearly
    /// invisible on a light one, which is the right way round — a glow is a
    /// thing you notice against darkness.
    ///
    /// A little more than it was, for the same reason the floor came up: pulled
    /// back to a whole flight, the halo is most of what makes the track read as
    /// a lit line rather than as a scratch, and it is the part that survives
    /// being scaled down.
    static let glowOpacity: CGFloat = 0.26

    /// A core colour every one of whose channels is at least this bright
    /// cannot lift itself off the map, and the halo behind it has to be dark
    /// instead.
    ///
    /// The darkest channel rather than a lightness, because lightness puts
    /// amber — which is 0.95, 0.71, 0.11 and about as pale as a hue can be
    /// while still obviously being one — within a rounding error of the
    /// threshold. Its darkest channel is a tenth, and white's is one; there is
    /// nothing to argue about in between.
    private static let paleCore: CGFloat = 0.85

    /// What the halo under a stretch of path is drawn in.
    ///
    /// Ordinarily the path's own colour: a wash of the same hue, which reads as
    /// a glow around the line and is why a crimson track stands off a dark map.
    ///
    /// The ground is the exception, and it has to be. That part of the track is
    /// white — see `AltitudeBand.groundColor` — and a white glow behind a white
    /// line over pale cartography or a pale apron is nothing behind nothing.
    /// So a core too light to lift itself gets the opposite: a dark halo, which
    /// is a shadow rather than a glow and does the same job from the other
    /// side. It is the same bargain the filed plan makes with its casing.
    ///
    /// Decided from the colour rather than from a flag, so there is one rule
    /// and nothing to keep in step: any pale colour this ramp ever grows gets a
    /// readable edge without anybody remembering to ask for one.
    static func halo(for core: UIColor) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard core.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return core }
        guard min(red, green, blue) >= paleCore else { return core }
        return UIColor(white: 0, alpha: alpha)
    }
}

/// The flown path: one overlay, drawn by hand.
///
/// ## What was here before, and why none of it survived
///
/// The track used to be two `MKGeodesicPolyline`s — a wide translucent one for
/// the halo and a narrow solid one on top — each drawn by an
/// `MKGradientPolylineRenderer` handed a list of colour stops. Every part of
/// that arrangement was a bug.
///
/// **The halo left the path.** A stroke is only a tidy outline of its centre
/// line while the line's turn radius stays comfortably wider than the stroke is
/// thick. A halo three times the core's width, on a taxi turn or a hold, is
/// far wider than the radius it is going round — so it stopped tracking the
/// path and bulged off the outside of every tight corner.
///
/// **And it blotched.** Two translucent strokes of the same geometry stack
/// their alpha wherever the track crosses itself, and a flown path crosses
/// itself constantly — holds, circuits, a taxi back down the same taxiway. Each
/// crossing came out darker than the line either side of it.
///
/// **The colours were in the wrong places.** `MKGradientPolylineRenderer` takes
/// its stops as fractions along the line, and the fractions were worked out on
/// the raw samples while the line drawn was the smoothed curve through them,
/// expanded again by `MKGeodesicPolyline` into however many points MapKit felt
/// like. Three different parameterisations of the same track, and the ramp was
/// laid against the wrong one.
///
/// ## What it does instead
///
/// One overlay, one renderer, and the drawing done here rather than asked for.
///
/// The colour is per segment, so there is no ramp to place and nothing to get
/// out of step: the piece of track between two samples is stroked in the colour
/// of the height at those samples, because that is the piece of track flown at
/// that height. Exact by construction.
///
/// The halo is the same path drawn wide *inside a transparency layer* — the
/// whole wide stroke is composited once, as a group, and only then faded. Self
/// overlap inside the layer is opaque-on-opaque and vanishes, which is the
/// whole fix for the blotching. And it is drawn at a much gentler spread, so it
/// stays a halo on the line rather than a shape beside it.
struct FlownPath {

    /// One point on the drawn curve, with the colour the track carries there.
    struct Node {
        let point: MKMapPoint
        let color: UIColor
    }

    let overlay: FlownPathOverlay

    /// At most this many samples are coloured individually.
    ///
    /// A fourteen-hour track is a couple of thousand samples. Every one of them
    /// getting its own colour is arithmetic nobody can resolve — the ramp is
    /// smooth by design, so dropping intermediate samples on a continuous climb
    /// changes nothing anyone could see, and a step sharp enough to matter is
    /// one the remaining samples still bracket. The *geometry* keeps every
    /// point either way; this only thins how often the colour is recomputed.
    private static let maximumColourSamples = 256

    /// Builds the path from a track and the band of each sample.
    ///
    /// `bands` is parallel to `points` and carries nil where the height was
    /// never sent — those stretches take the unknown grey, so a path that
    /// starts without heights and picks them up mid-flight fades into its
    /// colours rather than switching into them.
    ///
    /// `onPavement` is parallel too, and marks the ground part: geometry that
    /// has been matched onto the taxiways and is already exactly the shape of
    /// the concrete. It is handed straight to the smoothing, which leaves those
    /// corners alone — see `PathSmoothing`. Empty means nothing is on pavement,
    /// which is every track drawn without the ground layout.
    init?(
        points: [TrackPoint],
        bands: [Int?],
        onPavement: [Bool] = [],
        title: String
    ) {
        guard points.count >= 2, bands.count == points.count else { return nil }

        // The colour at each *sample*, before the curve is drawn through them.
        let step = max(1, Int((Double(points.count) / Double(Self.maximumColourSamples)).rounded(.up)))
        var sampleColors: [UIColor] = []
        sampleColors.reserveCapacity(points.count)
        var lastColor = Self.color(for: bands[0], at: points[0])
        for index in points.indices {
            // The one place the stride cannot be trusted: the moment the
            // aircraft leaves the ground or arrives on it.
            //
            // Everything else on this ramp is continuous, which is what makes
            // the thinning free — a colour held for three samples of a cruise
            // leg is the colour those three samples had, and a step sharp
            // enough to matter is one the remaining samples still bracket. The
            // ground is not on the ramp at all; it is a switch. Left to the
            // stride, a take-off could carry its white a dozen samples past the
            // runway, and at two nautical miles a sample that is a white line
            // halfway to the first waypoint.
            let leaves = index > 0 && points[index].isAirborne != points[index - 1].isAirborne

            // Recomputed on the stride, at that switch, and always at the ends.
            // In between it carries the last one forward.
            if index % step == 0 || leaves || index == points.count - 1 {
                lastColor = Self.color(for: bands[index], at: points[index])
            }
            sampleColors.append(lastColor)
        }

        // The curve, and which sample each of its points came from. Smoothing
        // inserts points *between* samples, so the colour of an inserted point
        // is the colour of the sample it was inserted after — which is exactly
        // the piece of track it belongs to.
        let smoothed = PathSmoothing.smoothedWithOrigins(
            points.map(\.coordinate),
            straight: onPavement
        )
        guard smoothed.coordinates.count >= 2 else { return nil }

        var nodes: [Node] = []
        nodes.reserveCapacity(smoothed.coordinates.count)
        for (index, coordinate) in smoothed.coordinates.enumerated() {
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let origin = min(smoothed.origins[index], sampleColors.count - 1)
            nodes.append(Node(point: MKMapPoint(coordinate), color: sampleColors[origin]))
        }
        guard nodes.count >= 2 else { return nil }

        guard let overlay = FlownPathOverlay(nodes: nodes, title: title) else { return nil }
        self.overlay = overlay
    }

    /// A sample's colour: the unknown grey where no height was sent, white
    /// where the aircraft was on the ground, and the height everywhere else.
    ///
    /// White for the ground because the ramp answers "how high" and on the
    /// ground that has no interesting answer — see `AltitudeBand.groundColor`.
    /// A taxi coloured by the elevation of the aerodrome under it is a claim
    /// about the field rather than about the aeroplane.
    ///
    /// The test is `TrackPoint.isAirborne`, which is the same rule the phase
    /// chip prints beside the callsign. One notion of "on the ground" in the
    /// app: the word next to the registration and the colour of the line under
    /// the aeroplane cannot disagree, because they are the same question.
    ///
    /// Asked *after* the unknown, and that order is the whole of what keeps it
    /// honest. "On the ground" reads low and slow, and a track the backend sent
    /// without heights or speeds reads low and slow too — so asking the ground
    /// first would paint a whole data-less transatlantic white and call it a
    /// taxi. The grey already means "we were not told", which is the true
    /// answer there, and a sample with a known height cannot be mistaken for
    /// one without.
    ///
    /// Interpolated through `color(forFeet:)` rather than snapped to the band's
    /// own colour. The band is still what decides whether a height is *known* —
    /// that judgement is about runs of zeroes and belongs where it is — but
    /// once it is known there is no reason to throw the feet away and draw the
    /// middle of the band the aircraft happened to be in.
    ///
    /// Not private, because the planet draws the same track and has to draw it
    /// in the same colours: a path that changes hue when you change the shape
    /// of the world is telling you about the renderer rather than about the
    /// flight. See `GlobeFlownPath`.
    static func color(for band: Int?, at point: TrackPoint) -> UIColor {
        guard band != nil else { return AltitudeBand.unknownColor }
        guard point.isAirborne else { return AltitudeBand.groundColor }
        return AltitudeBand.color(forFeet: point.altitudeFeet)
    }

    /// How far a path can run at exactly zero feet before the zero is read
    /// as missing rather than as low.
    ///
    /// A flight from a sea-level field reports tens of feet, not a clean
    /// zero, and an aircraft that never leaves the apron does not travel
    /// twenty miles. A run that does both is a height the backend did not
    /// send.
    private static let unknownHeightRunNM: Double = 20

    /// The band each sample belongs in, or nil where its height is missing
    /// rather than low.
    ///
    /// Judged per run rather than over the whole path: a track seeded from
    /// the backend without heights, with the live position on the end of
    /// it, is the ordinary case — and it should draw as an unknown path
    /// that becomes a coloured one, not as a flight that spent three hours
    /// on the deck.
    ///
    /// Here rather than on either map, because both of them draw this track
    /// and neither of them owns the rule.
    static func heightBands(of points: [TrackPoint]) -> [Int?] {
        var bands: [Int?] = points.map { AltitudeBand.band(forFeet: $0.altitudeFeet) }

        var start = 0
        while start < points.count {
            guard points[start].altitudeFeet == 0 else {
                start += 1
                continue
            }

            var end = start
            while end + 1 < points.count, points[end + 1].altitudeFeet == 0 { end += 1 }

            let spanNM = FlightProgress.distanceNM(
                from: points[start].coordinate,
                to: points[end].coordinate
            )
            if spanNM > unknownHeightRunNM {
                for index in start...end { bands[index] = nil }
            }

            start = end + 1
        }

        return bands
    }
}

/// The overlay itself: a run of projected points, each with a colour.
///
/// Points rather than coordinates, and projected once here rather than per
/// frame in the renderer. `MKMapPoint(_:)` is a projection with trigonometry in
/// it, the renderer runs on every tile of every frame of a pan, and the answer
/// never changes — so it is worked out when the track does.
final class FlownPathOverlay: NSObject, MKOverlay {

    let nodes: [FlownPath.Node]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D
    let title: String?

    /// Where the aeroplane is being drawn *this frame*, past the end of the
    /// track the feed has told us about.
    ///
    /// The track ends at the newest breadcrumb, and breadcrumbs are thinned by
    /// distance — two nautical miles apart at best, and more on a long flight.
    /// So between one and the next the aeroplane flies off the end of its own
    /// path, a gap opens behind it, and when the next sample lands the line
    /// catches up in one jump. Meanwhile the aircraft itself is being carried
    /// smoothly forward thirty times a second by `FlightMotion`.
    ///
    /// This is the piece that closes that gap: one segment from the last
    /// sample to wherever the aeroplane is right now, written by the same frame
    /// clock that moves the aeroplane, so the track grows with it rather than
    /// in steps behind it.
    ///
    /// Nil when there is nothing to draw — no open aircraft, or the aeroplane
    /// has run outside the room this overlay reserved for it, which is the
    /// signal that the path wants rebuilding rather than extending.
    ///
    /// Behind a lock, and it is the one piece of this overlay that needs one.
    /// Everything else was worked out once and never changes, which is why the
    /// renderer has always been free to run wherever MapKit felt like running
    /// it — and it does run a draw off the main thread. This is written by the
    /// frame clock on the main thread and read inside that draw, so the two
    /// have to agree about when.
    var head: MKMapPoint? {
        get {
            headLock.lock()
            defer { headLock.unlock() }
            return storedHead
        }
        set {
            headLock.lock()
            storedHead = newValue
            headLock.unlock()
        }
    }

    private var storedHead: MKMapPoint?
    private let headLock = NSLock()

    /// The end of the drawn track: where `head` grows from.
    let tail: MKMapPoint

    /// How far the head may run from `tail` before it would be drawn outside
    /// the rect this overlay is allowed to paint in.
    ///
    /// MapKit reads `boundingMapRect` when the overlay is added and asks for
    /// tiles inside it and nowhere else, so a head beyond this one would simply
    /// not be drawn. Reserved up front, and checked before every write.
    private let headRoom: MKMapRect

    /// Whether a position is inside the room reserved for the head.
    func canReach(_ point: MKMapPoint) -> Bool { headRoom.contains(point) }

    /// Where the track jumps the antimeridian, as indices into `nodes`.
    ///
    /// A projected x of nearly the world's width between two points is not a
    /// leg, it is the seam: the aircraft crossed 180° and the two points landed
    /// on opposite edges of the map. Stroked through, that is a line straight
    /// back across the planet. The renderer lifts the pen at these instead.
    let breaks: Set<Int>

    init?(nodes: [FlownPath.Node], title: String) {
        guard nodes.count >= 2 else { return nil }

        var breaks: Set<Int> = []
        var minX = nodes[0].point.x
        var maxX = nodes[0].point.x
        var minY = nodes[0].point.y
        var maxY = nodes[0].point.y

        let world = MKMapRect.world.size.width
        for index in 1..<nodes.count {
            let point = nodes[index].point
            if abs(point.x - nodes[index - 1].point.x) > world / 2 { breaks.insert(index) }
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }

        self.nodes = nodes
        self.breaks = breaks
        // Padded by a slice of its own size, so a stroke drawn wider than the
        // geometry — which is the whole of the halo — is not clipped off at the
        // edges of the rect it is allowed to draw in.
        //
        // A share of the span rather than a fixed distance, because the stroke
        // is a share of the span too. A width in points becomes a width in map
        // units by dividing by the zoom scale, and you only ever pull back far
        // enough for the track to fill the screen — at which point the zoom
        // scale is roughly the screen's width over the track's, and the stroke
        // lands at about one per cent of the span however long the flight was.
        // Five leaves room over the widest the halo gets.
        let padding = max((maxX - minX), (maxY - minY)) * 0.05 + 1_000

        // And room off the end for the live head to grow into. See `head`: it
        // is written between rebuilds, and a rect that stopped at the last
        // sample would leave it undrawn.
        let end = nodes[nodes.count - 1].point
        let reach = Self.headRoomMetres * MKMapPointsPerMeterAtLatitude(end.coordinate.latitude)
        let room = MKMapRect(
            x: end.x - reach,
            y: end.y - reach,
            width: reach * 2,
            height: reach * 2
        )

        self.tail = end
        self.headRoom = room
        self.boundingMapRect = MKMapRect(
            x: minX - padding,
            y: minY - padding,
            width: (maxX - minX) + padding * 2,
            height: (maxY - minY) + padding * 2
        ).union(room)
        self.coordinate = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2).coordinate
        self.title = title
        super.init()
    }

    /// How far past the last sample the head is allowed to run.
    ///
    /// The path is rebuilt every time the trail gains a breadcrumb, which is
    /// every two nautical miles at the tightest spacing the store uses — about
    /// sixteen seconds at cruise. Forty kilometres is ten times that, which
    /// covers the coarser spacing a long flight thins itself to and leaves the
    /// case where it does not to the span-proportional padding above, which by
    /// then is hundreds of kilometres wide.
    private static let headRoomMetres: CLLocationDistance = 40_000
}

/// Draws the track: a halo, then the line, both in one pass over the points.
final class FlownPathRenderer: MKOverlayRenderer {

    /// The core's width in points on screen, set by whoever knows where the
    /// camera is standing.
    ///
    /// In *points*, not in map units: the conversion needs the zoom scale, and
    /// that only exists inside a draw. Setting this does not repaint on its own
    /// — see `apply(width:)`.
    private(set) var width: CGFloat = FlownPathStyle.closeWidth

    private var path: FlownPathOverlay { overlay as! FlownPathOverlay }

    /// The scale the last draw ran at, so a repaint asked for outside a draw
    /// can work out how many map units the stroke is currently covering.
    ///
    /// A stroke's width is set in points on screen and drawn in map units, and
    /// the conversion is the zoom scale — which only exists inside `draw`. A
    /// dirty rect that did not allow for it would leave the halo's outer edge
    /// unrepainted, as a bright ghost trailing the aeroplane.
    private var lastZoomScale: MKZoomScale = 1

    func apply(width newWidth: CGFloat) {
        guard abs(newWidth - width) > 0.05 else { return }
        width = newWidth
        setNeedsDisplay()
    }

    /// Repaints just the strip the live head moved through.
    ///
    /// The head is written on every frame, and the track it belongs to is a
    /// few thousand points long — so this is deliberately not
    /// `setNeedsDisplay()`. What changed is one short segment's far end; the
    /// rest of the line is already correct on the tiles it was drawn into, and
    /// asking MapKit to rasterise them again thirty times a second is the
    /// whole cost of doing this badly.
    func refreshHead(from origin: MKMapPoint, to destination: MKMapPoint) {
        let scale = max(Double(lastZoomScale), .leastNormalMagnitude)
        let pad = Double(width * FlownPathStyle.glowSpread) / scale + 8

        let rect = MKMapRect(
            x: min(origin.x, destination.x),
            y: min(origin.y, destination.y),
            width: abs(destination.x - origin.x),
            height: abs(destination.y - origin.y)
        )
        setNeedsDisplay(rect.insetBy(dx: -pad, dy: -pad))
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        lastZoomScale = zoomScale

        let nodes = path.nodes
        guard nodes.count >= 2 else { return }

        // A stroke width set in map units draws that many *map units* wide, so
        // it doubles on screen every time you zoom in. Dividing by the zoom
        // scale is what pins it to the screen instead, and is the same trick
        // `MKPolylineRenderer` does internally with its own `lineWidth`.
        let core = width / zoomScale
        let halo = core * FlownPathStyle.glowSpread

        context.setLineCap(.round)
        context.setLineJoin(.round)

        // The halo first, and inside a transparency layer.
        //
        // This is the whole reason the glow no longer blotches. Stroking a wide
        // translucent line straight onto the context makes every self-crossing
        // composite twice and come out darker; drawing it opaque into a layer
        // and fading the finished layer composites the whole halo once, so a
        // hold or a taxi back down the same line is the same wash as a straight
        // leg beside it.
        context.setAlpha(FlownPathStyle.glowOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        stroke(nodes, width: halo, isHalo: true, in: context)
        context.endTransparencyLayer()
        context.setAlpha(1)

        stroke(nodes, width: core, isHalo: false, in: context)
    }

    /// One pass along the track, stroking each run of same-coloured segments.
    ///
    /// Batched rather than one stroke per segment: a colour thinned to a couple
    /// of hundred samples across a few thousand curve points means long runs
    /// share a colour, and each run is one path and one stroke.
    ///
    /// Segment `i` runs from node `i` to node `i + 1` and carries node `i`'s
    /// colour, because that is the piece of track flown at that height. A run
    /// ends where the colour changes or where the next node jumped the seam,
    /// and the next run starts at the node the last one finished on — so
    /// consecutive runs share a point and meet exactly, with a round cap over
    /// the join rather than a gap for the map to show through.
    private func stroke(
        _ nodes: [FlownPath.Node],
        width: CGFloat,
        isHalo: Bool,
        in context: CGContext
    ) {
        context.setLineWidth(width)

        let segments = nodes.count - 1
        var start = 0
        while start < segments {
            // A segment whose far node is across the antimeridian is not a leg.
            guard !path.breaks.contains(start + 1) else {
                start += 1
                continue
            }

            var end = start
            while end + 1 < segments,
                  !path.breaks.contains(end + 2),
                  nodes[end + 1].color == nodes[start].color {
                end += 1
            }

            context.beginPath()
            context.move(to: point(for: nodes[start].point))
            for step in (start + 1)...(end + 1) {
                context.addLine(to: point(for: nodes[step].point))
            }
            // The halo is not always the line's own colour — a white ground
            // track needs a dark one behind it rather than a white one. See
            // `FlownPathStyle.halo`.
            let colour = isHalo
                ? FlownPathStyle.halo(for: nodes[start].color)
                : nodes[start].color
            context.setStrokeColor(colour.cgColor)
            context.strokePath()

            // Always forward: `end` is never before `start`.
            start = end + 1
        }

        strokeHead(after: nodes, isHalo: isHalo, in: context)
    }

    /// The piece the feed has not caught up with: the last sample to wherever
    /// the aeroplane is being drawn this frame.
    ///
    /// Inside the same pass as everything else, which is what keeps the halo
    /// honest. Drawn separately it would be a second transparency layer over
    /// the first, and the two would composite at the join into a bright spot on
    /// an otherwise even wash.
    ///
    /// It carries the last sample's colour because that is the height the
    /// aircraft was last known to be at, and inventing a different one for a
    /// few seconds of track would be a claim about a climb nobody reported.
    private func strokeHead(after nodes: [FlownPath.Node], isHalo: Bool, in context: CGContext) {
        guard let head = path.head, let last = nodes.last else { return }

        // The seam, again: a head on the far side of the antimeridian from the
        // last sample is not a leg, and stroking it would draw a line back
        // across the planet.
        guard abs(head.x - last.point.x) < MKMapRect.world.size.width / 2 else { return }

        context.beginPath()
        context.move(to: point(for: last.point))
        context.addLine(to: point(for: head))
        context.setStrokeColor((isHalo ? FlownPathStyle.halo(for: last.color) : last.color).cgColor)
        context.strokePath()
    }
}
