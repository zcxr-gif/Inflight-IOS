import CoreLocation
import MapboxMaps
import SwiftUI
import UIKit

/// Which shape the map is.
///
/// This used to be tangled up with what the map was made of: there were four
/// styles, and the globe was one of them, which meant the planet only ever came
/// in satellite imagery and the flat map could never be black. They are two
/// different questions — what shape the world is, and what it is drawn in — and
/// they are now asked separately.
enum MapProjection: String, CaseIterable, Identifiable {

    /// The flat, north-up map. What the app has always opened on.
    case flat

    /// The planet: Mapbox's globe projection in imagery over real elevation,
    /// free to rotate and tilt, and a sphere once the camera is far enough
    /// back — easing into the flat map as you zoom in, with no seam.
    ///
    /// One look, and only one. The cartography palettes are the flat map's —
    /// see `MapLook.palette`.
    case globe

    /// The drawn planet: a vector globe of the app's own, in whichever colours
    /// you pick, with the traffic and the fields on it.
    ///
    /// Not Mapbox at all — see `PlanetSurface`. It began as a screen you opened
    /// from the corner of the map and closed again, and the argument for
    /// keeping it that way was that a renderer which is not the map's cannot
    /// reach the map's weather tiles, its gate layouts or its ruler, so
    /// offering it as a projection would mean silently turning features off.
    ///
    /// The weather is no longer one of those. The radar, the satellite, the
    /// barbs, the coloured field and the moving air are all drawn on the
    /// planet — see `GlobeWeather`, which paints the tiles by unprojecting
    /// every pixel of the screen onto the sphere and reading whatever is under
    /// it, because no transform will put a mercator tile on a globe.
    ///
    /// What changed is where it sits. The planet is now a layer *inside* the
    /// map rather than a screen instead of it, so the search field, the
    /// filters, the dock, the toolbar, every panel and the flight window are
    /// all still there and all still work — and the handful of things that
    /// genuinely need the map's own tiles say so by being switched off rather
    /// than by quietly doing nothing. The screen it began as is gone with that:
    /// a second, chrome-less copy of the map you are already looking at is a
    /// place to go that has nothing you did not have.
    case planet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .globe: return "Globe"
        case .planet: return "Planet"
        }
    }

    var detail: String {
        switch self {
        case .flat: return "The ordinary map, north up."
        case .globe: return "The whole planet in imagery, free to spin and tilt. Pull back to see it."
        case .planet: return "A drawn globe in colours you pick, with the traffic over it."
        }
    }

    var symbol: String {
        switch self {
        case .flat: return "map"
        case .globe: return "globe"
        case .planet: return "globe.americas"
        }
    }

    /// Whether this shape is drawn by the app rather than by Mapbox, which is
    /// what decides which of the map's controls have anything to act on.
    var isDrawn: Bool { self == .planet }

    /// The imagery globe is Pro; the flat map is what everybody has always
    /// had, and so is the drawn planet.
    ///
    /// The planet is deliberately free, and that is a decision about what it is
    /// rather than about what it costs to run: it is the app's own renderer, it
    /// fetches nothing the map would have fetched, and a shape of the world
    /// nobody without Pro can look at is one nobody without Pro can want. What
    /// is sold on it is the *editing* — its colours, its sky and how the
    /// traffic on it is drawn. See `ProFeature.planetLook`.
    var isPro: Bool { self == .globe }

    /// Whether the camera is free to rotate and tilt.
    ///
    /// Only the globe. The flat map is north-up on purpose: a map that can be
    /// spun is a map somebody can lose north on, and a flat map gains nothing
    /// from being crooked. The sprites would cope either way — they are turned
    /// against the map on the GPU — so this is a decision about the map rather
    /// than a cost.
    var isFreeCamera: Bool { self == .globe }

    /// How far out the camera goes when this projection is switched on, as a
    /// zoom level, or nil to leave the camera where it is.
    ///
    /// The globe only looks like a globe from far enough away. Switching to it
    /// from a map framed on one airport would otherwise show a tilted view of a
    /// runway and look like nothing had happened.
    var openingZoom: CGFloat? {
        self == .globe ? 1.6 : nil
    }

    /// The projection Mapbox draws this shape in. The drawn planet is not
    /// Mapbox's, and stands over a flat map nobody can see.
    var styleProjection: StyleProjectionName {
        self == .globe ? .globe : .mercator
    }
}

/// What the flat map is drawn in.
///
/// The flat map's, and deliberately only the flat map's. The globe is one look
/// — imagery over real elevation — and the cartography palettes are not offered
/// on it: see `MapLook.palette`, which is where that is decided and why.
enum MapPalette: String, CaseIterable, Identifiable {

    /// Follows the app's own light and dark. The default, and what the map did
    /// before there was anything to choose — the map turned when the app did.
    ///
    /// This is also where the old `dark` went. There used to be a fourth
    /// cartography colour that meant "night, whatever the app is set to", and
    /// the app is set to dark for very nearly everybody — so it drew the map
    /// this one already draws, sat next to it in the list, and the only way to
    /// tell the two apart was to go and change the app's appearance. A choice
    /// you cannot see the effect of is not a choice. See `from(stored:)`.
    case auto

    /// Daytime cartography, whatever the app itself is set to.
    case light

    /// Night cartography washed down towards black. For OLED, and for the map
    /// staying out of the way of the traffic at cruise.
    case black

    /// Imagery. It carries no labels at all, which makes the sprites the only
    /// legible thing on screen.
    ///
    /// Also what the globe is, always — though there it keeps place names,
    /// because a hemisphere with nothing written on it is a hemisphere you
    /// cannot identify.
    case satellite

    var id: String { rawValue }

    /// What a stored palette means now, including one this enum no longer has
    /// a case for.
    ///
    /// `dark` is the only such value, and it lands on `auto`. That is the
    /// palette it was drawing anyway on any install whose app appearance is
    /// dark — which is the default and what nearly every install is — so for
    /// nearly everybody the map is byte-for-byte what it was before the update.
    /// The exception is somebody running the app light with the map pinned
    /// dark, whose map now turns with the app; there is no surviving palette
    /// that means what theirs did, and `black` — the nearest — is a visibly
    /// different, dimmed map rather than the one they chose.
    static func from(stored raw: String?) -> MapPalette? {
        guard let raw = raw, !raw.isEmpty else { return nil }
        if raw == "dark" { return .auto }
        return MapPalette(rawValue: raw)
    }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .black: return "Black"
        case .satellite: return "Satellite"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Turns with the app's own light and dark."
        case .light: return "Daytime cartography, whatever the app is set to."
        case .black: return "Night cartography washed down to near black."
        case .satellite: return "Imagery. Flat it has no labels, so only the aircraft read."
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .black: return "circle.fill"
        case .satellite: return "globe.americas"
        }
    }

    /// Every finish is free, satellite imagery included. The globe is the
    /// map-style Pro has left — see `MapProjection.isPro`.
    var isPro: Bool { false }

    /// Which appearance the map draws in, or nil to follow the app.
    ///
    /// This drives the layers drawn over it too, since their colours are
    /// resolved against the map's own scheme — which is right: a route line
    /// drawn over a light map should be the light map's line.
    var scheme: ColorScheme? {
        switch self {
        case .auto, .satellite: return nil
        case .light: return .light
        case .black: return .dark
        }
    }

    /// Whether the map is imagery rather than cartography.
    var usesImagery: Bool { self == .satellite }

    /// How much black this palette washes over the map before anybody touches
    /// the brightness.
    ///
    /// Mapbox's monochrome night is already dark, but it is drawn to be read;
    /// this is the rest of the way: a wash under everything the app draws,
    /// which dims the map without touching a single aircraft on it.
    var dimming: CGFloat { self == .black ? 0.5 : 0 }
}

/// How much light is taken off the map, or put back onto it.
///
/// One signed number rather than two switches, because it is one question with
/// a middle: the map as Mapbox draws it. Positive is black laid over the
/// cartography, negative is white — and white genuinely does lift a dark map,
/// which is the half of this that a dimmer alone could never do. Satellite
/// imagery at night is the case that wants the first and a black palette read
/// in daylight is the case that wants the second, and neither of them is a
/// different *map*.
struct MapWash: Equatable {

    /// Positive darkens, negative lightens, zero is the map untouched.
    var depth: CGFloat

    /// Whether there is anything to draw at all. Below this the wash is a
    /// full-screen layer compositing a colour nobody can see.
    var isVisible: Bool { abs(depth) > 0.004 }

    /// What is laid over the map, and how much of it.
    var color: UIColor { depth >= 0 ? .black : .white }
    var alpha: CGFloat { min(abs(depth), 1) }
}

/// The map's whole look: its shape, its colour, and how much of it is drawn.
struct MapLook: Equatable {

    var projection: MapProjection = .flat

    /// What the map is drawn in — on the flat map.
    ///
    /// The globe ignores this, and that is the one place the two settings are
    /// not independent. It was worth trying: a black planet is a nice idea, and
    /// the split that made the palettes their own axis is what let anybody ask
    /// for one. What comes back is not a black planet. Cartography is drawn for
    /// a sheet you are looking down at — coastlines, a flat ground colour — and
    /// wrapped round a sphere lit by real elevation it reads as a paper globe
    /// rather than as the planet, so the one thing the globe is for is the
    /// thing it stops doing.
    ///
    /// So the globe is imagery, always, and the palettes stay what they have
    /// always effectively been: the flat map's finish. The stored choice is
    /// left alone rather than overwritten — see `resolvedPalette` — so a black
    /// map is still black when you come back down.
    var palette: MapPalette = .auto

    /// Real elevation under the map: mountains with height in them, and a
    /// camera that can be tilted down to look along it.
    ///
    /// Its own setting rather than a property of the shape, because it is a
    /// question you can ask of either. The globe has always had it — elevation
    /// is what gives the planet its relief at the edges, so a globe without it
    /// is not a globe — and turning it on for the flat map gives the ordinary
    /// map its terrain and lets the camera pitch over it.
    ///
    /// What it does not do is take the flat map's north away. Pitch is a camera
    /// looking down at something; rotation is the map being turned underneath
    /// you, and the flat map stays north-up either way — see `isFreeCamera`.
    var isTerrain: Bool = false

    /// Roads, terrain shading and place names at full strength, rather than the
    /// faded cartography the map recedes into behind the traffic. Nothing to do
    /// with imagery, which has no emphasis to set.
    var isDetailed: Bool = false

    /// Where the brightness slider is standing, from black at zero to washed
    /// out at one, with `neutralBrightness` meaning the map exactly as Mapbox
    /// draws it.
    ///
    /// A slider rather than another palette, because it is not a choice
    /// between looks — it is the same map, turned up or down. The three
    /// cartography palettes and the imagery are all drawn for a screen in a
    /// room, and the two places this app is actually read are a dark cabin at
    /// altitude, where any of them is a lamp, and a flight deck window seat in
    /// full sun, where the black one is a rumour. Neither of those wants a
    /// different map.
    ///
    /// Deliberately *not* part of what `mapStyle(isLight:)` answers, and
    /// `sameCartography(as:)` is what keeps it that way: dragging this must
    /// set one layer's opacity rather than reconfigure the basemap sixty
    /// times on the way across.
    var brightness: CGFloat = MapLook.neutralBrightness

    /// The middle of the slider: the map untouched.
    static let neutralBrightness: CGFloat = 0.5

    /// How black the map can be washed at the dark end.
    ///
    /// Not to one. A map you cannot see at all is not a setting anybody wants
    /// to arrive at by accident, and the traffic is drawn over this — a wash
    /// heavy enough to hide the coastline still has to leave enough of the
    /// field under an aeroplane to say where it is.
    static let deepestWash: CGFloat = 0.72

    /// And how far white can lift it at the other end. Shorter, because white
    /// over cartography goes flat much faster than black over it goes dark.
    static let brightestLift: CGFloat = 0.42

    /// What the map is actually drawn in, which on the globe is imagery
    /// whatever the palette says.
    ///
    /// Everything downstream reads this rather than `palette`: the style, the
    /// scheme, the black wash, and the menu's own checkmarks. One property, so
    /// the setting and the map cannot disagree.
    var resolvedPalette: MapPalette { projection == .globe ? .satellite : palette }

    var isFreeCamera: Bool { projection.isFreeCamera }

    /// The wash over the cartography: the palette's own, moved by wherever the
    /// brightness slider is standing.
    ///
    /// The two compose on one axis rather than fighting on two, which is what
    /// makes a black map brightenable: its half-black baseline is a starting
    /// point on the same number the slider moves, so pushing the slider up
    /// takes that wash off before it starts adding white of its own.
    ///
    /// The travel either side is measured against the *remaining* room rather
    /// than added flat, so both ends of the slider land on the same two
    /// extremes whatever palette is under it. Added flat, the black palette
    /// would already be most of the way to the dark end at the middle and the
    /// first third of the slider would do nothing at all — a control with a
    /// dead zone in it that changes size depending on a setting two sections
    /// up.
    var wash: MapWash {
        let base = resolvedPalette.dimming
        let travel = (Self.neutralBrightness - brightness) / Self.neutralBrightness
        let depth = travel >= 0
            ? base + travel * (Self.deepestWash - base)
            : base + travel * (base + Self.brightestLift)
        return MapWash(depth: min(max(depth, -Self.brightestLift), Self.deepestWash))
    }

    /// Whether two looks draw the same map, ignoring how much light is left on
    /// it.
    ///
    /// The brightness is a wash over the finished cartography and nothing the
    /// basemap is told about, so a change to it alone is one layer's opacity.
    /// Everything else here goes into `mapStyle(isLight:)` or the projection —
    /// see `TrackerMapView.Coordinator.applyLook`, which uses this to tell the
    /// two apart.
    func sameCartography(as other: MapLook) -> Bool {
        projection == other.projection
            && palette == other.palette
            && isTerrain == other.isTerrain
            && isDetailed == other.isDetailed
    }

    /// Whether the app draws this map itself. See `MapProjection.planet`.
    var isDrawn: Bool { projection.isDrawn }

    /// Whether there is real elevation under this map. Always true on the
    /// globe, which is what gives it its relief.
    var hasTerrain: Bool { projection == .globe || isTerrain }

    /// Whether the camera can be tilted away from straight down.
    ///
    /// Terrain you cannot lean over is terrain you cannot see: the whole of the
    /// difference between a flat map and an elevated one is visible only from
    /// an angle.
    var isPitchEnabled: Bool { isFreeCamera || isTerrain }

    /// The Mapbox style for this look.
    ///
    /// Mapbox Standard for the cartography and Standard Satellite for imagery.
    /// Both take their look from *configuration* rather than from a different
    /// style — the light preset, the theme, which labels — and Mapbox applies a
    /// change of configuration to the style already loaded, animated, without
    /// reloading anything. So turning the app from light to dark, or the map
    /// from faded to detailed, is a cross-fade rather than a reload; only the
    /// step between cartography and imagery swaps the style itself.
    ///
    /// Points of interest stay off everywhere: the map is a backdrop for
    /// traffic, and a scattering of restaurant pins competes with the aircraft
    /// for exactly the same attention. So do the 3D buildings and trees — the
    /// traffic is the only thing on this map that should be standing up, and
    /// not drawing a city's worth of extrusions is a good share of what keeps a
    /// pinch at the display's full frame rate.
    func mapStyle(isLight: Bool) -> MapStyle {
        guard !resolvedPalette.usesImagery else {
            // Imagery is a photograph and has no night of its own; the wash is
            // what dims it. Flat it carries no labels at all, so the traffic is
            // the only legible thing on screen. The globe keeps place names
            // and borders, because a hemisphere with nothing written on it is
            // a hemisphere you cannot identify.
            let named = projection == .globe
            return .standardSatellite(
                lightPreset: .day,
                showPointOfInterestLabels: false,
                showTransitLabels: false,
                showPlaceLabels: named,
                showRoadLabels: false,
                showRoadsAndTransit: false,
                showPedestrianRoads: false,
                showAdminBoundaries: named
            )
        }

        let theme: StandardTheme
        if resolvedPalette == .black {
            theme = .monochrome
        } else {
            theme = isDetailed ? .default : .faded
        }

        return .standard(
            theme: theme,
            lightPreset: isLight ? .day : .night,
            showPointOfInterestLabels: false,
            showTransitLabels: false,
            showPedestrianRoads: isDetailed,
            show3dObjects: false
        )
    }

    /// The look an old install's single stored style becomes.
    ///
    /// Every one of the four is still reachable, and lands exactly where it was
    /// — nobody's map changes under them on update.
    static func from(legacy stored: String) -> MapLook? {
        switch stored {
        case "muted": return MapLook(projection: .flat, palette: .auto)
        case "detailed": return MapLook(projection: .flat, palette: .auto, isDetailed: true)
        case "satellite": return MapLook(projection: .flat, palette: .satellite)
        case "globe": return MapLook(projection: .globe, palette: .satellite)
        default: return nil
        }
    }
}
