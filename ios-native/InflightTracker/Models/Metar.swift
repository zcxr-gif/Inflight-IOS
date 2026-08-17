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

    /// Height of the lowest broken or overcast layer, in feet above the field.
    /// Nil when nothing is broken or worse, which is the same as an unlimited
    /// ceiling — scattered cloud is not a ceiling however low it sits.
    let ceilingFeet: Int?

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
        var ceiling: Int?

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
                ceiling = lowest(ceiling, layerBase(token, prefixLength: 3))
            }
            else if token.hasPrefix("OVC") {
                coverage = max(coverage, .overcast)
                ceiling = lowest(ceiling, layerBase(token, prefixLength: 3))
            }
            else if token.hasPrefix("VV") {
                // Vertical visibility: the sky is obscured, and the figure is
                // how far up you can see rather than a cloud base. It counts
                // as a ceiling for the flight category all the same.
                coverage = max(coverage, .overcast)
                ceiling = lowest(ceiling, layerBase(token, prefixLength: 2))
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
            coverage: coverage,
            precipitation: precipitation,
            ceilingFeet: ceiling
        )
    }

    /// `BKN012` -> 1,200 ft. The three digits after the coverage code are
    /// hundreds of feet; `///` is the observation declining to say.
    private static func layerBase(_ token: String, prefixLength: Int) -> Int? {
        let digits = token.dropFirst(prefixLength).prefix(3)
        guard digits.count == 3, let hundreds = Int(digits) else { return nil }
        return hundreds * 100
    }

    private static func lowest(_ current: Int?, _ candidate: Int?) -> Int? {
        guard let candidate = candidate else { return current }
        guard let current = current else { return candidate }
        return min(current, candidate)
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

    /// What the field is legally good for, from ceiling and visibility.
    ///
    /// The Capacitor build worked this out by looking for the words `LIFR`,
    /// `IFR` and `MVFR` in the raw report (`old/www/flight.js`), which no METAR
    /// contains — the category is derived, never reported, so every field there
    /// came out VFR in fair weather and in fog alike. This is the real rule.
    enum FlightCategory: String {
        case vfr = "VFR"
        case mvfr = "MVFR"
        case ifr = "IFR"
        case lifr = "LIFR"

        var label: String { rawValue }

        var detail: String {
            switch self {
            case .vfr: return "Ceiling above 3,000 ft, better than 5 miles"
            case .mvfr: return "Ceiling 1,000–3,000 ft, or 3–5 miles"
            case .ifr: return "Ceiling 500–1,000 ft, or 1–3 miles"
            case .lifr: return "Ceiling below 500 ft, or under a mile"
            }
        }

        /// Each category's conventional aviation colour. The only place in the
        /// app that spends colour on meaning: these four are a standard pilots
        /// already read, and rendering them monochrome would throw away the
        /// one thing the strip is for.
        var tint: (red: Double, green: Double, blue: Double) {
            switch self {
            case .vfr: return (0.29, 0.87, 0.50)
            case .mvfr: return (0.38, 0.65, 0.98)
            case .ifr: return (0.97, 0.44, 0.44)
            case .lifr: return (0.75, 0.52, 0.99)
            }
        }
    }

    /// Statute miles of visibility, which is the unit the category rule is
    /// written in whatever the report used.
    private var visibilityStatuteMiles: Double? {
        guard let metres = visibilityMetres else { return nil }
        return Double(metres) / 1609.34
    }

    /// The worse of what the ceiling says and what the visibility says — a
    /// field with ten miles under a 300 ft overcast is LIFR, not VFR.
    var flightCategory: FlightCategory? {
        // Neither figure recorded is no answer rather than a good one. A
        // report with no visibility group and no cloud layers is most often a
        // partial observation, and calling that VFR is a claim about a field
        // nobody has looked at.
        guard ceilingFeet != nil || visibilityMetres != nil else { return nil }

        var category = FlightCategory.vfr

        func worsen(to candidate: FlightCategory) {
            let order: [FlightCategory] = [.vfr, .mvfr, .ifr, .lifr]
            guard let current = order.firstIndex(of: category),
                  let next = order.firstIndex(of: candidate),
                  next > current else { return }
            category = candidate
        }

        if let ceiling = ceilingFeet {
            if ceiling < 500 { worsen(to: .lifr) }
            else if ceiling < 1_000 { worsen(to: .ifr) }
            else if ceiling <= 3_000 { worsen(to: .mvfr) }
        }

        if let miles = visibilityStatuteMiles {
            if miles < 1 { worsen(to: .lifr) }
            else if miles < 3 { worsen(to: .ifr) }
            else if miles <= 5 { worsen(to: .mvfr) }
        }

        return category
    }

    /// `1,200 ft` — how far up the lowest solid layer is, or that there isn't
    /// one.
    var ceilingLabel: String {
        guard let ceiling = ceilingFeet else { return "Unlimited" }
        return "\(Format.number(Double(ceiling))) ft"
    }

    /// How close the air is to saturation. Worth showing beside the
    /// temperature: a small spread is fog on the way, which is the single most
    /// useful thing a dew point tells you.
    var dewPointSpreadC: Double? {
        guard let temperatureC = temperatureC, let dewPointC = dewPointC else { return nil }
        return temperatureC - dewPointC
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
