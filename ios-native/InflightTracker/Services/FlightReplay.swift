import Combine
import CoreLocation
import Foundation

/// Playback of a flight's own track.
///
/// The path is already on the device — the backend's history plus every live
/// sample since the window was opened — so a replay is a read over an array
/// rather than anything fetched. Nothing here talks to the map: it publishes a
/// frame, and the map draws whatever the current frame says.
///
/// Playback runs in *track* time rather than wall-clock time: the whole path
/// takes `duration` seconds however long the flight itself was, because the
/// point is to watch nine hours of flying, not to sit through it. Position is
/// interpolated between samples so the aircraft slides rather than hopping
/// breadcrumb to breadcrumb.
final class FlightReplay: ObservableObject {

    /// One instant of the replay: everything the map and the bar need to draw
    /// it, and nothing else.
    struct Frame: Equatable {
        let coordinate: CLLocationCoordinate2D
        let altitudeFeet: Double
        let groundSpeedKnots: Double

        /// Derived from the track either side of this point — breadcrumbs
        /// carry no heading of their own, and a sprite pointing north through
        /// a whole flight looks broken.
        let heading: Double

        /// When this sample was recorded, when the history said.
        let date: Date?

        static func == (lhs: Frame, rhs: Frame) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.heading == rhs.heading
        }
    }

    /// How fast the whole path is played through. Wall-clock seconds for the
    /// entire flight, so the choice is "how long am I watching this for".
    enum Pace: Double, CaseIterable, Identifiable {
        case slow = 60
        case normal = 30
        case fast = 12

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .slow: return "½×"
            case .normal: return "1×"
            case .fast: return "2½×"
            }
        }

        /// The next one round the ring, which is all the bar's button does.
        var next: Pace {
            switch self {
            case .slow: return .normal
            case .normal: return .fast
            case .fast: return .slow
            }
        }
    }

    /// The aircraft being replayed. Nil when nothing is playing, which is what
    /// everything else keys off.
    @Published private(set) var flightId: String?

    /// What to call it in the bar — the callsign, captured at the start rather
    /// than re-read, since the replay outlives the feed's interest in it.
    @Published private(set) var title = ""

    @Published private(set) var isPlaying = false

    /// 0...1 along the track. Written by the ticker, and by the scrubber.
    @Published var progress: Double = 0

    @Published var pace: Pace = .normal

    /// The current instant, recomputed whenever `progress` moves.
    @Published private(set) var frame: Frame?

    var isActive: Bool { flightId != nil }

    /// Shortest track worth replaying. Below this there is nothing to watch —
    /// the same floor the altitude profile uses before it draws.
    static let minimumPoints = 4

    private var points: [TrackPoint] = []
    private var ticker: AnyCancellable?

    /// 20 a second: smooth enough that the aircraft slides, cheap enough that
    /// the map is redrawing an annotation rather than re-laying out a view.
    private static let tickInterval: TimeInterval = 1.0 / 20.0

    // MARK: - Control

    func start(flightId: String, title: String, points: [TrackPoint]) {
        guard points.count >= Self.minimumPoints else { return }

        self.points = points
        self.flightId = flightId
        self.title = title
        self.progress = 0
        self.frame = Self.frame(at: 0, in: points)

        play()
    }

    func stop() {
        ticker?.cancel()
        ticker = nil

        isPlaying = false
        flightId = nil
        title = ""
        points = []
        frame = nil
        progress = 0
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func cyclePace() {
        pace = pace.next

        // Re-armed so the new pace takes effect on the next tick rather than
        // at the end of the current run.
        if isPlaying { play() }
    }

    /// Called by the scrubber. Dragging is a deliberate act, so it takes over
    /// from playback rather than fighting the ticker for the same value.
    func scrub(to value: Double) {
        pause()
        progress = min(max(value, 0), 1)
        frame = Self.frame(at: progress, in: points)
    }

    private func play() {
        guard points.count >= Self.minimumPoints else { return }

        // Replaying from the end would sit on the last frame doing nothing.
        if progress >= 0.999 { progress = 0 }

        isPlaying = true

        ticker?.cancel()
        ticker = Timer.publish(every: Self.tickInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    private func pause() {
        ticker?.cancel()
        ticker = nil
        isPlaying = false
    }

    private func tick() {
        let step = Self.tickInterval / pace.rawValue
        let next = progress + step

        guard next < 1 else {
            progress = 1
            frame = Self.frame(at: 1, in: points)
            // Held at the end rather than looped: a replay that starts over
            // without being asked is a replay you have to catch to stop.
            pause()
            return
        }

        progress = next
        frame = Self.frame(at: next, in: points)
    }

    // MARK: - Frames

    /// Where the aircraft is at `progress`, interpolated between the two
    /// samples either side of it.
    ///
    /// Position is taken in index space rather than by timestamp: breadcrumbs
    /// arrive at a roughly steady cadence, and the history's dates are patchy
    /// enough — some samples carry none at all — that trusting them would
    /// stall the replay wherever one is missing.
    private static func frame(at progress: Double, in points: [TrackPoint]) -> Frame? {
        guard points.count >= 2 else { return points.first.map(frame(for:)) }

        let clamped = min(max(progress, 0), 1)
        let position = clamped * Double(points.count - 1)
        let index = min(Int(position), points.count - 2)
        let fraction = position - Double(index)

        let start = points[index]
        let end = points[index + 1]

        let coordinate = CLLocationCoordinate2D(
            latitude: start.coordinate.latitude
                + (end.coordinate.latitude - start.coordinate.latitude) * fraction,
            longitude: start.coordinate.longitude
                + (end.coordinate.longitude - start.coordinate.longitude) * fraction
        )

        return Frame(
            coordinate: coordinate,
            altitudeFeet: start.altitudeFeet + (end.altitudeFeet - start.altitudeFeet) * fraction,
            groundSpeedKnots: start.groundSpeedKnots
                + (end.groundSpeedKnots - start.groundSpeedKnots) * fraction,
            heading: bearing(from: start.coordinate, to: end.coordinate),
            date: fraction < 0.5 ? start.date : end.date
        )
    }

    private static func frame(for point: TrackPoint) -> Frame {
        Frame(
            coordinate: point.coordinate,
            altitudeFeet: point.altitudeFeet,
            groundSpeedKnots: point.groundSpeedKnots,
            heading: 0,
            date: point.date
        )
    }

    /// Initial great-circle bearing, in degrees from north.
    private static func bearing(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let fromLatitude = start.latitude * .pi / 180
        let toLatitude = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180

        let y = sin(deltaLongitude) * cos(toLatitude)
        let x = cos(fromLatitude) * sin(toLatitude)
            - sin(fromLatitude) * cos(toLatitude) * cos(deltaLongitude)

        guard x != 0 || y != 0 else { return 0 }

        let degrees = atan2(y, x) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
