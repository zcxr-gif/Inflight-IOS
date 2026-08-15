import MapKit

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

    init(flight: Flight) {
        self.flight = flight
        self.storedCoordinate = flight.coordinate
        super.init()
    }

    /// Applies a fresh packet. Returns `true` when the icon or rotation needs
    /// to be refreshed on screen.
    @discardableResult
    func update(with flight: Flight) -> Bool {
        self.flight = flight
        coordinate = flight.coordinate

        let headingChanged = abs((renderedHeading ?? -999) - flight.heading) > 0.5
        let spriteChanged = renderedSpriteKey != flight.spriteKey
        return headingChanged || spriteChanged
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
