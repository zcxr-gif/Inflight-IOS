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
/// `tracker/colors.js` on the web side, ported entry for entry. Those are the
/// brand colours the web tracker has always held for Infinite Flight's
/// liveries, keyed by the same `liveryName` string the live feed sends, so the
/// two builds agree about what colour an airline is without a second list to
/// keep in step. Anything not in it gets no accent at all and the window looks
/// exactly as it does today — which is the right failure: a guessed colour on
/// somebody's airline is worse than no colour.
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

    /// Ported from `tracker/colors.js`, entry for entry, in its order.
    private static let liveries: [String: [UInt32]] = [
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
}
