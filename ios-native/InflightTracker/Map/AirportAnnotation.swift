import MapKit
import UIKit

/// A field on the map.
///
/// Static where a `FlightAnnotation` moves, so there is no KVO on the
/// coordinate here — an airport that changed position would be a bug, not an
/// animation.
final class AirportAnnotation: NSObject, MKAnnotation {

    let coordinate: CLLocationCoordinate2D

    /// Latest reading, so a field that gains a controller updates in place
    /// rather than being removed and re-added.
    var field: MapAirport

    var icao: String { field.airport.icao }

    var title: String? { field.airport.icao }

    var subtitle: String? { field.airport.name }

    init(field: MapAirport) {
        self.field = field
        self.coordinate = field.airport.coordinate
        super.init()
    }
}

/// The marker: the sprite sheet's own airport glyph with the ICAO under it.
///
/// A view with subviews rather than a composed `image`, because the alternative
/// is minting a bitmap per ICAO and holding a few hundred of them for text that
/// UIKit will draw for free.
final class AirportAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "airport"

    private static let width: CGFloat = 66
    private static let glyph: CGFloat = 20

    private let icon = UIImageView()
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false

        // Aircraft are what the map is for; a field is context. Both settings
        // say the same thing to MapKit — when a marker has to give way, this is
        // the one that gives way.
        displayPriority = .defaultLow
        zPriority = .min
        collisionMode = .circle

        frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.glyph + 15)
        // The glyph marks the field, so the *glyph* sits on the coordinate,
        // not the middle of a box that also contains a label.
        centerOffset = CGPoint(x: 0, y: -(15 / 2))

        icon.frame = CGRect(
            x: (Self.width - Self.glyph) / 2,
            y: 0,
            width: Self.glyph,
            height: Self.glyph
        )
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        label.frame = CGRect(x: 0, y: Self.glyph + 1, width: Self.width, height: 12)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 9.5, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        // Legible on imagery, on a light map and on a dark one. The shadow does
        // the work the map's own colour cannot be relied on for.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.85
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: AirportAnnotation) {
        let field = annotation.field

        // The sheet carries two airport glyphs, and the distinction it was
        // drawn for is exactly the one worth making here: a field somebody is
        // working reads as the larger mark.
        icon.image = PlaneSprites.shared.rawIcon(
            forKey: field.isControlled ? "AIRPORT_LARGE" : "AIRPORT_SMALL"
        )

        label.text = field.airport.icao

        // A staffed field is the one you would go looking for, so it is the one
        // that gets full strength; a busy but uncontrolled field is drawn back
        // far enough to read as context.
        label.textColor = .white
        alpha = field.isControlled ? 1 : 0.72
    }
}
