import SwiftUI
import UIKit

/// What the planet is drawn in.
///
/// Its own type rather than tokens read off `FlightInfoTheme`, for two reasons.
/// The canvas is a `UIView` drawing into Core Graphics, so it wants `UIColor`
/// and would otherwise bridge one per stroke; and the globe is a *picture of a
/// planet* rather than a surface of the app — its colours answer to what makes
/// a coastline legible against the traffic, not to what the flight window is
/// made of.
///
/// The look is the one the app has always been after on the map and never had:
/// unlit land, borders as hairlines, and nothing written on it. The aircraft
/// are the only thing on a globe with any colour in them, which is the whole
/// point of drawing the world this way.
struct GlobePalette: Equatable {

    /// The disc itself. Barely off the background — enough that the planet
    /// reads as an object with an edge, not so much that it competes with the
    /// borders drawn on it.
    var ocean: UIColor

    /// The bright rim where the planet meets space.
    var limb: UIColor
    var limbWidth: CGFloat

    /// Country outlines. The brightest thing on the planet, because they are
    /// the only thing giving it shape.
    var border: UIColor
    var borderWidth: CGFloat

    /// Meridians and parallels. Far dimmer — a grid you can find when you look
    /// for it and do not see when you are not.
    var graticule: UIColor
    var graticuleWidth: CGFloat

    /// Ordinary traffic, and the aircraft whose window is open.
    var traffic: UIColor
    var openTraffic: UIColor
    var dotRadius: CGFloat

    /// The night one, and the one the app opens on.
    static let night = GlobePalette(
        ocean: UIColor(white: 0.07, alpha: 1),
        limb: UIColor(white: 1, alpha: 0.5),
        limbWidth: 1,
        border: UIColor(white: 1, alpha: 0.55),
        borderWidth: 0.7,
        graticule: UIColor(white: 1, alpha: 0.09),
        graticuleWidth: 0.5,
        traffic: UIColor(white: 1, alpha: 0.75),
        openTraffic: UIColor(red: 0.36, green: 0.72, blue: 1, alpha: 1),
        dotRadius: 1.6
    )

    /// The daylight one. Not a recolour of the night palette but its inverse:
    /// dark ink on a pale planet, because a white hairline on a white disc is
    /// nothing at all.
    static let day = GlobePalette(
        ocean: UIColor(white: 0.93, alpha: 1),
        limb: UIColor(white: 0.35, alpha: 0.7),
        limbWidth: 1,
        border: UIColor(white: 0.2, alpha: 0.65),
        borderWidth: 0.7,
        graticule: UIColor(white: 0.2, alpha: 0.12),
        graticuleWidth: 0.5,
        traffic: UIColor(white: 0.1, alpha: 0.8),
        openTraffic: UIColor(red: 0.1, green: 0.42, blue: 0.85, alpha: 1),
        dotRadius: 1.6
    )

    init(
        ocean: UIColor,
        limb: UIColor,
        limbWidth: CGFloat,
        border: UIColor,
        borderWidth: CGFloat,
        graticule: UIColor,
        graticuleWidth: CGFloat,
        traffic: UIColor,
        openTraffic: UIColor,
        dotRadius: CGFloat
    ) {
        self.ocean = ocean
        self.limb = limb
        self.limbWidth = limbWidth
        self.border = border
        self.borderWidth = borderWidth
        self.graticule = graticule
        self.graticuleWidth = graticuleWidth
        self.traffic = traffic
        self.openTraffic = openTraffic
        self.dotRadius = dotRadius
    }

    /// The palette for the app as it is currently set. Only which way round —
    /// the globe does not take the app's accent, because an accent on the
    /// planet would be one more colour competing with the traffic.
    init(theme: FlightInfoTheme) {
        self = theme.isLight ? .day : .night
    }
}
