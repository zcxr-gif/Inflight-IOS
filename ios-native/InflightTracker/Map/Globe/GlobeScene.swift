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
    let points: [SIMD3<Float>]
    let color: UIColor
    let width: CGFloat
    let dash: [CGFloat]?
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
                points: flownPath.map(GlobeGeometry.vector),
                color: palette.flownPath,
                width: 1.8,
                dash: nil
            ))
        }

        if let route = route {
            let here = GlobeGeometry.vector(route.position)

            // Flown solid, still to fly dashed — the same reading the flat
            // map's route line has always had, and the one thing a line on a
            // planet can say without a label on it.
            if let departure = route.departure {
                lines.append(GlobeLine(
                    points: arc(from: GlobeGeometry.vector(departure), to: here),
                    color: palette.route,
                    width: 1.6,
                    dash: nil
                ))
            }
            if let arrival = route.arrival {
                lines.append(GlobeLine(
                    points: arc(from: here, to: GlobeGeometry.vector(arrival)),
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
    private static func path(through fixes: [CLLocationCoordinate2D]) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        for index in 0..<(fixes.count - 1) {
            let leg = arc(
                from: GlobeGeometry.vector(fixes[index]),
                to: GlobeGeometry.vector(fixes[index + 1])
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
    private static func arc(from start: SIMD3<Float>, to end: SIMD3<Float>) -> [SIMD3<Float>] {
        let dot = max(-1, min(1, simd_dot(start, end)))
        let angle = acos(dot)
        guard angle > 1e-4 else { return [start, end] }

        // Antipodal, where the great circle between them is not unique and any
        // answer is as good as any other. Straight through, so it is at least
        // continuous.
        guard angle < Float.pi - 1e-3 else { return [start, end] }

        let steps = max(8, min(96, Int(angle * 40)))
        let sine = sin(angle)

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(steps + 1)
        for step in 0...steps {
            let t = Float(step) / Float(steps)
            let a = sin((1 - t) * angle) / sine
            let b = sin(t * angle) / sine
            points.append(simd_normalize(start * a + end * b))
        }
        return points
    }
}
