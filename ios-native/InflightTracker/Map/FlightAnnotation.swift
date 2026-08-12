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
