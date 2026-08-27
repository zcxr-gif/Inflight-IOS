import CoreLocation
import MapKit
import UIKit

/// The flown track, as one overlay that draws itself.
///
/// ## What was wrong with drawing it as polylines
///
/// It was two `MKGeodesicPolyline`s — a casing and a coloured core — of about
/// three thousand points each, drawn by an `MKPolylineRenderer` and an
/// `MKGradientPolylineRenderer`. Every part of that is more work than the
/// picture needs, and the reasons compound:
///
/// * **`MKOverlayPathRenderer` has no idea what is on screen.** It hands Core
///   Graphics the whole path for every tile it is asked to draw and lets CG
///   clip. Zoom into one turn of a transatlantic track and MapKit re-strokes
///   three thousand points, twice, for each of the tiles under your finger, to
///   put a few hundred pixels on the screen. That is the zoom-in cliff.
/// * **The curve is drawn at a fixed resolution rather than the screen's.**
///   Three thousand points is the right number when you are looking at one
///   turn. Pulled back to the whole flight it is thousands of sub-pixel
///   segments, all of them stroked, none of them resolvable.
/// * **Geodesic on top of a spline is work for nothing.** The smoothing has
///   already put a point every fraction of a mile; MapKit then interpolates a
///   great circle between each of those pairs, which at that spacing is the
///   straight line it was given, densified again.
/// * **The gradient renderer is the dearest MapKit has**, and it was being run
///   over a path whose colour only ever changes slowly.
///
/// ## What this does instead
///
/// One overlay, one renderer, and the drawing bounded by the screen rather than
/// by the length of the flight:
///
/// * **Only what is visible.** Each segment is tested against the tile before
///   anything is drawn.
/// * **Only what can be seen.** The curve is resampled at draw time to about a
///   point of screen per segment. Zoomed out, a three-thousand-point track
///   collapses to a few hundred; zoomed in, every one of them is drawn. Work is
///   proportional to the pixels on screen, not to the hours in the air.
/// * **Casing and colour in one pass**, over the same resampled run, so the
///   second overlay is gone.
///
/// ## And it can be prettier for it
///
/// Bounded work buys detail elsewhere. The track now **tapers**: narrow at the
/// oldest end, full width at the aircraft. A flight path is a thing with a
/// direction and a present moment, and a wire of constant width says neither. It
/// also settles the far-zoom problem the width ramp exists for — the tangle of
/// old switchbacks is drawn thinner than the leg being flown now, so the recent
/// track reads through it instead of being lost in it.
///
/// The colour is interpolated per drawn segment from the samples either side,
/// so the ramp is genuinely continuous rather than a couple of hundred stops
/// with the aeroplane's own height quantised into one of them.
final class FlownPathOverlay: NSObject, MKOverlay {

    /// One point on the curve, ready to draw.
    struct Node {
        /// Unwrapped: continuous across the antimeridian, so `x` may sit
        /// outside the world. See `unwrap`.
        let point: MKMapPoint
        /// Resolved once here rather than per draw. The ramp's colours are
        /// plain sRGB — nothing in it varies with the trait collection — so
        /// there is no appearance to resolve it against, and a few hundred
        /// `cgColor` bridges per tile is work for nothing.
        let color: CGColor
        /// Where this sits along the whole track, 0 at the oldest end and 1 at
        /// the aircraft. Drives the taper.
        let along: CGFloat
    }

    let nodes: [Node]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    /// Map points per metre at the track's own latitude.
    ///
    /// The renderer needs it to answer "how much ground is a point of screen
    /// covering", which is what the width ramp is written in terms of. Taken at
    /// the track's centre and held: a flight can cross a lot of latitude, but
    /// the ramp is a judgement about how zoomed in you are, and a width that
    /// changed along the length of one track would read as a mistake.
    let mapPointsPerMetre: Double

    /// The copies of the world to draw. `[0]` for a track that stays on one
    /// side of the antimeridian, which is nearly all of them.
    let worldOffsets: [Double]

    /// Builds the drawable track from a trail and the altitude band of each
    /// sample.
    ///
    /// `bands` is parallel to `points` and carries nil where the height was
    /// never sent — those take the unknown grey, so a track that starts without
    /// heights and picks them up mid-flight fades into its colours rather than
    /// switching into them.
    init?(points: [TrackPoint], bands: [Int?]) {
        guard points.count >= 2, bands.count == points.count else { return nil }

        let sampleColors = zip(points, bands).map { point, band in
            band == nil ? AltitudeBand.unknownColor : AltitudeBand.color(forFeet: point.altitudeFeet)
        }

        let curve = PathSmoothing.smoothed(points.map(\.coordinate))
        guard curve.count >= 2 else { return nil }

        let unwrapped = Self.unwrap(curve.map { MKMapPoint($0.coordinate) })

        // How far along each point sits, by distance rather than by index. The
        // trail thins itself as it grows — the oldest samples are four or eight
        // miles apart where the newest are two — so counting indices would put
        // the taper's midpoint nowhere near the middle of the flight.
        //
        // In map points rather than metres, deliberately: the taper is a fact
        // about the drawn line, the drawn line is in map points, and
        // `MKMapPoint.distance(to:)` answers in metres — a different quantity,
        // and one with no meaning at all for the unwrapped x below.
        var travelled: [Double] = [0]
        travelled.reserveCapacity(unwrapped.count)
        var total = 0.0
        for index in 1..<unwrapped.count {
            total += Self.separation(unwrapped[index], unwrapped[index - 1])
            travelled.append(total)
        }
        guard total > 0, total.isFinite else { return nil }

        let lastSample = sampleColors.count - 1
        var nodes: [Node] = []
        nodes.reserveCapacity(unwrapped.count)

        for index in 0..<unwrapped.count {
            // The colour between two samples, mixed by how far between them
            // this point is. `progress` is what the smoother reports; the
            // clamp covers the ends and the straight-through cases.
            let progress = min(max(curve[index].progress, 0), Double(lastSample))
            let lower = min(Int(progress), max(lastSample - 1, 0))
            let blend = CGFloat(progress - Double(lower))

            nodes.append(
                Node(
                    point: unwrapped[index],
                    color: Self.mix(sampleColors[lower], sampleColors[min(lower + 1, lastSample)], blend).cgColor,
                    along: CGFloat(travelled[index] / total)
                )
            )
        }

        self.nodes = nodes
        self.mapPointsPerMetre = MKMapPointsPerMeterAtLatitude(
            points[points.count / 2].coordinate.latitude
        )

        let bounds = Self.bounds(of: unwrapped)
        let world = MKMapRect.world

        // A track that has been unwrapped past the seam has points outside the
        // world, and a bounding rect out there is not something MapKit will ask
        // about sensibly. Claiming the whole world instead is only affordable
        // because of the culling below — every tile gets asked, and every tile
        // that holds none of the track answers in a few hundred float compares.
        if bounds.minX < 0 || bounds.maxX > world.maxX {
            self.boundingMapRect = world
            self.worldOffsets = [-world.size.width, 0, world.size.width]
        } else {
            self.boundingMapRect = bounds
            self.worldOffsets = [0]
        }

        // Wrapped back into the world, which the unwrapping above may have
        // taken it out of. `truncatingRemainder` alone leaves a negative
        // negative, and a map point west of the prime meridian's antipode is
        // not a place.
        var centreX = bounds.midX.truncatingRemainder(dividingBy: world.size.width)
        if centreX < 0 { centreX += world.size.width }
        self.coordinate = MKMapPoint(
            x: centreX,
            y: min(max(bounds.midY, 0), world.maxY)
        ).coordinate

        super.init()
    }

    // MARK: - Geometry

    /// Makes `x` continuous across the antimeridian.
    ///
    /// The projection wraps at the seam, so a Pacific crossing arrives as a step
    /// of nearly the whole world between two points a few miles apart. Drawn
    /// literally that is a line back around the planet. Carrying an offset
    /// instead lets the track run straight off one edge; the renderer draws it
    /// again a world to each side so both halves appear.
    private static func unwrap(_ points: [MKMapPoint]) -> [MKMapPoint] {
        guard let first = points.first else { return [] }

        let world = MKMapSize.world.width
        var out: [MKMapPoint] = [first]
        out.reserveCapacity(points.count)
        var offset = 0.0

        for index in 1..<points.count {
            let previous = out[index - 1]
            let step = points[index].x + offset - previous.x
            if step > world / 2 {
                offset -= world
            } else if step < -world / 2 {
                offset += world
            }
            out.append(MKMapPoint(x: points[index].x + offset, y: points[index].y))
        }
        return out
    }

    /// Plain distance in map points. Not `MKMapPoint.distance(to:)`, which
    /// answers in metres and would silently be compared against thresholds
    /// written in map points.
    static func separation(_ a: MKMapPoint, _ b: MKMapPoint) -> Double {
        (separationSquared(a, b)).squareRoot()
    }

    static func separationSquared(_ a: MKMapPoint, _ b: MKMapPoint) -> Double {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private static func bounds(of points: [MKMapPoint]) -> MKMapRect {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude

        for point in points {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }

        let rect = MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Room for the stroke, which reaches outside the geometry: MapKit only
        // asks for tiles that meet the bounding rect, so half a line width at
        // each extremity would otherwise be clipped away. A proportion of the
        // track plus a floor, because a stroke is a screen measurement and this
        // rect has to cover every zoom at once — the floor is what covers a
        // track being looked at closely, the proportion what covers one being
        // looked at from orbit.
        let pad = max(max(rect.width, rect.height) * 0.02, 512)
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    /// Two colours, mixed. Straight linear interpolation in sRGB: the ramp's
    /// stops are already close together in hue, so nothing here is far enough
    /// apart for the usual complaints about mixing in this space to show.
    private static func mix(_ from: UIColor, _ to: UIColor, _ amount: CGFloat) -> UIColor {
        guard amount > 0 else { return from }
        guard amount < 1 else { return to }

        var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        guard from.getRed(&fr, green: &fg, blue: &fb, alpha: &fa),
              to.getRed(&tr, green: &tg, blue: &tb, alpha: &ta) else { return from }

        return UIColor(
            red: fr + (tr - fr) * amount,
            green: fg + (tg - fg) * amount,
            blue: fb + (tb - fb) * amount,
            alpha: fa + (ta - fa) * amount
        )
    }
}

/// Draws `FlownPathOverlay`.
///
/// Two passes over the same resampled run: the casing along all of it, then the
/// colour along all of it. Two passes and not one interleaved, because a track
/// that crosses itself — every circuit, hold and go-around — would otherwise
/// have the casing of a later leg painted over the colour of an earlier one.
///
/// MapKit draws tiles on background threads, several at once. Everything read
/// in here is either a local or an immutable property of the overlay, which is
/// the other thing this replaced: the width used to be a variable on the map's
/// coordinator, written from the main thread on every frame of a pan while
/// these draws were reading it.
final class FlownPathRenderer: MKOverlayRenderer {

    /// One piece of the track, ready to stroke.
    private struct Piece {
        let from: CGPoint
        let to: CGPoint
        let width: CGFloat
        let color: CGColor
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let track = overlay as? FlownPathOverlay, track.nodes.count >= 2 else { return }
        guard zoomScale > 0 else { return }

        // How much ground one point of screen is covering here. The width ramp
        // is written in these terms because that is what "zoomed in" means, and
        // it is the one thing about the camera the renderer is told.
        let metresPerPoint = 1 / (track.mapPointsPerMetre * Double(zoomScale))
        let lineWidth = FlownPathStyle.width(forMetresPerPoint: metresPerPoint)

        // Screen points to map points. Everything drawn in here is in map
        // points, including the widths.
        let toMap = 1 / CGFloat(zoomScale)
        let core = lineWidth * toMap
        let casing = FlownPathStyle.casingWidth(under: lineWidth) * toMap

        // How far apart two drawn points have to be to be worth drawing
        // separately. Around a point of screen: closer than that and the
        // segment cannot be resolved, so it is folded into its neighbour. This
        // is what makes the work proportional to the screen rather than to the
        // flight.
        let step = FlownPathStyle.resampleSpacing * toMap

        // Segments that just miss the tile still paint the part of their stroke
        // that reaches into it.
        let visible = mapRect.insetBy(dx: -Double(casing), dy: -Double(casing))

        var pieces: [Piece] = []
        for offset in track.worldOffsets {
            collect(track, into: &pieces, offset: offset, visible: visible, step: step, width: core)
        }
        guard !pieces.isEmpty else { return }

        context.setLineCap(.round)
        context.setLineJoin(.round)

        let ratio = core > 0 ? casing / core : 1
        context.setStrokeColor(FlownPathStyle.casingColor.cgColor)
        for piece in pieces {
            context.setLineWidth(piece.width * ratio)
            context.beginPath()
            context.move(to: piece.from)
            context.addLine(to: piece.to)
            context.strokePath()
        }

        for piece in pieces {
            context.setLineWidth(piece.width)
            context.setStrokeColor(piece.color)
            context.beginPath()
            context.move(to: piece.from)
            context.addLine(to: piece.to)
            context.strokePath()
        }
    }

    /// Walk the track once, keeping the pieces worth drawing.
    ///
    /// The walk itself is over every node, which is a few thousand float
    /// compares and costs nothing measurable. What it decides is how much
    /// *drawing* happens, and that is the expensive half.
    private func collect(
        _ track: FlownPathOverlay,
        into pieces: inout [Piece],
        offset: Double,
        visible: MKMapRect,
        step: CGFloat,
        width: CGFloat
    ) {
        let nodes = track.nodes
        var anchorPoint = MKMapPoint(x: nodes[0].point.x + offset, y: nodes[0].point.y)
        let stepSquared = Double(step) * Double(step)

        for index in 1..<nodes.count {
            let node = nodes[index]
            let point = MKMapPoint(x: node.point.x + offset, y: node.point.y)

            // Fold anything the screen cannot separate into the run — unless it
            // is the last node, which is the aircraft and always gets drawn.
            // Compared squared: this runs a few thousand times per tile and a
            // square root would be the only expensive thing in the loop.
            let far = FlownPathOverlay.separationSquared(point, anchorPoint) >= stepSquared
            guard far || index == nodes.count - 1 else { continue }

            // Advances even when the segment is culled below, so a run that
            // passes off screen and back does not come back drawn from wherever
            // it left.
            defer { anchorPoint = point }

            // Written out rather than built as an `MKMapRect` and handed to
            // `intersects`: a segment that happens to be exactly horizontal or
            // exactly vertical makes a rect of zero area, which counts as empty
            // and intersects nothing. That would drop a piece out of the middle
            // of the line, occasionally, for no reason anyone could see.
            let lowX = min(anchorPoint.x, point.x), highX = max(anchorPoint.x, point.x)
            let lowY = min(anchorPoint.y, point.y), highY = max(anchorPoint.y, point.y)
            guard highX >= visible.minX, lowX <= visible.maxX,
                  highY >= visible.minY, lowY <= visible.maxY else { continue }

            pieces.append(
                Piece(
                    from: self.point(for: anchorPoint),
                    to: self.point(for: point),
                    width: width * FlownPathStyle.taper(at: node.along),
                    // The colour of the newer end. A run folded together spans
                    // at most a point of screen, so which end it takes is a
                    // choice between two colours nobody can tell apart.
                    color: node.color
                )
            )
        }
    }
}
