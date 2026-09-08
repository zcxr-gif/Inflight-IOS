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

    /// How far apart two matches have to be to count as different answers.
    ///
    /// A taxiway is a polyline of many short edges, and the nearest point on
    /// each of them to a sample beside it is very nearly the same place. Wider
    /// than that and narrower than the gap between two crossing centrelines at
    /// a junction, which is the case the list exists for.
    private static let candidateSpacingMetres: Double = 18

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
        candidates(to: point, within: radius, limit: 1).first
    }

    /// The pieces of pavement a position could be on, nearest first.
    ///
    /// ## Why "nearest" is the wrong question on its own
    ///
    /// At a junction two taxiways cross, and a sample taken anywhere near the
    /// crossing is a few metres from both of them. Which one is *nearest* is
    /// then decided by GPS noise — a metre either way — while which one the
    /// aircraft was actually on is obvious from where it came from and where it
    /// went next.
    ///
    /// Answering with one match threw that away, and the result was the one
    /// artefact of the ground matching anybody ever noticed: a sample at a
    /// crossing snapped to the taxiway being crossed, the leg in routed up it,
    /// the leg out routed straight back down, and a clean taxi grew a little
    /// hook at the junction. See `GroundTrack.chosen`, which is what does the
    /// deciding now.
    ///
    /// Deduplicated by position rather than by edge. A centreline is a
    /// polyline, so a fifty-metre run of one taxiway is a dozen edges, and a
    /// list of the twelve nearest is twelve versions of the same answer.
    func candidates(to point: Point, within radius: Double, limit: Int) -> [Match] {
        // The cells are worked out by dividing and truncating, and truncating a
        // number that is not one is a trap rather than a wrong answer.
        guard point.x.isFinite, point.y.isFinite, limit > 0 else { return [] }

        let low = Self.cell(for: Point(x: point.x - radius, y: point.y - radius))
        let high = Self.cell(for: Point(x: point.x + radius, y: point.y + radius))

        var found: [Match] = []
        // An edge is filed in every cell its extent touches, so a long one is
        // reached from several of the cells being read here.
        var seen: Set<Int> = []

        for x in low.x...high.x {
            for y in low.y...high.y {
                for index in buckets[Cell(x: x, y: y)] ?? [] {
                    guard seen.insert(index).inserted else { continue }
                    let edge = edges[index]
                    let closest = Self.closest(
                        to: point,
                        onSegmentFrom: nodes[edge.from],
                        to: nodes[edge.to]
                    )
                    guard closest.distance <= radius else { continue }
                    found.append(
                        Match(edge: index, point: closest.point, metresFromTrack: closest.distance)
                    )
                }
            }
        }

        found.sort { $0.metresFromTrack < $1.metresFromTrack }

        var kept: [Match] = []
        for match in found {
            guard kept.count < limit else { break }
            let isNew = !kept.contains {
                Self.length(from: $0.point, to: match.point) < Self.candidateSpacingMetres
            }
            guard isNew else { continue }
            kept.append(match)
        }
        return kept
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

    /// The track as it should be drawn, and which of its points the pavement
    /// is responsible for.
    ///
    /// The flags travel with the points because the two things downstream that
    /// draw this need to know them apart. A routed ground run is already the
    /// shape of the concrete — right angles, exactly where the chart puts them
    /// — and running a spline through it rounds those corners off onto the
    /// grass. See `PathSmoothing`, which leaves them alone.
    struct Track {

        let points: [TrackPoint]

        /// Parallel to `points`. True where the point is on mapped pavement,
        /// which is every routed ground point and every sample the matching
        /// moved; false for the whole airborne length of every flight.
        let onPavement: [Bool]

        static func untouched(_ points: [TrackPoint]) -> Track {
            Track(points: points, onPavement: Array(repeating: false, count: points.count))
        }
    }

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

    // MARK: - Choosing between pieces of pavement

    /// How many pieces of pavement a single sample is allowed to be weighed
    /// against. Four is a crossroads with a stand lead-in on it, which is as
    /// ambiguous as an aerodrome gets.
    private static let maximumCandidates = 4

    /// How much further than the nearest a candidate may be and still be
    /// considered.
    ///
    /// This is what keeps the whole arrangement cheap: past a junction there is
    /// only ever one piece of pavement inside this, so the ordinary sample
    /// costs one lookup and no routing at all. Wide enough to hold both arms of
    /// a crossing, which is the case worth spending anything on.
    private static let candidateSlackMetres: Double = 30

    /// A candidate is charged this per metre it sits from the raw sample, set
    /// against the metres of detour choosing it would cost.
    ///
    /// Below one on purpose. A sample's own position is noisy — that is the
    /// entire reason the track is being matched to the map — while a detour is
    /// arithmetic on the chart, so when the two disagree the chart is the
    /// better witness.
    private static let snapWeight: Double = 0.6

    /// How many routing searches the choosing may spend on one track.
    ///
    /// A taxi has a handful of genuinely ambiguous samples and the rest cost
    /// nothing, so this is the guard against a pathological track rather than a
    /// working limit — past it, samples fall back to plain nearest, which is
    /// what they used to get everywhere.
    private static let maximumChoiceSearches = 600

    // MARK: - Spikes

    /// A turn sharper than this is a reversal rather than a corner.
    ///
    /// Taxiways meet at right angles and the odd oblique; nothing on an
    /// aerodrome asks an aircraft to turn back on itself inside a few tens of
    /// metres. Held as the cosine so the test is a dot product rather than an
    /// arccosine — this runs over every point of every ground run.
    private static let reversalCosine: Double = -0.87

    /// And how short the legs either side of it have to be to be a spike rather
    /// than a genuine turn-back.
    ///
    /// An aircraft really can reverse direction on the ground — a back-track
    /// down a runway, a push and pull at a de-icing pad — and those run
    /// hundreds of metres. A hook at a junction is a few tens.
    private static let spikeMetres: Double = 90

    /// Passes of spike removal. A spike removed can leave its neighbours
    /// forming a shallower one; three passes settles anything a junction
    /// produces, and stopping is what keeps this from eating a real turn one
    /// point at a time.
    private static let spikePasses = 3

    /// The same track, with everything on the ground running along the pavement
    /// rather than across it.
    ///
    /// Samples that match nothing — the whole airborne part of every flight,
    /// and any ground segment at a field whose taxiways are not mapped — are
    /// returned exactly as they came in, so the fallback is per segment rather
    /// than per flight.
    static func following(_ points: [TrackPoint], on networks: [TaxiNetwork]) -> Track {
        guard !networks.isEmpty, points.count >= 2 else { return .untouched(points) }

        let matches = chosen(for: points, on: networks)
        guard matches.contains(where: { $0 != nil }) else { return .untouched(points) }

        var output: [TrackPoint] = []
        var onPavement: [Bool] = []
        output.reserveCapacity(points.count + 128)
        onPavement.reserveCapacity(points.count + 128)
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
            // The head is not on the pavement even when it matched: it is drawn
            // at the raw position, so the segment into it is a chord like any
            // other and is smoothed like one.
            onPavement.append(!isHead && matches[index] != nil)

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
                onPavement.append(true)
                inserted += 1
            }
        }

        return withoutSpikes(Track(points: output, onPavement: onPavement))
    }

    // MARK: - Where each sample is

    /// One sample's place on the network: which graph, and where on it.
    private typealias Placement = (network: Int, match: TaxiNetwork.Match)

    /// Which piece of pavement each sample is drawn onto.
    ///
    /// Not simply the nearest one. A sample at a junction is a few metres from
    /// two crossing taxiways and the nearer of them is decided by noise, so
    /// choosing on distance alone puts a taxi on the wrong arm of the crossing
    /// for exactly one sample — which the router then draws as a hook out and
    /// straight back, because that is faithfully what it was told happened.
    ///
    /// So an ambiguous sample is charged for the *detour* each of its
    /// candidates would cost: how much further the pavement route runs, into it
    /// from the sample before and out of it towards the sample after, than the
    /// straight line between them. A hook pays for itself twice and loses to a
    /// candidate a few metres further from the raw position, which is the whole
    /// judgement being made here.
    ///
    /// One pass forwards rather than a search over every combination. The
    /// lookahead is against the *nearest* candidate of the following sample —
    /// not its final choice, which has not been made yet — and that is enough:
    /// what it has to notice is that leaving this candidate costs a detour at
    /// all, and any point on the next piece of pavement says so.
    private static func chosen(
        for points: [TrackPoint],
        on networks: [TaxiNetwork]
    ) -> [Placement?] {
        var placements: [Placement?] = Array(repeating: nil, count: points.count)
        var previous: Placement?
        var searches = 0

        for index in points.indices {
            let options = candidates(for: points[index], on: networks)
            guard let nearest = options.first else {
                previous = nil
                continue
            }

            // The ordinary sample: one piece of pavement anywhere near it, or
            // no budget left to weigh the alternatives. Either way the nearest
            // is the answer, which is what every sample used to get.
            guard options.count > 1, searches < maximumChoiceSearches else {
                placements[index] = nearest
                previous = nearest
                continue
            }

            var ahead: Placement?
            if index + 1 < points.count {
                ahead = candidates(for: points[index + 1], on: networks).first
            }

            var best: Placement = nearest
            var bestCost = Double.greatestFiniteMagnitude
            for option in options {
                var cost = option.match.metresFromTrack * snapWeight
                if let previous = previous {
                    cost += detour(from: previous, to: option, on: networks)
                    searches += 1
                }
                if let ahead = ahead {
                    cost += detour(from: option, to: ahead, on: networks)
                    searches += 1
                }
                guard cost < bestCost else { continue }
                bestCost = cost
                best = option
            }

            placements[index] = best
            previous = best
        }

        return placements
    }

    /// How much further the pavement runs between two placements than the
    /// straight line between them.
    ///
    /// Zero for two placements on different fields — there is nothing to
    /// compare and nothing to route — which is right: a candidate cannot be
    /// blamed for a leg that was never going to be drawn along the concrete.
    private static func detour(
        from: Placement,
        to: Placement,
        on networks: [TaxiNetwork]
    ) -> Double {
        guard from.network == to.network else { return 0 }

        let network = networks[from.network]
        let straight = TaxiNetwork.length(from: from.match.point, to: to.match.point)
        let allowance = straight * detourFactor + detourSlackMetres
        let between = network.route(from: from.match, to: to.match, limitMetres: allowance)
        guard !between.isEmpty else { return 0 }

        let run = [from.match.point] + between + [to.match.point]
        var length = 0.0
        for step in 1..<run.count {
            length += TaxiNetwork.length(from: run[step - 1], to: run[step])
        }
        return max(0, length - straight)
    }

    /// The pieces of pavement a sample could be on, nearest first, with the
    /// obviously-worse ones already dropped.
    private static func candidates(
        for point: TrackPoint,
        on networks: [TaxiNetwork]
    ) -> [Placement] {
        guard point.groundSpeedKnots <= taxiSpeedCeiling,
              CLLocationCoordinate2DIsValid(point.coordinate) else { return [] }

        var found: [Placement] = []
        for (index, network) in networks.enumerated() {
            let matches = network.candidates(
                to: network.point(point.coordinate),
                within: snapRadiusMetres,
                limit: maximumCandidates
            )
            for match in matches {
                found.append((network: index, match: match))
            }
        }

        found.sort { $0.match.metresFromTrack < $1.match.metresFromTrack }
        guard let nearest = found.first else { return [] }

        let ceiling = nearest.match.metresFromTrack + candidateSlackMetres
        let near = found.prefix { $0.match.metresFromTrack <= ceiling }
        return Array(near.prefix(maximumCandidates))
    }

    private static func placed(
        _ point: TrackPoint,
        at match: Placement?,
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

    // MARK: - Cleaning up after the router

    /// Takes the hooks out of a routed ground run.
    ///
    /// The belt to `chosen`'s braces. Choosing the right piece of pavement
    /// removes the reason a taxi grows a spur at a junction, and this removes
    /// the spur itself in the cases it does not: a stand lead-in the aircraft
    /// was genuinely parked on and then left, a field whose centrelines are
    /// drawn as a star of stubs, a sample the router could only reach by going
    /// round something.
    ///
    /// A spike is a point whose two neighbours lie back in nearly the same
    /// direction — a turn of more than about 150° — with at least one short leg
    /// either side. That is a description of going out and coming back, and it
    /// is not a description of any turn an aircraft makes on the ground at
    /// that scale.
    ///
    /// Only points the pavement put there are eligible, and never the ends: the
    /// first point is where the track starts and the last is where the
    /// aeroplane is being drawn.
    private static func withoutSpikes(_ track: Track) -> Track {
        var points = track.points
        var onPavement = track.onPavement
        guard points.count == onPavement.count, points.count >= 3 else { return track }

        for _ in 0..<spikePasses {
            var keep = Array(repeating: true, count: points.count)
            var dropped = 0

            var index = 1
            while index < points.count - 1 {
                guard onPavement[index], onPavement[index - 1], onPavement[index + 1] else {
                    index += 1
                    continue
                }

                let into = vector(from: points[index - 1], to: points[index])
                let outOf = vector(from: points[index], to: points[index + 1])
                let lengthIn = (into.x * into.x + into.y * into.y).squareRoot()
                let lengthOut = (outOf.x * outOf.x + outOf.y * outOf.y).squareRoot()
                guard lengthIn > 0, lengthOut > 0 else {
                    index += 1
                    continue
                }
                guard min(lengthIn, lengthOut) < spikeMetres else {
                    index += 1
                    continue
                }

                let cosine = (into.x * outOf.x + into.y * outOf.y) / (lengthIn * lengthOut)
                guard cosine < reversalCosine else {
                    index += 1
                    continue
                }

                keep[index] = false
                dropped += 1
                // Past the point just dropped as well: judging the next one
                // against a neighbour that is on its way out would measure a
                // turn nothing will be drawn at.
                index += 2
            }

            guard dropped > 0 else { break }

            var nextPoints: [TrackPoint] = []
            var nextPavement: [Bool] = []
            nextPoints.reserveCapacity(points.count - dropped)
            nextPavement.reserveCapacity(points.count - dropped)
            for position in points.indices where keep[position] {
                nextPoints.append(points[position])
                nextPavement.append(onPavement[position])
            }
            points = nextPoints
            onPavement = nextPavement
        }

        return Track(points: points, onPavement: onPavement)
    }

    /// Two points as metres east and north of the first.
    ///
    /// A local flattening rather than either network's frame: this runs over a
    /// track that may touch two fields, the answer is only ever used as a
    /// direction and a length over a few hundred metres, and at that size the
    /// difference is centimetres.
    private static func vector(
        from: TrackPoint,
        to: TrackPoint
    ) -> (x: Double, y: Double) {
        let metresPerDegree = 111_320.0
        let scale = cos(from.coordinate.latitude * .pi / 180)
        var deltaLongitude = to.coordinate.longitude - from.coordinate.longitude
        if deltaLongitude > 180 { deltaLongitude -= 360 }
        if deltaLongitude < -180 { deltaLongitude += 360 }
        return (
            x: deltaLongitude * metresPerDegree * scale,
            y: (to.coordinate.latitude - from.coordinate.latitude) * metresPerDegree
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
