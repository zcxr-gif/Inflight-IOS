import MapKit
import UIKit

/// How a field's pavement is drawn.
///
/// ## Why this stopped being a line width in points
///
/// Runways and taxiways were strokes of a fixed number of points — seven and
/// two and a half — which meant a runway was the same thickness on screen at
/// the threshold as it was from the next county. The note that used to sit
/// here defended it: a runway drawn to scale is a hairline from the edge of
/// the field, and this layer has to be readable at both ends.
///
/// That is true and it is not a reason to draw a fixed width, it is a reason
/// to draw a *floor*. Pavement has a real width — a runway is forty-five
/// metres of concrete and a taxiway is twenty-three — and at the zooms where
/// this layer is on at all, that is most of what makes it look like an
/// aerodrome rather than a diagram of one. So it is drawn to scale, and the
/// scale is clamped so it never falls below something you can see.
///
/// ## And why it asks what the map is made of
///
/// Grey pavement on grey cartography is a drawing. Grey pavement on a
/// photograph of the same pavement is a smear over the thing it is describing.
/// Imagery already contains the concrete, in the right place and the right
/// shape, so over imagery this draws almost nothing: an edge to catch the
/// light and the markings that a photograph cannot give you — the designators,
/// the letters, the hold bars.
enum AirportGroundStyle {

    // MARK: Widths

    /// What a piece of pavement is, in metres, when OpenStreetMap does not say.
    ///
    /// A code-E runway is forty-five metres and a code-C taxiway twenty-three,
    /// which is what the great majority of the fields anybody watches are built
    /// to. Where OSM carries a `width` it is used instead and this is not
    /// consulted.
    static func defaultWidth(for kind: AirportLayout.Piece.Kind) -> CLLocationDistance {
        switch kind {
        case .runway: return 45
        case .taxiway: return 23
        case .holdShort: return 1.5
        case .apron, .terminal: return 0
        }
    }

    /// The narrowest a piece may be drawn on screen, in points.
    ///
    /// The floor under the scale. Pulled back far enough, true width goes to
    /// nothing and the field would disappear before the map stopped drawing
    /// it — so past that point these stop being scale drawings and become
    /// marks, which is the same bargain a paper chart makes.
    static func minimumPoints(for kind: AirportLayout.Piece.Kind) -> CGFloat {
        switch kind {
        case .runway: return 3
        case .taxiway: return 1.4
        case .holdShort: return 2.2
        case .apron, .terminal: return 0
        }
    }

    // MARK: Looks

    /// What the map underneath is made of, as far as this layer cares.
    ///
    /// Three cases rather than the palette's five, because pavement only has
    /// three questions to answer: am I drawing on light paper, on dark paper,
    /// or on a photograph of the ground itself.
    enum Ground {
        case light
        case dark
        case imagery

        init(_ look: MapLook, isLight: Bool) {
            if look.resolvedPalette.usesImagery {
                self = .imagery
            } else {
                self = isLight ? .light : .dark
            }
        }

        /// Whether the concrete is already on the map and only wants marking
        /// rather than painting.
        var isPhotographic: Bool { self == .imagery }
    }

    /// The body of a runway or taxiway.
    static func fill(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> UIColor {
        let isRunway = kind == .runway

        switch ground {
        case .light:
            return UIColor(white: 0.36, alpha: isRunway ? 0.55 : 0.34)
        case .dark:
            return UIColor(white: 0.78, alpha: isRunway ? 0.34 : 0.22)
        case .imagery:
            // Nothing over the photograph. The pavement in the picture is the
            // pavement, and a wash across it only takes the detail off it.
            return .clear
        }
    }

    /// The line round the edge of it.
    ///
    /// On cartography this is what keeps a runway from bleeding into the
    /// taxiway beside it. On imagery it is the whole of the drawing: a thin
    /// bright edge that says *this* strip of the photograph is the runway,
    /// without covering any of it.
    static func edge(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> UIColor {
        let isRunway = kind == .runway

        switch ground {
        case .light:
            return UIColor(white: 0.20, alpha: isRunway ? 0.42 : 0.24)
        case .dark:
            return UIColor(white: 0.96, alpha: isRunway ? 0.34 : 0.20)
        case .imagery:
            return UIColor(white: 1, alpha: isRunway ? 0.72 : 0.42)
        }
    }

    /// How thick that edge is, in points. Screen-constant: an outline is a
    /// mark on the map rather than a thing on the ground with a size.
    static func edgePoints(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> CGFloat {
        guard kind == .runway || kind == .taxiway else { return 0 }
        if ground.isPhotographic { return kind == .runway ? 1.1 : 0.7 }
        return kind == .runway ? 0.8 : 0.5
    }

    /// The dashed stripe down the middle of a runway.
    ///
    /// The one piece of real runway marking worth drawing, and the thing that
    /// makes a grey slab read as a runway at a glance. Skipped on taxiways —
    /// their centreline is yellow and continuous in life, and at these sizes
    /// it would only be a second line inside a line two points wide.
    static func centreline(on ground: Ground) -> UIColor {
        switch ground {
        case .light: return UIColor(white: 1, alpha: 0.60)
        case .dark: return UIColor(white: 1, alpha: 0.45)
        case .imagery: return UIColor(white: 1, alpha: 0.55)
        }
    }

    /// Aprons and terminals, which are areas rather than runs.
    static func area(for kind: AirportLayout.Piece.Kind, on ground: Ground) -> UIColor {
        let isTerminal = kind == .terminal

        switch ground {
        case .light:
            return UIColor(white: 0.30, alpha: isTerminal ? 0.20 : 0.12)
        case .dark:
            return UIColor(white: 0.92, alpha: isTerminal ? 0.18 : 0.10)
        case .imagery:
            // A terminal is a building and reads as one from above; an apron is
            // just more concrete. Only the building is worth outlining, and
            // even that faintly.
            return isTerminal ? UIColor(white: 1, alpha: 0.10) : .clear
        }
    }

    /// The bar across a taxiway where it meets a runway.
    ///
    /// Yellow on every one of the three grounds. It is the one thing on this
    /// layer that is not describing where the concrete is but what you are
    /// told to do on it, and it is yellow in life for exactly that reason.
    static let holdBar = UIColor(red: 0.98, green: 0.78, blue: 0.16, alpha: 0.95)
}

/// A run of pavement, projected once and carrying what it is.
///
/// Its own overlay rather than a titled `MKPolyline` because the renderer needs
/// to know two things a polyline cannot carry — which kind of pavement this is
/// and how wide it really is — and the previous arrangement smuggled the first
/// through the title string and had nowhere at all to put the second.
final class GroundOverlay: NSObject, MKOverlay {

    let kind: AirportLayout.Piece.Kind

    /// The real width of this pavement in metres, from OSM where it says and
    /// from the type where it does not.
    let widthMetres: CLLocationDistance

    let points: [MKMapPoint]
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init?(piece: AirportLayout.Piece) {
        guard piece.coordinates.count >= 2, !piece.kind.isArea else { return nil }

        let points = piece.coordinates.map(MKMapPoint.init)
        var minX = points[0].x, maxX = points[0].x
        var minY = points[0].y, maxY = points[0].y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }

        self.kind = piece.kind
        self.widthMetres = piece.widthMetres ?? AirportGroundStyle.defaultWidth(for: piece.kind)
        self.points = points

        // Padded by the widest this could be drawn. A stroke is centred on its
        // line, so half of a forty-five metre runway hangs outside the box its
        // centreline describes, and MapKit will not ask a renderer to draw
        // tiles its overlay does not claim.
        let padding = max(self.widthMetres * 4, 400) * MKMapPointsPerMeterAtLatitude(
            piece.coordinates[0].latitude
        )
        self.boundingMapRect = MKMapRect(
            x: minX - padding,
            y: minY - padding,
            width: (maxX - minX) + padding * 2,
            height: (maxY - minY) + padding * 2
        )
        self.coordinate = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2).coordinate
        super.init()
    }
}

/// Draws one run of pavement to its real width.
final class GroundRenderer: MKOverlayRenderer {

    private let ground: AirportGroundStyle.Ground

    private var pavement: GroundOverlay { overlay as! GroundOverlay }

    init(overlay: GroundOverlay, ground: AirportGroundStyle.Ground) {
        self.ground = ground
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let points = pavement.points
        guard points.count >= 2 else { return }

        let kind = pavement.kind
        let path = CGMutablePath()
        path.move(to: point(for: points[0]))
        for next in points.dropFirst() { path.addLine(to: point(for: next)) }

        // True width, then the floor under it.
        //
        // `MKMapPointsPerMeterAtLatitude` is what turns metres into the units
        // this context is drawn in; dividing points by the zoom scale is what
        // turns a screen measurement into the same. Taking the larger is the
        // whole of the scale-with-a-minimum: real concrete while the concrete
        // is big enough to see, a mark once it is not.
        let perMetre = MKMapPointsPerMeterAtLatitude(pavement.coordinate.latitude)
        let scaled = pavement.widthMetres * perMetre
        let floor = AirportGroundStyle.minimumPoints(for: kind) / zoomScale
        let width = max(scaled, floor)

        context.setLineJoin(.round)
        // Butt rather than round: pavement ends where it ends, and a rounded
        // cap puts a semicircle of concrete past the end of every runway.
        context.setLineCap(kind == .holdShort ? .butt : .round)

        if kind == .holdShort {
            context.addPath(path)
            context.setStrokeColor(AirportGroundStyle.holdBar.cgColor)
            context.setLineWidth(max(AirportGroundStyle.minimumPoints(for: kind) / zoomScale, 2 / zoomScale))
            context.strokePath()
            return
        }

        let body = AirportGroundStyle.fill(for: kind, on: ground)
        if body != UIColor.clear {
            context.addPath(path)
            context.setStrokeColor(body.cgColor)
            context.setLineWidth(width)
            context.strokePath()
        }

        // The edge, drawn as the outline of the same stroke rather than a
        // second line beside it: stroking the path at the full width and then
        // again a hair narrower in the ground colour would be two fills to get
        // one line. `replacePathWithStrokedPath` turns the wide stroke into its
        // own outline, which is exactly the edge of the pavement.
        let edgeWidth = AirportGroundStyle.edgePoints(for: kind, on: ground)
        if edgeWidth > 0 {
            context.saveGState()
            context.addPath(path)
            context.setLineWidth(width)
            context.replacePathWithStrokedPath()
            context.setStrokeColor(AirportGroundStyle.edge(for: kind, on: ground).cgColor)
            context.setLineWidth(edgeWidth / zoomScale)
            context.strokePath()
            context.restoreGState()
        }

        // And the dashes down the middle of a runway, once there is enough
        // runway on screen to have dashes on.
        guard kind == .runway, width > 4 / zoomScale else { return }
        context.addPath(path)
        context.setStrokeColor(AirportGroundStyle.centreline(on: ground).cgColor)
        context.setLineWidth(max(width * 0.035, 0.7 / zoomScale))
        context.setLineDash(phase: 0, lengths: [30 * perMetre, 20 * perMetre])
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [])
    }
}
