import SwiftUI
import UIKit

/// The airline a flight is painted in, as one colour.
///
/// The flight window can take a hint of the operator's own colour — see
/// `FlightInfoTheme.tinted(with:)` and the "Airline colour" switch in Settings.
/// This is where that colour comes from.
///
/// ## Why a table and not something cleverer
///
/// The obvious alternatives are both worse. Deriving a hue from a hash of the
/// name gives every airline *a* colour but never *its* colour, which is the
/// whole point — a Ryanair flight has to come up Ryanair blue or the feature is
/// just noise. Sampling the livery photograph would give the right colour and
/// costs a download, a decode and a guess about which pixel matters, for
/// something that has to be known before the window draws its first frame.
///
/// So: a table, keyed on what the feed actually sends. Infinite Flight names a
/// livery in plain words — "British Airways", "Lufthansa Retro" — and the match
/// is a substring of that, upper-cased, longest key first so a specific livery
/// wins over a general one. An airline that is not in the table gets no colour
/// and the window stays as it is, which is the right failure: a wrong colour
/// would be worse than none.
///
/// Adding one is a line. Colours are the operator's primary brand colour rather
/// than whatever dominates the tail, because that is the one people recognise
/// without being told what they are looking at.
enum AirlineColour {

    /// Brand colours, as they are published. Nothing here is adjusted for
    /// legibility — `FlightInfoTheme.tinted(with:)` does that against the
    /// window it is going into, because the same navy has to survive a black
    /// window and a white one.
    ///
    /// Keys are matched as substrings of the upper-cased livery, so they have
    /// to be long enough not to collide. Two that caught this out and are worth
    /// leaving as a warning: "ANA" is inside "AIR C**ANA**DA", and "SAS" would
    /// need the same care — both are keyed on their full names instead.
    private static let brands: [String: UInt32] = [
        // North America
        "AMERICAN AIRLINES": 0x0078D2,
        "DELTA": 0xE01933,
        "UNITED": 0x002244,
        "SOUTHWEST": 0x304CB2,
        "JETBLUE": 0x003876,
        "ALASKA": 0x01426A,
        "SPIRIT": 0xFFEC00,
        "FRONTIER": 0x007A33,
        "HAWAIIAN": 0x59118E,
        "ALLEGIANT": 0x003087,
        "SUN COUNTRY": 0x00263E,
        "AIR CANADA": 0xF01428,
        "WESTJET": 0x0F5499,
        "PORTER": 0x003A5D,
        "AEROMEXICO": 0x0C2340,
        "VOLARIS": 0x9C1F7E,

        // South America
        "LATAM": 0x1B0088,
        "AVIANCA": 0xD31245,
        "COPA": 0x003DA6,
        "AZUL": 0x0033A0,
        "GOL LINHAS": 0xFF7900,

        // British Isles and Ireland
        "BRITISH AIRWAYS": 0x075AAA,
        "VIRGIN ATLANTIC": 0xE10A0A,
        "AER LINGUS": 0x008A73,
        "RYANAIR": 0x073590,
        "EASYJET": 0xFF6600,

        // Continental Europe
        "LUFTHANSA": 0x05164D,
        "AIR FRANCE": 0x002157,
        "KLM": 0x00A1DE,
        "IBERIA": 0xD40F14,
        "SWISS": 0xE30613,
        "AUSTRIAN": 0xCC0000,
        "BRUSSELS": 0x00A0DF,
        "SCANDINAVIAN": 0x001489,
        "FINNAIR": 0x0B1560,
        "NORWEGIAN": 0xD81939,
        "ICELANDAIR": 0x0C2340,
        "TAP AIR": 0x007749,
        "VUELING": 0xFFCC00,
        "WIZZ": 0xC6007E,
        "EUROWINGS": 0x97002E,
        "CONDOR": 0xFFD200,
        "AEGEAN": 0x003876,
        "ITA AIRWAYS": 0x004B87,
        "ALITALIA": 0x00693E,
        "TURKISH": 0xC70A0C,
        "PEGASUS": 0xFDB913,
        "AEROFLOT": 0x00256B,

        // Middle East and Africa
        "EMIRATES": 0xD71A21,
        "QATAR": 0x5C0632,
        "ETIHAD": 0xBD8B13,
        "SAUDIA": 0x007A53,
        "EGYPTAIR": 0x003E7E,
        "ETHIOPIAN": 0x7C9C3E,
        "KENYA AIRWAYS": 0xC8102E,
        "SOUTH AFRICAN": 0x002F6C,
        "ROYAL AIR MAROC": 0xC8102E,

        // Asia
        "ALL NIPPON": 0x13448F,
        "JAPAN AIRLINES": 0xC8102E,
        "KOREAN AIR": 0x0B2E6F,
        "ASIANA": 0xC8102E,
        "CHINA AIRLINES": 0xCE0E2D,
        "CHINA EASTERN": 0x1A2B6D,
        "CHINA SOUTHERN": 0x009DDC,
        "AIR CHINA": 0xE60012,
        "CATHAY": 0x006564,
        "EVA AIR": 0x00693E,
        "SINGAPORE AIRLINES": 0x002B5C,
        "THAI AIRWAYS": 0x6B2C91,
        "MALAYSIA AIRLINES": 0x00539B,
        "GARUDA": 0x005CA9,
        "VIETNAM AIRLINES": 0x005A9C,
        "PHILIPPINE": 0x00529B,
        "CEBU": 0xFFD100,
        "INDIGO": 0x00246B,
        "AIR INDIA": 0xC8102E,
        "VISTARA": 0x4B286D,

        // Oceania
        "QANTAS": 0xE40000,
        "VIRGIN AUSTRALIA": 0xE10A0A,
        "JETSTAR": 0xFF5115,
        "AIR NEW ZEALAND": 0x00B0B9,
        "FIJI AIRWAYS": 0x00539B,

        // Freight
        "FEDEX": 0x4D148C,
        "UPS": 0x351C15,
        "DHL": 0xFFCC00,
        "ATLAS AIR": 0x003DA5,
        "CARGOLUX": 0x00539B
    ]

    /// Longest key first, so "CHINA SOUTHERN" is decided before "CHINA
    /// AIRLINES" can be tested and a livery naming two airlines resolves to the
    /// more specific one. Built once — the table is fixed at compile time and
    /// this is a sort of a hundred strings.
    private static let ordered: [(key: String, colour: Color)] = brands
        .sorted { $0.key.count > $1.key.count }
        .map { ($0.key, Color(rgb: $0.value)) }

    /// Resolved liveries, because this is asked once per window redraw and the
    /// answer for a given livery never changes. A handful of entries in
    /// practice: one flight is open at a time.
    private static var cache: [String: Color?] = [:]
    private static let lock = NSLock()

    /// The airline's colour for this livery, or nil where the livery names no
    /// airline this knows — a house livery, a private registration, or simply
    /// one that has not been added.
    static func brand(forLivery livery: String?) -> Color? {
        guard let livery = livery?.trimmingCharacters(in: .whitespacesAndNewlines),
              !livery.isEmpty else { return nil }

        lock.lock()
        if let cached = cache[livery] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let haystack = livery.uppercased()
        let found = ordered.first { haystack.contains($0.key) }?.colour

        lock.lock()
        if cache.count < 256 { cache[livery] = found }
        lock.unlock()

        return found
    }
}

extension Color {

    /// A colour from a packed 0xRRGGBB, which is how brand colours are
    /// published and the only form in which a table of them is readable.
    init(rgb: UInt32) {
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
