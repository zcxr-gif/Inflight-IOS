import SwiftUI
import UIKit

/// What colour the planet is.
///
/// The globe used to have exactly two looks — one for a light app and one for a
/// dark one — because it was one screen you visited rather than a map you could
/// choose. As a map you can be on all day it wants the same answer the flat map
/// has always had: a list of finishes, picked by looking at them.
///
/// Each skin is written out in full rather than derived from a seed colour. A
/// planet is six or seven colours that have to work *against each other* — a
/// coastline against its ocean, a code against the coastline, an aeroplane
/// against all of it — and a generator that tints them all together is exactly
/// how you get a skin where the traffic disappears into the land.
enum GlobeSkin: String, CaseIterable, Identifiable {

    /// Turns with the app's own light and dark, which is what the globe did
    /// before there was anything to choose.
    case auto

    /// The dark one the globe has always opened on: an unlit disc, every
    /// country a white hairline, and nothing filled.
    case midnight

    /// Its inverse — dark ink on a pale planet — for a light app.
    case daylight

    /// Filled land in cool grey on a darker sea. The first of the skins that
    /// draws the continents as shapes rather than as outlines.
    case slate

    /// Deep water and lit coastlines: the blue one.
    case ocean

    /// Land in green on near-black water.
    case emerald

    /// Drafting paper. Cyan lines on navy, with the graticule brought up to
    /// where you are meant to see it rather than find it.
    case blueprint

    /// A radar screen: amber on a warm black.
    case amber

    /// No colour at all in the cartography, so every coloured thing on screen
    /// is an aeroplane.
    case mono

    /// The light filled one: cream land, pale sea, brown coastlines.
    case paper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .midnight: return "Midnight"
        case .daylight: return "Daylight"
        case .slate: return "Slate"
        case .ocean: return "Ocean"
        case .emerald: return "Emerald"
        case .blueprint: return "Blueprint"
        case .amber: return "Amber"
        case .mono: return "Mono"
        case .paper: return "Paper"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Turns with the app's own light and dark."
        case .midnight: return "Unlit, with every coastline a white hairline."
        case .daylight: return "Dark ink on a pale planet."
        case .slate: return "Filled land in cool grey on a darker sea."
        case .ocean: return "Deep water, lit coastlines."
        case .emerald: return "Green continents on near-black water."
        case .blueprint: return "Drafting paper: cyan on navy, grid and all."
        case .amber: return "A radar screen, warm and dim."
        case .mono: return "No colour but the aircraft."
        case .paper: return "Cream land, pale sea, brown coastlines."
        }
    }

    /// Whether the planet is drawn light. Read by the backdrop, which has to
    /// know which way round the sky behind it goes.
    func isLight(scheme: ColorScheme) -> Bool {
        switch self {
        case .auto: return scheme == .light
        case .daylight, .paper: return true
        default: return false
        }
    }

    /// The colours themselves.
    ///
    /// `scheme` is only ever read by `auto`; every other skin is the same
    /// planet whichever way the app is set, which is the point of choosing one.
    func palette(scheme: ColorScheme) -> GlobePalette {
        switch self {
        case .auto: return scheme == .light ? Self.daylightPalette : Self.midnightPalette
        case .midnight: return Self.midnightPalette
        case .daylight: return Self.daylightPalette
        case .slate: return Self.slatePalette
        case .ocean: return Self.oceanPalette
        case .emerald: return Self.emeraldPalette
        case .blueprint: return Self.blueprintPalette
        case .amber: return Self.amberPalette
        case .mono: return Self.monoPalette
        case .paper: return Self.paperPalette
        }
    }

    // MARK: - The planets

    private static let midnightPalette = GlobePalette(
        ocean: UIColor(white: 0.07, alpha: 1),
        land: nil,
        limb: UIColor(white: 1, alpha: 0.5),
        halo: UIColor(white: 1, alpha: 0.10),
        border: UIColor(white: 1, alpha: 0.55),
        graticule: UIColor(white: 1, alpha: 0.09),
        traffic: UIColor(white: 1, alpha: 0.75),
        openTraffic: UIColor(red: 0.36, green: 0.72, blue: 1, alpha: 1),
        route: UIColor(red: 0.36, green: 0.72, blue: 1, alpha: 0.85),
        fieldRing: UIColor(white: 1, alpha: 0.55),
        fieldLabel: UIColor(white: 1, alpha: 0.92),
        fieldLabelHalo: UIColor(white: 0, alpha: 0.65),
        fieldPlain: UIColor(red: 0.36, green: 0.72, blue: 1, alpha: 1)
    )

    private static let daylightPalette = GlobePalette(
        ocean: UIColor(white: 0.93, alpha: 1),
        land: nil,
        limb: UIColor(white: 0.35, alpha: 0.7),
        halo: nil,
        border: UIColor(white: 0.2, alpha: 0.65),
        graticule: UIColor(white: 0.2, alpha: 0.12),
        traffic: UIColor(white: 0.1, alpha: 0.8),
        openTraffic: UIColor(red: 0.1, green: 0.42, blue: 0.85, alpha: 1),
        night: UIColor(red: 0.05, green: 0.07, blue: 0.14, alpha: 0.26),
        route: UIColor(red: 0.1, green: 0.42, blue: 0.85, alpha: 0.85),
        track: UIColor(red: 0.15, green: 0.30, blue: 0.55, alpha: 0.45),
        fieldRing: UIColor(white: 0.2, alpha: 0.6),
        fieldLabel: UIColor(white: 0.08, alpha: 1),
        fieldLabelHalo: UIColor(white: 1, alpha: 0.75),
        fieldControlled: UIColor(red: 0.13, green: 0.55, blue: 0.2, alpha: 1),
        fieldPlain: UIColor(red: 0.1, green: 0.42, blue: 0.85, alpha: 1)
    )

    private static let slatePalette = GlobePalette(
        ocean: UIColor(red: 0.055, green: 0.075, blue: 0.105, alpha: 1),
        land: UIColor(red: 0.145, green: 0.175, blue: 0.220, alpha: 1),
        limb: UIColor(red: 0.60, green: 0.68, blue: 0.80, alpha: 0.55),
        halo: UIColor(red: 0.45, green: 0.60, blue: 0.85, alpha: 0.12),
        border: UIColor(red: 0.55, green: 0.63, blue: 0.75, alpha: 0.75),
        graticule: UIColor(white: 1, alpha: 0.07),
        traffic: UIColor(white: 1, alpha: 0.85),
        openTraffic: UIColor(red: 1.0, green: 0.72, blue: 0.24, alpha: 1),
        route: UIColor(red: 1.0, green: 0.72, blue: 0.24, alpha: 0.85),
        fieldRing: UIColor(white: 1, alpha: 0.5),
        fieldLabel: UIColor(white: 1, alpha: 0.92),
        fieldLabelHalo: UIColor(white: 0, alpha: 0.6),
        fieldPlain: UIColor(red: 0.62, green: 0.78, blue: 1, alpha: 1)
    )

    private static let oceanPalette = GlobePalette(
        ocean: UIColor(red: 0.024, green: 0.086, blue: 0.161, alpha: 1),
        land: UIColor(red: 0.055, green: 0.180, blue: 0.271, alpha: 1),
        limb: UIColor(red: 0.44, green: 0.76, blue: 1, alpha: 0.6),
        halo: UIColor(red: 0.30, green: 0.66, blue: 1, alpha: 0.16),
        border: UIColor(red: 0.42, green: 0.74, blue: 0.95, alpha: 0.85),
        graticule: UIColor(red: 0.42, green: 0.74, blue: 0.95, alpha: 0.10),
        traffic: UIColor(white: 1, alpha: 0.88),
        openTraffic: UIColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 1),
        route: UIColor(red: 1.0, green: 0.78, blue: 0.30, alpha: 0.85),
        fieldRing: UIColor(white: 1, alpha: 0.55),
        fieldLabel: UIColor(white: 1, alpha: 0.94),
        fieldLabelHalo: UIColor(red: 0.01, green: 0.04, blue: 0.09, alpha: 0.7),
        fieldPlain: UIColor(red: 0.55, green: 0.85, blue: 1, alpha: 1)
    )

    private static let emeraldPalette = GlobePalette(
        ocean: UIColor(red: 0.016, green: 0.063, blue: 0.059, alpha: 1),
        land: UIColor(red: 0.043, green: 0.180, blue: 0.145, alpha: 1),
        limb: UIColor(red: 0.35, green: 0.90, blue: 0.70, alpha: 0.55),
        halo: UIColor(red: 0.25, green: 0.85, blue: 0.62, alpha: 0.14),
        border: UIColor(red: 0.35, green: 0.85, blue: 0.66, alpha: 0.80),
        graticule: UIColor(red: 0.35, green: 0.85, blue: 0.66, alpha: 0.09),
        traffic: UIColor(white: 1, alpha: 0.88),
        openTraffic: UIColor(red: 1.0, green: 0.70, blue: 0.36, alpha: 1),
        route: UIColor(red: 1.0, green: 0.70, blue: 0.36, alpha: 0.85),
        fieldRing: UIColor(white: 1, alpha: 0.52),
        fieldLabel: UIColor(white: 1, alpha: 0.94),
        fieldLabelHalo: UIColor(red: 0, green: 0.03, blue: 0.03, alpha: 0.7),
        fieldPlain: UIColor(red: 0.55, green: 1.0, blue: 0.85, alpha: 1)
    )

    private static let blueprintPalette = GlobePalette(
        ocean: UIColor(red: 0.031, green: 0.086, blue: 0.196, alpha: 1),
        land: nil,
        limb: UIColor(red: 0.45, green: 0.75, blue: 1, alpha: 0.8),
        halo: UIColor(red: 0.30, green: 0.62, blue: 1, alpha: 0.18),
        border: UIColor(red: 0.39, green: 0.72, blue: 1, alpha: 0.9),
        borderWidth: 0.65,
        graticule: UIColor(red: 0.39, green: 0.72, blue: 1, alpha: 0.28),
        graticuleWidth: 0.45,
        traffic: UIColor(red: 1.0, green: 0.95, blue: 0.80, alpha: 0.95),
        openTraffic: UIColor(red: 1.0, green: 0.55, blue: 0.30, alpha: 1),
        route: UIColor(red: 1.0, green: 0.55, blue: 0.30, alpha: 0.85),
        fieldRing: UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 0.7),
        fieldLabel: UIColor(red: 0.85, green: 0.94, blue: 1, alpha: 1),
        fieldLabelHalo: UIColor(red: 0.01, green: 0.04, blue: 0.11, alpha: 0.75),
        fieldPlain: UIColor(red: 0.55, green: 0.82, blue: 1, alpha: 1)
    )

    private static let amberPalette = GlobePalette(
        ocean: UIColor(red: 0.055, green: 0.039, blue: 0.016, alpha: 1),
        land: UIColor(red: 0.145, green: 0.086, blue: 0.016, alpha: 1),
        limb: UIColor(red: 1.0, green: 0.72, blue: 0.28, alpha: 0.7),
        halo: UIColor(red: 1.0, green: 0.62, blue: 0.16, alpha: 0.14),
        border: UIColor(red: 1.0, green: 0.71, blue: 0.28, alpha: 0.85),
        graticule: UIColor(red: 1.0, green: 0.71, blue: 0.28, alpha: 0.13),
        traffic: UIColor(red: 1.0, green: 0.94, blue: 0.82, alpha: 0.95),
        openTraffic: UIColor(red: 0.55, green: 0.86, blue: 1.0, alpha: 1),
        route: UIColor(red: 0.55, green: 0.86, blue: 1.0, alpha: 0.85),
        fieldRing: UIColor(red: 1.0, green: 0.80, blue: 0.45, alpha: 0.7),
        fieldLabel: UIColor(red: 1.0, green: 0.90, blue: 0.72, alpha: 1),
        fieldLabelHalo: UIColor(red: 0.05, green: 0.03, blue: 0, alpha: 0.75),
        fieldControlled: UIColor(red: 0.55, green: 0.95, blue: 0.60, alpha: 1),
        fieldPlain: UIColor(red: 1.0, green: 0.80, blue: 0.45, alpha: 1)
    )

    private static let monoPalette = GlobePalette(
        ocean: UIColor(white: 0.02, alpha: 1),
        land: UIColor(white: 0.13, alpha: 1),
        limb: UIColor(white: 1, alpha: 0.6),
        halo: nil,
        border: UIColor(white: 1, alpha: 0.5),
        graticule: UIColor(white: 1, alpha: 0.07),
        traffic: UIColor(white: 1, alpha: 0.9),
        openTraffic: UIColor(red: 1.0, green: 0.62, blue: 0.04, alpha: 1),
        route: UIColor(white: 1, alpha: 0.6),
        fieldRing: UIColor(white: 1, alpha: 0.5),
        fieldLabel: UIColor(white: 1, alpha: 0.92),
        fieldLabelHalo: UIColor(white: 0, alpha: 0.7),
        fieldPlain: UIColor(white: 1, alpha: 0.85)
    )

    private static let paperPalette = GlobePalette(
        ocean: UIColor(red: 0.827, green: 0.886, blue: 0.929, alpha: 1),
        land: UIColor(red: 0.957, green: 0.937, blue: 0.878, alpha: 1),
        limb: UIColor(red: 0.35, green: 0.31, blue: 0.26, alpha: 0.65),
        halo: nil,
        border: UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.8),
        graticule: UIColor(red: 0.38, green: 0.33, blue: 0.27, alpha: 0.14),
        traffic: UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 0.9),
        openTraffic: UIColor(red: 0.80, green: 0.25, blue: 0.10, alpha: 1),
        night: UIColor(red: 0.05, green: 0.07, blue: 0.14, alpha: 0.24),
        route: UIColor(red: 0.80, green: 0.25, blue: 0.10, alpha: 0.85),
        track: UIColor(red: 0.20, green: 0.28, blue: 0.45, alpha: 0.45),
        fieldRing: UIColor(red: 0.30, green: 0.26, blue: 0.21, alpha: 0.65),
        fieldLabel: UIColor(red: 0.15, green: 0.13, blue: 0.10, alpha: 1),
        fieldLabelHalo: UIColor(white: 1, alpha: 0.8),
        fieldControlled: UIColor(red: 0.13, green: 0.50, blue: 0.20, alpha: 1),
        fieldPlain: UIColor(red: 0.15, green: 0.35, blue: 0.70, alpha: 1)
    )
}

/// What is behind the planet.
///
/// Its own setting rather than part of the skin, because it is a different
/// question and people answer it differently: the same slate planet reads as a
/// spacecraft window against stars and as a piece of the app against the app's
/// own ground, and both are things to want.
enum GlobeBackdrop: String, CaseIterable, Identifiable {

    /// The app's own window colour, so the planet sits on the same ground every
    /// other screen is made of. What the globe did before there was a choice.
    case app

    /// Deep space: near black, with a little more of it in the corners.
    case space

    /// Space, with stars in it. The stars are fixed to the screen rather than
    /// to the sky — turning the planet turns the planet.
    case stars

    /// A gradient tinted by whichever skin is on, so the sky behind a blue
    /// planet is blue and the sky behind an amber one is not.
    case gradient

    /// One flat colour, taken from the skin's own ocean and pushed away from
    /// it — the plainest ground there is, and the one that keeps the disc's
    /// edge unambiguous.
    case plain

    var id: String { rawValue }

    var label: String {
        switch self {
        case .app: return "App"
        case .space: return "Space"
        case .stars: return "Starfield"
        case .gradient: return "Gradient"
        case .plain: return "Plain"
        }
    }

    var detail: String {
        switch self {
        case .app: return "The same ground the rest of the app is made of."
        case .space: return "Near black, deepening into the corners."
        case .stars: return "Space, with stars behind the planet."
        case .gradient: return "A wash in the planet's own colour."
        case .plain: return "One flat colour, and nothing else."
        }
    }

    var symbol: String {
        switch self {
        case .app: return "square.fill"
        case .space: return "moon.stars"
        case .stars: return "sparkles"
        case .gradient: return "circle.lefthalf.filled"
        case .plain: return "rectangle.fill"
        }
    }

    /// The backdrop as the canvas wants it, which needs the skin: every one of
    /// these but `space` is a colour the planet decides.
    func style(skin: GlobeSkin, scheme: ColorScheme, windowFill: UIColor) -> GlobeBackdropStyle {
        let palette = skin.palette(scheme: scheme)
        let isLight = skin.isLight(scheme: scheme)

        switch self {
        case .app:
            return GlobeBackdropStyle(colors: [windowFill], stars: nil, vignette: nil)

        case .space:
            return GlobeBackdropStyle(
                colors: [UIColor(white: 0.04, alpha: 1)],
                stars: nil,
                vignette: UIColor(white: 0, alpha: 0.55)
            )

        case .stars:
            return GlobeBackdropStyle(
                colors: [UIColor(white: 0.035, alpha: 1)],
                stars: UIColor(white: 1, alpha: 0.85),
                vignette: UIColor(white: 0, alpha: 0.5)
            )

        case .gradient:
            // Both ends taken off the planet's own ocean rather than invented,
            // so a gradient is the same colour family as the thing standing in
            // front of it however far the skins drift.
            return GlobeBackdropStyle(
                colors: isLight
                    ? [palette.ocean.mixed(with: .white, amount: 0.55),
                       palette.ocean.mixed(with: .white, amount: 0.20)]
                    : [palette.ocean.mixed(with: .black, amount: 0.55),
                       palette.ocean.mixed(with: .black, amount: 0.05)],
                stars: nil,
                vignette: nil
            )

        case .plain:
            return GlobeBackdropStyle(
                colors: [palette.ocean.mixed(with: isLight ? .white : .black, amount: 0.45)],
                stars: nil,
                vignette: nil
            )
        }
    }
}

extension UIColor {

    /// This colour moved a fraction of the way towards another.
    ///
    /// Component-wise in whatever space the colour reports, which for every
    /// colour in this file is sRGB — they are all written out as literals. A
    /// colour that cannot report components (a pattern, most obviously) is
    /// returned unchanged rather than turned into black.
    func mixed(with other: UIColor, amount: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
              other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2) else { return self }

        let t = min(1, max(0, amount))
        return UIColor(
            red: r1 + (r2 - r1) * t,
            green: g1 + (g2 - g1) * t,
            blue: b1 + (b2 - b1) * t,
            alpha: a1 + (a2 - a1) * t
        )
    }
}
