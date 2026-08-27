import CoreLocation
import MapKit
import UIKit

/// How the flown path is drawn: how wide, and in what.
///
/// ## Why the width is not one number
///
/// `MKOverlayPathRenderer` takes its width in points, so a line set to three
/// and a half of them is three and a half points wide at every zoom — which
/// sounds like exactly what you want and is why the path looked like rope from
/// any distance. A track is not a road. Zoomed in, the line is a thin thing
/// following a wide gap between samples and the width reads as the width of the
/// line. Pulled back to the whole flight, the same track is a tangle of
/// switchbacks compressed into a couple of hundred pixels, and a stroke that
/// stays three and a half points wide while the gaps between its own turns fall
/// below one point stops being a line and becomes a filled shape. The remedy is
/// the obvious one and it is the one MapKit will not do for you: draw it
/// narrower the further back you stand.
///
/// Interpolated on the log of the camera distance rather than on the distance
/// itself, because that is how zoom works — each step out doubles what is on
/// screen, so a linear ramp would spend almost all of its travel in the first
/// aerodrome-sized fraction of the range and then sit at its minimum across
/// every view that actually shows a flight.
enum FlownPathStyle {

    /// Wide enough to read as a drawn line over cartography and imagery both.
    static let closeWidth: CGFloat = 3.4

    /// Narrow enough that a long-haul's turns are still separate lines rather
    /// than one shape, and no narrower: a hairline over satellite imagery is a
    /// line nobody can see.
    static let farWidth: CGFloat = 1.3

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

    // MARK: - The casing

    /// How much wider the casing under the line is than the line itself.
    ///
    /// ## Why this is not a glow
    ///
    /// It was. The under-layer used to be the path's own colours at a fifth of
    /// their opacity, three and a bit times as wide, on the reasoning that a
    /// wide faint wash of the same colour reads as a halo. It does not, and the
    /// arithmetic says why: at the close width that is a band nearly eleven
    /// points across, and a stroke of uniform opacity has a **hard edge**
    /// wherever it ends. So what got drawn was not a glow but a flat-topped
    /// stripe with a visible border down each side — two extra lines running
    /// parallel to the track, worst exactly where the line is widest, which is
    /// zoomed in. And because the stripe was the line's own colour, the line
    /// inside it had nothing to contrast against: the crisp track vanished into
    /// the middle of a fat soft-coloured ribbon.
    ///
    /// A glow needs a falloff, and a falloff needs either a blur or a stack of
    /// strokes. What the line actually needs is neither — it needs to be
    /// legible over cartography, over labels and over satellite imagery, and
    /// the answer to that is the one the aircraft marks on the same map already
    /// use: a dark casing, barely proud of the line, in a colour the line can
    /// never be.
    ///
    /// A ratio rather than a fixed number of points, so it tracks the width
    /// ramp above: about a point either side when the line is at its widest,
    /// about a third of one when it is at its narrowest. A fixed casing would
    /// be right at one end of the zoom range and a blob at the other.
    static let casingSpread: CGFloat = 1.55

    /// The casing's colour: the same near-black the plane icons are outlined
    /// in, so an aircraft and the track behind it read as one drawing rather
    /// than as two things that happen to meet.
    ///
    /// Held back from opaque so cartography still shows through a track laid
    /// over a city, and dark in both appearances for the same reason the icon
    /// outline is: it is contrast against the *line*, not against the map, and
    /// the altitude ramp is light at every height it draws.
    static let casingColor = UIColor(red: 0.07, green: 0.08, blue: 0.11, alpha: 0.65)

    /// The casing under a line of this width. Taken from the line rather than
    /// from the camera so the two can never be computed from different frames:
    /// the width ramp is read once per region change, and both strokes are set
    /// from that one answer.
    static func casingWidth(under lineWidth: CGFloat) -> CGFloat {
        lineWidth * casingSpread
    }
}

/// The flown path: one line, and the ramp of colour laid along it.
///
/// ## One line rather than one per band
///
/// The track used to be cut into runs of samples sharing an altitude band and
/// drawn as a polyline each. That is what put a hard edge at every band
/// boundary — the colour did not change through the climb, it stepped, six
/// times, at heights that mean nothing to anyone watching an aeroplane. It also
/// made the path fatter than it had any right to be: every run ends in a round
/// cap, every cap overlaps the next run's, and a climb through five bands is
/// ten overlapping discs laid over a line that is already too wide.
///
/// `MKGradientPolylineRenderer` takes colour stops at fractions along a single
/// line and blends between them, which is the same thing the profile chart has
/// always done with `AltitudeBand.color(forFeet:)`. So the map now draws what
/// the chart draws: a sweep through the ramp, on one polyline, with one cap at
/// each end of the whole flight.
struct FlownPath {

    let line: MKPolyline

    /// The same geometry again, drawn a little wider and dark, underneath.
    ///
    /// A second overlay rather than one renderer drawing twice, because the two
    /// have to be laid down in two complete passes: casing along the whole
    /// track first, then colour along the whole track over it. Stroking them
    /// segment by segment would put the casing of a later leg on top of the
    /// colour of an earlier one wherever a track crosses itself — which is
    /// every circuit, hold and go-around, and is exactly where somebody is
    /// zoomed in far enough to see it.
    ///
    /// See `FlownPathStyle.casingSpread` for why this is a casing and not the
    /// glow it started as.
    let casing: MKPolyline

    /// The stops, and where along the line each one sits. Handed straight to
    /// the renderer.
    ///
    /// Only the line carries them. The casing is one flat colour, which is what
    /// lets it be drawn by a plain `MKPolylineRenderer` — the cheapest renderer
    /// MapKit has, against the gradient renderer, which is among the dearest.
    /// Halving the number of gradient passes is most of what makes a long track
    /// bearable to zoom around in.
    let colors: [UIColor]
    let locations: [CGFloat]

    /// At most this many stops.
    ///
    /// A fourteen-hour track is a couple of thousand samples, and a couple of
    /// thousand colour stops on a gradient is a lot of arithmetic for a ramp
    /// nobody could resolve past a few dozen steps. Thinning loses nothing that
    /// can be seen: the whole point of the gradient is that it is smooth, so
    /// dropping intermediate stops on a continuous climb changes nothing, and a
    /// step change in height sharp enough to matter is one the remaining stops
    /// still bracket.
    private static let maximumStops = 192

    /// Two stops closer together than this along the line are one stop. Guards
    /// the renderer against a pair of samples at the same place, which is a
    /// zero-length step in the ramp.
    private static let minimumStopGap: CGFloat = 0.0005

    /// Builds the path from a track and the band of each sample.
    ///
    /// `bands` is parallel to `points` and carries nil where the height was
    /// never sent — those stops take the unknown grey, so a path that starts
    /// without heights and picks them up mid-flight fades into its colours
    /// rather than switching into them.
    init?(points: [TrackPoint], bands: [Int?], title: String, casingTitle: String) {
        guard points.count >= 2, bands.count == points.count else { return nil }

        let coordinates = points.map(\.coordinate)

        // Where each sample falls along the track, as a fraction of the whole.
        //
        // Measured on the samples rather than on the curve drawn through them:
        // the spline passes through every one of them and only decides how to
        // get between two, so the distance along the drawn line and the
        // distance along the samples agree everywhere it matters — at the
        // samples, which is where the stops are.
        var travelled: [Double] = [0]
        travelled.reserveCapacity(points.count)
        var total = 0.0
        for index in 1..<coordinates.count {
            total += FlightProgress.distanceNM(
                from: coordinates[index - 1],
                to: coordinates[index]
            )
            travelled.append(total)
        }
        guard total > 0, total.isFinite else { return nil }

        let step = max(1, Int((Double(points.count) / Double(Self.maximumStops)).rounded(.up)))

        var colors: [UIColor] = []
        var locations: [CGFloat] = []

        func add(_ index: Int) {
            let location = CGFloat(travelled[index] / total)
            guard location.isFinite else { return }
            // Strictly increasing, which the renderer needs and coincident
            // samples do not give it.
            if let last = locations.last, location - last < Self.minimumStopGap { return }
            locations.append(min(max(location, 0), 1))
            colors.append(Self.color(for: bands[index], feet: points[index].altitudeFeet))
        }

        for index in stride(from: 0, to: points.count, by: step) { add(index) }
        // The last sample is the aircraft's own position, and it decides the
        // colour at the head of the track. Never dropped to the stride.
        add(points.count - 1)

        guard colors.count >= 2 else { return nil }

        // The ramp has to reach both ends of the line or the renderer leaves
        // the tail and the head flat in the first and last stop's colour, which
        // on a short track is most of it.
        if let first = locations.first, first > 0 { locations[0] = 0 }
        if let last = locations.last, last < 1 { locations[locations.count - 1] = 1 }

        let curve = PathSmoothing.smoothed(coordinates)
        let line = MKGeodesicPolyline(coordinates: curve, count: curve.count)
        line.title = title

        // Built from the same curve rather than sharing the object: an overlay
        // can only be on the map once, and the casing has to be added first so
        // it is drawn underneath.
        let casing = MKGeodesicPolyline(coordinates: curve, count: curve.count)
        casing.title = casingTitle

        self.line = line
        self.casing = casing
        self.colors = colors
        self.locations = locations
    }

    /// A stop's colour: the height where there was one, the unknown grey where
    /// there was not.
    ///
    /// Interpolated through `color(forFeet:)` rather than snapped to the band's
    /// own colour. The band is still what decides whether a height is *known* —
    /// that judgement is about runs of zeroes and belongs where it is — but
    /// once it is known there is no reason to throw the feet away and draw the
    /// middle of the band the aircraft happened to be in.
    private static func color(for band: Int?, feet: Double) -> UIColor {
        band == nil ? AltitudeBand.unknownColor : AltitudeBand.color(forFeet: feet)
    }
}
