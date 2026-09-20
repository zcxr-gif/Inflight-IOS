import Foundation

/// ICAO type designators, for traffic that reports one.
///
/// ## Why this exists beside `AircraftCatalog`
///
/// The catalog matches Infinite Flight's *names* — "Boeing 737-800", "Airbus
/// A350-900", "Cessna 172" — by scanning them for substrings. Real-world
/// traffic reports none of that. An ADS-B message carries a four-character ICAO
/// type designator, and the two are different languages that happen to overlap
/// in places: "B738" contains "B73" and lands on the right icon by luck, while
/// "B06" is a Bell 206 and contains nothing the catalog knows, so it fell
/// through to the generic airliner.
///
/// That is how the map ended up drawing **helicopters as 737s**, along with
/// every Gulfstream, Citation, Learjet, King Air, Caravan, ATR-600 and E-Jet
/// whose designator the name-matcher had never been written for.
///
/// So designators are resolved from a table rather than by scanning. It is
/// consulted first for real traffic and the catalog remains the fallback, which
/// keeps one useful property: a designator this table has never heard of still
/// gets whatever the substring rules can make of it before defaulting.
///
/// Designators are from the ICAO Doc 8643 list. Where the sprite set has no
/// mark for a type, it maps to the nearest one it does have — every civil
/// helicopter without its own drawing becomes `EUROCOPTER`, which is the
/// generic rotorcraft mark, rather than an aeroplane.
enum AircraftTypeDesignators {

    /// The sprite key for one ICAO designator, or nil if it is not in the
    /// table. Case-insensitive; the caller has usually upper-cased already.
    static func spriteKey(for designator: String) -> String? {
        let code = designator.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { return nil }
        if let exact = table[code] { return exact }
        return prefixed(code)
    }

    // MARK: - Families that are easier as a rule than as rows

    /// The handful where a prefix genuinely means something.
    ///
    /// Kept short on purpose: a prefix rule that is nearly right is worse than
    /// no rule, because it fires on types nobody thought about. These four are
    /// the ones where the leading characters are the manufacturer's own
    /// numbering and the whole range draws the same mark.
    private static func prefixed(_ code: String) -> String? {
        // Airbus Helicopters, in both its naming eras: EC120…EC155 and the
        // H-numbers that replaced them. The Super Pumas are pulled out by name
        // in the table above this, because they have their own mark.
        if code.hasPrefix("EC") || code.hasPrefix("H1") || code.hasPrefix("H2") {
            return "EUROCOPTER"
        }
        // Robinson: R22, R44, R66.
        if code.hasPrefix("R2") || code.hasPrefix("R4") || code.hasPrefix("R6") {
            return "EUROCOPTER"
        }
        // Boeing's own numbering, for a variant this table has not caught up
        // with. B7xx only — B06 is a Bell.
        if code.hasPrefix("B7") { return "B737" }
        return nil
    }

    // MARK: - The table

    private static let table: [String: String] = {
        var map: [String: String] = [:]

        func add(_ keys: [String], _ sprite: String) {
            for key in keys { map[key] = sprite }
        }

        // ------------------------------------------------------------------
        // Helicopters. The reason this file exists: every one of these used to
        // be drawn as an airliner.
        // ------------------------------------------------------------------

        // Sikorsky/Airbus military types with marks of their own.
        add(["H60", "S70", "UH60", "S70A", "S70B", "S92", "H92"], "H60")
        add(["H64", "AH64", "A64"], "H64")
        add(["H47", "CH47", "CH-47"], "CHINOOK")
        add(["LYNX", "G2CA", "AW15"], "LYNX")
        add(["EH10", "A101", "AW01", "MERL"], "EH10")
        add(["PUMA", "AS32", "H215", "H225", "SA30", "AS3B", "EC25"], "PUMA")

        // Everything else that hovers. The sprite set has one civil rotorcraft
        // mark, and a generic helicopter is a far better answer than a 737.
        add(["B06", "B06T", "B47G", "B105", "B222", "B230", "B407", "B412",
             "B429", "B430", "B505", "B525", "BK17", "B427", "B206"], "EUROCOPTER")
        add(["A109", "A119", "A139", "A169", "A189", "AW09", "A129"], "EUROCOPTER")
        add(["S61", "S64", "S76", "S434"], "EUROCOPTER")
        add(["AS50", "AS55", "AS65", "AS35", "SA34", "GAZL", "ALO3"], "EUROCOPTER")
        add(["MD52", "MD60", "EN28", "EXPL", "NH90", "TIGR"], "EUROCOPTER")
        add(["MI8", "MI17", "MI24", "MI26", "MI2", "KA32", "KA26"], "EUROCOPTER")
        add(["R22", "R44", "R66"], "EUROCOPTER")

        // ------------------------------------------------------------------
        // Airliners
        // ------------------------------------------------------------------

        add(["A318", "A319", "A320", "A321", "A19N", "A20N", "A21N",
             "BCS1", "BCS3", "A221", "A223"], "A320")
        add(["A306", "A30B", "A310", "A3ST"], "A300")
        add(["A332", "A333", "A338", "A339", "A337", "A33X"], "A330")
        add(["A342", "A343", "A345", "A346"], "A340")
        add(["A359", "A35K", "A350"], "A350")
        add(["A388", "A380"], "A380")
        add(["A400", "A40J"], "A400")

        add(["B712", "MD11", "MD81", "MD82", "MD83", "MD87", "MD88", "MD90",
             "DC91", "DC93", "DC95"], "MD80")
        add(["B721", "B722"], "B757")
        add(["B732", "B733", "B734", "B735", "B736", "B737", "B738", "B739",
             "B37M", "B38M", "B39M", "B3XM"], "B737")
        add(["B741", "B742", "B743", "B744", "B748", "B74R", "B74S", "BLCF",
             "N744"], "B747")
        add(["B752", "B753"], "B757")
        add(["B762", "B763", "B764"], "B767")
        add(["B772", "B773", "B77L", "B77W", "B778", "B779"], "B777")
        add(["B788", "B789", "B78X"], "B787")
        add(["DC10", "MD1F", "L101"], "A330")

        add(["E135", "E145", "E45X", "E35L", "E170", "E175", "E75L", "E75S",
             "E190", "E195", "E290", "E295"], "E190")
        add(["CRJ1", "CRJ2", "CRJ7", "CRJ9", "CRJX"], "E190")
        add(["RJ1H", "RJ70", "RJ85", "B461", "B462", "B463"], "RJ100")
        add(["F70", "F100", "F28"], "FOKKER100")

        add(["DH8A", "DH8B", "DH8C", "DH8D"], "DASH8")
        add(["AT43", "AT44", "AT45", "AT46"], "AT42")
        add(["AT72", "AT73", "AT75", "AT76"], "AT72")
        add(["SF34", "SB20", "D328", "J328", "SW4", "JS32", "JS41",
             "F406", "BE99", "B190"], "TWINPROP")

        // ------------------------------------------------------------------
        // Business jets and general aviation
        // ------------------------------------------------------------------

        add(["GLF2", "GLF3", "GLF4", "GLF5", "GLF6", "GL5T", "GL7T", "GLEX",
             "G150", "G280"], "PRIVATEJET")
        add(["CL30", "CL35", "CL60", "CL600", "CL604"], "PRIVATEJET")
        add(["LJ31", "LJ35", "LJ40", "LJ45", "LJ55", "LJ60", "LJ70", "LJ75"], "PRIVATEJET")
        add(["C25A", "C25B", "C25C", "C500", "C501", "C510", "C525", "C550",
             "C551", "C560", "C56X", "C650", "C680", "C68A", "C700", "C750"], "PRIVATEJET")
        add(["F2TH", "FA7X", "FA8X", "F900", "FA50", "F2000"], "PRIVATEJET")
        add(["E50P", "E55P", "PC24", "HDJT", "H25B", "H25C", "PRM1",
             "BE40", "EA50"], "PRIVATEJET")

        add(["PC12", "PC6T"], "PC12")
        add(["B350", "BE20", "BE30", "BE9L", "BE10", "C441", "DA42", "DA62",
             "P68", "PA31", "PA34", "PA44", "C310", "C340", "C402", "C404",
             "C421", "AC90", "AEST"], "TWINPROP")
        add(["C152", "C162", "C172", "C177", "C182", "C185", "C206", "C208",
             "C210", "SR20", "SR22", "S22T", "DA40", "DV20", "C82R", "CH7A",
             "TBM7", "TBM8", "TBM9", "TBM"], "SINGLEPROP")
        add(["P28A", "P28B", "P28R", "P28T", "PA18", "PA25", "PA38", "J3",
             "CUB", "CH70", "RV7", "RV8", "RV10", "RV12"], "PA28")

        add(["GLID", "AS21", "AS25", "DG40", "LS8", "SZD5"], "GLIDER")
        add(["BALL", "GASB", "HXA"], "BALLOON")
        add(["SHIP", "UAV", "DRON", "Q4", "RQ4", "MQ9"], "DRONE")

        // ------------------------------------------------------------------
        // Military fixed wing
        // ------------------------------------------------------------------

        add(["C130", "C30J", "L100"], "C130")
        add(["C17", "C5M", "C5"], "C17")
        add(["K35R", "KC135", "R135", "KC10", "KE3", "A3ST2"], "KC35R")
        add(["E3TF", "E3CF", "E3", "E767"], "E3CF")
        add(["F16", "F2", "F18", "FA18", "F15", "F5", "A10", "AV8B"], "F16")
        add(["F22"], "RC-22")
        add(["F35", "F35A", "F35B"], "F35")
        add(["EUFI", "TYPH"], "EUFI")
        add(["TOR", "TORN"], "TOR")
        add(["HAWK", "HAWK T1", "HAWT"], "HAWK")
        add(["B52", "B1", "B2"], "B52")
        add(["U2"], "U2")
        add(["T38", "T6", "T38A"], "T38")
        add(["SPIT"], "SPIT")
        add(["LANC"], "LANC")

        return map
    }()
}
