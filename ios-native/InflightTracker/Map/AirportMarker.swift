import CoreLocation
import UIKit

/// How a field is written on the map: an airport pin with the ICAO under it,
/// coloured by its flight category, and — close enough in — its wind and
/// temperature on a second line.
///
/// The marker itself is a Mapbox symbol: the pin is an image, the two lines are
/// text, and the collision rules give way to the traffic. What is left here is
/// the wording, which is the one part that is the app's rather than the
/// renderer's.
enum AirportMarker {

    /// The pin's side, in points.
    static let glyph: CGFloat = 20

    /// The sprite key a field is drawn with. A field somebody is working reads
    /// as the larger, blue mark; one without a controller is drawn back to the
    /// size of context.
    static func spriteKey(isControlled: Bool) -> String {
        isControlled ? "AIRPORT_LARGE" : "AIRPORT_SMALL"
    }

    /// Wind and temperature on one short line.
    ///
    /// Written tighter than the window writes the same report — `270/12kt 18°`
    /// rather than `270° @ 12 kt` — because this has the width of an ICAO code
    /// to say it in. Nothing else from the report comes with it: the code above
    /// is already carrying the flight category in its colour, and a marker on a
    /// map is not somewhere to read a METAR.
    static func conditionsLine(for metar: Metar) -> String {
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

/// A runway designator or a taxiway letter, drawn on the field itself.
///
/// The reason the ground layer exists: the basemap draws pavement without
/// naming it and imagery shows concrete without telling you which runway you
/// are looking at.
struct GroundLabel {

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
    }
}
