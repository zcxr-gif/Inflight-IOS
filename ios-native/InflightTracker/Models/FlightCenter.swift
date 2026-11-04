import CoreLocation
import Foundation

// MARK: - Airlines

/// Which airline an aircraft is flying for, decided the way the web Flight
/// Center decides it, so the two builds never disagree about whose fleet a
/// flight is part of.
///
/// The table is `tracker/airlineLogos.js` ported entry for entry: a livery or
/// airline name, normalised, to the ICAO code the logo sets are keyed by.
/// Matching is longest prefix, so "Delta Air Lines (SkyTeam)" still lands on
/// Delta and "Air Canada Rouge" falls back to Air Canada.
///
/// The livery decides first, then the callsign — a Speedbird callsign on an
/// aeroplane in BA paint is BA either way, and a generic livery flying `BAW11`
/// is still BA because the callsign says so. A callsign is only believed when
/// its three letters are a code the table already knows: `ABC123` is not an
/// airline just because it is shaped like one.
enum AirlineDirectory {

    /// Logo sources, tried in order. The square sets — the wide RadarBox
    /// banners the map's label badges use would be a sliver in a 38-point tile.
    ///
    /// Airline names and logos are trademarks of their owners, shown only to
    /// say whose livery a virtual flight is wearing. Takedowns are honoured
    /// through the backend's blocklist, which `AirlineLogoStore` applies before
    /// any of these is asked for.
    static func logoURLs(for icao: String) -> [URL] {
        let code = icao.uppercased()
        guard code.count == 3, code.allSatisfy({ $0.isLetter || $0.isNumber }) else { return [] }
        return [
            "https://raw.githubusercontent.com/sexym0nk3y/airline-logos/main/logos/\(code).png",
            "https://raw.githubusercontent.com/Jxck-S/airline-logos/main/flightaware_logos/\(code).png",
        ].compactMap(URL.init(string:))
    }

    /// The ICAO code for a livery or airline name, or nil.
    static func icao(forLivery livery: String) -> String? {
        let words = normalise(livery).split(separator: " ")
        guard !words.isEmpty else { return nil }

        // Longest prefix wins, so "air india express" beats "air india".
        var length = min(words.count, 5)
        while length >= 1 {
            let key = words.prefix(length).joined(separator: " ")
            if let icao = byName[key] { return icao }
            length -= 1
        }
        return nil
    }

    /// The airline a flight is flying for, or nil when nothing about it says.
    static func icao(for flight: Flight) -> String? {
        guard !Flight.isRealWorld(id: flight.id) else { return nil }

        let callsign = flight.callsign ?? ""
        let key = "\(flight.liveryName)|\(callsign)"

        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached.icao }

        let resolved = resolve(livery: flight.liveryName, callsign: callsign)

        lock.lock()
        // Bounded as a safety net: the key space is the liveries and
        // callsigns actually on the server, which is a few thousand at most.
        if cache.count > 6_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = Cached(icao: resolved)
        lock.unlock()

        return resolved
    }

    /// The name the table holds for an airline, title-cased. The airline's
    /// own page prefers the livery the feed is actually sending — see
    /// `FlightCenterAirline.name` — and falls back to this.
    static func name(for icao: String) -> String {
        names[icao.uppercased()] ?? icao.uppercased()
    }

    /// Whether the table knows this code at all.
    static func isKnown(_ icao: String) -> Bool {
        names[icao.uppercased()] != nil
    }

    /// Airlines whose name starts with what was typed, or contains it once
    /// enough has been typed for "contains" to mean something, or whose code
    /// it is. Codes, alphabetically by name.
    static func search(_ query: String) -> [String] {
        let needle = normalise(query)
        guard needle.count >= 2 else { return [] }

        var found: Set<String> = []
        let code = needle.uppercased().replacingOccurrences(of: " ", with: "")
        if names[code] != nil { found.insert(code) }

        for (name, icao) in byName {
            if name.hasPrefix(needle) || (needle.count >= 4 && name.contains(needle)) {
                found.insert(icao)
            }
        }

        var sorted: [String] = Array(found)
        sorted.sort { first, second in
            // The exact code first: somebody typing `BAW` wants BA, not the
            // alphabetical neighbour whose name happens to start with a B.
            if first == code { return true }
            if second == code { return false }
            return name(for: first) < name(for: second)
        }
        return sorted
    }

    // MARK: Internals

    private struct Cached { let icao: String? }

    private static var cache: [String: Cached] = [:]
    private static let lock = NSLock()

    private static func resolve(livery: String, callsign: String) -> String? {
        if !livery.isEmpty, let icao = icao(forLivery: livery) { return icao }

        // The callsign's letters, read as a name: "Speedbird" would not be in
        // the table, but a callsign typed as "DELTA" or "JETBLUE" is.
        let letters = String(callsign.prefix { !$0.isNumber })
        if !letters.isEmpty, let icao = icao(forLivery: letters) { return icao }

        // Three letters and a number — `BAW11`, `DAL 123` — and only for a code
        // the table already knows.
        let upper = callsign.uppercased()
        let chars = Array(upper)
        guard chars.count >= 4 else { return nil }
        let prefix = chars.prefix(3)
        guard prefix.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let next = chars[3] == " " && chars.count >= 5 ? chars[4] : chars[3]
        guard next.isNumber else { return nil }
        let code = String(prefix)
        return names[code] != nil ? code : nil
    }

    /// Lowercase, variant suffixes in brackets dropped, punctuation stripped,
    /// spaces collapsed — the key format of the table.
    static func normalise(_ text: String) -> String {
        let unbracketed = text
            .lowercased()
            .replacingOccurrences(of: "\\(.*?\\)", with: " ", options: .regularExpression)

        var kept = String.UnicodeScalarView()
        for scalar in unbracketed.unicodeScalars {
            let value = scalar.value
            let isLetter = value >= 97 && value <= 122
            let isDigit = value >= 48 && value <= 57
            if isLetter || isDigit {
                kept.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                kept.append(" ")
            }
        }

        return String(kept)
            .split(separator: " ")
            .joined(separator: " ")
    }

    /// ICAO → the longest name the table holds for it, title-cased.
    private static let names: [String: String] = {
        var longest: [String: String] = [:]
        for (name, icao) in AirlineDirectory.byName {
            if let current = longest[icao] {
                if current.count > name.count { continue }
                if current.count == name.count, current < name { continue }
            }
            longest[icao] = name
        }

        var titled: [String: String] = [:]
        for (icao, name) in longest {
            titled[icao] = name.capitalized
        }
        return titled
    }()

    /// Livery/airline display name → ICAO. Generated from
    /// `tracker/airlineLogos.js` (`AIRLINE_LIVERY_ICAO`); keep the two in step.
    static let byName: [String: String] = [
        "american airlines": "AAL",
        "american": "AAL",
        "delta air lines": "DAL",
        "delta": "DAL",
        "united airlines": "UAL",
        "united": "UAL",
        "southwest airlines": "SWA",
        "southwest": "SWA",
        "alaska airlines": "ASA",
        "jetblue airways": "JBU",
        "jetblue": "JBU",
        "spirit airlines": "NKS",
        "frontier airlines": "FFT",
        "allegiant air": "AAY",
        "hawaiian airlines": "HAL",
        "sun country airlines": "SCX",
        "breeze airways": "MXY",
        "avelo airlines": "VXP",
        "fedex express": "FDX",
        "fedex": "FDX",
        "ups airlines": "UPS",
        "ups": "UPS",
        "atlas air": "GTI",
        "kalitta air": "CKS",
        "omni air international": "OAE",
        "national airlines": "NCR",
        "air canada": "ACA",
        "westjet": "WJA",
        "air transat": "TSC",
        "porter airlines": "POE",
        "flair airlines": "FLE",
        "cargojet": "CJT",
        "sunwing airlines": "SWG",
        "us airways": "AWE",
        "continental airlines": "COA",
        "northwest airlines": "NWA",
        "virgin america": "VRD",
        "aeromexico": "AMX",
        "volaris": "VOI",
        "vivaaerobus": "VIV",
        "copa airlines": "CMP",
        "avianca": "AVA",
        "latam airlines": "LAN",
        "latam": "LAN",
        "gol linhas aereas": "GLO",
        "gol": "GLO",
        "azul": "AZU",
        "aerolineas argentinas": "ARG",
        "jetsmart": "JAT",
        "sky airline": "SKU",
        "caribbean airlines": "BWA",
        "boliviana de aviacion": "BOV",
        "british airways": "BAW",
        "virgin atlantic": "VIR",
        "easyjet": "EZY",
        "ryanair": "RYR",
        "jet2": "EXS",
        "jet2com": "EXS",
        "tui airways": "TOM",
        "tui": "TOM",
        "wizz air": "WZZ",
        "lufthansa cargo": "GEC",
        "lufthansa": "DLH",
        "eurowings discover": "OCN",
        "discover airlines": "OCN",
        "discover": "OCN",
        "eurowings": "EWG",
        "condor": "CFG",
        "austrian airlines": "AUA",
        "swiss international air lines": "SWR",
        "swiss": "SWR",
        "edelweiss air": "EDW",
        "brussels airlines": "BEL",
        "klm royal dutch airlines": "KLM",
        "klm": "KLM",
        "transavia": "TRA",
        "air france": "AFR",
        "french bee": "FBU",
        "corsair": "CRL",
        "iberia": "IBE",
        "vueling": "VLG",
        "air europa": "AEA",
        "tap air portugal": "TAP",
        "tap portugal": "TAP",
        "scandinavian airlines": "SAS",
        "sas": "SAS",
        "norwegian air shuttle": "NAX",
        "norwegian": "NAX",
        "finnair": "FIN",
        "icelandair": "ICE",
        "play": "FPY",
        "aer lingus": "EIN",
        "ita airways": "ITY",
        "alitalia": "AZA",
        "aegean airlines": "AEE",
        "lot polish airlines": "LOT",
        "turkish airlines": "THY",
        "pegasus airlines": "PGT",
        "aeroflot": "AFL",
        "airbaltic": "BTI",
        "air serbia": "ASL",
        "croatia airlines": "CTN",
        "luxair": "LGL",
        "volotea": "VOE",
        "sky express": "SEH",
        "norse atlantic airways": "NBT",
        "air berlin": "BER",
        "air astana": "KZR",
        "uzbekistan airways": "UZB",
        "azerbaijan airlines": "AHY",
        "emirates": "UAE",
        "etihad airways": "ETD",
        "etihad": "ETD",
        "qatar airways": "QTR",
        "saudia": "SVA",
        "flynas": "KNE",
        "flydubai": "FDB",
        "gulf air": "GFA",
        "oman air": "OMA",
        "kuwait airways": "KAC",
        "el al": "ELY",
        "royal jordanian": "RJA",
        "middle east airlines": "MEA",
        "air arabia": "ABY",
        "jazeera airways": "JZR",
        "salamair": "OMS",
        "egyptair": "MSR",
        "ethiopian airlines": "ETH",
        "kenya airways": "KQA",
        "south african airways": "SAA",
        "royal air maroc": "RAM",
        "air algerie": "DAH",
        "rwandair": "RWD",
        "air mauritius": "MAU",
        "taag angola airlines": "DTA",
        "singapore airlines": "SIA",
        "scoot": "TGW",
        "malaysia airlines": "MAS",
        "airasia": "AXM",
        "garuda indonesia": "GIA",
        "lion air": "LNI",
        "batik air": "BTK",
        "thai airways": "THA",
        "bangkok airways": "BKP",
        "vietjet air": "VJC",
        "vietjet": "VJC",
        "vietnam airlines": "HVN",
        "philippine airlines": "PAL",
        "cebu pacific": "CEB",
        "cathay pacific": "CPA",
        "hong kong express": "HKE",
        "hk express": "HKE",
        "china airlines": "CAL",
        "eva air": "EVA",
        "starlux airlines": "SJX",
        "japan airlines": "JAL",
        "all nippon airways": "ANA",
        "ana": "ANA",
        "zipair tokyo": "TZP",
        "zipair": "TZP",
        "peach aviation": "APJ",
        "peach": "APJ",
        "korean air": "KAL",
        "asiana airlines": "AAR",
        "jeju air": "JJA",
        "air china": "CCA",
        "china eastern airlines": "CES",
        "china eastern": "CES",
        "china southern airlines": "CSN",
        "china southern": "CSN",
        "xiamen air": "CXA",
        "xiamenair": "CXA",
        "hainan airlines": "CHH",
        "air india express": "AXB",
        "air india": "AIC",
        "indigo": "IGO",
        "vistara": "VTI",
        "spicejet": "SEJ",
        "akasa air": "AKJ",
        "srilankan airlines": "ALK",
        "pakistan international airlines": "PIA",
        "qantas": "QFA",
        "jetstar airways": "JST",
        "jetstar": "JST",
        "virgin australia": "VOZ",
        "air new zealand": "ANZ",
        "fiji airways": "FJI",
        "air tahiti nui": "THT",
    ]
}

// MARK: - One airline, live

/// An airline's share of the server right now.
struct FlightCenterAirline: Identifiable, Equatable {

    let icao: String

    /// The livery its aircraft are actually wearing, brackets dropped — the
    /// name the feed uses, which reads better than the table's lower-cased
    /// key. The table's name when none of its aircraft wear one that resolves.
    let name: String

    /// One livery of theirs, for the airline's colour on the badge.
    let livery: String

    let total: Int
    let airborne: Int

    var id: String { icao }
    var onGround: Int { total - airborne }
}

/// Counts liveries per airline, so the name an airline is shown under is the
/// one most of its aircraft are actually painted in.
private struct LiveryVote {

    private var counts: [String: [String: Int]] = [:]

    mutating func note(_ flight: Flight, icao: String) {
        let livery = flight.liveryName
            .replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !livery.isEmpty else { return }
        // Only a livery that is itself this airline: a callsign-matched
        // aeroplane in a generic scheme would otherwise name the fleet
        // "Generic".
        guard AirlineDirectory.icao(forLivery: livery) == icao else { return }
        counts[icao, default: [:]][livery, default: 0] += 1
    }

    func winner(for icao: String) -> String? {
        guard let votes = counts[icao] else { return nil }
        var best: String?
        var bestCount = 0
        for (livery, count) in votes {
            if count > bestCount || (count == bestCount && (best.map { livery < $0 } ?? true)) {
                best = livery
                bestCount = count
            }
        }
        return best
    }
}

// MARK: - The home page

/// What the Flight Center's home page is drawn from: the server in numbers,
/// the busiest fields, the airlines in the air and the busiest routes.
///
/// Counted out of the packet the map is drawn from, like the dock's lists and
/// the stats — nothing here is fetched, so nothing here can disagree with the
/// map in front of it. One pass, rebuilt once per packet.
struct FlightCenterDigest: Equatable {

    struct AirportRow: Identifiable, Equatable {
        let icao: String
        let name: String
        let flag: String
        let inbound: Int
        let outbound: Int
        let isStaffed: Bool

        var id: String { icao }
        var total: Int { inbound + outbound }
    }

    struct RouteRow: Identifiable, Equatable {
        let from: String
        let to: String
        let fromName: String?
        let toName: String?
        let count: Int
        /// Great-circle length between the two filed ends, when both resolve.
        let distanceNM: Double?

        var id: String { "\(from)-\(to)" }
    }

    var total = 0
    var airborne = 0
    var onGround = 0
    var airlineCount = 0
    var staffedFields = 0

    var airports: [AirportRow] = []
    var airlines: [FlightCenterAirline] = []
    var routes: [RouteRow] = []

    static let empty = FlightCenterDigest()

    /// How long each list runs on the home page. A screenful, not a census;
    /// the lists' own pages have the rest.
    static let listLength = 8

    static func from(flights: [Flight], stations: [AtcStation], limit: Int = listLength) -> FlightCenterDigest {
        let store = AirportStore.shared

        var digest = FlightCenterDigest()

        var departures: [String: Int] = [:]
        var arrivals: [String: Int] = [:]
        var routes: [String: Int] = [:]
        var airlineTotals: [String: Int] = [:]
        var airlineAirborne: [String: Int] = [:]
        var airlineLivery: [String: String] = [:]
        var votes = LiveryVote()

        for flight in flights where !Flight.isRealWorld(id: flight.id) {
            digest.total += 1
            let isGround = FlightPhase.from(flight) == .ground
            if isGround { digest.onGround += 1 } else { digest.airborne += 1 }

            if let icao = AirlineDirectory.icao(for: flight) {
                airlineTotals[icao, default: 0] += 1
                if !isGround { airlineAirborne[icao, default: 0] += 1 }
                if airlineLivery[icao] == nil, !flight.liveryName.isEmpty {
                    airlineLivery[icao] = flight.liveryName
                }
                votes.note(flight, icao: icao)
            }

            let from = flight.departureIcao?.uppercased() ?? ""
            let to = flight.arrivalIcao?.uppercased() ?? ""
            if !from.isEmpty { departures[from, default: 0] += 1 }
            if !to.isEmpty { arrivals[to, default: 0] += 1 }
            if !from.isEmpty, !to.isEmpty, from != to {
                routes["\(from)-\(to)", default: 0] += 1
            }
        }

        let staffed = Set(stations.filter { !$0.isCenter }.map { $0.identifier.uppercased() })
        digest.staffedFields = staffed.count

        // Fields: by movements, ties by code so the board does not reshuffle
        // between packets.
        var fieldTotals: [String: Int] = [:]
        for (icao, count) in departures { fieldTotals[icao, default: 0] += count }
        for (icao, count) in arrivals { fieldTotals[icao, default: 0] += count }

        var rankedFields: [(icao: String, total: Int)] = []
        rankedFields.reserveCapacity(fieldTotals.count)
        for (icao, total) in fieldTotals { rankedFields.append((icao: icao, total: total)) }
        rankedFields.sort { first, second in
            if first.total != second.total { return first.total > second.total }
            return first.icao < second.icao
        }

        for field in rankedFields {
            guard digest.airports.count < limit else { break }
            guard let airport = store.airport(field.icao) else { continue }
            digest.airports.append(AirportRow(
                icao: field.icao,
                name: airport.name,
                flag: airport.flag,
                inbound: arrivals[field.icao] ?? 0,
                outbound: departures[field.icao] ?? 0,
                isStaffed: staffed.contains(field.icao)
            ))
        }

        // Airlines: by aircraft on the server, ties by code.
        digest.airlineCount = airlineTotals.count
        var rankedAirlines: [(icao: String, total: Int)] = []
        rankedAirlines.reserveCapacity(airlineTotals.count)
        for (icao, total) in airlineTotals { rankedAirlines.append((icao: icao, total: total)) }
        rankedAirlines.sort { first, second in
            if first.total != second.total { return first.total > second.total }
            return first.icao < second.icao
        }

        for entry in rankedAirlines.prefix(limit) {
            digest.airlines.append(FlightCenterAirline(
                icao: entry.icao,
                name: votes.winner(for: entry.icao) ?? AirlineDirectory.name(for: entry.icao),
                livery: airlineLivery[entry.icao] ?? "",
                total: entry.total,
                airborne: airlineAirborne[entry.icao] ?? 0
            ))
        }

        // Routes: by flights on them, ties by the pair.
        var rankedRoutes: [(key: String, count: Int)] = []
        rankedRoutes.reserveCapacity(routes.count)
        for (key, count) in routes { rankedRoutes.append((key: key, count: count)) }
        rankedRoutes.sort { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.key < second.key
        }

        for entry in rankedRoutes.prefix(limit) {
            let ends = entry.key.split(separator: "-").map(String.init)
            guard ends.count == 2 else { continue }
            digest.routes.append(route(from: ends[0], to: ends[1], count: entry.count, store: store))
        }

        return digest
    }

    static func route(from: String, to: String, count: Int, store: AirportStore = .shared) -> RouteRow {
        let start = store.airport(from)
        let end = store.airport(to)
        var distance: Double?
        if let start, let end {
            distance = FlightProgress.distanceNM(from: start.coordinate, to: end.coordinate)
        }
        return RouteRow(
            from: from,
            to: to,
            fromName: start.map { FlightCenterText.place($0) },
            toName: end.map { FlightCenterText.place($0) },
            count: count,
            distanceNM: distance
        )
    }
}

// MARK: - One airline's page

/// Everything the airline's own page says: its live fleet, how much of it is
/// flying, what it is flying, where, and from where.
struct FlightCenterAirlineReport: Equatable {

    struct Tally: Identifiable, Equatable {
        let name: String
        let detail: String?
        let count: Int
        var id: String { name }
    }

    let airline: FlightCenterAirline
    let flights: [Flight]

    /// Aircraft types in the fleet right now, commonest first.
    let types: [Tally]

    /// Routes being flown, busiest first. Keyed `EGLL-KJFK`.
    let routes: [Tally]

    /// The fields the fleet is flying out of — its hubs, as tonight's traffic
    /// draws them rather than as a timetable claims them.
    let hubs: [Tally]

    var topRoute: Tally? { routes.first }

    static func make(icao: String, flights: [Flight]) -> FlightCenterAirlineReport {
        let code = icao.uppercased()
        let store = AirportStore.shared

        var fleet: [Flight] = []
        var airborne = 0
        var types: [String: Int] = [:]
        var routes: [String: Int] = [:]
        var hubs: [String: Int] = [:]
        var votes = LiveryVote()
        var livery = ""

        for flight in flights where AirlineDirectory.icao(for: flight) == code {
            fleet.append(flight)
            if FlightPhase.from(flight) != .ground { airborne += 1 }
            if !flight.aircraftName.isEmpty { types[flight.aircraftName, default: 0] += 1 }
            if livery.isEmpty { livery = flight.liveryName }
            votes.note(flight, icao: code)

            let from = flight.departureIcao?.uppercased() ?? ""
            let to = flight.arrivalIcao?.uppercased() ?? ""
            if !from.isEmpty { hubs[from, default: 0] += 1 }
            if !from.isEmpty, !to.isEmpty, from != to { routes["\(from)-\(to)", default: 0] += 1 }
        }

        let airline = FlightCenterAirline(
            icao: code,
            name: votes.winner(for: code) ?? AirlineDirectory.name(for: code),
            livery: livery,
            total: fleet.count,
            airborne: airborne
        )

        return FlightCenterAirlineReport(
            airline: airline,
            flights: fleet,
            types: rank(types) { _ in nil },
            routes: rank(routes) { key in
                let ends = key.split(separator: "-").map(String.init)
                guard ends.count == 2 else { return nil }
                guard let start = store.airport(ends[0]), let end = store.airport(ends[1]) else { return nil }
                return Lf("%@ to %@", FlightCenterText.place(start), FlightCenterText.place(end))
            },
            hubs: rank(hubs) { icao in store.airport(icao)?.name }
        )
    }

    static func rank(_ counts: [String: Int], describe: (String) -> String?) -> [Tally] {
        var ranked: [(key: String, count: Int)] = []
        ranked.reserveCapacity(counts.count)
        for (key, count) in counts { ranked.append((key: key, count: count)) }
        ranked.sort { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.key < second.key
        }
        return ranked.prefix(6).map { Tally(name: $0.key, detail: describe($0.key), count: $0.count) }
    }
}

// MARK: - Sorting a list of flights

/// The orders a fleet or a route's list can be read in.
enum FlightCenterSort: String, CaseIterable, Identifiable {
    case callsign
    case altitude
    case speed
    case type
    case remaining

    var id: String { rawValue }

    var label: String {
        switch self {
        case .callsign: return "Callsign"
        case .altitude: return "Altitude"
        case .speed: return "Ground speed"
        case .type: return "Aircraft"
        case .remaining: return "Time to go"
        }
    }

    var symbol: String {
        switch self {
        case .callsign: return "textformat.abc"
        case .altitude: return "arrow.up.and.down"
        case .speed: return "speedometer"
        case .type: return "airplane"
        case .remaining: return "clock"
        }
    }

    /// Sorted, with a stable tie-break on the id so the list does not shuffle
    /// between packets.
    func apply(_ flights: [Flight]) -> [Flight] {
        switch self {
        case .callsign:
            return flights.sorted { first, second in
                let lhs = first.displayName, rhs = second.displayName
                return lhs != rhs ? lhs.localizedStandardCompare(rhs) == .orderedAscending : first.id < second.id
            }
        case .altitude:
            return flights.sorted { first, second in
                first.altitudeFeet != second.altitudeFeet ? first.altitudeFeet > second.altitudeFeet : first.id < second.id
            }
        case .speed:
            return flights.sorted { first, second in
                first.groundSpeedKnots != second.groundSpeedKnots
                    ? first.groundSpeedKnots > second.groundSpeedKnots
                    : first.id < second.id
            }
        case .type:
            return flights.sorted { first, second in
                first.aircraftName != second.aircraftName
                    ? first.aircraftName < second.aircraftName
                    : first.displayName < second.displayName
            }
        case .remaining:
            // Soonest in first; anything with no estimate — on the ground, no
            // plan — after everything that has one.
            let minutes: [String: Double] = Dictionary(
                flights.map { ($0.id, FlightCenterText.minutesToGo($0) ?? .greatestFiniteMagnitude) },
                uniquingKeysWith: { first, _ in first }
            )
            return flights.sorted { first, second in
                let lhs = minutes[first.id] ?? .greatestFiniteMagnitude
                let rhs = minutes[second.id] ?? .greatestFiniteMagnitude
                return lhs != rhs ? lhs < rhs : first.id < second.id
            }
        }
    }
}

// MARK: - Routes

enum FlightCenterRoute {

    /// Flights filed between two fields. Either end may be left open: "out of
    /// EGLL to anywhere", "into KJFK from anywhere".
    static func flights(from: String?, to: String?, in flights: [Flight]) -> [Flight] {
        let origin = from?.uppercased() ?? ""
        let destination = to?.uppercased() ?? ""
        guard !origin.isEmpty || !destination.isEmpty else { return [] }

        return flights.filter { flight in
            guard !Flight.isRealWorld(id: flight.id) else { return false }
            if !origin.isEmpty, flight.departureIcao?.uppercased() != origin { return false }
            if !destination.isEmpty, flight.arrivalIcao?.uppercased() != destination { return false }
            return true
        }
    }

    /// "EGLL KJFK", "EGLL-KJFK", "EGLL to KJFK", "EGLL → KJFK": a typed route,
    /// when both ends are fields the dataset knows.
    static func parse(_ query: String) -> (from: String, to: String)? {
        let separators = CharacterSet(charactersIn: " -–—>→/,")
        let tokens = query
            .uppercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty && $0 != "TO" }
        guard tokens.count == 2 else { return nil }
        let store = AirportStore.shared
        guard let start = store.airport(tokens[0]), let end = store.airport(tokens[1]),
              start.icao != end.icao else { return nil }
        return (start.icao, end.icao)
    }
}

// MARK: - Search

/// What the Flight Center's search field finds: airlines, fields and flights —
/// every pilot, callsign and registration on the server — each its own group,
/// the way the web Flight Center lays its results out.
struct FlightCenterSearchResults {

    var route: (from: String, to: String)?
    var airlines: [FlightCenterAirline] = []
    var airports: [Airport] = []
    var flights: [Flight] = []

    var isEmpty: Bool { route == nil && airlines.isEmpty && airports.isEmpty && flights.isEmpty }

    static func run(_ query: String, flights: [Flight]) -> FlightCenterSearchResults {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var results = FlightCenterSearchResults()
        guard trimmed.count >= MapSearch.minimumLength else { return results }

        results.route = FlightCenterRoute.parse(trimmed)

        // Airlines, with what each has on the server right now, busiest first
        // — an airline with nothing in the air is still listed, at the end, so
        // a search for it is answered rather than ignored.
        let codes = AirlineDirectory.search(trimmed)
        if !codes.isEmpty {
            let wanted = Set(codes.prefix(12))
            var totals: [String: Int] = [:]
            var airborne: [String: Int] = [:]
            var liveries: [String: String] = [:]
            var votes = LiveryVote()
            for flight in flights {
                guard let icao = AirlineDirectory.icao(for: flight), wanted.contains(icao) else { continue }
                totals[icao, default: 0] += 1
                if FlightPhase.from(flight) != .ground { airborne[icao, default: 0] += 1 }
                if liveries[icao] == nil { liveries[icao] = flight.liveryName }
                votes.note(flight, icao: icao)
            }
            var airlines: [FlightCenterAirline] = []
            for icao in codes.prefix(12) {
                airlines.append(FlightCenterAirline(
                    icao: icao,
                    name: votes.winner(for: icao) ?? AirlineDirectory.name(for: icao),
                    livery: liveries[icao] ?? "",
                    total: totals[icao] ?? 0,
                    airborne: airborne[icao] ?? 0
                ))
            }
            airlines.sort { first, second in
                if first.total != second.total { return first.total > second.total }
                return first.name < second.name
            }
            results.airlines = Array(airlines.prefix(5))
        }

        // Fields and flights, ranked the way the map's own search ranks them.
        let live = flights.filter { !Flight.isRealWorld(id: $0.id) }
        for hit in MapSearch.results(for: trimmed, in: live, limit: 60) {
            switch hit {
            case .airport(let airport):
                if results.airports.count < 5 { results.airports.append(airport) }
            case .flight(let flight):
                results.flights.append(flight)
            }
        }

        return results
    }
}

// MARK: - Recently viewed

/// The last few things opened in the Flight Center, on this device.
///
/// Airlines, fields and routes are remembered by code and always reopen.
/// Flights are remembered by id and callsign, and only offered while the
/// aircraft is still on the server — a recent flight that has landed has no
/// window left to open.
@MainActor
final class FlightCenterRecents: ObservableObject {

    static let shared = FlightCenterRecents()

    struct Entry: Codable, Identifiable, Equatable {
        enum Kind: String, Codable {
            case airline
            case airport
            case route
            case flight
        }

        let kind: Kind
        /// ICAO for an airline or field, `EGLL-KJFK` for a route, the flight id
        /// for a flight.
        let key: String
        let title: String
        let detail: String

        var id: String { "\(kind.rawValue)|\(key)" }
    }

    @Published private(set) var entries: [Entry] = []

    private static let defaultsKey = "flightCenter.recents"
    private static let limit = 10

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        }
    }

    func note(_ entry: Entry) {
        var next = entries.filter { $0.id != entry.id }
        // A flight is one leg; keeping the last few of the same callsign would
        // fill the row with one pilot.
        if entry.kind == .flight {
            next.removeAll { $0.kind == .flight && $0.title == entry.title }
        }
        next.insert(entry, at: 0)
        if next.count > Self.limit { next = Array(next.prefix(Self.limit)) }
        entries = next
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

// MARK: - Words

/// The few sentences every page of the Flight Center writes the same way.
enum FlightCenterText {

    /// "Heathrow EGLL", trimmed of the words every airport name carries.
    static func place(_ airport: Airport) -> String {
        "\(shortName(airport)) \(airport.icao)"
    }

    static func shortName(_ airport: Airport) -> String {
        var name = airport.name
        for word in [" International Airport", " Airport", " International", " Intl"] {
            name = name.replacingOccurrences(of: word, with: "")
        }
        return name
    }

    /// "EGLL → KJFK", or whichever end there is.
    static func route(_ flight: Flight) -> String {
        let from = flight.departureIcao?.uppercased() ?? ""
        let to = flight.arrivalIcao?.uppercased() ?? ""
        switch (from.isEmpty, to.isEmpty) {
        case (false, false): return "\(from) → \(to)"
        case (true, false): return Lf("To %@", to)
        case (false, true): return Lf("From %@", from)
        case (true, true): return "No flight plan"
        }
    }

    /// Minutes to the filed destination at the current ground speed, or nil.
    static func minutesToGo(_ flight: Flight) -> Double? {
        guard FlightPhase.from(flight) != .ground,
              flight.groundSpeedKnots > 60,
              let end = AirportStore.shared.airport(flight.arrivalIcao) else { return nil }
        let remaining = FlightProgress.distanceNM(from: flight.coordinate, to: end.coordinate)
        return remaining / flight.groundSpeedKnots * 60
    }

    /// `42 min`, `3h 05m`.
    static func duration(minutes: Double) -> String {
        guard minutes.isFinite, minutes > 0 else { return "—" }
        let whole = max(1, Int(minutes.rounded()))
        guard whole >= 60 else { return Lf("%@ min", "\(whole)") }
        return String(format: "%dh %02dm", whole / 60, whole % 60)
    }

    /// The one figure a row of flights leads with: height in the air, the
    /// phase on the ground.
    static func altitude(_ flight: Flight) -> (value: String, unit: String) {
        guard FlightPhase.from(flight) != .ground else {
            return (flight.groundSpeedKnots >= 5 ? "TAXI" : "GND", "")
        }
        if flight.altitudeFeet >= 18_000 {
            return ("FL\(Int((flight.altitudeFeet / 100).rounded()))", "")
        }
        return (Format.number(flight.altitudeFeet), "FT")
    }

    /// The letters before the flight number — "BAW" out of "BAW11" — or the
    /// first two of whatever the callsign is. The badge for an airline with no
    /// logo.
    static func monogram(_ flight: Flight) -> String {
        let callsign = (flight.callsign ?? flight.username ?? "").uppercased()
        let letters = callsign.prefix { $0.isLetter }
        return String(letters.isEmpty ? callsign.prefix(2) : letters.prefix(3))
    }
}
