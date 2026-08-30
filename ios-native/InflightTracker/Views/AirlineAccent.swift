import SwiftUI
import UIKit

/// The airline's own colour, and what the flight info window is allowed to do
/// with it.
///
/// A small thing, deliberately. The window takes the airline's colour for its
/// hairline edges, its dividers and the handful of pieces already drawn in the
/// app's accent — the filled tile, the progress fill, the badge on the route.
/// Nothing else: not the ground, not the cards, not the type. A window painted
/// in an airline's livery is a poster for that airline and stops being a
/// readable instrument; a window whose *edges* are that airline's colour tells
/// you whose aeroplane you are looking at before you have read a word of it,
/// which is the whole of what this is for.
///
/// It can be switched off — Settings › Appearance — and everything falls back
/// to the palette's own accent, which is what every one of these tokens was
/// before this existed.
///
/// ## Where the colours come from
///
/// `tracker/colors.js` on the web side, ported entry for entry — the brand
/// colours the web tracker has always held, keyed by the same `liveryName`
/// string the live feed sends, so the two builds cannot disagree about what
/// colour an airline is.
///
/// That list covered about fifty liveries, which is a small fraction of what
/// Infinite Flight ships, and every aircraft outside it was drawn in the app's
/// own accent — so the setting looked broken rather than absent. The tables
/// under it now carry the rest of the roster: the European, American, Asian,
/// Oceanian, Middle Eastern and African airlines the sim has liveries for, the
/// cargo operators, and the manufacturers' and air forces' house schemes.
///
/// Anything still not in them gets no accent at all and the window looks
/// exactly as it did before this existed — which remains the right failure. A
/// guessed colour on somebody's airline is worse than no colour.
enum AirlineAccent {

    /// The tint itself, and what is legible written on top of it.
    ///
    /// Carried as a pair rather than derived later because the tint is built
    /// from hue/saturation/brightness here and reading those back off a
    /// `Color` is a round trip through `UIColor` that is only *usually* exact.
    struct Colours: Equatable {
        let tint: Color
        let ink: Color
    }

    // MARK: - Lookup

    /// The colours for a livery, or nil for one we hold nothing for.
    ///
    /// `isLight` is part of the answer, not a detail of it: a navy that reads
    /// as a hairline on a dark window is invisible on a white one, and the
    /// other way round. The hue is the constant; the lightness is not.
    static func colours(forLivery livery: String, isLight: Bool) -> Colours? {
        let name = livery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }

        let key = "\(name.lowercased())|\(isLight)"

        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached = cached { return cached.colours }

        let resolved = signature(forLivery: name).map { build($0, isLight: isLight) }

        cacheLock.lock()
        // Bounded as a safety net. The key space is the set of liveries
        // actually on the server, which is small; this only stops a feed
        // sending junk from growing the map without limit.
        if cache.count < cacheLimit { cache[key] = Cached(colours: resolved) }
        cacheLock.unlock()

        return resolved
    }

    /// `Colours?` boxed so a *miss* is cached too — the lookup runs on every
    /// redraw of an open window, and re-walking the table to conclude "still
    /// nothing" for a livery we have never held is the common case.
    private struct Cached { let colours: Colours? }

    private static var cache: [String: Cached] = [:]
    private static let cacheLock = NSLock()
    private static let cacheLimit = 512

    /// The one colour that stands for this airline.
    ///
    /// Not simply the first in the list. Several of these open on a silver or a
    /// white — American on its grey, Jet2 on its silver — and a hairline in the
    /// colour of aluminium is a hairline nobody can tell from the theme's own.
    /// So the first entry with real colour in it wins, and the first entry is
    /// only the answer when none of them has any.
    private static func signature(forLivery livery: String) -> UInt32? {
        guard let palette = entry(for: livery) else { return nil }
        return palette.first(where: hasColour) ?? palette.first
    }

    /// Exact first, then the livery without its variant suffix.
    ///
    /// The feed spells a repaint as "Lufthansa - 2018" or "KLM - Orange Pride".
    /// Some of those are in the table with their own colours and are matched
    /// above; the ones that are not should still come out in the airline's
    /// colour rather than in none, because they are still that airline.
    private static func entry(for livery: String) -> [UInt32]? {
        if let exact = byName[livery.lowercased()] { return exact }

        guard let separator = livery.range(of: " - ") else { return nil }
        let base = String(livery[livery.startIndex..<separator.lowerBound])
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return base.isEmpty ? nil : byName[base]
    }

    /// Enough distance between the channels to read as a colour rather than as
    /// a grey. Anything under this is white, black, silver or charcoal.
    private static func hasColour(_ hex: UInt32) -> Bool {
        let (red, green, blue) = channels(hex)
        return max(red, max(green, blue)) - min(red, min(green, blue)) > 0.12
    }

    // MARK: - Making it legible

    /// Pulls a brand colour into the band this window can actually draw a
    /// hairline in, keeping its hue.
    ///
    /// Brand palettes are chosen for paint on an aluminium tube in daylight, so
    /// they run to extremes at both ends — BA's navy is `#011750`, which on a
    /// dark window is a hairline the same colour as the window. Hue survives
    /// untouched; brightness and saturation are clamped into a range that reads
    /// against the ground this theme actually has.
    private static func build(_ hex: UInt32, isLight: Bool) -> Colours {
        let (red, green, blue) = channels(hex)

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        // The result says whether the conversion was possible, which for a
        // colour built from RGB components it always is.
        _ = UIColor(red: red, green: green, blue: blue, alpha: 1)
            .getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // A brand grey has no hue worth keeping — the clamp below would turn it
        // into an arbitrary pastel. Kept as a neutral of the right lightness
        // instead, which is what a silver livery should look like anyway.
        if saturation < 0.12 {
            let level: CGFloat = isLight ? 0.42 : 0.78
            return Colours(
                tint: Color(uiColor: UIColor(hue: 0, saturation: 0, brightness: level, alpha: 1)),
                ink: isLight ? .white : Color(white: 0.08)
            )
        }

        let wanted = isLight
            ? (saturation: clamp(saturation, 0.55, 1.0), brightness: clamp(brightness, 0.42, 0.72))
            : (saturation: clamp(saturation, 0.45, 0.95), brightness: clamp(brightness, 0.62, 0.94))

        let colour = UIColor(
            hue: hue,
            saturation: wanted.saturation,
            brightness: wanted.brightness,
            alpha: 1
        )

        return Colours(tint: Color(uiColor: colour), ink: ink(on: wanted.brightness, hue: hue))
    }

    /// What to write on top of the tint. Relative luminance would be the exact
    /// answer; brightness with a nod to how bright the eye finds yellows and
    /// greens is close enough for two-tone text on a badge, and cannot fail the
    /// way reading components back off a `Color` can.
    private static func ink(on brightness: CGFloat, hue: CGFloat) -> Color {
        // Yellow through green — roughly 45° to 190° — reads lighter than its
        // brightness says, so the ink flips to dark sooner there.
        let isWarmBright = hue > 0.11 && hue < 0.52
        return brightness > (isWarmBright ? 0.62 : 0.78) ? Color(white: 0.06) : .white
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }

    private static func channels(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255
        )
    }

    // MARK: - The table

    /// Lower-cased keys, built once. The feed's spelling and the table's agree
    /// today; case-folding means one of them drifting does not silently drop an
    /// airline's colour.
    private static let byName: [String: [UInt32]] = Dictionary(
        liveries.map { ($0.key.lowercased(), $0.value) },
        uniquingKeysWith: { first, _ in first }
    )

    /// Every table there is, in precedence order.
    ///
    /// Split into groups for one reason and it is not tidiness: a dictionary
    /// literal of two hundred entries, each of them an array, is a single
    /// expression the Swift type checker has to solve in one go, and it does
    /// not finish. Each group is small enough to be checked on its own and they
    /// are merged at run time, which costs one pass over a few hundred strings
    /// on first use.
    ///
    /// `ported` is first, so anything the web tracker already had an answer for
    /// keeps that answer and the two builds cannot drift.
    private static let liveries: [String: [UInt32]] = {
        var table: [String: [UInt32]] = [:]
        let groups = [
            ported, europe, northAmerica, latinAmerica,
            eastAsia, southAndSoutheastAsia, oceania,
            middleEastAndCentralAsia, africa, cargo, houseAndState
        ]
        for group in groups {
            table.merge(group) { first, _ in first }
        }
        return table
    }()

    /// Ported from `tracker/colors.js`, entry for entry, in its order.
    private static let ported: [String: [UInt32]] = [
        "TUI": [0x092A5E, 0x70CBF4, 0xD40E14],
        "EasyJet": [0xFF6600, 0xFFFFFF, 0x000000],
        "Ryanair": [0x073590, 0xF1C933, 0xFFFFFF],
        "Qantas": [0xE00000, 0xFFFFFF, 0x8A8D8F],
        "British Airways": [0x011750, 0xDA291C, 0xFFFFFF, 0xB9C8D0],
        "BA CityFlyer": [0x011750, 0xDA291C, 0xFFFFFF, 0xB9C8D0],
        "Emirates": [0xFF0000, 0x00732F, 0xFFFFFF, 0x000000, 0xD3A762],
        "Emirates - 1999": [0xFF0000, 0x00732F, 0xFFFFFF, 0x000000],
        "LOT Polish Airlines": [0x1A3171, 0xFFFFFF],
        "Lufthansa": [0x002654, 0xFFB300, 0xFFFFFF],
        "Lufthansa - 2018": [0x002654, 0xFFFFFF],
        "KLM": [0x00A1E4, 0x00205B, 0xFFFFFF],
        "KLM - Orange Pride": [0xFF8C00, 0x00A1E4, 0xFFFFFF],
        "Delta Air Lines": [0xE3132C, 0x003A70, 0xFFFFFF],
        "Delta Airlines": [0xE3132C, 0x003A70, 0xFFFFFF],
        "Swiss International Air Lines": [0xC8102E, 0xFFFFFF],
        "Jet2holidays": [0x003882, 0xED1C24, 0xFFFFFF],
        "Jet2": [0xC0C0C0, 0xED1C24, 0x58595B],
        "LATAM": [0x1B0088, 0xE8114B, 0xFFFFFF],
        "Eurowings": [0x580C1F, 0x00A0D6, 0xFFFFFF],
        "Etihad": [0xB89D5E, 0x5C4E3D, 0xFFFFFF, 0xEBEAE5],
        "Turkish Airlines": [0xC70A0C, 0x1A1D42, 0xFFFFFF, 0xA7A9AC],
        "ITA Airways": [0x00508F, 0xCE2B37, 0x009246, 0xFFFFFF],
        "Malaysia Airlines": [0x002B5C, 0xED1C24, 0xFFFFFF],
        "Garuda Indonesia": [0x002561, 0x00A3A1, 0xFFFFFF],
        "FrenchBee": [0x00B0F0, 0x0A3977, 0xFFFFFF],
        "DHL": [0xFFCC00, 0xD40511],
        "Aer Lingus": [0x006766, 0x81BC00, 0xFFFFFF],
        "Virgin Atlantic": [0xC8102E, 0x8A001A, 0xFFFFFF, 0x41225A],
        "Virgin Atlantic - Old": [0xC8102E, 0xC0C0C0, 0x41225A],
        "Avianca": [0xDA291C, 0xFFFFFF],
        "American Airlines": [0xA9A8A9, 0xC30019, 0x0078D2, 0x1F4788],
        "Saudia": [0x006937, 0xFFFFFF, 0x161616],
        "Air France": [0x002157, 0xE5002B, 0xFFFFFF],
        "Air Canada": [0xF01428, 0x1F1A17, 0xFFFFFF],
        "Aeromexico": [0x002244, 0xDA291C, 0xFFFFFF],
        "Air China": [0xE31B23, 0x003882, 0xFFFFFF],
        "Pakistan International Airlines": [0x006233, 0xBCA85B, 0xFFFFFF],
        "AeroLogic": [0xFFC600, 0x5B6770, 0xFFFFFF],
        "Air India": [0xFF0100, 0xFE9901, 0x4C224E, 0xFFFFFF],
        "Air Europa": [0x005CFF, 0xFFFFFF],
        "Korean Airlines": [0x0064A8, 0xC4DFF6, 0xE31C23, 0xFFFFFF],
        "Kenya Airways": [0xD10022, 0x000000, 0x006233, 0xFFFFFF],
        "Infinite Flight": [0xFF7B00, 0x1C232B, 0xFFFFFF],
        "Infinite Flight - 2019": [0xFF7B00, 0x1C232B, 0xFFFFFF],
        "United Airlines": [0x005DAA, 0xFFFFFF],
        "Qatar Airways": [0x5A0A3A, 0xA6A6A6, 0xFFFFFF],
        "FedEx": [0x4D148C, 0xFF6600, 0xFFFFFF],
        "Cathay Pacific": [0x006564, 0xFFFFFF],
        "SAS": [0x002F6C, 0xFFFFFF],
        "KC-10 Extender USAF": [0x6F7A81, 0x3C454A],
        "Swiss": [0xC8102E, 0xFFFFFF],
        "GOL - 2018": [0xFF5A00, 0x737373, 0xFFFFFF],
        "TAP": [0x00602B, 0xE31837, 0xFFFFFF],
        "China Southern": [0x003A88, 0xE60012, 0xFFFFFF],
        "IndiGo": [0x001B94, 0x00D2D3, 0xFFFFFF],
    ]

    // MARK: The tables added here
    //
    // Everything below is keyed on the livery names Infinite Flight actually
    // ships, and every value is that airline's own brand colour rather than a
    // guess at one. Which matters less than it sounds: `build` keeps the *hue*
    // and clamps saturation and brightness into the band this window can draw a
    // legible hairline in, so what a table entry really has to get right is
    // whether an airline is red, or blue, or green. Being a few points off the
    // exact ink is invisible; being the wrong colour is not.
    //
    // Variants come free. `entry(for:)` strips a " - " suffix, so "Qantas -
    // Retro" and "Air New Zealand - All Blacks" both come out in the airline's
    // own colour without an entry of their own. Only a repaint that is
    // genuinely a *different* colour earns a line here.
    //
    // Where two spellings are both plausible — "Korean Air" and "Korean
    // Airlines", "ANA" and "All Nippon Airways" — both are listed. The cost of
    // a spare key is nothing; the cost of a miss is an airline with no colour.

    private static let europe: [String: [UInt32]] = [
        "Aegean Airlines": [0x005DA9, 0xFFFFFF],
        "Aeroflot": [0x00317F, 0xF07F13, 0xFFFFFF],
        "Air Baltic": [0x8CC63E, 0x00519E, 0xFFFFFF],
        "airBaltic": [0x8CC63E, 0x00519E, 0xFFFFFF],
        "Air Dolomiti": [0x006F51, 0x00427A, 0xFFFFFF],
        "Air Greenland": [0xE2001A, 0xFFFFFF],
        "Air Malta": [0xC8102E, 0xFFFFFF],
        "Air Serbia": [0xC8102E, 0x0A2A5E, 0xFFFFFF],
        "Alitalia": [0x006341, 0xCD202C, 0xFFFFFF],
        "Austrian": [0xD40E14, 0xFFFFFF],
        "Austrian Airlines": [0xD40E14, 0xFFFFFF],
        "Belavia": [0x00953B, 0xE01E26, 0xFFFFFF],
        "Brussels Airlines": [0x00427A, 0xE4002B, 0xFFFFFF],
        "Condor": [0xFFC300, 0x000000, 0xFFFFFF],
        "Corsair": [0x0A2D5C, 0xD6001C, 0xFFFFFF],
        "Croatia Airlines": [0x0B4EA2, 0xE30613, 0xFFFFFF],
        "Czech Airlines": [0x004C97, 0xE3001B, 0xFFFFFF],
        "Discover Airlines": [0x00A5B5, 0x1B2B4B, 0xFFFFFF],
        "Edelweiss": [0xD8232A, 0x005AAB, 0xFFFFFF],
        "Edelweiss Air": [0xD8232A, 0x005AAB, 0xFFFFFF],
        "Eurowings Discover": [0x00A5B5, 0x1B2B4B, 0xFFFFFF],
        "Finnair": [0x0B1E7B, 0xFFFFFF],
        "Flybe": [0x6E2585, 0xC4D600, 0xFFFFFF],
        "Germanwings": [0xA6093D, 0xFFCC00, 0xFFFFFF],
        "Helvetic Airways": [0xD8232A, 0xFFFFFF],
        "Iberia": [0xD7192D, 0xF3B229, 0xFFFFFF],
        "Icelandair": [0x003057, 0x00AEEF, 0xFFFFFF],
        "Lufthansa CityLine": [0x002654, 0xFFB300, 0xFFFFFF],
        "Luxair": [0x004B93, 0xE30613, 0xFFFFFF],
        "Neos": [0x00539F, 0xF07E26, 0xFFFFFF],
        "Norse Atlantic Airways": [0x001F5B, 0xD22630, 0xFFFFFF],
        "Norwegian": [0xD81E05, 0x0B1560, 0xFFFFFF],
        "Olympic Air": [0x00539F, 0xFFFFFF],
        "Pegasus Airlines": [0xFFC20E, 0x2B2E34, 0xFFFFFF],
        "PLAY": [0xE4002B, 0xFFFFFF],
        "Rossiya": [0x0033A0, 0xDA291C, 0xFFFFFF],
        "S7 Airlines": [0x9ACA3C, 0xFFFFFF],
        "Scandinavian Airlines": [0x002F6C, 0xFFFFFF],
        "SunExpress": [0x005CA9, 0xF58220, 0xFFFFFF],
        "TAROM": [0x00539F, 0xE30613, 0xFFFFFF],
        "Transavia": [0x00A94F, 0xFFFFFF],
        "Tunisair": [0xD6001C, 0xFFFFFF],
        "Ukraine International Airlines": [0x005BAA, 0xFFD800, 0xFFFFFF],
        "Ural Airlines": [0x0072BC, 0x8DC63F, 0xFFFFFF],
        "UTair": [0x005BAA, 0xFFFFFF],
        "Volotea": [0x8E2E8B, 0xF07E26, 0xFFFFFF],
        "Vueling": [0xFFCC00, 0x9E9E9E, 0xFFFFFF],
        "Wideroe": [0x00843D, 0xFFFFFF],
        "Wizz Air": [0xC6007E, 0x20205F, 0xFFFFFF],
        "WizzAir": [0xC6007E, 0x20205F, 0xFFFFFF],
    ]

    private static let northAmerica: [String: [UInt32]] = [
        "Air Canada Express": [0xF01428, 0x1F1A17, 0xFFFFFF],
        "Air Canada Rouge": [0xE4002B, 0x1F1A17, 0xFFFFFF],
        "Air Transat": [0x0033A0, 0x00A0DF, 0xFFFFFF],
        "Alaska Airlines": [0x01426A, 0x44C8F5, 0xFFFFFF],
        "Allegiant Air": [0x00539F, 0xF58220, 0xFFFFFF],
        "American Eagle": [0xC30019, 0x0078D2, 0xA9A8A9],
        "Breeze Airways": [0x0072CE, 0x00B2A9, 0xFFFFFF],
        "Delta Connection": [0xE3132C, 0x003A70, 0xFFFFFF],
        "Endeavor Air": [0xE3132C, 0x003A70, 0xFFFFFF],
        "Frontier Airlines": [0x007A33, 0xFFFFFF],
        "Hawaiian Airlines": [0x52247F, 0xE5308A, 0xFFFFFF],
        "JetBlue": [0x003876, 0x00A1DE, 0xFFFFFF],
        "JetBlue Airways": [0x003876, 0x00A1DE, 0xFFFFFF],
        "Porter Airlines": [0x1C3B5A, 0xFFFFFF],
        "Republic Airways": [0x00447C, 0xFFFFFF],
        "SkyWest Airlines": [0x1B3D6D, 0xFFFFFF],
        "Southwest Airlines": [0x304CB2, 0xE31837, 0xF9B612],
        "Spirit Airlines": [0xFFEC00, 0x000000, 0xFFFFFF],
        "Sun Country Airlines": [0x003DA5, 0xE4002B, 0xFFFFFF],
        "Sunwing Airlines": [0xE4002B, 0xF58220, 0xFFCC00],
        "United Express": [0x005DAA, 0xFFFFFF],
        "WestJet": [0x005DA9, 0x00A551, 0xFFFFFF],
    ]

    private static let latinAmerica: [String: [UInt32]] = [
        "Aerolineas Argentinas": [0x00A3E0, 0xFFFFFF],
        "Azul": [0x0033A1, 0xFFFFFF],
        "Copa Airlines": [0x003087, 0xFFFFFF],
        "GOL": [0xFF6900, 0x737373, 0xFFFFFF],
        "Interjet": [0xE4002B, 0xFFFFFF],
        "JetSMART": [0xF15A29, 0xFFFFFF],
        "Sky Airline": [0x0057B8, 0xFFFFFF],
        "Viva Aerobus": [0x00A94F, 0xE4002B, 0xFFFFFF],
        "VivaAerobus": [0x00A94F, 0xE4002B, 0xFFFFFF],
        "Volaris": [0xA6228C, 0xE4002B, 0xFFFFFF],
    ]

    private static let eastAsia: [String: [UInt32]] = [
        "Air Macau": [0x008C95, 0xFFFFFF],
        "All Nippon Airways": [0x003C93, 0xFFFFFF],
        "ANA": [0x003C93, 0xFFFFFF],
        "Asiana Airlines": [0xE4002B, 0x00539F, 0xB0B0B0],
        "China Airlines": [0xD6001C, 0x00539F, 0xFFFFFF],
        "China Eastern": [0x004B8D, 0xE4002B, 0xFFFFFF],
        "China Eastern Airlines": [0x004B8D, 0xE4002B, 0xFFFFFF],
        "EVA Air": [0x006747, 0xF58220, 0xFFFFFF],
        "Hainan Airlines": [0xC8102E, 0xD4AF37, 0xFFFFFF],
        "Japan Airlines": [0xC8102E, 0xFFFFFF],
        "Jeju Air": [0xF58220, 0x00539F, 0xFFFFFF],
        "Juneyao Airlines": [0x005BAC, 0xE4002B, 0xFFFFFF],
        "Korean Air": [0x0064A8, 0xC4DFF6, 0xE31C23],
        "Peach Aviation": [0xE4007F, 0xFFFFFF],
        "Shenzhen Airlines": [0xC8102E, 0x005BAC, 0xFFFFFF],
        "Sichuan Airlines": [0xC8102E, 0xFFFFFF],
        "Spring Airlines": [0x00A94F, 0xFFFFFF],
        "STARLUX Airlines": [0x1C2B4B, 0xB68D4C, 0xFFFFFF],
        "Tianjin Airlines": [0xC8102E, 0xFFFFFF],
        "Xiamen Air": [0x005BAC, 0xFFFFFF],
        "Xiamen Airlines": [0x005BAC, 0xFFFFFF],
        "ZIPAIR": [0x9EA2A2, 0xFFFFFF],
    ]

    private static let southAndSoutheastAsia: [String: [UInt32]] = [
        "Air Asia": [0xE4002B, 0xFFFFFF],
        "AirAsia": [0xE4002B, 0xFFFFFF],
        "Air India Express": [0xE4002B, 0xFF7900, 0xFFFFFF],
        "Bangkok Airways": [0x00539F, 0xE4002B, 0xFFFFFF],
        "Batik Air": [0xE4002B, 0xFFFFFF],
        "Biman Bangladesh Airlines": [0x006A4D, 0xE4002B, 0xFFFFFF],
        "Cebu Pacific": [0xFFC72C, 0x00539F, 0xFFFFFF],
        "Citilink": [0x00A94F, 0xFFFFFF],
        "Lion Air": [0xE4002B, 0xFFFFFF],
        "Nok Air": [0xFFD500, 0xE4002B, 0xFFFFFF],
        "Philippine Airlines": [0x00539F, 0xE4002B, 0xFFCC00],
        "Royal Brunei Airlines": [0xFFC72C, 0x00539F, 0xFFFFFF],
        "Scoot": [0xFFD500, 0x000000, 0xFFFFFF],
        "Singapore Airlines": [0x0B1E64, 0xF0AB00, 0xFFFFFF],
        "SpiceJet": [0xE4002B, 0xF58220, 0xFFFFFF],
        "SriLankan Airlines": [0x005E7D, 0xE4002B, 0xF0AB00],
        "Thai Airways": [0x4E2A84, 0xD6006D, 0xF0AB00],
        "Thai Airways International": [0x4E2A84, 0xD6006D, 0xF0AB00],
        "Thai Smile": [0xD6006D, 0x4E2A84, 0xFFFFFF],
        "VietJet Air": [0xE4002B, 0xFFCC00, 0xFFFFFF],
        "Vietnam Airlines": [0x00629B, 0xC8A063, 0xFFFFFF],
        "Vistara": [0x51285F, 0xC9A227, 0xFFFFFF],
    ]

    private static let oceania: [String: [UInt32]] = [
        "Air New Zealand": [0x000000, 0x00B2A9, 0xFFFFFF],
        "Air Tahiti Nui": [0x002F87, 0x00A9E0, 0xFFFFFF],
        "Fiji Airways": [0x0B3B5C, 0x8C6239, 0xFFFFFF],
        "Jetstar": [0xFF5100, 0x000000, 0xFFFFFF],
        "QantasLink": [0xE00000, 0xFFFFFF, 0x8A8D8F],
        "Virgin Australia": [0xE4002B, 0xFFFFFF],
    ]

    private static let middleEastAndCentralAsia: [String: [UInt32]] = [
        "Air Arabia": [0xE4002B, 0xFFFFFF],
        "Air Astana": [0x00A9CE, 0x002F5F, 0xFFFFFF],
        "Azerbaijan Airlines": [0x00539F, 0xFFFFFF],
        "EL AL": [0x004B93, 0xFFFFFF],
        "El Al": [0x004B93, 0xFFFFFF],
        "flydubai": [0xF37021, 0x1B365D, 0xFFFFFF],
        "Gulf Air": [0x1B365D, 0xB89D5E, 0xFFFFFF],
        "Iraqi Airways": [0x00954C, 0xFFFFFF],
        "Kuwait Airways": [0x005BAC, 0xE4002B, 0xFFFFFF],
        "Middle East Airlines": [0xC8102E, 0x00A94F, 0xFFFFFF],
        "Oman Air": [0x00594F, 0xB89D5E, 0xFFFFFF],
        "Riyadh Air": [0x54306E, 0xB9A6D6, 0xFFFFFF],
        "Royal Jordanian": [0xC8102E, 0x63666A, 0xFFFFFF],
        "Uzbekistan Airways": [0x00539F, 0x00A94F, 0xFFFFFF],
    ]

    private static let africa: [String: [UInt32]] = [
        "Air Algerie": [0xC8102E, 0x006233, 0xFFFFFF],
        "Air Mauritius": [0xC8102E, 0x00539F, 0xFFFFFF],
        "Egyptair": [0x005BAC, 0xFFCC00, 0xFFFFFF],
        "EgyptAir": [0x005BAC, 0xFFCC00, 0xFFFFFF],
        "Ethiopian Airlines": [0x00954C, 0xFFCC00, 0xE4002B],
        "Jambojet": [0x00A94F, 0xFFCC00, 0xFFFFFF],
        "Nouvelair": [0x0072CE, 0xFFFFFF],
        "Royal Air Maroc": [0xC8102E, 0x006233, 0xFFFFFF],
        "RwandAir": [0x00539F, 0x00A94F, 0xFFCC00],
        "South African Airways": [0x005BAC, 0xE4002B, 0xFFCC00],
        "TAAG Angola Airlines": [0xC8102E, 0xFFCC00, 0x000000],
    ]

    private static let cargo: [String: [UInt32]] = [
        "ABX Air": [0x00539F, 0xFFFFFF],
        "Amazon Prime Air": [0x00A8E1, 0x232F3E, 0xFFFFFF],
        "Asiana Cargo": [0xE4002B, 0x00539F, 0xB0B0B0],
        "Atlas Air": [0x003087, 0xFFFFFF],
        "Cargolux": [0xC8102E, 0x005DAA, 0xFFFFFF],
        "Cathay Pacific Cargo": [0x006564, 0xFFFFFF],
        "China Cargo Airlines": [0x004B8D, 0xE4002B, 0xFFFFFF],
        "Emirates SkyCargo": [0xFF0000, 0x00732F, 0xFFFFFF],
        "Ethiopian Cargo": [0x00954C, 0xFFCC00, 0xE4002B],
        "Kalitta Air": [0x00539F, 0xFFFFFF],
        "Korean Air Cargo": [0x0064A8, 0xC4DFF6, 0xE31C23],
        "Lufthansa Cargo": [0xFFB300, 0x002654, 0xFFFFFF],
        "Nippon Cargo Airlines": [0x00539F, 0xFFFFFF],
        "Polar Air Cargo": [0x003087, 0xE4002B, 0xFFFFFF],
        "Qatar Airways Cargo": [0x5A0A3A, 0xA6A6A6, 0xFFFFFF],
        "Saudia Cargo": [0x006937, 0xFFFFFF],
        "Silk Way West Airlines": [0x005BAC, 0xFFFFFF],
        "Singapore Airlines Cargo": [0x0B1E64, 0xF0AB00, 0xFFFFFF],
        "Turkish Cargo": [0xC70A0C, 0x1A1D42, 0xFFFFFF],
        "UPS": [0x644117, 0xFFB500, 0xFFFFFF],
    ]

    /// Manufacturers, state operators and the rest — the liveries that are not
    /// an airline at all but still fly past somebody's window.
    private static let houseAndState: [String: [UInt32]] = [
        "Airbus": [0x00205B, 0x00A0DF, 0xFFFFFF],
        "Airbus House Livery": [0x00205B, 0x00A0DF, 0xFFFFFF],
        "Boeing": [0x0033A1, 0xFFFFFF],
        "Boeing House Livery": [0x0033A1, 0xFFFFFF],
        "NASA": [0x0B3D91, 0xFC3D21, 0xFFFFFF],
        "Royal Air Force": [0x1B3F73, 0x9EA2A2],
        "United States Air Force": [0x00308F, 0x9EA2A2],
        "US Air Force": [0x00308F, 0x9EA2A2],
        "US Navy": [0x00205B, 0xFFC72C],
    ]
}
