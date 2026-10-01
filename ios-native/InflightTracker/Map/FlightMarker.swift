import CoreLocation
import QuartzCore

/// A single aircraft on the map, as the map holds it between packets.
///
/// Not a view and not an annotation: every aeroplane on the map is one feature
/// in one GeoJSON source, drawn by a single symbol layer on the GPU. This is
/// the state behind that feature — the last packet, where the aeroplane is
/// currently *drawn*, and what was last written to the source — so the map can
/// tell which features actually need rewriting on a frame.
final class FlightMarker {

    /// Latest snapshot of the flight this marker represents.
    var flight: Flight

    var flightId: String { flight.id }

    /// Where the aircraft is drawn right now: the reported position, or the
    /// smoothed one while it is being carried between packets.
    private(set) var coordinate: CLLocationCoordinate2D

    /// The position and heading last written to the map's source, so a frame
    /// that has moved the aeroplane by less than can be seen writes nothing.
    var writtenCoordinate: CLLocationCoordinate2D?
    var writtenHeading: Double?

    /// Dead reckoning between packets, while this aircraft is being smoothed.
    ///
    /// Nil is the ordinary case: the marker sits where the last packet put it.
    /// See `FlightMotion`, and `beginMotion` below for when one is worth having.
    private var motion: FlightMotion?

    /// Whether the drawn position is currently being carried forward.
    var isSmoothing: Bool { motion != nil }

    /// The bearing to turn the sprite to: the smoothed one while this aircraft
    /// is being carried, and the reported one otherwise.
    var drawnHeading: Double { motion?.drawnHeading ?? flight.heading }

    init(flight: Flight) {
        self.flight = flight
        self.coordinate = flight.coordinate
    }

    /// Applies a fresh packet.
    func update(with flight: Flight, now: CFTimeInterval) {
        self.flight = flight

        if motion != nil {
            // Handed to the smoothing rather than drawn. The drawn position is
            // the ticker's to write, and writing the reported one here would be
            // precisely the jump the ticker exists to spend a second removing.
            motion?.report(flight, now: now)
        } else {
            coordinate = flight.coordinate
        }
    }

    // MARK: - Motion

    /// Starts carrying this aircraft between packets, from where it is drawn
    /// now.
    func beginMotion(now: CFTimeInterval) {
        guard motion == nil else { return }
        motion = FlightMotion(flight: flight, drawnAt: coordinate, now: now)
    }

    /// Stops, and puts the aircraft back on the position it was last reported
    /// at — which is where it belongs when nothing is animating it.
    func endMotion() {
        guard motion != nil else { return }
        motion = nil
        coordinate = flight.coordinate
    }

    /// Advances one frame.
    func advanceMotion(to now: CFTimeInterval) {
        guard motion != nil else { return }
        coordinate = motion?.advance(to: now) ?? coordinate
    }

    /// Whether what is drawn has moved far enough from what was last written
    /// to the map to be worth writing again: a tenth of a point of travel, or
    /// half a degree of turn.
    ///
    /// The threshold is the whole reason this scales. Writing a feature is the
    /// expensive half of a frame, so it is spent on movement somebody can
    /// actually see, and an aeroplane whose progress this frame is a hundredth
    /// of a point simply banks it until it adds up to something.
    func needsWrite(pointsPerMetre: Double) -> Bool {
        guard let written = writtenCoordinate, let heading = writtenHeading else { return true }
        if abs(heading - drawnHeading) > 0.5 { return true }
        return FlightMotion.pointsApart(written, coordinate, pointsPerMetre: pointsPerMetre) >= 0.1
    }

    /// How far this aircraft travels in a second, in points on the map as it is
    /// currently scaled. Below a fraction of one, there is nothing to animate
    /// and the smoothing is not worth running.
    func drawnPointsPerSecond(pointsPerMetre: Double) -> Double {
        flight.groundSpeedKnots * 0.514444 * pointsPerMetre
    }
}
