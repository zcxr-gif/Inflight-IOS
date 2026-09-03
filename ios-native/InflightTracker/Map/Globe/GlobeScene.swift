import Combine
import CoreLocation
import Foundation
import QuartzCore
import SwiftUI
import UIKit
import simd

/// One aircraft on the planet.
///
/// Everything about it that the drawing needs, worked out once when the packet
/// lands. The position and the heading are directions on the sphere rather than
/// degrees precisely so that turning the planet costs nothing: a direction does
/// not change when the camera does.
struct GlobeTrafficDot: Equatable {

    let id: String

    /// Where it is being drawn.
    ///
    /// A `var`, unlike everything else here, because an aeroplane between
    /// packets is not where the feed last saw it: `GlobeScene.flyForward`
    /// carries this one forward on the frame clock at the heading and speed it
    /// last reported. Which is why it is written here rather than kept beside
    /// the scene — the crowding grid, the hit test and the drawing all read
    /// this, and all three should be talking about the aeroplane you can see.
    var position: SIMD3<Float>

    /// Which way it is pointing, as a direction lying along the surface. Only
    /// read when the traffic is drawn as aircraft rather than as dots.
    var heading: SIMD3<Float>

    /// Which piece of artwork it is. `PlaneSprites` resolves it.
    let spriteKey: String

    /// What it is painted, when the pilot colouring has an opinion — your own
    /// aeroplane, or somebody you watch. Nil is ordinary traffic.
    let tint: UIColor?

    /// Whether it is the aircraft whose window is open, which is drawn larger
    /// and over the rest.
    let isOpen: Bool

    /// What it is called, for the label beside it.
    ///
    /// Carried here rather than looked up while drawing for the reason
    /// everything else here is: the drawing runs at the frame rate and the
    /// packet does not. It costs nothing — a `String` on the dot is the same
    /// string the flight already holds.
    let callsign: String?

    /// The partner VA whose logo goes above it, as the id `VaMarkStore` keeps
    /// its picture under. Nil when the callsign matches no partner, and nil for
    /// everything when the setting is off — see `rebuild`, which is where the
    /// lookup happens and where not doing it is free.
    ///
    /// The id rather than the listing: three thousand copies of a directory
    /// entry, rebuilt on every packet, to draw the handful of logos that are
    /// ever on screen at once.
    let vaId: String?
}

/// One field on the planet: where it is, what it is called, and whether
/// anybody is working it.
struct GlobeFieldMark: Equatable {
    let icao: String
    let position: SIMD3<Float>
    let isControlled: Bool
}

/// One fix on the open aircraft's filed plan, ready to be drawn on a sphere.
///
/// Its own mark rather than a point on the route line, for the reason the flat
/// map gives a fix its own annotation: a line through unnamed corners is a
/// shape, and the names are most of why the plan is worth plotting instead of
/// its two ends. The diamond is what makes it read as a route.
struct GlobePlanFix: Equatable {

    /// Where it is, as a direction on the sphere.
    let position: SIMD3<Float>

    /// What it is called. Empty for a fix the backend gave no name — those
    /// still get a diamond, because the corner is real either way.
    let name: String

    /// Whether this is the fix being flown to. See `PlanProgress.next`.
    let isNext: Bool

    /// Whether the aircraft is already past it. Drawn dimmer: a plan is most
    /// useful when you can see at a glance how much of it is left.
    let isPassed: Bool
}

/// A staffed sector's name, written over the middle of its airspace.
///
/// The boundary itself is drawn as ordinary `GlobeLine`s — an outline is an
/// outline — so this carries only the part the line cannot say: which station
/// it is and who is working it.
struct GlobeAtcLabel: Equatable {
    let position: SIMD3<Float>
    let text: String
}

/// A line drawn on the surface — today, the open aircraft's route.
struct GlobeLine: Equatable {
    /// Full precision, unlike everything else on the planet.
    ///
    /// These are the lines you look at when you are zoomed all the way in —
    /// a taxi trail across an apron — and a `Float` unit vector resolves to
    /// about forty centimetres of ground, which at that zoom is three quarters
    /// of a point. Consecutive fixes then land on a lattice and the path
    /// zigzags by more than half its own width. There are a few hundred points
    /// here, not ten thousand, so the precision is nearly free.
    let points: [SIMD3<Double>]
    let color: UIColor
    let width: CGFloat
    let dash: [CGFloat]?
}

/// Where the open aircraft has actually been, ready to be drawn on a sphere.
///
/// ## Why this is not one of the lines above
///
/// It used to be. A flown path was a `GlobeLine` — one array of points, one
/// colour, one width — and every one of those three was wrong for it.
///
/// **One colour.** The flat map has coloured this track by height since there
/// was a track to colour, and the planet drew it in a flat half-strength wash
/// of the route's colour. So the same flight told you what height it had been
/// at on one map and nothing at all on the other, and the ramp — which is the
/// only thing that makes a two-hour track readable as a climb, a cruise and a
/// descent — was simply missing on the planet.
///
/// **Straight between the fixes.** The store thins breadcrumbs by distance, so
/// a turn the aeroplane flew as an arc arrives as three points with hard
/// corners between them. The map has run them through `PathSmoothing` for a
/// long time. The planet drew the corners.
///
/// **One width, at every zoom.** A stroke that stays 1.8 points wide is a
/// hairline over a whole planet and a thread at an aerodrome — see
/// `FlownPathStyle`, which is where the map's answer to that lives and which
/// this now shares.
///
/// So it is its own thing, with the geometry and the colours worked out when
/// the track changes rather than per frame, and the drawing — halo, core, and
/// the live segment out to the aeroplane — left to the canvas.
struct GlobeFlownPath: Equatable {

    /// A stretch of the curve drawn in one colour: the points from `first` to
    /// `last`, both ends included.
    ///
    /// Runs rather than a colour per point, for the reason the map's renderer
    /// batches too: the colours are thinned, so a cruise leg is hundreds of
    /// points sharing one, and each run is then one path and one stroke.
    struct Run: Equatable {
        let first: Int
        let last: Int
        let color: UIColor
    }

    /// The smoothed curve, full precision. See `GlobeLine.points`.
    let points: [SIMD3<Double>]

    let runs: [Run]

    /// The colour the live segment out to the aeroplane is drawn in — the
    /// height the aircraft was last known to be at, since inventing a
    /// different one for a few seconds of track would be a claim about a climb
    /// nobody reported.
    let headColor: UIColor

    /// At most this many samples are coloured individually. The map's own
    /// figure, and the same reasoning: see `FlownPath.maximumColourSamples`.
    private static let maximumColourSamples = 256

    /// Builds the path from a track, coloured exactly as the flat map colours
    /// the same track.
    init?(_ track: [TrackPoint]) {
        guard track.count >= 2 else { return nil }

        let bands = FlownPath.heightBands(of: track)
        guard bands.count == track.count else { return nil }

        // The colour at each *sample*, before the curve is drawn through them.
        let step = max(
            1,
            Int((Double(track.count) / Double(Self.maximumColourSamples)).rounded(.up))
        )
        var sampleColors: [UIColor] = []
        sampleColors.reserveCapacity(track.count)
        var carried = FlownPath.color(for: bands[0], feet: track[0].altitudeFeet)
        for index in track.indices {
            if index % step == 0 || index == track.count - 1 {
                carried = FlownPath.color(for: bands[index], feet: track[index].altitudeFeet)
            }
            sampleColors.append(carried)
        }

        // The curve, and which sample each of its points came from — so an
        // inserted point takes the colour of the piece of track it was
        // inserted into rather than a fraction along a line.
        let curve = PathSmoothing.smoothedWithOrigins(track.map(\.coordinate))
        guard curve.coordinates.count >= 2 else { return nil }

        var points: [SIMD3<Double>] = []
        var colors: [UIColor] = []
        points.reserveCapacity(curve.coordinates.count)
        colors.reserveCapacity(curve.coordinates.count)
        for (index, coordinate) in curve.coordinates.enumerated() {
            guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
            points.append(GlobeGeometry.preciseVector(coordinate))
            colors.append(sampleColors[min(curve.origins[index], sampleColors.count - 1)])
        }
        guard points.count >= 2, let last = colors.last else { return nil }

        // Segment `i` runs from point `i` to point `i + 1` and carries point
        // `i`'s colour, because that is the piece of track flown at that
        // height. A run ends where the colour changes, and the next one starts
        // on the point the last one finished on — so consecutive runs meet
        // exactly, with a round cap over the join rather than a gap.
        var runs: [Run] = []
        let segments = points.count - 1
        var start = 0
        while start < segments {
            var end = start
            while end + 1 < segments, colors[end + 1] == colors[start] { end += 1 }
            runs.append(Run(first: start, last: end + 1, color: colors[start]))
            start = end + 1
        }

        self.points = points
        self.runs = runs
        self.headColor = last
    }

    /// Where the drawn track ends, and the live segment begins.
    var tail: SIMD3<Double> { points[points.count - 1] }
}

/// A field's pavement, ready to be drawn on a sphere.
///
/// ## Why this is metres and not directions
///
/// Everything else on the planet is a unit vector, because a direction does
/// not change when the camera turns. Pavement cannot be, and the reason is
/// arithmetic rather than taste: a `SIMD3<Float>` unit vector carries about
/// seven digits, which on a planet six and a half thousand kilometres across
/// is a resolution of roughly half a metre. That is invisible on a coastline
/// and it is half the width of the runway centreline.
///
/// So a layout is held as a tangent plane pinned at the field: a direction for
/// the field itself, the two directions that are east and north *there*, and
/// every point as its offset in metres. Over the few kilometres an aerodrome
/// covers, the difference between that plane and the sphere is millimetres,
/// and drawing a point becomes two multiplies and two adds off a single
/// projected origin — which is also why it stays cheap at a zoom where the
/// sphere is a million points across.
struct GlobeGround: Equatable {

    struct Piece: Equatable {
        let kind: AirportLayout.Piece.Kind
        /// Metres east and metres north of the field.
        let points: [SIMD2<Float>]
        /// What this pavement really is, across. Zero for areas, which are
        /// filled rather than stroked.
        let widthMetres: Double
    }

    let icao: String

    /// The field itself, and the tangent frame there.
    let anchor: SIMD3<Float>
    let east: SIMD3<Float>
    let north: SIMD3<Float>

    let pieces: [Piece]

    /// How far the furthest pavement is from the field, in metres. The whole
    /// layout is rejected on this when the field is off screen.
    let reachMetres: Double

    static func == (lhs: GlobeGround, rhs: GlobeGround) -> Bool { lhs.icao == rhs.icao }

    /// A store layout, in the terms the canvas draws in.
    init?(_ layout: AirportLayout, at centre: CLLocationCoordinate2D) {
        guard !layout.isEmpty else { return nil }

        let anchor = GlobeGeometry.vector(centre)
        let lon = centre.longitude * .pi / 180
        let east = SIMD3<Float>(Float(-sin(lon)), Float(cos(lon)), 0)
        let north = simd_cross(anchor, east)

        // Metres per degree, on the plane at this field. Longitude shrinks
        // with the latitude; latitude does not shrink at all.
        let metresPerDegree = GlobeCamera.earthRadiusMetres * .pi / 180
        let eastPerDegree = metresPerDegree * cos(centre.latitude * .pi / 180)

        var pieces: [Piece] = []
        var reach: Double = 0
        pieces.reserveCapacity(layout.pieces.count)

        for piece in layout.pieces where piece.coordinates.count > 1 {
            var points: [SIMD2<Float>] = []
            points.reserveCapacity(piece.coordinates.count)
            for coordinate in piece.coordinates {
                var delta = coordinate.longitude - centre.longitude
                // A field on the antimeridian, whose pavement is a fraction of
                // a degree wide and three hundred and sixty degrees away.
                if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }

                let x = delta * eastPerDegree
                let y = (coordinate.latitude - centre.latitude) * metresPerDegree
                reach = max(reach, (x * x + y * y).squareRoot())
                points.append(SIMD2<Float>(Float(x), Float(y)))
            }
            pieces.append(Piece(
                kind: piece.kind,
                points: points,
                widthMetres: piece.widthMetres ?? AirportGroundStyle.defaultWidth(for: piece.kind)
            ))
        }

        guard !pieces.isEmpty else { return nil }

        self.icao = layout.icao
        self.anchor = anchor
        self.east = east
        self.north = north
        self.pieces = pieces
        self.reachMetres = reach
    }
}

/// Everything on the planet that is not the planet.
///
/// A reference type, published as a single revision number, and that shape is
/// the whole point. The traffic is rebuilt when a packet lands — a few times a
/// minute — and the camera changes sixty times a second while a finger is
/// moving. Holding the traffic in the view's own body meant every one of those
/// frames rebuilt an array of three thousand aircraft to hand to a canvas that
/// then compared it, element by element, against the identical array it already
/// had. That was the lag, and none of it was drawing.
///
/// Now a frame carries one integer. The canvas redraws when the revision moves
/// and reads the arrays in place.
final class GlobeScene: ObservableObject {

    /// Bumped whenever anything below changes. The only thing SwiftUI sees.
    @Published private(set) var revision = 0

    private(set) var traffic: [GlobeTrafficDot] = []
    private(set) var fields: [GlobeFieldMark] = []
    private(set) var lines: [GlobeLine] = []

    /// The fixes on the open aircraft's filed plan. Their own array rather
    /// than points on a line, because they are drawn as marks with names on
    /// them — see `GlobePlanFix`.
    private(set) var planFixes: [GlobePlanFix] = []

    /// The staffed sectors' names. Empty whenever the layer is off, which is
    /// how the layer is switched off — the canvas has no flag for it, because
    /// a scene with nothing in it draws nothing.
    private(set) var atcLabels: [GlobeAtcLabel] = []

    /// Where the open aircraft has been. Its own thing rather than a line,
    /// because it is coloured by height along its length — see
    /// `GlobeFlownPath`.
    private(set) var flown: GlobeFlownPath?

    /// Where each aircraft is *between* packets, parallel to `traffic`, and
    /// nil for anything not worth carrying — on the ground, stopped, or with
    /// the smoothing switched off.
    ///
    /// Parallel to the traffic rather than keyed by id because it is read on
    /// the frame clock: a dictionary lookup per aeroplane per frame is a
    /// string hash per aeroplane per frame, and there are three thousand of
    /// them. The keys are only ever touched when a packet lands, which is
    /// where `carried` comes in.
    private var motions: [FlightMotion?] = []

    /// The same states, keyed by aircraft, so a packet landing can hand each
    /// aeroplane back the prediction it was already flying rather than
    /// starting it again from wherever the feed has just put it.
    private var carried: [String: FlightMotion] = [:]

    /// Whether anything on the planet is being carried between packets. What
    /// tells the canvas whether a frame clock is worth running at all.
    private(set) var hasMotion = false

    /// The pavement of every field in view, once the camera is close enough
    /// for pavement to mean anything. Set on its own rather than through
    /// `rebuild`, because it arrives from the network on its own schedule and
    /// has nothing to do with a packet of traffic landing.
    ///
    /// A list rather than one field: aerodromes come in clusters, and a view
    /// that reaches two of them should draw both rather than pick whichever is
    /// nearest the middle of the screen this second.
    private(set) var ground: [GlobeGround] = []

    /// What the last rebuild was made from, so a body that runs for an
    /// unrelated reason does not rebuild anything.
    private var stamp: Int?

    /// Rebuilds the scene, if what it would be made of has actually moved.
    ///
    /// - Parameter signature: a hash of everything the caller knows the scene
    ///   depends on. The map already keeps one for exactly this purpose.
    func rebuild(
        signature: Int,
        flights: [Flight],
        fields: [MapAirport],
        openFlightId: String?,
        highlighting: PilotHighlighting,
        route: GlobeRoute?,
        flownPath: [TrackPoint],
        natTracks: [[CLLocationCoordinate2D]],
        atcSectors: [AtcActiveSector],
        smoothsTraffic: Bool,
        // Whether any aeroplane could be wearing a VA logo. The lookup is
        // memoised and cheap, but it is still a lock and a dictionary per
        // aircraft per packet — so with the setting off it is not done at all.
        // The caller's signature carries this, or a flip of the switch would
        // not rebuild anything.
        showsVaMarks: Bool,
        palette: GlobePalette
    ) {
        guard stamp != signature else { return }
        stamp = signature

        let now = CACurrentMediaTime()
        var traffic: [GlobeTrafficDot] = []
        var motions: [FlightMotion?] = []
        var carried: [String: FlightMotion] = [:]
        var hasMotion = false
        traffic.reserveCapacity(flights.count)
        motions.reserveCapacity(flights.count)
        if smoothsTraffic { carried.reserveCapacity(flights.count) }

        for flight in flights {
            // Where it is drawn, which is where it was predicted to be by the
            // time this packet landed — not where the packet says it is. The
            // gap between the two is what the prediction spends the next
            // second closing, and closing it is the whole point: an aeroplane
            // that jumped to every packet would be advertising the packets.
            var motion: FlightMotion?
            if smoothsTraffic, flight.isWorthSmoothing {
                var carrying = self.carried[flight.id]
                    ?? FlightMotion(flight: flight, drawnAt: flight.coordinate, now: now)
                carrying.report(flight, now: now)
                carried[flight.id] = carrying
                motion = carrying
                hasMotion = true
            }
            motions.append(motion)

            let place = motion?.drawn ?? flight.coordinate
            let heading = motion?.drawnHeading ?? flight.heading

            traffic.append(GlobeTrafficDot(
                id: flight.id,
                position: GlobeGeometry.vector(place),
                heading: GlobeGeometry.headingVector(
                    latitude: place.latitude,
                    longitude: place.longitude,
                    headingDegrees: heading
                ),
                spriteKey: flight.spriteKey,
                tint: highlighting.tint(for: flight.username),
                isOpen: flight.id == openFlightId,
                callsign: flight.callsign,
                // Asking is also what starts the download, which is why the
                // picture is asked for here and read back by id when it is
                // drawn — see `VaMarkStore.mark(id:)`.
                vaId: showsVaMarks
                    ? VaMarkStore.shared.partner(callsign: flight.callsign).map { ad in
                        _ = VaMarkStore.shared.mark(for: ad)
                        return ad.id
                    }
                    : nil
            ))
        }

        self.traffic = traffic
        self.motions = motions
        self.carried = carried
        self.hasMotion = hasMotion
        self.fields = fields.map {
            GlobeFieldMark(
                icao: $0.airport.icao,
                position: GlobeGeometry.vector($0.airport.coordinate),
                isControlled: $0.isControlled
            )
        }
        let flown = GlobeFlownPath(flownPath)
        self.flown = flown
        self.lines = Self.lines(
            route: route,
            // Only where there is a track drawn to join up to. A single fix,
            // or the layer switched off, leaves the route to say the whole of
            // it on its own.
            flownFrom: flown == nil ? nil : flownPath.first?.coordinate,
            natTracks: natTracks,
            atcSectors: atcSectors,
            palette: palette
        )
        self.planFixes = Self.planFixes(route: route)
        self.atcLabels = atcSectors.map {
            GlobeAtcLabel(
                position: GlobeGeometry.vector($0.sector.label),
                text: $0.label
            )
        }

        revision &+= 1
    }

    /// Flies one aircraft forward to now, and says whether it moved.
    ///
    /// Called from the drawing, once per aeroplane per frame and only for the
    /// ones the frame is actually going to draw — dead reckoning an aircraft
    /// nobody can see is arithmetic for nothing, and `FlightMotion` takes a
    /// long gap as a resume rather than as a step, so one that arrives on
    /// screen having been left alone for a minute simply appears where it
    /// should be.
    ///
    /// Exactly once, though: called twice in a frame, the second call sees no
    /// elapsed time and takes the raw prediction, which is the snapping the
    /// smoothing exists to remove.
    @discardableResult
    func flyForward(_ index: Int, to now: CFTimeInterval) -> Bool {
        guard index < motions.count, var motion = motions[index] else { return false }

        let place = motion.advance(to: now)
        let heading = motion.drawnHeading
        motions[index] = motion

        traffic[index].position = GlobeGeometry.vector(place)
        traffic[index].heading = GlobeGeometry.headingVector(
            latitude: place.latitude,
            longitude: place.longitude,
            headingDegrees: heading
        )
        return true
    }


    /// How many times the pavement has changed.
    ///
    /// Counted apart from `revision`, which every packet moves, because the two
    /// belong to different layers of the drawing: the traffic is drawn over the
    /// ground and the ground is only redrawn when it is the ground that
    /// changed. See `GlobeWorldView`.
    private(set) var groundRevision = 0

    /// The fields in view, or nothing when there are none worth drawing.
    ///
    /// Compared by which fields they are — `GlobeGround` is equal by its own
    /// ICAO — so the same aerodromes arriving again is not a redraw.
    func setGround(_ ground: [GlobeGround]) {
        guard ground != self.ground else { return }
        self.ground = ground
        groundRevision &+= 1
        revision &+= 1
    }

    // MARK: - The route

    /// The open aircraft's route, as the two legs worth drawing on a planet:
    /// where it came from to where it is, and where it is to where it is going.
    ///
    /// Coordinates rather than fields, because the caller has already resolved
    /// them and because this has no business reaching into the airport dataset.
    struct GlobeRoute: Equatable {
        var departure: CLLocationCoordinate2D?
        var position: CLLocationCoordinate2D
        var arrival: CLLocationCoordinate2D?

        /// The route as filed, when the pilot filed one and the layer asking
        /// for it is the filed plan rather than the direct line.
        ///
        /// Empty is the ordinary case and not a failure: most pilots file
        /// nothing, and the two great circles above are then the whole of what
        /// can honestly be said about where this aeroplane is going.
        var plan: [PlanWaypoint] = []

        static func == (lhs: GlobeRoute, rhs: GlobeRoute) -> Bool {
            lhs.departure?.latitude == rhs.departure?.latitude
                && lhs.departure?.longitude == rhs.departure?.longitude
                && lhs.arrival?.latitude == rhs.arrival?.latitude
                && lhs.arrival?.longitude == rhs.arrival?.longitude
                && lhs.position.latitude == rhs.position.latitude
                && lhs.position.longitude == rhs.position.longitude
                && lhs.plan == rhs.plan
        }

        /// Whether there is enough of a plan to draw as a route rather than as
        /// a single point. One fix is a corner with nothing either side of it.
        var hasPlan: Bool { plan.count >= 2 }
    }

    /// Every line on the planet, in the order they are drawn.
    ///
    /// The organised tracks first, because they are about the ocean rather than
    /// about anybody in particular and everything else belongs on top of them;
    /// then where the open aircraft came from, and where it is going. Where it
    /// has actually *been* is not one of these — see `GlobeFlownPath`.
    private static func lines(
        route: GlobeRoute?,
        flownFrom: CLLocationCoordinate2D?,
        natTracks: [[CLLocationCoordinate2D]],
        atcSectors: [AtcActiveSector],
        palette: GlobePalette
    ) -> [GlobeLine] {
        var lines: [GlobeLine] = []

        // Airspace first, under everything else. It is the largest thing on the
        // planet by far — a sector spans a country — and it is context for the
        // traffic rather than a claim about any aeroplane, so nothing else
        // should have to give way to it.
        //
        // Outlined, not filled. The flat map washes the inside of a staffed
        // sector, which it can because MapKit clips a polygon to the viewport;
        // here a sector crossing the limb is a ring the horizon cuts in half,
        // and the honest closed shape to fill it with does not exist. The
        // outline is what makes an FIR readable anyway — the wash only says
        // which side of the line is inside.
        for sector in atcSectors {
            for ring in sector.sector.rings where ring.count > 2 {
                lines.append(GlobeLine(
                    points: ring.map { GlobeGeometry.preciseVector($0) },
                    color: palette.atcBoundary,
                    width: 1,
                    dash: nil
                ))
            }
        }

        for track in natTracks where track.count > 1 {
            lines.append(GlobeLine(
                points: path(through: track),
                color: palette.track,
                width: 1.1,
                dash: [6, 4]
            ))
        }

        if let route = route, route.hasPlan {
            // MARK: The plan as filed
            //
            // The whole of it, in one dashed line through every fix, and none
            // of the two great circles below. Both pictures at once is two
            // claims about the same flight with nothing to say which is which
            // — the same argument `RouteLineMode` settles for the flat map,
            // settled the same way here.
            //
            // Great circles between neighbouring fixes rather than straight
            // lines, for the reason the organised tracks are drawn that way:
            // on a sphere the chord between two fixes ten degrees apart cuts
            // visibly inside the path an aeroplane actually flies between
            // them.
            lines.append(GlobeLine(
                points: path(through: route.plan.map(\.coordinate)),
                color: palette.route.withAlphaComponent(0.75),
                width: 1.4,
                dash: [4, 4]
            ))
        } else if let route = route {
            let here = GlobeGeometry.preciseVector(route.position)

            // Where the aircraft came from.
            //
            // Two different lines, and which one it is depends on whether the
            // track is being drawn. With a track, the great circle from the
            // departure to the aeroplane is not the route — it is a claim that
            // it flew straight there, drawn as a solid line *across* the path
            // that shows what it actually did, and the two of them crossing
            // and recrossing is most of what made this look wrong. So the
            // honest line is the short dashed one from the field to the
            // earliest fix we hold, which is the flat map's answer as well:
            // "before we were watching, it came from here".
            //
            // Without a track there is nothing else to say where it has been,
            // and the direct line is the whole of the answer.
            if let departure = route.departure {
                let start = GlobeGeometry.preciseVector(departure)
                if let first = flownFrom {
                    if FlightProgress.distanceNM(from: departure, to: first) > 1 {
                        lines.append(GlobeLine(
                            points: arc(from: start, to: GlobeGeometry.preciseVector(first)),
                            color: palette.route.withAlphaComponent(0.75),
                            width: 1.4,
                            dash: [4, 4]
                        ))
                    }
                } else {
                    lines.append(GlobeLine(
                        points: arc(from: start, to: here),
                        color: palette.route,
                        width: 1.6,
                        dash: nil
                    ))
                }
            }

            // Still to fly, dashed — the same reading the flat map's route
            // line has always had, and the one thing a line on a planet can
            // say without a label on it.
            if let arrival = route.arrival {
                lines.append(GlobeLine(
                    points: arc(from: here, to: GlobeGeometry.preciseVector(arrival)),
                    color: palette.route.withAlphaComponent(0.75),
                    width: 1.4,
                    dash: [4, 4]
                ))
            }
        }

        return lines
    }

    /// The fixes on the filed plan, marked up with where the aeroplane has got
    /// to along it.
    ///
    /// Worked out once, when the plan or the packet moves, rather than per
    /// frame: `PlanProgress.next` walks the whole plan and the drawing runs
    /// sixty times a second. What it buys is the one thing a plotted plan
    /// cannot say on its own — which of forty fixes is the one being flown to
    /// — and it is the same answer the flight window prints and the navigation
    /// display puts in its corner, so the three cannot disagree.
    private static func planFixes(route: GlobeRoute?) -> [GlobePlanFix] {
        guard let route = route, route.hasPlan else { return [] }

        let next = PlanProgress.next(in: route.plan, from: route.position)?.waypoint.index

        return route.plan.map { fix in
            GlobePlanFix(
                position: GlobeGeometry.vector(fix.coordinate),
                name: fix.name,
                isNext: fix.index == next,
                // Everything before the fix being flown to. Nil — no leg could
                // be resolved — leaves the whole plan ahead of the aeroplane,
                // which is the honest answer when nothing says otherwise.
                isPassed: next.map { fix.index < $0 } ?? false
            )
        }
    }

    /// A run of fixes, joined by the great circle between each neighbouring
    /// pair.
    ///
    /// Straight lines between the fixes would be right on a flat map and wrong
    /// here: a NAT segment is ten degrees of longitude, and the shortest path
    /// between its ends bows several hundred miles north of the chord on a
    /// sphere. Which is the whole reason the tracks are shaped the way they
    /// are, so drawing them straight would hide the point of them.
    private static func path(through fixes: [CLLocationCoordinate2D]) -> [SIMD3<Double>] {
        var points: [SIMD3<Double>] = []
        for index in 0..<(fixes.count - 1) {
            let leg = arc(
                from: GlobeGeometry.preciseVector(fixes[index]),
                to: GlobeGeometry.preciseVector(fixes[index + 1])
            )
            // The joint is the same point twice; the second copy is a zero
            // length segment and a wasted round line cap. Dropped by count
            // rather than by a conditional, which would be an `Array` against
            // an `ArraySlice` and not a type.
            points.append(contentsOf: leg.dropFirst(index == 0 ? 0 : 1))
        }
        return points
    }

    /// The great circle between two places, as points on the sphere.
    ///
    /// Spherical interpolation rather than a straight line between the two
    /// directions: a chord through the planet projects to a line that cuts
    /// across the ocean instead of following it, and on a globe that is
    /// immediately, obviously wrong.
    ///
    /// The step count follows the angle, so a hop between two neighbouring
    /// fields is a handful of points and a transpacific is a smooth arc.
    private static func arc(from start: SIMD3<Double>, to end: SIMD3<Double>) -> [SIMD3<Double>] {
        let dot = max(-1, min(1, simd_dot(start, end)))
        let angle = acos(dot)
        guard angle > 1e-4 else { return [start, end] }

        // Antipodal, where the great circle between them is not unique and any
        // answer is as good as any other. Straight through, so it is at least
        // continuous.
        guard angle < Double.pi - 1e-3 else { return [start, end] }

        let steps = max(8, min(96, Int(angle * 40)))
        let sine = sin(angle)

        var points: [SIMD3<Double>] = []
        points.reserveCapacity(steps + 1)
        for step in 0...steps {
            let t = Double(step) / Double(steps)
            let a = sin((1 - t) * angle) / sine
            let b = sin(t * angle) / sine
            points.append(simd_normalize(start * a + end * b))
        }
        return points
    }
}
