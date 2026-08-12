import Foundation

/// Maps an Infinite Flight aircraft name onto a key in the shared sprite
/// sheet (`markers.png` + `sprite-uvs.json`).
///
/// The first block is a faithful port of `getAircraftCategory()` in
/// `old/www/flight.js`, so any aircraft the old tracker recognised gets the
/// exact same icon here. The second block only runs for names the old
/// function did not match — where it would have fallen back to `B737` — so
/// it can add coverage without changing existing behaviour.
enum AircraftCatalog {

    static func spriteKey(for aircraftName: String?) -> String {
        guard let raw = aircraftName?.uppercased(), !raw.isEmpty else { return "B737" }

        // ------------------------------------------------------------------
        // Port of getAircraftCategory() — order matters, first match wins.
        // ------------------------------------------------------------------

        // 1. Military / fighters
        if contains(raw, ["F-16", "F-18", "F-22", "F-35", "A-10", "EUFI"]) { return "F16" }
        if contains(raw, ["C-130", "C130", "AC-130"]) { return "C130" }
        if raw.contains("C-17") || raw.contains("C5") { return "C17" }

        // 2. Heavy / jumbo
        if raw.contains("A380") || raw.contains("A388") { return "A380" }
        if raw.contains("747") { return "B747" }

        // 3. Widebody
        if raw.contains("777") || raw.contains("B77") { return "B777" }
        if raw.contains("787") || raw.contains("B78") { return "B787" }
        if raw.contains("A350") || raw.contains("A359") { return "A350" }
        if raw.contains("A330") || raw.contains("A333") || raw.contains("A339") { return "A330" }
        if raw.contains("DC-10") || raw.contains("MD-11") { return "A330" }

        // 4. Narrowbody
        if raw.contains("737") || raw.contains("B73") || raw.contains("B38M") { return "B737" }
        if raw.contains("A320") || raw.contains("A321") || raw.contains("A319")
            || raw.contains("A20N") || raw.contains("A21N") { return "A320" }
        if raw.contains("757") || raw.contains("B75") { return "B757" }

        // 5. Regional / GA / helicopters
        if raw.contains("CRJ") || raw.contains("E175") || raw.contains("E190") { return "E190" }
        if raw.contains("DASH 8") || raw.contains("DH8D") || raw.contains("Q400") { return "DASH8" }
        if contains(raw, ["C172", "SR22", "CESSNA", "SINGLEPROP"]) { return "SINGLEPROP" }
        if contains(raw, ["EUROCOPTER", "H60", "H64", "CHINOOK", "LYNX"]) { return "EUROCOPTER" }

        // ------------------------------------------------------------------
        // Extra coverage. Only reached where the old tracker fell back to the
        // generic B737 icon, so nothing above changes.
        // ------------------------------------------------------------------

        if raw.contains("A340") { return "A340" }
        if raw.contains("A400") { return "A400" }
        if raw.contains("A300") || raw.contains("A310") { return "A300" }
        if raw.contains("767") || raw.contains("B76") { return "B767" }
        if raw.contains("MD-80") || raw.contains("MD80") || raw.contains("MD-90") { return "MD80" }
        if raw.contains("717") || raw.contains("DC-9") { return "MD80" }
        if raw.contains("FOKKER") || raw.contains("F100") { return "FOKKER100" }
        if raw.contains("RJ85") || raw.contains("RJ100") || raw.contains("BAE") { return "RJ100" }
        if raw.contains("ATR 42") || raw.contains("ATR42") || raw.contains("AT42") { return "AT42" }
        if raw.contains("ATR 72") || raw.contains("ATR72") || raw.contains("AT72") { return "AT72" }
        if raw.contains("EMB") || raw.contains("ERJ") || raw.contains("E170")
            || raw.contains("E195") { return "E190" }
        if raw.contains("PC-12") || raw.contains("PC12") { return "PC12" }
        if raw.contains("TBM") || raw.contains("KING AIR") || raw.contains("BARON")
            || raw.contains("TWINPROP") { return "TWINPROP" }
        if raw.contains("CITATION") || raw.contains("LEARJET") || raw.contains("GULFSTREAM")
            || raw.contains("GLOBAL") || raw.contains("CHALLENGER") { return "PRIVATEJET" }
        if raw.contains("SPITFIRE") { return "SPIT" }
        if raw.contains("LANCASTER") { return "LANC" }
        if raw.contains("B52") || raw.contains("B-52") { return "B52" }
        if raw.contains("U-2") { return "U2" }
        if raw.contains("T-38") || raw.contains("T38") { return "T38" }
        if raw.contains("HAWK") { return "HAWK" }
        if raw.contains("TORNADO") { return "TOR" }
        if raw.contains("KC-10") || raw.contains("KC-135") || raw.contains("KC135") { return "KC35R" }
        if raw.contains("E-3") || raw.contains("AWACS") { return "E3CF" }
        if raw.contains("GLIDER") || raw.contains("ASK") { return "GLIDER" }
        if raw.contains("BALLOON") { return "BALLOON" }
        if raw.contains("HELI") || raw.contains("AS350") || raw.contains("BELL")
            || raw.contains("UH-") { return "EUROCOPTER" }
        if raw.contains("CUB") || raw.contains("PA-28") || raw.contains("PA28")
            || raw.contains("DA40") || raw.contains("XCUB") { return "PA28" }

        return "B737"
    }

    private static func contains(_ haystack: String, _ needles: [String]) -> Bool {
        for needle in needles where haystack.contains(needle) { return true }
        return false
    }
}
