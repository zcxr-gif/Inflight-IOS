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

    /// One size, everywhere.
    ///
    /// The marker used to draw the sheet's `AIRPORT_LARGE` glyph at a
    /// controlled field and `AIRPORT_SMALL` at an uncontrolled one, meaning to
    /// make a staffed tower the bigger mark. It never did: both sprites are
    /// square (64px and 44px on a 1024×512 sheet) and both were scaled to fit
    /// the same 20pt box, so the only thing the swap changed was which of two
    /// identical-looking glyphs got scaled more. What it did do was make every
    /// airport on the map small.
    ///
    /// So: one glyph, one size, at a size you can actually read — and the
    /// distinction that was wanted carried by `alpha`, which was already doing
    /// it and is the half that worked.
    private static let width: CGFloat = 78
    private static let glyph: CGFloat = 28

    /// The ICAO under it. Fixed too — a label that shrinks to fit is a second
    /// size, and four characters at this weight fit the width above with room
    /// to spare.
    private static let labelHeight: CGFloat = 14
    private static let labelGap: CGFloat = 2

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

        let below = Self.labelGap + Self.labelHeight
        frame = CGRect(x: 0, y: 0, width: Self.width, height: Self.glyph + below)
        // The glyph marks the field, so the *glyph* sits on the coordinate,
        // not the middle of a box that also contains a label.
        centerOffset = CGPoint(x: 0, y: -(below / 2))

        icon.frame = CGRect(
            x: (Self.width - Self.glyph) / 2,
            y: 0,
            width: Self.glyph,
            height: Self.glyph
        )
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        label.frame = CGRect(
            x: 0,
            y: Self.glyph + Self.labelGap,
            width: Self.width,
            height: Self.labelHeight
        )
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 11.5, weight: .bold)
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

        // The same glyph at every field. `AIRPORT_LARGE` is the higher-
        // resolution of the sheet's two, so it is the one that survives being
        // drawn at this size.
        icon.image = PlaneSprites.shared.rawIcon(forKey: "AIRPORT_LARGE")

        label.text = field.airport.icao

        // A staffed field is the one you would go looking for, so it is the one
        // that gets full strength; a busy but uncontrolled field is drawn back
        // far enough to read as context.
        label.textColor = .white
        alpha = field.isControlled ? 1 : 0.72
    }
}
