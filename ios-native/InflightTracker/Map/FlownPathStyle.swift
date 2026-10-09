import CoreLocation
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

    /// The path drawn in the air, beside the 3D aircraft: about two thirds
    /// as wide as the one on the map. Up there it has nothing to hold its own
    /// against — no runway edges, no coastline — and it is drawn from two
    /// sides at once (see `MapLayerStyle.applyAirPath`), so a fine line reads
    /// as a solid one.
    static func airWidth(forCameraDistance distance: CLLocationDistance) -> CGFloat {
        width(forCameraDistance: distance) * 0.7
    }

    /// How much of the flat path stays on the map under the one in the air,
    /// as its shadow.
    static let shadowOpacity = 0.3

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
    /// amber — which is 0.97, 0.74, 0.25 and about as pale as a hue can be
    /// while still obviously being one — within a rounding error of the
    /// threshold. Its darkest channel is a quarter, and white's is one; there
    /// is nothing to argue about in between.
    ///
    /// Down from 0.85, because the ramp's low end is pale now rather than
    /// crimson — see `AltitudeBand`. The ice blue on the deck is 0.75 in its
    /// darkest channel, which is a colour that cannot lift itself off a light
    /// map any more than white can, and it wants the same shadow. Everything
    /// from the sky blue upwards still carries its own glow.
    private static let paleCore: CGFloat = 0.70

    /// What the halo under a stretch of path is drawn in.
    ///
    /// Ordinarily the path's own colour: a wash of the same hue, which reads as
    /// a glow around the line and is why a red track stands off a dark map.
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

/// The flown path, as runs of one colour each.
///
/// ## What was here before, and why none of it survived
///
/// The track has been drawn three ways. First as a pair of geodesic polylines
/// — a wide translucent halo and a narrow line — with a gradient renderer
/// handed colour stops as fractions along the line. The halo bulged off every
/// tight corner, blotched wherever the track crossed itself, and the stops were
/// laid against a different parameterisation of the track than the one drawn.
/// Then as a hand-written MapKit renderer stroking every segment in the colour
/// of its height, which was exact and was also the most expensive thing on the
/// map: every tile of every frame of a pan re-stroked a few thousand points on
/// the CPU.
///
/// ## What it does now
///
/// The colour is still per segment, so there is no ramp to place and nothing
/// to get out of step: the piece of track between two samples carries the
/// colour of the height at those samples, because that is the piece of track
/// flown at that height. Consecutive segments of one colour are gathered into a
/// *run*, and each run is one line feature for Mapbox, which tessellates it
/// once and then draws it on the GPU at whatever zoom the fingers ask for.
/// Runs share their end points, and the round joins and caps cover the seam.
///
/// The longitudes are kept continuous along the whole track, so a flight that
/// crosses the antimeridian is one line running off the edge of the map and
/// back on at the other, rather than a line drawn back across the planet.
struct FlownPath {

    /// One stretch of track flown in one colour.
    struct Run {
        let coordinates: [CLLocationCoordinate2D]
        let color: UIColor
        /// Height above the ground at each coordinate, in metres, for the
        /// path drawn in the air. Empty when no heights were given.
        let heights: [Double]
        /// Altitude above the sea at each coordinate, in metres, for the path
        /// drawn over real terrain. Empty when none were given.
        let seaHeights: [Double]
    }

    let runs: [Run]

    /// Where the drawn track ends, and the colour it ends in — which is where
    /// the live head grows from, and what it is drawn in. See
    /// `TrackerMapView.Coordinator.updateFlownHead`.
    let tail: CLLocationCoordinate2D
    let tailColor: UIColor
    /// And the height it ends at, in metres, when heights were given.
    let tailHeight: Double?

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
    ///
    /// `heights` is parallel too, when given: each sample's height above the
    /// ground in metres — see `FlownPathProfile.heights(of:bands:)`. The
    /// curve between two samples climbs smoothly from one to the next.
    init?(
        points: [TrackPoint],
        bands: [Int?],
        onPavement: [Bool] = [],
        heights: [Double] = [],
        seaHeights: [Double] = []
    ) {
        guard points.count >= 2, bands.count == points.count else { return nil }
        let sampleHeights = heights.count == points.count ? heights : []
        let sampleSea = seaHeights.count == points.count ? seaHeights : []

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

        // The curve, with every point's colour and its longitude brought onto
        // one continuous line.
        var coordinates: [CLLocationCoordinate2D] = []
        var colors: [UIColor] = []
        var curveHeights: [Double] = []
        var curveSea: [Double] = []
        coordinates.reserveCapacity(smoothed.coordinates.count)
        colors.reserveCapacity(smoothed.coordinates.count)
        for (index, coordinate) in smoothed.coordinates.enumerated() {
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            let origin = min(smoothed.origins[index], sampleColors.count - 1)
            let continuous = coordinates.last.map { GreatCircle.unwrapped(coordinate, after: $0) } ?? coordinate
            coordinates.append(continuous)
            colors.append(sampleColors[origin])
            if !sampleHeights.isEmpty {
                curveHeights.append(FlownPathProfile.height(
                    at: coordinate, after: origin, of: points, heights: sampleHeights
                ))
            }
            if !sampleSea.isEmpty {
                curveSea.append(FlownPathProfile.height(
                    at: coordinate, after: origin, of: points, heights: sampleSea
                ))
            }
        }
        guard coordinates.count >= 2 else { return nil }

        // Segment `i` runs from point `i` to point `i + 1` and carries point
        // `i`'s colour. A run ends where the colour changes, and the next one
        // starts on the point the last one finished on.
        var runs: [Run] = []
        var start = 0
        let segments = coordinates.count - 1
        while start < segments {
            var end = start
            while end + 1 < segments, colors[end + 1] == colors[start] {
                end += 1
            }
            runs.append(Run(
                coordinates: Array(coordinates[start...(end + 1)]),
                color: colors[start],
                heights: curveHeights.isEmpty ? [] : Array(curveHeights[start...(end + 1)]),
                seaHeights: curveSea.isEmpty ? [] : Array(curveSea[start...(end + 1)])
            ))
            start = end + 1
        }

        self.runs = runs
        self.tail = coordinates[coordinates.count - 1]
        self.tailColor = colors[colors.count - 1]
        self.tailHeight = curveHeights.last
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
