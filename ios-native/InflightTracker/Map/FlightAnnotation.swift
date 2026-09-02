import MapKit
import QuartzCore

/// A single aircraft on the map.
///
/// `coordinate` posts manual KVO notifications so MapKit animates the
/// annotation view to its new position instead of requiring a
/// remove-and-re-add on every update.
final class FlightAnnotation: NSObject, MKAnnotation {

    private var storedCoordinate: CLLocationCoordinate2D

    var coordinate: CLLocationCoordinate2D {
        get { storedCoordinate }
        set {
            willChangeValue(forKey: "coordinate")
            storedCoordinate = newValue
            didChangeValue(forKey: "coordinate")
        }
    }

    /// Latest snapshot of the flight this annotation represents.
    var flight: Flight

    var flightId: String { flight.id }

    var title: String? { flight.displayName }

    var subtitle: String? { flight.aircraftName.isEmpty ? nil : flight.aircraftName }

    /// Sprite key currently drawn, so the view only reloads its image when the
    /// aircraft type actually changes.
    var renderedSpriteKey: String?

    /// Heading currently applied as a rotation, for the same reason.
    var renderedHeading: Double?

    /// The marks currently drawn over this aeroplane, as the key that says
    /// whether they are still the right ones — the VA, whether its logo has
    /// arrived, and the callsign text.
    ///
    /// Same bargain as the two above: the marks are re-derived for every
    /// aeroplane on every traffic pass, and on a settled map the answer is the
    /// one already on screen. Comparing a short string is what stops that pass
    /// from touching a view.
    var renderedMarkKey: String?

    /// Dead reckoning between packets, while this aircraft is being smoothed.
    ///
    /// Nil is the ordinary case and the old behaviour exactly: the annotation
    /// sits where the last packet put it. See `FlightMotion`, and `beginMotion`
    /// below for when one is worth having.
    private var motion: FlightMotion?

    /// Whether the drawn position is currently being carried forward.
    var isSmoothing: Bool { motion != nil }

    /// The bearing to turn the sprite to: the smoothed one while this aircraft
    /// is being carried, and the reported one otherwise.
    var drawnHeading: Double { motion?.drawnHeading ?? flight.heading }

    init(flight: Flight) {
        self.flight = flight
        self.storedCoordinate = flight.coordinate
        super.init()
    }

    /// Applies a fresh packet. Returns `true` when the icon or rotation needs
    /// to be refreshed on screen.
    @discardableResult
    func update(with flight: Flight, now: CFTimeInterval) -> Bool {
        self.flight = flight

        if motion != nil {
            // Handed to the smoothing rather than drawn. The drawn position is
            // the ticker's to write, and writing the reported one here would be
            // precisely the jump the ticker exists to spend a second removing.
            motion?.report(flight, now: now)
        } else if storedCoordinate.latitude != flight.latitude
            || storedCoordinate.longitude != flight.longitude {
            // Only when it has actually moved. Setting the coordinate posts two
            // KVO notifications and asks MapKit to reposition the view, and a
            // good share of a busy server is sitting still at a gate — those
            // would be several hundred repositions a packet, all of them to the
            // same place.
            coordinate = flight.coordinate
        }

        let headingChanged = abs((renderedHeading ?? -999) - drawnHeading) > 0.5
        let spriteChanged = renderedSpriteKey != flight.spriteKey
        return headingChanged || spriteChanged
    }

    // MARK: - Motion

    /// Starts carrying this aircraft between packets, from where it is drawn
    /// now.
    func beginMotion(now: CFTimeInterval) {
        guard motion == nil else { return }
        motion = FlightMotion(flight: flight, drawnAt: storedCoordinate, now: now)
    }

    /// Stops, and puts the aircraft back on the position it was last reported
    /// at — which is where it belongs when nothing is animating it.
    func endMotion() {
        guard motion != nil else { return }
        motion = nil
        if storedCoordinate.latitude != flight.latitude
            || storedCoordinate.longitude != flight.longitude {
            coordinate = flight.coordinate
        }
    }

    /// Advances one frame, and writes the new position only if it is far enough
    /// from the last one to be seen.
    ///
    /// The threshold is the whole reason this scales. Repositioning an
    /// annotation is the expensive half of a frame — two KVO notifications and
    /// a layout, per aircraft — so it is spent on movement somebody can
    /// actually see, and an aeroplane whose progress this frame is a hundredth
    /// of a point simply banks it until it adds up to something.
    ///
    /// Returns whether the sprite's rotation wants refreshing too.
    @discardableResult
    func advanceMotion(to now: CFTimeInterval, pointsPerMetre: Double) -> Bool {
        guard motion != nil else { return false }

        let position = motion?.advance(to: now) ?? storedCoordinate

        let moved = FlightMotion.pointsApart(
            storedCoordinate,
            position,
            pointsPerMetre: pointsPerMetre
        )
        if moved >= 0.1 { coordinate = position }

        return abs((renderedHeading ?? -999) - drawnHeading) > 0.5
    }

    /// How far this aircraft travels in a second, in points on the map as it is
    /// currently scaled. Below a fraction of one, there is nothing to animate
    /// and the smoothing is not worth running.
    func drawnPointsPerSecond(pointsPerMetre: Double) -> Double {
        flight.groundSpeedKnots * 0.514444 * pointsPerMetre
    }
}

/// The aircraft a replay is drawing.
///
/// Separate from `FlightAnnotation` because it is not one of the server's
/// aircraft: it is a position on a path we already have, and it moves twenty
/// times a second rather than once a packet. Same KVO treatment on
/// `coordinate`, for the same reason — MapKit slides the view to each new
/// position instead of being handed a new annotation each frame.
final class ReplayAnnotation: NSObject, MKAnnotation {

    private var storedCoordinate: CLLocationCoordinate2D

    var coordinate: CLLocationCoordinate2D {
        get { storedCoordinate }
        set {
            willChangeValue(forKey: "coordinate")
            storedCoordinate = newValue
            didChangeValue(forKey: "coordinate")
        }
    }

    /// Bearing along the track, which is what the sprite is rotated by.
    var heading: Double

    /// Held here rather than read from the feed each frame, so the replay
    /// keeps its aircraft even if the flight stops reporting mid-playback.
    var spriteKey: String

    init(coordinate: CLLocationCoordinate2D, heading: Double, spriteKey: String) {
        self.storedCoordinate = coordinate
        self.heading = heading
        self.spriteKey = spriteKey
        super.init()
    }
}
