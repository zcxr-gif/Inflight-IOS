import Foundation
import UIKit

/// A parsed METAR, kept to what the weather pill actually shows.
///
/// The Capacitor build read the same reports (`old/www/weather.js`) but only
/// pulled out wind, temperature and cloud groups by regex; this goes a little
/// further so the icon can tell rain from snow from a clear night.
/// The four categories a field's weather is read in, and the four colours
/// every chart and every other tracker draws them in. Kept to those colours on
/// purpose: this is a convention a pilot already knows, and inventing a nicer
/// palette for it would only mean it had to be learned.
enum FlightCategory: String {
    case vfr = "VFR"
    case mvfr = "MVFR"
    case ifr = "IFR"
    case lifr = "LIFR"

    var colour: UIColor {
        switch self {
        case .vfr: return UIColor(red: 0.30, green: 0.83, blue: 0.45, alpha: 1)
        case .mvfr: return UIColor(red: 0.36, green: 0.68, blue: 1.00, alpha: 1)
        case .ifr: return UIColor(red: 1.00, green: 0.35, blue: 0.32, alpha: 1)
        case .lifr: return UIColor(red: 0.85, green: 0.44, blue: 0.98, alpha: 1)
        }
    }

    /// What it means, for the panel that has room to say so.
    var detail: String {
        switch self {
        case .vfr: return "Ceiling above 3,000 ft and more than 5 miles visibility."
        case .mvfr: return "Ceiling 1,000–3,000 ft, or 3–5 miles visibility."
        case .ifr: return "Ceiling 500–1,000 ft, or 1–3 miles visibility."
        case .lifr: return "Ceiling below 500 ft, or under a mile of visibility."
        }
    }
}

struct Metar: Equatable {

    enum Coverage: Int, Comparable {
        case clear, few, scattered, broken, overcast

        static func < (lhs: Coverage, rhs: Coverage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    enum Precipitation: Equatable {
        case thunderstorm
        case snow
        case rain
        case drizzle
        case fog
    }

    let station: String
    let raw: String
    let temperatureC: Double?
    let dewPointC: Double?

    /// Nil when the wind is variable or calm.
    let windDirectionDegrees: Int?
    let windSpeedKnots: Int?
    let windGustKnots: Int?

    let visibilityMetres: Int?

    /// Lowest broken or overcast layer, in feet. Nil where nothing is broken
    /// or overcast, which is the same as saying there is no ceiling — a few
    /// or scattered layer is not one.
    let ceilingFeet: Int?
    let coverage: Coverage
    let precipitation: Precipitation?

    /// Reads the parts of a report the window shows and ignores the rest —
    /// remarks, runway state, trends.
    static func parse(_ raw: String) -> Metar? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        // The service answers with prose when it has nothing.
        guard text.count > 10, !text.contains("NO METAR"), !text.hasPrefix("<") else { return nil }

        let tokens = text.split(separator: " ").map(String.init)
        guard let station = tokens.first, station.count == 4 else { return nil }

        var temperature: Double?
        var dewPoint: Double?
        var direction: Int?
        var speed: Int?
        var gust: Int?
        var visibility: Int?
        var coverage: Coverage = .clear
        var ceiling: Int?
        var precipitation: Precipitation?

        for token in tokens.dropFirst() {
            if token.hasSuffix("KT"), token.count >= 7 {
                let body = String(token.dropLast(2))
                let headingPart = String(body.prefix(3))
                direction = headingPart == "VRB" ? nil : Int(headingPart)

                let rest = body.dropFirst(3)
                if let gustRange = rest.range(of: "G") {
                    speed = Int(rest[rest.startIndex..<gustRange.lowerBound])
                    gust = Int(rest[gustRange.upperBound...])
                } else {
                    speed = Int(rest)
                }
                continue
            }

            if token == "CAVOK" {
                visibility = 10_000
                continue
            }

            if token.count == 4, let metres = Int(token), token.allSatisfy({ $0.isNumber }) {
                visibility = metres
                continue
            }

            if token.hasSuffix("SM"), let miles = Double(token.dropLast(2).replacingOccurrences(of: "P", with: "")) {
                visibility = Int(miles * 1609)
                continue
            }

            if let group = temperatureGroup(token) {
                temperature = group.0
                dewPoint = group.1
                continue
            }

            if token.hasPrefix("FEW") { coverage = max(coverage, .few) }
            else if token.hasPrefix("SCT") { coverage = max(coverage, .scattered) }
            else if token.hasPrefix("BKN") {
                coverage = max(coverage, .broken)
                ceiling = Metar.lowest(ceiling, in: token, after: 3)
            }
            else if token.hasPrefix("OVC") {
                coverage = max(coverage, .overcast)
                ceiling = Metar.lowest(ceiling, in: token, after: 3)
            }
            else if token.hasPrefix("VV") {
                // Vertical visibility: the sky is obscured, and the figure is
                // how far up you can see. It is a ceiling by any reading.
                coverage = max(coverage, .overcast)
                ceiling = Metar.lowest(ceiling, in: token, after: 2)
            }

            if precipitation == nil {
                precipitation = weather(in: token)
            }
        }

        return Metar(
            station: station,
            raw: text,
            temperatureC: temperature,
            dewPointC: dewPoint,
            windDirectionDegrees: direction,
            windSpeedKnots: speed,
            windGustKnots: gust,
            visibilityMetres: visibility,
            ceilingFeet: ceiling,
            coverage: coverage,
            precipitation: precipitation
        )
    }

    /// The height out of a layer token — `BKN012` is 1,200 ft — keeping
    /// whichever of it and what we already had is lower. A ceiling is the
    /// lowest broken layer, not the last one written down.
    private static func lowest(_ current: Int?, in token: String, after prefix: Int) -> Int? {
        let digits = token.dropFirst(prefix).prefix(3)
        guard digits.count == 3, let hundreds = Int(digits) else { return current }
        let feet = hundreds * 100
        guard let current = current else { return feet }
        return min(current, feet)
    }

    /// What the field is legally good for, by the American thresholds every
    /// tracker draws in the same four colours.
    ///
    /// Worked out from the ceiling and the visibility, worst of the two
    /// deciding — which is how a pilot reads it, and the reason a field with a
    /// clear sky can still be red.
    var flightCategory: FlightCategory {
        let statuteMiles = visibilityMetres.map { Double($0) / 1609.34 }
        let ceiling = ceilingFeet

        // Nothing said about either is not the same as good weather, but a
        // report with no visibility group and no cloud group is CAVOK-shaped
        // and reads as VFR everywhere else.
        if statuteMiles == nil && ceiling == nil { return .vfr }

        if (ceiling.map { $0 < 500 } ?? false) || (statuteMiles.map { $0 < 1 } ?? false) {
            return .lifr
        }
        if (ceiling.map { $0 < 1_000 } ?? false) || (statuteMiles.map { $0 < 3 } ?? false) {
            return .ifr
        }
        if (ceiling.map { $0 <= 3_000 } ?? false) || (statuteMiles.map { $0 <= 5 } ?? false) {
            return .mvfr
        }
        return .vfr
    }

    /// `12/07`, `M03/M05` — temperature over dew point, `M` for below zero.
    private static func temperatureGroup(_ token: String) -> (Double, Double)? {
        let parts = token.split(separator: "/")
        guard parts.count == 2 else { return nil }

        func value(_ part: Substring) -> Double? {
            let negative = part.hasPrefix("M")
            let digits = negative ? part.dropFirst() : part
            guard digits.count == 2, let number = Double(digits) else { return nil }
            return negative ? -number : number
        }

        guard let temperature = value(parts[0]), let dew = value(parts[1]) else { return nil }
        return (temperature, dew)
    }

    private static func weather(in token: String) -> Precipitation? {
        if token.contains("TS") { return .thunderstorm }
        if token.contains("SN") || token.contains("SG") { return .snow }
        if token.contains("RA") { return .rain }
        if token.contains("DZ") { return .drizzle }
        if token.contains("FG") || token.contains("BR") || token.contains("HZ") { return .fog }
        return nil
    }

    // MARK: - Presentation

    /// The temperature in the unit the user reads in. The degree sign carries
    /// no letter: the chip is small, and the scale is a setting the reader
    /// chose rather than something each reading has to restate.
    func temperatureLabel(in unit: TemperatureUnit) -> String {
        guard let temperatureC = temperatureC else { return "—" }
        return "\(Int(unit.convert(fromCelsius: temperatureC).rounded()))°"
    }

    /// Direction, speed, and the gust when there is one — `240° @ 12G20 kt`.
    ///
    /// The unit is written out here, unlike the temperature: a bare number
    /// beside a heading could be any of the three.
    func windLabel(in unit: WindUnit) -> String {
        guard let speed = windSpeedKnots else { return "Calm" }
        if speed == 0 { return "Calm" }

        func convert(_ knots: Int) -> Int { Int(unit.convert(fromKnots: Double(knots)).rounded()) }

        let heading = windDirectionDegrees.map { String(format: "%03d°", $0) } ?? "VRB"
        guard let gust = windGustKnots else {
            return "\(heading) @ \(convert(speed)) \(unit.label)"
        }
        return "\(heading) @ \(convert(speed))G\(convert(gust)) \(unit.label)"
    }

    /// How far you can see, written the way the range itself asks for: metres
    /// while that is a number worth reading, kilometres once it isn't.
    ///
    /// Ten kilometres is the top of the scale a METAR reports rather than a
    /// measurement, so it is written as a floor — the report is saying "at
    /// least this", and rendering it as a flat `10.0 km` claims a precision the
    /// observation never had.
    var visibilityLabel: String? {
        guard let metres = visibilityMetres, metres >= 0 else { return nil }
        if metres >= 9_999 { return "10 km+" }
        if metres >= 1_000 { return String(format: "%.1f km", Double(metres) / 1000) }
        return "\(metres) m"
    }

    var conditionLabel: String {
        if let precipitation = precipitation {
            switch precipitation {
            case .thunderstorm: return "Thunderstorms"
            case .snow: return "Snow"
            case .rain: return "Rain"
            case .drizzle: return "Drizzle"
            case .fog: return "Fog"
            }
        }

        switch coverage {
        case .clear: return "Clear"
        case .few: return "Few clouds"
        case .scattered: return "Scattered"
        case .broken: return "Broken"
        case .overcast: return "Overcast"
        }
    }

    /// SF Symbol for the report, which needs to know whether the sun is up.
    func symbol(isDaylight: Bool) -> String {
        if let precipitation = precipitation {
            switch precipitation {
            case .thunderstorm: return "cloud.bolt.rain.fill"
            case .snow: return "cloud.snow.fill"
            case .rain: return "cloud.rain.fill"
            case .drizzle: return "cloud.drizzle.fill"
            case .fog: return "cloud.fog.fill"
            }
        }

        switch coverage {
        case .clear: return isDaylight ? "sun.max.fill" : "moon.stars.fill"
        case .few, .scattered: return isDaylight ? "cloud.sun.fill" : "cloud.moon.fill"
        case .broken, .overcast: return "cloud.fill"
        }
    }
}
