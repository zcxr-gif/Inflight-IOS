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
/// A value handed in rather than read: every colour on the planet comes from
/// one `GlobeSkin`, and the skin is a setting. See `GlobeSkin.palette(for:)`.
struct GlobePalette: Equatable {

    /// The disc itself, where there is no land on it.
    var ocean: UIColor

    /// Land, filled. Nil draws the planet as outlines on open water, which is
    /// what the globe did before there was anything to choose — a coastline is
    /// a hairline and the sea and the continents are the same colour.
    ///
    /// The fill is worth having on most skins and worth *not* having on some:
    /// a filled planet reads as a globe at a glance, an unfilled one keeps the
    /// traffic the only solid thing on screen.
    var land: UIColor?

    /// The bright rim where the planet meets space.
    var limb: UIColor
    var limbWidth: CGFloat

    /// A soft ring of atmosphere just outside the limb. Nil on the flat-looking
    /// skins, where a glow would be the only lit thing on an unlit drawing.
    var halo: UIColor?

    /// Country outlines. On an unfilled planet they are the only thing giving
    /// it shape, so they are the brightest thing on it.
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

    /// How large an aircraft is drawn when the traffic is drawn as aircraft
    /// rather than as dots. In points, the long side of the artwork.
    ///
    /// `AppConfig.iconPointSize` by default, which is what the flat map draws
    /// its traffic at — same artwork, same colours, same size, so an aeroplane
    /// does not change size when you change the shape of the world.
    var planeSize: CGFloat

    /// The wash over the half of the planet that is in darkness.
    var night: UIColor

    /// The open aircraft's route, where the planet draws one.
    var route: UIColor

    /// Where the open aircraft has actually been, and the organised track
    /// system when it is switched on. Both are lines about *traffic* rather
    /// than about the ground, so neither takes a cartography colour.
    var flownPath: UIColor
    var track: UIColor

    /// A field: the ring around it, its code, and the halo that keeps the code
    /// legible over a coastline.
    var fieldRing: UIColor
    var fieldLabel: UIColor
    var fieldLabelHalo: UIColor

    /// Green where somebody is working the field, plain where nobody is. The
    /// one piece of colour a marker carries, and the one thing about a field
    /// you cannot work out by looking at the traffic.
    var fieldControlled: UIColor
    var fieldPlain: UIColor

    init(
        ocean: UIColor,
        land: UIColor? = nil,
        limb: UIColor,
        limbWidth: CGFloat = 1,
        halo: UIColor? = nil,
        border: UIColor,
        borderWidth: CGFloat = 0.7,
        graticule: UIColor,
        graticuleWidth: CGFloat = 0.5,
        traffic: UIColor,
        openTraffic: UIColor,
        dotRadius: CGFloat = 1.6,
        planeSize: CGFloat = AppConfig.iconPointSize,
        night: UIColor = UIColor(white: 0, alpha: 0.32),
        route: UIColor,
        flownPath: UIColor? = nil,
        track: UIColor = UIColor(red: 0.45, green: 0.72, blue: 1, alpha: 0.5),
        fieldRing: UIColor,
        fieldLabel: UIColor,
        fieldLabelHalo: UIColor,
        fieldControlled: UIColor = UIColor(red: 0.42, green: 0.85, blue: 0.45, alpha: 1),
        fieldPlain: UIColor
    ) {
        self.ocean = ocean
        self.land = land
        self.limb = limb
        self.limbWidth = limbWidth
        self.halo = halo
        self.border = border
        self.borderWidth = borderWidth
        self.graticule = graticule
        self.graticuleWidth = graticuleWidth
        self.traffic = traffic
        self.openTraffic = openTraffic
        self.dotRadius = dotRadius
        self.planeSize = planeSize
        self.night = night
        self.route = route
        // Defaults to the route's own colour at half strength: a flown path is
        // the same journey as the line ahead of it, and giving it a colour of
        // its own would be one more thing on the planet to tell apart.
        self.flownPath = flownPath ?? route.withAlphaComponent(0.55)
        self.track = track
        self.fieldRing = fieldRing
        self.fieldLabel = fieldLabel
        self.fieldLabelHalo = fieldLabelHalo
        self.fieldControlled = fieldControlled
        self.fieldPlain = fieldPlain
    }
}

/// What sits behind the planet.
///
/// Resolved from a `GlobeBackdrop` and whichever skin is on, because the two
/// have to agree: a starfield behind a daylight planet is a planet floating in
/// the wrong sky, and a backdrop that ignores the skin is the one way to make
/// the disc's edge disappear.
struct GlobeBackdropStyle: Equatable {

    /// One colour is a flat ground; two or more is a vertical gradient down the
    /// screen.
    var colors: [UIColor]

    /// The starfield's colour, or nil for a sky with nothing in it.
    var stars: UIColor?

    /// A darkening towards the corners, which is what stops a flat ground from
    /// reading as a wall the planet is stuck to.
    var vignette: UIColor?

    static let plain = GlobeBackdropStyle(colors: [.black], stars: nil, vignette: nil)
}
