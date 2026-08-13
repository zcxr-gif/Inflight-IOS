import Foundation

/// A parsed METAR, kept to what the weather pill actually shows.
///
/// The Capacitor build read the same reports (`old/www/weather.js`) but only
/// pulled out wind, temperature and cloud groups by regex; this goes a little
/// further so the icon can tell rain from snow from a clear night.
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
            else if token.hasPrefix("BKN") { coverage = max(coverage, .broken) }
            else if token.hasPrefix("OVC") || token.hasPrefix("VV") { coverage = max(coverage, .overcast) }

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
            coverage: coverage,
            precipitation: precipitation
        )
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

    var temperatureLabel: String {
        guard let temperatureC = temperatureC else { return "—" }
        return "\(Int(temperatureC.rounded()))°"
    }

    var windLabel: String {
        guard let speed = windSpeedKnots else { return "Calm" }
        if speed == 0 { return "Calm" }

        let heading = windDirectionDegrees.map { String(format: "%03d°", $0) } ?? "VRB"
        guard let gust = windGustKnots else { return "\(heading) @ \(speed) kt" }
        return "\(heading) @ \(speed)G\(gust) kt"
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
