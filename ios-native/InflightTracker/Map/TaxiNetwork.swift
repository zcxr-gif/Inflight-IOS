import CoreLocation
import Foundation

/// The field's pavement, as something a path can be routed along.
///
/// ## Why the flown path needs this
///
/// A track is a handful of positions and a straight line between each pair. In
/// the air that is very nearly true — an aeroplane between two breadcrumbs went
/// approximately straight — and on the ground it is not true at all. An
/// aircraft taxiing from a stand to the runway follows a alphabet of pavement
/// with right angles in it; the samples land at the corners and wherever else
/// the feed happened to tick, and the line drawn between them cuts the corners,
/// crosses the grass, and runs through two terminals on the way. The trail store
/// makes this worse rather than better: it thins by *distance*, at two nautical
/// miles to begin with, so a whole taxi can arrive as two points.
///
/// So the ground part of the path is matched to the map: each sample is put on
/// the piece of pavement it is on, and the line between two samples is the route
/// along the pavement rather than the chord across it. This is the standard
/// map-matching arrangement and it makes the standard bargain — the drawn line
/// is the shortest way the aircraft *could* have gone between two things we
/// know, which is a better claim than the straight line was making and is on the
/// concrete either way.
///
/// ## What is in the graph, and what it costs
///
/// Taxiways and runways. Runways are here for the connectivity rather than for
/// themselves: a taxi route crosses them constantly, and a graph without them
/// falls into disconnected pieces at every crossing. They are priced at
/// `runwayWeight` a metre so the router only takes one where there is genuinely
/// no taxiway alternative — a crossing, which is short — rather than running a
/// mile down 27L because it is straighter than the parallel taxiway.
///
/// Aprons and terminals are areas rather than centrelines and are not routable;
/// a push-back across an unmapped apron simply finds nothing and is drawn as it
/// always was.
final class TaxiNetwork {

    // MARK: - Geometry

    /// A position in metres, east and north of the field.
    struct Point {
        var x: Double
        var y: Double
    }

    /// Latitude and longitude, flattened onto metres around one field.
    ///
    /// An aerodrome is four miles across. At that size the earth is flat, the
    /// error in treating it so is centimetres, and the arithmetic that follows
    /// — distance from a point to a segment, thousands of times — is a
    /// subtraction and a multiply rather than a haversine.
    struct Frame {

        private let latitude: Double
        private let longitude: Double
        private let metresPerLatitude: Double
        private let metresPerLongitude: Double

        init(centre: CLLocationCoordinate2D) {
            latitude = centre.latitude
            longitude = centre.longitude
            metresPerLatitude = 111_320
            // A degree of longitude shortens towards the poles. Floored so the
            // frame is still invertible at latitudes no aerodrome is at.
            metresPerLongitude = max(111_320 * cos(centre.latitude * .pi / 180), 1)
        }

        func point(_ coordinate: CLLocationCoordinate2D) -> Point {
            Point(
                x: Self.wrapped(coordinate.longitude - longitude) * metresPerLongitude,
                y: (coordinate.latitude - latitude) * metresPerLatitude
            )
        }

        func coordinate(_ point: Point) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: latitude + point.y / metresPerLatitude,
                longitude: Self.wrapped(longitude + point.x / metresPerLongitude)
            )
        }

        /// A longitude difference the short way round.
        ///
        /// A field at 179.9° and an aircraft at −179.95° are four miles apart
        /// and three hundred and sixty degrees of arithmetic apart. Without
        /// this the frame puts one of them forty thousand kilometres away and
        /// nothing at that field ever matches.
        private static func wrapped(_ degrees: Double) -> Double {
            guard degrees.isFinite else { return 0 }
            var value = degrees.truncatingRemainder(dividingBy: 360)
            if value > 180 { value -= 360 }
            if value < -180 { value += 360 }
            return value
        }
    }

    /// One straight run of centreline between two of its own nodes.
    struct Edge {
        let from: Int
        let to: Int
        let metres: Double

        /// What a metre of this pavement costs the router. One for a taxiway,
        /// `runwayWeight` for a runway.
        let weight: Double
    }

    /// Where a position sits on the network: which piece, whereabouts on it,
    /// and how far it had to be moved to get there.
    struct Match {
        let edge: Int
        let point: Point
        let metresFromTrack: Double
    }

    // MARK: - Tuning

    /// How much dearer a metre of runway is than a metre of taxiway.
    ///
    /// High enough that a runway is never a short cut and low enough that a
    /// crossing — thirty metres of it — is still obviously the way across.
    private static let runwayWeight: Double = 8

    /// Vertices closer together than this are the same junction.
    ///
    /// OpenStreetMap ways share a node at a junction, so the coordinates are
    /// usually identical and any tolerance at all would do. This is for the
    /// fields where they are not quite — a way drawn to touch another rather
    /// than to join it — which would otherwise leave the graph in pieces.
    private static let weldMetres: Double = 2

    /// The side of a lookup cell, in metres. Wider than a stand and narrower
    /// than a taxiway is long.
    private static let cellMetres: Double = 120

    /// Nodes a single search may settle before it gives up.
    ///
    /// A search between two samples of one taxi is local — a few dozen nodes —
    /// and this is the guard against the pathological case rather than a
    /// working limit: a match on the wrong side of a large field with no route
    /// to the other, which would otherwise walk the whole graph to find that
    /// out.
    private static let maximumSettled = 4_000

    // MARK: - Contents

    let icao: String
    let frame: Frame

    private var nodes: [Point] = []
    private var edges: [Edge] = []
    private var adjacency: [[Int]] = []

    /// Edges by cell, so finding the pavement nearest a position reads a
    /// handful of buckets rather than every centreline at the field.
    private var buckets: [Cell: [Int]] = [:]

    /// Nodes by cell, used only while building, to weld the ways together at
    /// their junctions.
    private var welds: [Cell: [Int]] = [:]

    var isEmpty: Bool { edges.isEmpty }

    /// Identifies this graph's contents for a redraw key.
    var edgeCount: Int { edges.count }

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    init(layout: AirportLayout, centre: CLLocationCoordinate2D) {
        icao = layout.icao
        frame = Frame(centre: centre)

        for piece in layout.pieces {
            let weight: Double
            switch piece.kind {
            case .taxiway: weight = 1
            case .runway: weight = Self.runwayWeight
            // Aprons and terminals are shapes, and a hold bar is paint. None of
            // them is a centreline, and a route down one would be a claim about
            // where an aircraft went that the map does not make.
            case .apron, .terminal, .holdShort: continue
            }

            var previous: Int?
            for coordinate in piece.coordinates {
                // A way with a bad node in it is otherwise a graph with an
                // infinity in it, and every distance measured against that node
                // comes back as one.
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }

                let here = node(at: frame.point(coordinate))
                guard let start = previous, start != here else {
                    previous = here
                    continue
                }
                previous = here

                let metres = Self.length(from: nodes[start], to: nodes[here])
                guard metres > 0 else { continue }

                let edge = edges.count
                edges.append(Edge(from: start, to: here, metres: metres, weight: weight))
                adjacency[start].append(edge)
                adjacency[here].append(edge)
                file(edge: edge, from: nodes[start], to: nodes[here])
            }
        }

        // Nothing reads these once the graph is built, and at a large field
        // they are as big as the graph.
        welds.removeAll()
    }

    // MARK: - Building

    /// The node at a position, welding onto one already there.
    private func node(at point: Point) -> Int {
        // On a grid of its own, sized to the welding radius rather than to the
        // lookup radius. A junction is metres across and a lookup cell is a
        // hundred and twenty of them: scanning the neighbours of a *lookup*
        // cell would compare every vertex within a couple of city blocks
        // against every other one, which at a large field is a million
        // distances to answer a question about two.
        let cell = Self.weldCell(for: point)
        var best: Int?
        var bestDistance = Self.weldMetres

        for dx in -1...1 {
            for dy in -1...1 {
                for candidate in welds[Cell(x: cell.x + dx, y: cell.y + dy)] ?? [] {
                    let distance = Self.length(from: nodes[candidate], to: point)
                    guard distance <= bestDistance else { continue }
                    bestDistance = distance
                    best = candidate
                }
            }
        }

        if let existing = best { return existing }

        let index = nodes.count
        nodes.append(point)
        adjacency.append([])
        welds[cell, default: []].append(index)
        return index
    }

    /// Files an edge in every cell its extent touches.
    private func file(edge: Int, from: Point, to: Point) {
        let low = Self.cell(for: Point(x: min(from.x, to.x), y: min(from.y, to.y)))
        let high = Self.cell(for: Point(x: max(from.x, to.x), y: max(from.y, to.y)))

        // The extent rather than the line, so a piece of pavement is always
        // findable from anywhere it might be nearest to — walking the cells the
        // line actually crosses would be tighter and would occasionally clip a
        // corner, which costs a match rather than a distance test.
        //
        // The bound is on the pathological way rather than on the long one: a
        // runway laid corner to corner is nine hundred buckets, and something
        // that wants four thousand of them is a way that runs across a county
        // and is not a taxiway.
        guard (high.x - low.x + 1) * (high.y - low.y + 1) <= 4_096 else { return }

        for x in low.x...high.x {
            for y in low.y...high.y {
                buckets[Cell(x: x, y: y), default: []].append(edge)
            }
        }
    }

    private static func cell(for point: Point) -> Cell {
        Cell(
            x: Int((point.x / cellMetres).rounded(.down)),
            y: Int((point.y / cellMetres).rounded(.down))
        )
    }

    /// The build-time grid: one cell to the welding radius, so the nine cells
    /// around a vertex are guaranteed to hold anything close enough to be the
    /// same junction and very little else.
    private static func weldCell(for point: Point) -> Cell {
        Cell(
            x: Int((point.x / weldMetres).rounded(.down)),
            y: Int((point.y / weldMetres).rounded(.down))
        )
    }

    // MARK: - Matching

    /// The pavement nearest a position, if any of it is near enough.
    func nearest(to point: Point, within radius: Double) -> Match? {
        // The cells are worked out by dividing and truncating, and truncating a
        // number that is not one is a trap rather than a wrong answer.
        guard point.x.isFinite, point.y.isFinite else { return nil }

        let low = Self.cell(for: Point(x: point.x - radius, y: point.y - radius))
        let high = Self.cell(for: Point(x: point.x + radius, y: point.y + radius))

        var best: Match?

        for x in low.x...high.x {
            for y in low.y...high.y {
                for index in buckets[Cell(x: x, y: y)] ?? [] {
                    let edge = edges[index]
                    let closest = Self.closest(
                        to: point,
                        onSegmentFrom: nodes[edge.from],
                        to: nodes[edge.to]
                    )
                    guard closest.distance <= radius else { continue }
                    guard closest.distance < (best?.metresFromTrack ?? .greatestFiniteMagnitude) else { continue }
                    best = Match(edge: index, point: closest.point, metresFromTrack: closest.distance)
                }
            }
        }

        return best
    }

    /// Converts a matched position back to something the map can draw.
    func coordinate(_ point: Point) -> CLLocationCoordinate2D { frame.coordinate(point) }

    func point(_ coordinate: CLLocationCoordinate2D) -> Point { frame.point(coordinate) }

    static func length(from: Point, to: Point) -> Double {
        let dx = to.x - from.x
        let dy = to.y - from.y
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - Routing

    /// The pavement between two matched positions, as the points between them.
    ///
    /// Empty has one meaning and it is the right one either way: draw the
    /// straight line. Two matches on the same piece of centreline *are* a
    /// straight line, and two the router could not join inside `limitMetres`
    /// are two the map cannot say anything better about than the chord — which
    /// is the fallback the whole arrangement is supposed to have.
    func route(from start: Match, to goal: Match, limitMetres: Double) -> [Point] {
        guard start.edge != goal.edge, start.edge < edges.count, goal.edge < edges.count else { return [] }

        let startEdge = edges[start.edge]
        let goalEdge = edges[goal.edge]
        let goalPoint = goal.point

        // What it costs to leave the goal's own piece of pavement at each of
        // its ends. The search is over nodes, and the goal is not one.
        var exits: [Int: Double] = [:]
        for end in [goalEdge.from, goalEdge.to] {
            exits[end] = Self.length(from: nodes[end], to: goalPoint) * goalEdge.weight
        }

        var distance: [Int: Double] = [:]
        var previous: [Int: Int] = [:]
        var settled: Set<Int> = []
        var heap = Heap()

        // Both ends of the piece the track is on, priced by how far along it
        // the match sits. Seeding both is what lets the route leave in the
        // sensible direction rather than always walking to one end first.
        for end in [startEdge.from, startEdge.to] {
            let cost = Self.length(from: start.point, to: nodes[end]) * startEdge.weight
            guard cost <= limitMetres, cost < distance[end] ?? .greatestFiniteMagnitude else { continue }
            distance[end] = cost
            heap.push(end, priority: cost + Self.length(from: nodes[end], to: goalPoint))
        }

        var best = Double.greatestFiniteMagnitude
        var arrival: Int?

        while let popped = heap.pop() {
            // A* pops in order of cost-so-far plus the straight line left to
            // run. The straight line is never an over-estimate, so the first
            // pop that cannot beat what we already have is the last one worth
            // making.
            if popped.priority >= best { break }
            if settled.count >= Self.maximumSettled { break }
            if settled.contains(popped.node) { continue }
            settled.insert(popped.node)

            guard let here = distance[popped.node] else { continue }

            if let exit = exits[popped.node], here + exit < best {
                best = here + exit
                arrival = popped.node
            }

            for index in adjacency[popped.node] {
                let edge = edges[index]
                let other = edge.from == popped.node ? edge.to : edge.from
                guard !settled.contains(other) else { continue }

                let cost = here + edge.metres * edge.weight
                guard cost <= limitMetres, cost < distance[other] ?? .greatestFiniteMagnitude else { continue }
                distance[other] = cost
                previous[other] = popped.node
                heap.push(other, priority: cost + Self.length(from: nodes[other], to: goalPoint))
            }
        }

        guard let end = arrival, best <= limitMetres else { return [] }

        var walk: [Int] = [end]
        var cursor = end
        while let step = previous[cursor], walk.count <= settled.count {
            walk.append(step)
            cursor = step
        }

        return walk.reversed().map { nodes[$0] }
    }

    // MARK: - Segment arithmetic

    private static func closest(
        to point: Point,
        onSegmentFrom from: Point,
        to end: Point
    ) -> (point: Point, distance: Double) {
        let dx = end.x - from.x
        let dy = end.y - from.y
        let squared = dx * dx + dy * dy

        guard squared > 0 else { return (from, length(from: from, to: point)) }

        let along = min(max(((point.x - from.x) * dx + (point.y - from.y) * dy) / squared, 0), 1)
        let landed = Point(x: from.x + dx * along, y: from.y + dy * along)
        return (landed, length(from: landed, to: point))
    }

    // MARK: - Queue

    /// A binary heap, because the search is the one part of this that runs more
    /// than once per field and `Array.min()` would make it quadratic.
    private struct Heap {

        private var items: [(node: Int, priority: Double)] = []

        mutating func push(_ node: Int, priority: Double) {
            items.append((node, priority))
            var child = items.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard items[child].priority < items[parent].priority else { break }
                items.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> (node: Int, priority: Double)? {
            guard let first = items.first else { return nil }
            items.swapAt(0, items.count - 1)
            items.removeLast()

            var parent = 0
            while true {
                let left = parent * 2 + 1
                let right = left + 1
                var smallest = parent
                if left < items.count, items[left].priority < items[smallest].priority { smallest = left }
                if right < items.count, items[right].priority < items[smallest].priority { smallest = right }
                guard smallest != parent else { break }
                items.swapAt(parent, smallest)
                parent = smallest
            }

            return first
        }
    }
}

/// One graph per field, built once.
///
/// A large aerodrome is a few thousand nodes and welding them is the expensive
/// part. The map asks for this on the layout pass that draws a path, which is
/// every pass where anything about the open aircraft changed, so the answer has
/// to be a dictionary lookup rather than a rebuild.
///
/// Main thread only, like the app's other stores.
final class TaxiNetworkStore {

    static let shared = TaxiNetworkStore()

    /// Keyed by ICAO, and holding nil for a field whose pavement turned out to
    /// have nothing routable in it — so that answer is not worked out twice
    /// either.
    private var networks: [String: TaxiNetwork?] = [:]

    /// What the layout looked like when its graph was built. A field is fetched
    /// once and cached for a month, so this changes about never — but a graph
    /// built from a layout that has since been replaced is a graph of the wrong
    /// aerodrome, and the check is a comparison of two integers.
    private var built: [String: Int] = [:]

    private init() {}

    func network(for layout: AirportLayout, centre: CLLocationCoordinate2D) -> TaxiNetwork? {
        if built[layout.icao] == layout.pieces.count, let cached = networks[layout.icao] {
            return cached
        }

        let network = TaxiNetwork(layout: layout, centre: centre)
        let usable = network.isEmpty ? nil : network
        networks[layout.icao] = usable
        built[layout.icao] = layout.pieces.count
        return usable
    }
}

/// Puts the ground part of a flown path back on the pavement.
enum GroundTrack {

    /// How far a sample may be moved to reach a centreline.
    ///
    /// About the distance from a stand to the taxilane serving it. Wider than
    /// this and a parked aircraft starts being dragged onto pavement it is not
    /// on; narrower and the samples on a stand — the ones with the most to gain
    /// — find nothing.
    static let snapRadiusMetres: Double = 50

    /// Above this, the aircraft is not taxiing.
    ///
    /// Sixty rather than thirty because a landing rollout decelerates through
    /// the taxi speeds and the turn-off is the part worth having. A take-off
    /// roll passes through this on its way up and the samples above it are left
    /// alone, which is the right answer twice over: the runway is not what this
    /// is for, and a departure is a straight line anyway.
    static let taxiSpeedCeiling: Double = 60

    /// How far a routed leg may run compared to the straight line it replaces.
    ///
    /// A taxi between two samples is rarely more than a right angle, which is a
    /// factor of about one and a half. Anything much beyond that is the router
    /// having matched one end to the wrong side of the field and found the long
    /// way round, and a straight line is the better answer.
    private static let detourFactor: Double = 2.6

    /// Added to the allowance, so two samples a few metres apart either side of
    /// a junction are not held to a few metres of pavement.
    private static let detourSlackMetres: Double = 120

    /// Total points the matching may add to a path.
    ///
    /// A taxi at a large field is a couple of hundred; this is the guard
    /// against a track that spends an hour on the ground turning into more
    /// geometry than the smoothing budget downstream can carry.
    private static let maximumInsertedPoints = 1_200

    /// The same track, with everything on the ground running along the pavement
    /// rather than across it.
    ///
    /// Samples that match nothing — the whole airborne part of every flight,
    /// and any ground segment at a field whose taxiways are not mapped — are
    /// returned exactly as they came in, so the fallback is per segment rather
    /// than per flight.
    static func following(_ points: [TrackPoint], on networks: [TaxiNetwork]) -> [TrackPoint] {
        guard !networks.isEmpty, points.count >= 2 else { return points }

        let matches = points.map { match(for: $0, on: networks) }
        guard matches.contains(where: { $0 != nil }) else { return points }

        var output: [TrackPoint] = []
        output.reserveCapacity(points.count + 128)
        var inserted = 0

        for index in points.indices {
            // Every sample but the last is drawn where the pavement says it is.
            //
            // The last one is the aircraft's live position, and it is drawn
            // where the aircraft is. The icon is there; a track that ended
            // fifty metres up the taxiway from its own aeroplane would be the
            // one artefact of this anybody would notice.
            let isHead = index == points.count - 1
            output.append(isHead ? points[index] : placed(points[index], at: matches[index], on: networks))

            guard !isHead, inserted < maximumInsertedPoints else { continue }
            guard let here = matches[index], let next = matches[index + 1], here.network == next.network else {
                continue
            }

            let network = networks[here.network]
            let straight = TaxiNetwork.length(from: here.match.point, to: next.match.point)
            let allowance = straight * detourFactor + detourSlackMetres
            let between = network.route(from: here.match, to: next.match, limitMetres: allowance)
            guard !between.isEmpty else { continue }

            let run = [here.match.point] + between + [next.match.point]
            var reached: [Double] = [0]
            reached.reserveCapacity(run.count)
            for step in 1..<run.count {
                reached.append(reached[step - 1] + TaxiNetwork.length(from: run[step - 1], to: run[step]))
            }
            guard let total = reached.last, total > 0 else { continue }

            for step in 1..<(run.count - 1) {
                output.append(
                    interpolated(
                        from: points[index],
                        to: points[index + 1],
                        fraction: reached[step] / total,
                        at: network.coordinate(run[step])
                    )
                )
                inserted += 1
            }
        }

        return output
    }

    // MARK: - Where each sample is

    private static func match(
        for point: TrackPoint,
        on networks: [TaxiNetwork]
    ) -> (network: Int, match: TaxiNetwork.Match)? {
        guard point.groundSpeedKnots <= taxiSpeedCeiling,
              CLLocationCoordinate2DIsValid(point.coordinate) else { return nil }

        var best: (network: Int, match: TaxiNetwork.Match)?
        for (index, network) in networks.enumerated() {
            guard let found = network.nearest(
                to: network.point(point.coordinate),
                within: snapRadiusMetres
            ) else { continue }
            guard found.metresFromTrack < (best?.match.metresFromTrack ?? .greatestFiniteMagnitude) else {
                continue
            }
            best = (index, found)
        }
        return best
    }

    private static func placed(
        _ point: TrackPoint,
        at match: (network: Int, match: TaxiNetwork.Match)?,
        on networks: [TaxiNetwork]
    ) -> TrackPoint {
        guard let match = match else { return point }
        return TrackPoint(
            coordinate: networks[match.network].coordinate(match.match.point),
            altitudeFeet: point.altitudeFeet,
            groundSpeedKnots: point.groundSpeedKnots,
            date: point.date
        )
    }

    /// A point invented between two samples, carrying their height and speed in
    /// proportion to how far along the routed leg it sits.
    ///
    /// The height matters: the path is coloured by it, and a taxi drawn from
    /// two samples reporting zero has to keep reporting zero along its whole
    /// length or the ground turns a different colour halfway down taxiway B.
    private static func interpolated(
        from: TrackPoint,
        to: TrackPoint,
        fraction: Double,
        at coordinate: CLLocationCoordinate2D
    ) -> TrackPoint {
        let date: Date?
        if let start = from.date, let end = to.date {
            date = start.addingTimeInterval(end.timeIntervalSince(start) * fraction)
        } else {
            date = from.date ?? to.date
        }

        return TrackPoint(
            coordinate: coordinate,
            altitudeFeet: from.altitudeFeet + (to.altitudeFeet - from.altitudeFeet) * fraction,
            groundSpeedKnots: from.groundSpeedKnots
                + (to.groundSpeedKnots - from.groundSpeedKnots) * fraction,
            date: date
        )
    }
}
