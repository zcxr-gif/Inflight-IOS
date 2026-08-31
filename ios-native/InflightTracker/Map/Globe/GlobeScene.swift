import Combine
import CoreLocation
import Foundation
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

    let position: SIMD3<Float>

    /// Which way it is pointing, as a direction lying along the surface. Only
    /// read when the traffic is drawn as aircraft rather than as dots.
    let heading: SIMD3<Float>

    /// Which piece of artwork it is. `PlaneSprites` resolves it.
    let spriteKey: String

    /// What it is painted, when the pilot colouring has an opinion — your own
    /// aeroplane, or somebody you watch. Nil is ordinary traffic.
    let tint: UIColor?

    /// Whether it is the aircraft whose window is open, which is drawn larger
    /// and over the rest.
    let isOpen: Bool
}

/// One field on the planet: where it is, what it is called, and whether
/// anybody is working it.
struct GlobeFieldMark: Equatable {
    let icao: String
    let position: SIMD3<Float>
    let isControlled: Bool
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

    /// The pavement of whichever field the camera is sitting over, once it is
    /// close enough for that to mean anything. Set on its own rather than
    /// through `rebuild`, because it arrives from the network on its own
    /// schedule and has nothing to do with a packet of traffic landing.
    private(set) var ground: GlobeGround?

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
        flownPath: [CLLocationCoordinate2D],
        natTracks: [[CLLocationCoordinate2D]],
        palette: GlobePalette
    ) {
        guard stamp != signature else { return }
        stamp = signature

        var traffic: [GlobeTrafficDot] = []
        traffic.reserveCapacity(flights.count)
        for flight in flights {
            traffic.append(GlobeTrafficDot(
                id: flight.id,
                position: GlobeGeometry.vector(flight.coordinate),
                heading: GlobeGeometry.headingVector(
                    latitude: flight.latitude,
                    longitude: flight.longitude,
                    headingDegrees: flight.heading
                ),
                spriteKey: flight.spriteKey,
                tint: highlighting.tint(for: flight.username),
                isOpen: flight.id == openFlightId
            ))
        }

        self.traffic = traffic
        self.fields = fields.map {
            GlobeFieldMark(
                icao: $0.airport.icao,
                position: GlobeGeometry.vector($0.airport.coordinate),
                isControlled: $0.isControlled
            )
        }
        self.lines = Self.lines(
            route: route,
            flownPath: flownPath,
            natTracks: natTracks,
            palette: palette
        )

        revision &+= 1
    }

    /// The field under the camera, or nothing when there is none worth drawing.
    func setGround(_ ground: GlobeGround?) {
        guard ground?.icao != self.ground?.icao else { return }
        self.ground = ground
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

        static func == (lhs: GlobeRoute, rhs: GlobeRoute) -> Bool {
            lhs.departure?.latitude == rhs.departure?.latitude
                && lhs.departure?.longitude == rhs.departure?.longitude
                && lhs.arrival?.latitude == rhs.arrival?.latitude
                && lhs.arrival?.longitude == rhs.arrival?.longitude
                && lhs.position.latitude == rhs.position.latitude
                && lhs.position.longitude == rhs.position.longitude
        }
    }

    /// Every line on the planet, in the order they are drawn.
    ///
    /// The organised tracks first, because they are about the ocean rather than
    /// about anybody in particular and everything else belongs on top of them;
    /// then where the open aircraft has been; then where it is going.
    private static func lines(
        route: GlobeRoute?,
        flownPath: [CLLocationCoordinate2D],
        natTracks: [[CLLocationCoordinate2D]],
        palette: GlobePalette
    ) -> [GlobeLine] {
        var lines: [GlobeLine] = []

        for track in natTracks where track.count > 1 {
            lines.append(GlobeLine(
                points: path(through: track),
                color: palette.track,
                width: 1.1,
                dash: [6, 4]
            ))
        }

        // The flown path is a series of reports rather than a route, so it is
        // joined fix to fix rather than smoothed: a great circle drawn between
        // two positions a few seconds apart is a claim about a turn nobody
        // reported.
        if flownPath.count > 1 {
            lines.append(GlobeLine(
                points: flownPath.map(GlobeGeometry.preciseVector),
                color: palette.flownPath,
                width: 1.8,
                dash: nil
            ))
        }

        if let route = route {
            let here = GlobeGeometry.preciseVector(route.position)

            // Flown solid, still to fly dashed — the same reading the flat
            // map's route line has always had, and the one thing a line on a
            // planet can say without a label on it.
            if let departure = route.departure {
                lines.append(GlobeLine(
                    points: arc(from: GlobeGeometry.preciseVector(departure), to: here),
                    color: palette.route,
                    width: 1.6,
                    dash: nil
                ))
            }
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
