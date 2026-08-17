import Foundation

/// One runway at a field: both ends, its dimensions and what it is made of.
///
/// Distilled from `old/www/runways.json`, which the web tracker shipped whole —
/// 26 MB of survey rows, most of them for strips our airport dataset has never
/// heard of. The bundled `runways.txt` keeps only the fields the panel shows,
/// only for airports we can actually resolve, and only for runways that are
/// still open: 14,500 rows in under half a megabyte.
struct Runway: Identifiable, Equatable {

    let icao: String

    /// The two designators — `09L` / `27R`. Either can be empty for a strip
    /// surveyed from one end only.
    let lowEnd: String
    let highEnd: String

    let lengthFeet: Int
    let widthFeet: Int

    /// As the survey wrote it: `ASP`, `CON`, `Coral grass`. Read through
    /// `surfaceLabel` rather than shown raw.
    let surface: String

    let isLighted: Bool

    /// True headings for each end, or nil where neither the survey nor the
    /// designator gave one.
    let lowHeading: Int?
    let highHeading: Int?

    var id: String { "\(icao)|\(lowEnd)|\(highEnd)" }

    /// `09L / 27R`, or just the end that exists.
    var name: String {
        switch (lowEnd.isEmpty, highEnd.isEmpty) {
        case (false, false): return "\(lowEnd) / \(highEnd)"
        case (false, true): return lowEnd
        case (true, false): return highEnd
        case (true, true): return "Runway"
        }
    }

    /// `12,091 × 150 ft`, dropping the width when the survey didn't record one.
    var dimensionsLabel: String {
        guard lengthFeet > 0 else { return "Length unrecorded" }
        let length = Format.number(Double(lengthFeet))
        guard widthFeet > 0 else { return "\(length) ft" }
        return "\(length) × \(widthFeet) ft"
    }

    /// The survey's shorthand written out. Codes are the FAA/OurAirports set;
    /// anything unrecognised falls through to whatever was recorded, which for
    /// the smaller fields is already prose — "Coral grass", "Gravel dirt".
    var surfaceLabel: String {
        let code = surface.trimmingCharacters(in: .whitespaces).uppercased()
        guard !code.isEmpty else { return "Surface unknown" }

        switch code {
        case "ASP", "ASPH", "ASPHALT", "ASPH-G", "ASPH-F", "ASPH-P", "ASPH-E": return "Asphalt"
        case "CON", "CONC", "CONCRETE", "CONC-G", "CONC-F", "CONC-E": return "Concrete"
        case "GRS", "GRASS", "TURF", "TURF-G", "TURF-F": return "Grass"
        case "GRE", "GVL", "GRVL", "GRAVEL": return "Gravel"
        case "DIRT", "DRT": return "Dirt"
        case "WATER", "WAT": return "Water"
        case "SNOW", "ICE": return "Snow or ice"
        case "SAND": return "Sand"
        case "MATS", "PSP", "MAT": return "Matting"
        case "COP", "COM": return "Composite"
        default:
            // Already prose. Title-case the first letter and leave the rest,
            // so "gravel dirt" reads as a sentence without mangling "ASPH-G".
            let raw = surface.trimmingCharacters(in: .whitespaces)
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// The two ends as things that can be flown, each with its own heading.
    /// Ends with no heading at all are dropped — they can't be scored against
    /// the wind, which is the only reason this exists.
    var ends: [End] {
        var result: [End] = []
        if !lowEnd.isEmpty, let heading = lowHeading {
            result.append(End(runway: self, designator: lowEnd, headingDegrees: heading))
        }
        if !highEnd.isEmpty, let heading = highHeading {
            result.append(End(runway: self, designator: highEnd, headingDegrees: heading))
        }
        return result
    }

    /// One landing direction.
    struct End: Identifiable, Equatable {
        let runway: Runway
        let designator: String
        let headingDegrees: Int

        var id: String { "\(runway.icao)|\(designator)" }

        /// Knots of wind straight down the runway. Negative is a tailwind,
        /// which is what rules an end out.
        func headwind(fromDegrees direction: Int, speedKnots: Int) -> Double {
            let delta = Double(direction - headingDegrees) * .pi / 180
            return Double(speedKnots) * cos(delta)
        }

        /// Knots of wind across it, unsigned — the number that decides whether
        /// a runway is usable at all.
        func crosswind(fromDegrees direction: Int, speedKnots: Int) -> Double {
            let delta = Double(direction - headingDegrees) * .pi / 180
            return abs(Double(speedKnots) * sin(delta))
        }
    }
}

/// Which end of which runway the wind favours, and by how much.
struct FavouredRunway: Equatable {

    let end: Runway.End
    let headwindKnots: Double
    let crosswindKnots: Double

    /// `12 kt down, 4 kt across`. The two components are what a pilot picks a
    /// runway on, so both are said rather than just the answer.
    var componentsLabel: String {
        let head = Int(headwindKnots.rounded())
        let cross = Int(crosswindKnots.rounded())
        if head <= 0 && cross == 0 { return "Calm" }
        return "\(max(head, 0)) kt down · \(cross) kt across"
    }

    /// The best end for a given wind, or nil when the wind is calm or variable
    /// — neither of which favours anything, and claiming otherwise from a
    /// direction the report declined to give would be inventing it.
    static func best(for runways: [Runway], metar: Metar?) -> FavouredRunway? {
        guard let metar = metar,
              let direction = metar.windDirectionDegrees,
              let speed = metar.windSpeedKnots,
              speed >= 3 else { return nil }

        var best: FavouredRunway?

        for runway in runways {
            for end in runway.ends {
                let headwind = end.headwind(fromDegrees: direction, speedKnots: speed)
                guard best.map({ headwind > $0.headwindKnots }) ?? true else { continue }
                best = FavouredRunway(
                    end: end,
                    headwindKnots: headwind,
                    crosswindKnots: end.crosswind(fromDegrees: direction, speedKnots: speed)
                )
            }
        }

        // A pure tailwind on every end means the field has one runway pointing
        // the wrong way, and naming it as "favoured" would be wrong.
        guard let resolved = best, resolved.headwindKnots > 0 else { return nil }
        return resolved
    }
}

/// Offline runway lookup, loaded the same way the airport dataset is.
///
/// Parsed lazily and once: most sessions never open a field panel, and the file
/// costs nothing until one does.
final class RunwayStore {

    static let shared = RunwayStore()

    private var runways: [String: [Runway]] = [:]
    private var isLoaded = false
    private let lock = NSLock()

    private init() {}

    /// Parses off the main thread, so the first field panel opened doesn't wait
    /// on it. Called alongside the airport dataset at launch.
    func preload() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.loadIfNeeded()
        }
    }

    /// Every open runway at a field, longest first — which is the one anybody
    /// looking at the list wants at the top.
    func runways(at icao: String?) -> [Runway] {
        guard let icao = icao?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              icao.count == 4 else { return [] }

        loadIfNeeded()

        lock.lock()
        defer { lock.unlock() }
        return runways[icao] ?? []
    }

    /// The longest runway at a field, for the one-line summary on the panel's
    /// stat strip.
    func longestRunway(at icao: String?) -> Runway? {
        runways(at: icao).first
    }

    private func loadIfNeeded() {
        lock.lock()
        if isLoaded {
            lock.unlock()
            return
        }
        lock.unlock()

        var parsed: [String: [Runway]] = [:]

        if let url = Bundle.main.url(forResource: "runways", withExtension: "txt"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {

            parsed.reserveCapacity(9_000)

            // ICAO|low|high|length|width|surface|lighted|lowHeading|highHeading
            for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                let fields = line.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count >= 9 else { continue }

                let icao = String(fields[0])

                // -1 is the generator's "no heading anywhere" marker: neither
                // the survey nor the designator gave one.
                func heading(_ field: Substring) -> Int? {
                    guard let value = Int(field), value >= 0 else { return nil }
                    return value
                }

                let runway = Runway(
                    icao: icao,
                    lowEnd: String(fields[1]),
                    highEnd: String(fields[2]),
                    lengthFeet: Int(fields[3]) ?? 0,
                    widthFeet: Int(fields[4]) ?? 0,
                    surface: String(fields[5]),
                    isLighted: fields[6] == "1",
                    lowHeading: heading(fields[7]),
                    highHeading: heading(fields[8])
                )

                parsed[icao, default: []].append(runway)
            }

            for icao in parsed.keys {
                parsed[icao]?.sort { $0.lengthFeet > $1.lengthFeet }
            }
        }

        lock.lock()
        runways = parsed
        isLoaded = true
        lock.unlock()
    }
}
