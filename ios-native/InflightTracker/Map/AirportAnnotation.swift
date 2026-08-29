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

/// The marker: an airport pin with the ICAO under it.
///
/// A view with subviews rather than a composed `image`, because the alternative
/// is minting a bitmap per ICAO and holding a few hundred of them for text that
/// UIKit will draw for free.
final class AirportAnnotationView: MKAnnotationView {

    static let reuseIdentifier = "airport"

    private static let width: CGFloat = 76
    private static let glyph: CGFloat = 20

    /// Height of the code, and of the conditions line under it.
    private static let codeHeight: CGFloat = 12
    private static let conditionsHeight: CGFloat = 11

    /// How far above the coordinate the middle of the glyph sits.
    private static let glyphLift: CGFloat = 15

    private let icon = UIImageView()
    private let label = UILabel()

    /// Wind and temperature, when the map is close enough to have room for
    /// them. Hidden rather than removed: a marker is reused across fields, and
    /// laying the subview out once is cheaper than adding and removing it as
    /// the map zooms.
    private let conditions = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false

        // Aircraft are what the map is for; a field is context. Both settings
        // say the same thing to MapKit — when a marker has to give way, this is
        // the one that gives way.
        displayPriority = .defaultLow
        zPriority = .min
        collisionMode = .circle

        frame = CGRect(
            x: 0,
            y: 0,
            width: Self.width,
            height: Self.glyph + Self.codeHeight + Self.conditionsHeight + 3
        )
        // Where the glyph lands is measured from the coordinate rather than
        // from the middle of the box, which also holds two lines of text —
        // and it lands exactly where it did when the box was one line shorter,
        // so gaining a conditions line moved the text and not the mark.
        //
        // Held constant whether or not that second line is drawn, too: the
        // frame keeps its full height and the label is hidden, so zooming past
        // the threshold changes what a marker says without shifting where it
        // points.
        centerOffset = CGPoint(x: 0, y: frame.height / 2 - Self.glyph / 2 - Self.glyphLift)

        icon.frame = CGRect(
            x: (Self.width - Self.glyph) / 2,
            y: 0,
            width: Self.glyph,
            height: Self.glyph
        )
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        label.frame = CGRect(x: 0, y: Self.glyph + 1, width: Self.width, height: Self.codeHeight)
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

        conditions.frame = CGRect(
            x: 0,
            y: Self.glyph + Self.codeHeight + 2,
            width: Self.width,
            height: Self.conditionsHeight
        )
        conditions.textAlignment = .center
        conditions.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        conditions.adjustsFontSizeToFitWidth = true
        conditions.minimumScaleFactor = 0.75
        conditions.layer.shadowColor = UIColor.black.cgColor
        conditions.layer.shadowOpacity = 0.85
        conditions.layer.shadowRadius = 2
        conditions.layer.shadowOffset = .zero
        conditions.textColor = .white
        addSubview(conditions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Draws one field.
    ///
    /// `showingConditions` is decided by the map rather than here: it is a
    /// question about the camera, and a marker has no idea how far out it is
    /// being looked at from.
    func apply(_ annotation: AirportAnnotation, conditions showingConditions: Bool = false) {
        let field = annotation.field

        // A field somebody is working reads as the larger, blue mark; one
        // without a controller is drawn back to the size of context.
        icon.image = PlaneSprites.shared.rawIcon(
            forKey: field.isControlled ? "AIRPORT_LARGE" : "AIRPORT_SMALL",
            pointSize: Self.glyph
        )

        label.text = field.airport.icao

        // The ICAO carries the field's flight category, in the four colours a
        // pilot already reads them in. Done with the text rather than another
        // dot beside it: the marker is a pin, a code and nothing else, and the
        // code is the part everyone is looking at anyway.
        label.textColor = WeatherService.shared.cached(field.airport.icao)?.flightCategory.colour ?? .white

        // A staffed field is the one you would go looking for, so it is the one
        // that gets full strength; a busy but uncontrolled field is drawn back
        // far enough to read as context.
        alpha = field.isControlled ? 1 : 0.72

        let report = showingConditions ? WeatherService.shared.cached(field.airport.icao) : nil
        conditions.text = report.map(Self.conditionsLine)
        conditions.isHidden = conditions.text?.isEmpty ?? true
    }

    /// Wind and temperature on one short line.
    ///
    /// Written tighter than the window writes the same report — `270/12kt 18°`
    /// rather than `270° @ 12 kt` — because this has the width of an ICAO code
    /// to say it in. Nothing else from the report comes with it: the code above
    /// is already carrying the flight category in its colour, and a marker on a
    /// map is not somewhere to read a METAR.
    private static func conditionsLine(for metar: Metar) -> String {
        let preferences = WeatherPreferences.shared
        var parts: [String] = []

        if let speed = metar.windSpeedKnots {
            if speed == 0 {
                parts.append("CALM")
            } else {
                let direction = metar.windDirectionDegrees
                    .map { String(format: "%03d", $0) } ?? "VRB"
                let converted = Int(
                    preferences.windUnit.convert(fromKnots: Double(speed)).rounded()
                )
                var wind = "\(direction)/\(converted)"
                if let gust = metar.windGustKnots {
                    let gusting = Int(
                        preferences.windUnit.convert(fromKnots: Double(gust)).rounded()
                    )
                    wind += "G\(gusting)"
                }
                parts.append(wind + preferences.windUnit.label)
            }
        }

        if let temperature = metar.temperatureC {
            let value = preferences.temperatureUnit.convert(fromCelsius: temperature)
            parts.append("\(Int(value.rounded()))°")
        }

        return parts.joined(separator: " ")
    }
}

/// A runway designator, drawn on the field itself.
///
/// The reason the ground layer exists: Apple's basemap draws pavement without
/// naming it and imagery shows concrete without telling you which runway you
/// are looking at.
final class GroundLabel: NSObject, MKAnnotation {

    /// Which piece of pavement is being named, which is the whole of how it is
    /// drawn.
    ///
    /// A chart does not letter its taxiways the way it numbers its runways. The
    /// designator is the biggest thing on the field and the taxiway letters are
    /// a quiet alphabet threaded between them — so runways get the weight, and
    /// taxiways get a smaller mark that gives way first when they collide.
    enum Kind {
        case runway
        case taxiway
    }

    let coordinate: CLLocationCoordinate2D
    let text: String
    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, text: String, kind: Kind = .runway) {
        self.coordinate = coordinate
        self.text = text
        self.kind = kind
        super.init()
    }
}

final class GroundLabelView: MKAnnotationView {

    static let reuseIdentifier = "groundLabel"

    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false
        isEnabled = false

        // The pavement is context for the traffic, so it gives way to it — and
        // to the field markers, which are what a tap is looking for. Which of
        // the two ground labels gives way first is set in `apply`.
        zPriority = .min
        collisionMode = .circle

        frame = CGRect(x: 0, y: 0, width: 64, height: 16)
        label.frame = bounds
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        // Legible on a light map, a dark one and imagery alike, which is the
        // same problem the ICAO under a field marker solves the same way.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.9
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        label.textColor = .white
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: GroundLabel) {
        label.text = annotation.text

        switch annotation.kind {
        case .runway:
            label.font = .systemFont(ofSize: 10.5, weight: .heavy)
            label.alpha = 1
            // Still under the traffic, and above the alphabet between them.
            displayPriority = .defaultLow

        case .taxiway:
            // A letter rather than a designator: smaller, lighter, and the
            // first thing dropped when two labels want the same patch of
            // pavement. A field has a handful of runways and a hundred
            // taxiways, so this is what keeps the map from silting up.
            label.font = .systemFont(ofSize: 9, weight: .bold)
            label.alpha = 0.85
            displayPriority = MKFeatureDisplayPriority(rawValue: MKFeatureDisplayPriority.defaultLow.rawValue - 100)
        }
    }
}
