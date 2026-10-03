import Foundation

/// Which model each source draws for each aircraft, and where it lives.
///
/// Two steps. An aircraft is first named by its ICAO type designator —
/// Infinite Flight's own names ("Boeing 737-800", "Airbus A320neo") are read
/// into one, and real traffic reports one already. Then the collection is
/// asked for that designator, and failing that for the nearest thing it has:
/// a 737 becomes an A320, a 777 an A340. Nothing falls back to
/// a different *kind* of aeroplane: a fighter, a helicopter with no model or a
/// balloon keeps its flat icon rather than turning into an airliner.
enum AircraftModelCatalog {

    struct Entry: Hashable {
        let source: AircraftModelSource
        /// Stable within the source. Part of the cache key and the style id.
        let id: String
        /// Where to fetch it.
        let url: URL
        /// Which way the nose and the roof point in the file as published.
        let forward: GLBNormaliser.Axis
        let up: GLBNormaliser.Axis
        /// The designators this model is drawn for directly.
        let designators: [String]
        let licence: String
        /// Who made it — see `credits`.
        let credit: Credit

        var styleId: String { "ac3d-\(source.key)-\(id)" }
    }

    // MARK: - Lookup

    /// The model to draw for an aircraft, or nil to keep its flat icon.
    static func entry(for flight: Flight, in source: AircraftModelSource) -> Entry? {
        guard source != .off, let designator = designator(for: flight) else { return nil }
        return entry(forDesignator: designator, in: source)
    }

    static func entry(forDesignator designator: String, in source: AircraftModelSource) -> Entry? {
        let table = index[source] ?? [:]
        for candidate in [designator] + (nearest[designator] ?? []) {
            if let entry = table[candidate] { return entry }
        }
        return nil
    }

    private static let index: [AircraftModelSource: [String: Entry]] = {
        var out: [AircraftModelSource: [String: Entry]] = [:]
        for entry in flightAirMap {
            for designator in entry.designators where out[entry.source]?[designator] == nil {
                out[entry.source, default: [:]][designator] = entry
            }
        }
        return out
    }()

    // MARK: - Naming an aircraft

    private static var designatorCache: [String: String?] = [:]
    private static let designatorLock = NSLock()

    /// The ICAO type designator for a flight, or nil when there is no model
    /// that would be honest for it.
    static func designator(for flight: Flight) -> String? {
        let name = flight.aircraftName
        guard !name.isEmpty else { return nil }
        let key = (flight.origin == .realWorld ? "rw:" : "if:") + name

        designatorLock.lock()
        if let cached = designatorCache[key] {
            designatorLock.unlock()
            return cached
        }
        designatorLock.unlock()

        let resolved: String?
        if flight.origin == .realWorld {
            let code = name.uppercased().trimmingCharacters(in: .whitespaces)
            resolved = nearest[code] != nil || modelled.contains(code) ? code : nil
        } else {
            resolved = designator(forInfiniteFlightName: name)
        }

        designatorLock.lock()
        if designatorCache.count < 1024 { designatorCache[key] = resolved }
        designatorLock.unlock()
        return resolved
    }

    /// Every designator some source has a model or a fallback for.
    private static let modelled: Set<String> = Set(flightAirMap.flatMap(\.designators))

    /// Infinite Flight's aircraft names, read into designators. Order matters:
    /// the variant before the family it belongs to.
    static func designator(forInfiniteFlightName name: String) -> String? {
        let raw = name.uppercased()
        let flat = raw.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        func has(_ needles: String...) -> Bool { needles.contains { flat.contains($0) } }

        // Things there is no fair model for: keep the icon.
        if has("F14", "F16", "F18", "F22", "F35", "THUNDERBOLT", "FAIRCHILD", "SPITFIRE", "P38", "EUROFIGHTER",
               "TYPHOON", "B2SPIRIT", "HERCULES", "C130", "GLOBEMASTER", "KC10", "KC135", "SENTRY", "BALLOON",
               "BLIMP") { return nil }

        if has("A2201", "A220100", "CS100") { return "BCS1" }
        if has("A220", "CS300") { return "BCS3" }
        if has("A318") { return "A318" }
        if has("A319NEO") { return "A19N" }
        if has("A319") { return "A319" }
        if has("A320NEO") { return "A20N" }
        if has("A320") { return "A320" }
        if has("A321NEO") { return "A21N" }
        if has("A321") { return "A321" }
        if has("A330200") { return "A332" }
        if has("A330900", "A330NEO") { return "A339" }
        if has("A330") { return "A333" }
        if has("A340600") { return "A346" }
        if has("A340") { return "A343" }
        if has("A3501000") { return "A35K" }
        if has("A350") { return "A359" }
        if has("A380") { return "A388" }
        if has("BELUGA") { return "A3ST" }
        if has("A300") { return "A306" }

        if has("717") { return "B712" }
        if has("737MAX8", "7378MAX", "737MAX") { return "B38M" }
        if has("737600") { return "B736" }
        if has("737700") { return "B737" }
        if has("737900") { return "B739" }
        if has("737") { return "B738" }
        if has("7478") { return "B748" }
        if has("747200", "747100", "747SP") { return "B742" }
        if has("747") { return "B744" }
        if has("757300") { return "B753" }
        if has("757") { return "B752" }
        if has("767200") { return "B762" }
        if has("767400") { return "B764" }
        if has("767") { return "B763" }
        if has("777F", "777200LR") { return "B77L" }
        if has("7779", "777X") { return "B779" }
        if has("777200") { return "B772" }
        if has("777") { return "B77W" }
        if has("7878") { return "B788" }
        if has("78710") { return "B78X" }
        if has("787") { return "B789" }
        if has("707") { return "B703" }

        if has("CRJ1000") { return "CRJX" }
        if has("CRJ900") { return "CRJ9" }
        if has("CRJ700") { return "CRJ7" }
        if has("CRJ") { return "CRJ2" }
        if has("Q400", "DASH8") { return "DH8D" }
        if has("E195E2", "E195E") { return "E295" }
        if has("E190E2") { return "E290" }
        if has("E175") { return "E175" }
        if has("E170") { return "E170" }
        if has("E195") { return "E195" }
        if has("E190") { return "E190" }
        if has("E145", "ERJ145", "ERJ") { return "E145" }
        if has("ATR72") { return "AT76" }
        if has("ATR42") { return "AT45" }
        if has("BAE146", "AVRO", "RJ85", "RJ100") { return "B463" }
        if has("MD11") { return "MD11" }
        if has("DC10") { return "DC10" }
        if has("MD80", "MD82", "MD83", "MD88", "MD90") { return "MD82" }
        if has("TU134") { return "T134" }
        if has("DC3", "C47") { return "DC3" }
        if has("DHC4", "CARIBOU") { return "DHC4" }

        if has("CITATIONX") { return "C750" }
        if has("CITATION", "CJ4") { return "C550" }
        if has("CHALLENGER") { return "CL35" }
        if has("GLOBAL", "GULFSTREAM") { return "GLEX" }
        if has("HONDAJET") { return "HDJT" }
        if has("SF50", "VISIONJET") { return "SF50" }
        if has("TBM") { return "TBM9" }
        if has("PC12") { return "PC12" }
        if has("PC21") { return "PC21" }
        if has("C208", "CARAVAN") { return "C208" }
        if has("C182") { return "C182" }
        if has("C172", "CESSNA172") { return "C172" }
        if has("SR22") { return "SR22" }
        if has("SR20") { return "SR20" }
        if has("XCUB", "CUB", "PA18") { return "PA18" }
        if has("PA28", "WARRIOR", "ARCHER", "CHEROKEE") { return "P28A" }
        if has("PA32", "SARATOGA") { return "PA32" }
        if has("DR400", "ROBIN") { return "DR40" }
        if has("DA42", "TWINSTAR") { return "DA42" }
        if has("DA62") { return "DA62" }
        if has("DA40") { return "DA40" }
        if has("KINGAIR", "BE20", "B350") { return "BE20" }
        if has("BARON", "BE58") { return "BE58" }
        if has("EC135", "H135") { return "EC35" }
        if has("GAZELLE") { return "GAZL" }
        if has("ASK21", "GLIDER") { return "AS21" }

        // An airliner the table has not met yet, rather than nothing: the
        // flat icon's own default is a 737 for the same reason.
        if has("AIRBUS") { return "A320" }
        if has("BOEING") { return "B738" }
        return nil
    }

    // MARK: - Nearest models

    /// For each designator, what to draw when a source has no model of it —
    /// nearest first, and never a different kind of aircraft.
    private static let nearest: [String: [String]] = {
        var out: [String: [String]] = [:]
        func family(_ members: [String], then fallback: [String] = []) {
            for member in members { out[member] = members.filter { $0 != member } + fallback }
        }

        let a320 = ["A320", "A321", "A319", "A318", "A20N", "A21N", "A19N"]
        let b737 = ["B738", "B737", "B739", "B736", "B38M", "B39M", "B37M", "B734", "B733", "B735", "B732"]
        family(a320, then: b737)
        family(["BCS3", "BCS1", "A221", "A223"], then: ["E195", "E190", "A319", "A320"])
        family(b737, then: a320)
        family(["B752", "B753"], then: ["B738", "A321"])
        family(["B763", "B762", "B764"], then: ["B788", "A332", "A333"])
        family(["B788", "B789", "B78X"], then: ["B763", "A359", "A332"])
        family(["B77W", "B773", "B772", "B77L", "B779", "B778"], then: ["A346", "A359", "B744"])
        family(["B744", "B748", "B742", "B741", "B743", "B74S"], then: ["A388", "B77W"])
        family(["A333", "A332", "A339", "A338"], then: ["A359", "B788", "B763"])
        family(["A343", "A346", "A342", "A345"], then: ["A333", "B77W"])
        family(["A359", "A35K"], then: ["B789", "A333"])
        family(["A388"], then: ["B748", "B744"])
        family(["A3ST"], then: ["A306", "A333"])
        family(["A306", "A310", "A30B"], then: ["A333", "B763"])
        family(["MD11", "DC10"], then: ["B77W", "A333"])
        family(["B712", "MD82", "MD83", "MD88", "MD90", "DC93"], then: ["CRJ9", "E190", "A319"])
        family(["T134"], then: ["B712", "CRJ9"])
        family(["B703", "B701"], then: ["B752", "B738"])
        family(["B463", "B462", "B461", "RJ85", "RJ1H", "RJ70"], then: ["E190", "BCS1"])

        family(["E190", "E170", "E175", "E75L", "E195", "E290", "E295"], then: ["CRJ9", "BCS1", "A319"])
        family(["CRJ9", "CRJ7", "CRJ2", "CRJX", "CRJ1"], then: ["E170", "E145"])
        family(["E145", "E135", "E45X"], then: ["CRJ2", "CRJ7"])
        family(["AT76", "AT75", "AT72", "AT73", "AT45", "AT43", "AT44", "AT46"], then: ["DH8D", "DH8C", "SF34", "DHC4"])
        family(["DH8D", "DH8C", "DH8A", "DH8B"], then: ["AT76", "AT45", "SF34"])
        family(["SF34", "D328", "D228"], then: ["DH8C", "AT45"])
        family(["DHC4", "DC3"], then: ["AT45", "DH8C"])

        family(["C550", "C750", "C56X", "C680", "C510", "C525", "C25A", "C25B", "HDJT", "SF50", "E55P", "E50P",
                "LJ45", "PC24", "EA50"], then: ["CL35", "CL60"])
        family(["CL35", "CL30", "CL60", "G280", "F900", "FA7X"], then: ["GLEX", "C550"])
        family(["GLEX", "GLF5", "GLF6", "GL5T", "GL7T"], then: ["CL60", "C550"])

        family(["C172", "C152", "C182", "C208"], then: ["P28A", "SR22", "PA32"])
        family(["P28A", "PA32", "PA22", "SR22", "SR20", "DA40", "DR40", "TBM9", "PC12", "PC21"],
               then: ["C172", "C182", "C208"])
        family(["PA18"], then: ["C172", "PA22"])
        family(["DA42", "DA62", "PA34", "BE58", "C310", "BE20", "B350"], then: ["C208", "PC12"])
        family(["EC35", "GAZL"])
        family(["AS21"])
        return out
    }()

    // MARK: - FlightAirMap

    /// Pinned to the commit the orientations were checked against, so a
    /// change upstream cannot turn an aeroplane round.
    static let flightAirMapCommit = "0906d9ba1bdd906ce45807e45ed706c09912db19"

    /// The `glTF2` exports. Most of the collection has its nose along +Z; the
    /// exceptions were found by drawing every model from above and the side.
    /// Four folders with no licence file (B407, BCS1, BCS3, C421) are left out.
    static let flightAirMap: [Entry] = {
        func model(_ path: String, _ forward: GLBNormaliser.Axis, _ designators: [String]) -> Entry {
            let base = "https://raw.githubusercontent.com/Ysurac/FlightAirMap-3dmodels/\(flightAirMapCommit)/"
            let id = path.replacingOccurrences(of: "/glTF2/", with: "-").replacingOccurrences(of: ".glb", with: "")
            let folder = String(path.prefix { $0 != "/" })
            guard let credit = credits.first(where: { $0.folder == folder }) else {
                preconditionFailure("No credit for FlightAirMap folder \(folder)")
            }
            return Entry(source: .flightAirMap, id: id.lowercased(), url: URL(string: base + path)!, forward: forward,
                         up: .py, designators: designators, licence: credit.licence, credit: credit)
        }
        return [
            model("a320/glTF2/A318.glb", .pz, ["A318"]),
            model("a320/glTF2/A319.glb", .pz, ["A319", "A19N"]),
            model("a320/glTF2/A320.glb", .px, ["A320", "A20N"]),
            model("a320/glTF2/A321.glb", .pz, ["A321", "A21N"]),
            model("a332/glTF2/A332.glb", .pz, ["A332"]),
            model("a333/glTF2/A333.glb", .pz, ["A333", "A338", "A339"]),
            model("a343/glTF2/A343.glb", .pz, ["A343", "A342", "A345", "A346"]),
            model("a350/glTF2/A350.glb", .pz, ["A359", "A35K"]),
            model("a380/glTF2/A380.glb", .pz, ["A388"]),
            model("ask21/glTF2/AS21.glb", .pz, ["AS21"]),
            model("atr42/glTF2/AT45.glb", .pz, ["AT45", "AT43", "AT44", "AT46"]),
            model("atr72/glTF2/AT75.glb", .pz, ["AT76", "AT75", "AT72", "AT73"]),
            model("b707/glTF2/707.glb", .px, ["B703", "B701"]),
            model("b744/glTF2/B747.glb", .pz, ["B744", "B741", "B742", "B743"]),
            model("b748/glTF2/B748.glb", .pz, ["B748"]),
            model("b752/glTF2/757.glb", .pz, ["B752", "B753"]),
            model("b767/glTF2/B763.glb", .pz, ["B763", "B762", "B764"]),
            model("b788/glTF2/B788.glb", .pz, ["B788", "B789", "B78X"]),
            model("c182/glTF2/C182.glb", .pz, ["C182", "C172", "C152"]),
            model("c208/glTF2/C208.glb", .pz, ["C208"]),
            model("c550/glTF2/C550.glb", .pz, ["C550", "C750", "C56X", "C680", "C510", "C525"]),
            model("crj2/glTF2/CRJ2.glb", .pz, ["CRJ2", "CRJ1"]),
            model("crj9/glTF2/CRJ7.glb", .pz, ["CRJ7"]),
            model("crj9/glTF2/CRJ9.glb", .pz, ["CRJ9", "CRJX"]),
            model("dhc4/glTF2/DHC4.glb", .pz, ["DHC4", "DC3"]),
            model("dr40/glTF2/DR40.glb", .pz, ["DR40"]),
            model("e145/glTF2/E145.glb", .pz, ["E145", "E135"]),
            model("e190/glTF2/E170.glb", .pz, ["E170"]),
            model("e190/glTF2/E75L.glb", .pz, ["E175", "E75L"]),
            model("e190/glTF2/E190.glb", .pz, ["E190", "E195", "E290", "E295"]),
            model("ec35/glTF2/EC35.glb", .pz, ["EC35"]),
            model("gazl/glTF2/GAZL.glb", .pz, ["GAZL"]),
            model("md11/glTF2/MD11.glb", .pz, ["MD11", "DC10"]),
            model("pa18/glTF2/PA18.glb", .nz, ["PA18"]),
            model("pa22/glTF2/PA22.glb", .pz, ["PA22"]),
            model("pa28/glTF2/PA28.glb", .pz, ["P28A"]),
            model("pa32/glTF2/PA32.glb", .pz, ["PA32"]),
            model("pc12/glTF2/PC12.glb", .pz, ["PC12", "TBM9"]),
            model("pc21/glTF2/PC21.glb", .pz, ["PC21"]),
            model("sr22/glTF2/SR22.glb", .pz, ["SR22", "SR20", "DA40"]),
            model("t134/glTF2/T134.glb", .pz, ["T134"]),
        ]
    }()

    // MARK: - Credits

    /// Who made each model, as their own work records it.
    ///
    /// FlightAirMap collects the models; nearly every one is a FlightGear
    /// aircraft from FGMEMBERS, linked from its folder at the commit the
    /// conversion was made from. The authors are the ones that aircraft
    /// names in its own `-set.xml` or `AUTHORS`, and the licence is the one
    /// in its FlightAirMap folder.
    struct Credit: Hashable {
        /// The folder in the FlightAirMap repository.
        let folder: String
        let aircraft: String
        let authors: String
        let licence: String
        /// The FlightGear aircraft it was converted from, at FGMEMBERS.
        let origin: String

        var licenceName: String {
            switch licence {
            case "GPL-3.0": return "GNU GPL v3"
            case "GPL-2.0-or-later": return "GNU GPL v2 or later"
            default: return "GNU GPL v2"
            }
        }

        /// The folder, with its licence file and the model's source files.
        var folderURL: URL {
            URL(string: "https://github.com/Ysurac/FlightAirMap-3dmodels/tree/\(flightAirMapCommit)/\(folder)")!
        }

        var originURL: URL {
            URL(string: "https://github.com/FGMEMBERS/\(origin)")!
        }
    }

    static let credits: [Credit] = [
        Credit(folder: "a320", aircraft: "Airbus A318, A319, A320 and A321",
               authors: "Ampere K. Hardraade (3D, FDM), Skyop (systems, instruments)",
               licence: "GPL-2.0", origin: "A320-family"),
        Credit(folder: "a332", aircraft: "Airbus A330-200",
               authors: "Ampere K. Hardraade (3D, FDM), Skyop (systems, instruments)",
               licence: "GPL-2.0", origin: "A330-200"),
        Credit(folder: "a333", aircraft: "Airbus A330-300",
               authors: "Ampere K. Hardraade (3D, FDM), Skyop (systems, instruments)",
               licence: "GPL-2.0", origin: "A330-300"),
        Credit(folder: "a343", aircraft: "Airbus A340-300",
               authors: "Liam Gathercole, Andino",
               licence: "GPL-2.0", origin: "A340-313X"),
        Credit(folder: "a350", aircraft: "Airbus A350 XWB",
               authors: "vezza",
               licence: "GPL-2.0", origin: "A350XWB"),
        Credit(folder: "a380", aircraft: "Airbus A380",
               authors: "N. Muraleedharan, Ampere K., I. Cunningham, F. Dalvi, S. Hamilton, et al.",
               licence: "GPL-2.0", origin: "A380-omega"),
        Credit(folder: "ask21", aircraft: "Schleicher ASK 21",
               authors: "Patrice Poly, D-ECHO",
               licence: "GPL-2.0", origin: "ASK21"),
        Credit(folder: "atr42", aircraft: "ATR 42-500",
               authors: "Narendran Muraleedharan, Malik Daniels (3D), from the ATR 42 by Jon, Eric and Victhor",
               licence: "GPL-2.0", origin: "ATR-42-500"),
        Credit(folder: "atr72", aircraft: "ATR 72-500",
               authors: "Narendran Muraleedharan, Donald Belcham, Dwayne Gable, Oliver (ot-666), camelon",
               licence: "GPL-3.0", origin: "ATR72"),
        Credit(folder: "b707", aircraft: "Boeing 707",
               authors: "Innis Cunningham, Isaias Prestes",
               licence: "GPL-3.0", origin: "707-400"),
        Credit(folder: "b744", aircraft: "Boeing 747-400",
               authors: "Gijs de Rooy, Ivan Ngeow, Markus Bulik",
               licence: "GPL-2.0", origin: "747-400"),
        Credit(folder: "b748", aircraft: "Boeing 747-8",
               authors: "John Williams, Grupo FGBr",
               licence: "GPL-2.0", origin: "747-8i"),
        Credit(folder: "b752", aircraft: "Boeing 757",
               authors: "Juuso Tapaninen, John Williams, from the 757-200 by Liam Gathercole, Skyop and Isaias Prestes",
               licence: "GPL-2.0-or-later", origin: "757-200"),
        Credit(folder: "b767", aircraft: "Boeing 767",
               authors: "Isaias V. Prestes (3D), Peter Brendt, Liam Gathercole",
               licence: "GPL-2.0", origin: "767"),
        Credit(folder: "b788", aircraft: "Boeing 787",
               authors: "Joshua W. (model), Omega95, Redneck, Jentron and the 787-8 team",
               licence: "GPL-2.0", origin: "787-8"),
        Credit(folder: "c182", aircraft: "Cessna 182",
               authors: "HHS81",
               licence: "GPL-2.0", origin: "c182s"),
        Credit(folder: "c208", aircraft: "Cessna 208 Caravan",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "Cessna-208-Caravan"),
        Credit(folder: "c550", aircraft: "Cessna Citation II",
               authors: "Curtis L. Olson, Ludovic Brenta, chris_blues",
               licence: "GPL-2.0-or-later", origin: "Citation"),
        Credit(folder: "crj2", aircraft: "Bombardier CRJ200",
               authors: "Joshua Wilson, Nick I.",
               licence: "GPL-2.0", origin: "CRJ-200"),
        Credit(folder: "crj9", aircraft: "Bombardier CRJ700 and CRJ900",
               authors: "Ryan Miller",
               licence: "GPL-2.0-or-later", origin: "CRJ700-family"),
        Credit(folder: "dhc4", aircraft: "de Havilland Canada DHC-4 Caribou",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "dhc4"),
        Credit(folder: "dr40", aircraft: "Robin DR400",
               authors: "Emmanuel Baranger, Laurent Wromman, Laurent Hayvel, F-JJTH",
               licence: "GPL-2.0", origin: "DR400"),
        Credit(folder: "e145", aircraft: "Embraer ERJ 145",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "Embraer-ERJ-145"),
        Credit(folder: "e190", aircraft: "Embraer E170, E175 and E190",
               authors: "Narendran Muraleedharan",
               licence: "GPL-2.0", origin: "E-jet-family"),
        Credit(folder: "ec35", aircraft: "Eurocopter EC135",
               authors: "Heiko Schulz, Maik Justus, Melchior Franz, Oliver Thurau, et al.",
               licence: "GPL-2.0", origin: "ec135"),
        Credit(folder: "gazl", aircraft: "Aérospatiale Gazelle",
               authors: "3dregenerator, Lester Bofo (3D), StuartC (FlightGear)",
               licence: "GPL-2.0", origin: "Gazelle"),
        Credit(folder: "md11", aircraft: "McDonnell Douglas MD-11",
               authors: "Juuso Tapaninen (3D), John Williams, Joshua Davidson",
               licence: "GPL-2.0-or-later", origin: "MD-11"),
        Credit(folder: "pa18", aircraft: "Piper PA-18 Super Cub",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "Piper-PA-18"),
        Credit(folder: "pa22", aircraft: "Piper PA-22",
               authors: "Robert Leda (3D), Pawel Luchowski",
               licence: "GPL-2.0", origin: "pa22"),
        Credit(folder: "pa28", aircraft: "Piper PA-28",
               authors: "Emmanuel Baranger, 5H1N0B1",
               licence: "GPL-2.0", origin: "Piper-PA-28"),
        Credit(folder: "pa32", aircraft: "Piper PA-32",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "Piper-PA-32"),
        Credit(folder: "pc12", aircraft: "Pilatus PC-12",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "PC-12"),
        Credit(folder: "pc21", aircraft: "Pilatus PC-21",
               authors: "Petar Jedvaj, Ernest Teuscher",
               licence: "GPL-3.0", origin: "PC-21"),
        Credit(folder: "sr22", aircraft: "Cirrus SR22",
               authors: "Emmanuel Baranger",
               licence: "GPL-2.0", origin: "Cirrus-SR22"),
        Credit(folder: "t134", aircraft: "Tupolev Tu-134",
               authors: "Emmanuel Baranger (3D), Artem Kovalchuk, Gary Buckaroo",
               licence: "GPL-2.0", origin: "Tu-134"),
    ]
}
