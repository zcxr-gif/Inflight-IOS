import MapKit
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

    /// The planet: imagery over realistic elevation, free to rotate and tilt,
    /// and a sphere once the camera is far enough back.
    ///
    /// One look, and only one. The cartography palettes are the flat map's —
    /// see `MapLook.palette`.
    case globe

    /// The drawn planet: a vector globe of the app's own, in whichever colours
    /// you pick, with the traffic and the fields on it.
    ///
    /// Not MapKit at all — see `PlanetSurface`. It began as a screen you opened
    /// from the corner of the map and closed again, and the argument for
    /// keeping it that way was that a renderer which is not MapKit cannot
    /// reach the map's weather tiles, its gate layouts or its ruler, so
    /// offering it as a projection would mean silently turning features off.
    ///
    /// What changed is where it sits. The planet is now a layer *inside* the
    /// map rather than a screen instead of it, so the search field, the
    /// filters, the dock, the toolbar, every panel and the flight window are
    /// all still there and all still work — and the handful of things that
    /// genuinely need MapKit tiles say so by being switched off rather than by
    /// quietly doing nothing.
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

    /// Whether this shape is drawn by the app rather than by MapKit, which is
    /// what decides which of the map's controls have anything to act on.
    var isDrawn: Bool { self == .planet }

    /// The planet is Pro; the flat map is what everybody has always had.
    var isPro: Bool { self == .globe }

    /// Whether the camera is free to rotate and tilt.
    ///
    /// Only the globe. The flat map is north-up on purpose: a sprite's rotation
    /// is its true heading, and a map that can be spun means that rotation has
    /// to be corrected against the camera on every frame. The globe earns that
    /// cost because spinning it *is* the feature; a flat map gains nothing from
    /// being crooked.
    var isFreeCamera: Bool { self == .globe }

    /// How far back the camera goes when this projection is switched on, in
    /// metres, or nil to leave the camera where it is.
    ///
    /// The globe only looks like a globe from far enough away. Switching to it
    /// from a map framed on one airport would otherwise show a tilted view of a
    /// runway and look like nothing had happened.
    var openingDistance: CLLocationDistance? {
        self == .globe ? 26_000_000 : nil
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
    /// Also what the globe is, always — though there it keeps coastline names,
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

    /// Imagery is Pro, the same as it was when it was a style of its own. The
    /// three cartography colours are free: they are a finish on the map
    /// everybody already has.
    var isPro: Bool { self == .satellite }

    /// Which appearance MapKit draws in, or nil to follow the app.
    ///
    /// This drives the overlays and the annotations too, since they resolve
    /// their dynamic colours against the map view's own trait — which is right:
    /// a route line drawn over a light map should be the light map's line.
    var scheme: ColorScheme? {
        switch self {
        case .auto, .satellite: return nil
        case .light: return .light
        case .black: return .dark
        }
    }

    /// Whether the map is imagery rather than cartography.
    var usesImagery: Bool { self == .satellite }

    /// How much black is washed over the map underneath the traffic.
    ///
    /// MapKit has no blacker configuration than its own dark cartography, so
    /// this is the rest of the way: an overlay under everything the app draws,
    /// which dims the map without touching a single aircraft on it.
    ///
    /// Half rather than the old 0.42. The wash used to stop at the edges of one
    /// copy of the world — see `MapDimming` — so it was tuned against a map
    /// that was only ever partly dark, and a figure that looked right beside an
    /// undimmed neighbour is too timid once the whole thing goes down.
    var dimming: CGFloat { self == .black ? 0.5 : 0 }
}

/// The map's whole look: its shape, its colour, and how much of it is drawn.
struct MapLook: Equatable {

    var projection: MapProjection = .flat

    /// What the map is drawn in — on the flat map.
    ///
    /// The globe ignores this, and that is the one place the two settings are
    /// not independent. It was worth trying: a black planet is a nice idea, and
    /// the split that made the palettes their own axis is what let anybody ask
    /// for one. What comes back is not a black planet. MapKit's cartography is
    /// drawn for a sheet you are looking down at — coastlines, graticule, a
    /// flat ground colour — and wrapped round a sphere lit by real elevation it
    /// reads as a paper globe rather than as the planet, so the one thing the
    /// globe is for is the thing it stops doing.
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
    /// question you can ask of either. The globe has always had it — realistic
    /// elevation is what rounds the planet off at the edges, so a globe without
    /// it is not a globe — and the flat map never could, which is why a
    /// mountain range on it has always been a picture of one rather than a
    /// shape. Turning it on there gives the ordinary map its terrain back and
    /// lets the camera pitch over it.
    ///
    /// What it does not do is take the flat map's north away. Pitch is a camera
    /// looking down at something; rotation is the map being turned underneath
    /// you, and the flat map stays north-up either way — see `isFreeCamera`.
    var isTerrain: Bool = false

    /// Roads, terrain shading and place names at full strength, rather than the
    /// muted cartography the map recedes into behind the traffic. Nothing to do
    /// with imagery, which has no emphasis to set.
    var isDetailed: Bool = false

    /// What the map is actually drawn in, which on the globe is imagery
    /// whatever the palette says.
    ///
    /// Everything downstream reads this rather than `palette`: the
    /// configuration, the scheme, the black wash, and the menu's own
    /// checkmarks. One property, so the setting and the map cannot disagree.
    var resolvedPalette: MapPalette { projection == .globe ? .satellite : palette }

    var isFreeCamera: Bool { projection.isFreeCamera }
    var dimming: CGFloat { resolvedPalette.dimming }

    /// Whether the app draws this map itself. See `MapProjection.planet`.
    var isDrawn: Bool { projection.isDrawn }

    /// Whether there is real elevation under this map. Always true on the
    /// globe, which is what rounds it off.
    var hasTerrain: Bool { projection == .globe || isTerrain }

    /// Whether the camera can be tilted away from straight down.
    ///
    /// Terrain you cannot lean over is terrain you cannot see: the whole of the
    /// difference between a flat map and an elevated one is visible only from
    /// an angle.
    var isPitchEnabled: Bool { isFreeCamera || isTerrain }

    /// Whether a sprite's angle on screen has to be measured rather than
    /// derived from its heading and the camera's bearing.
    ///
    /// The subtraction only holds where north points straight up the screen
    /// everywhere, which is a flat map viewed from directly above. Spin it,
    /// tilt it, or round it off into a planet and it stops holding — worst at
    /// the edges, where a globe's meridians have converged and a pitched map
    /// has run into perspective. See `TrackerMapView.Coordinator.screenAngle`.
    ///
    /// Which is to say: is the camera free to be anywhere but straight above,
    /// pointing north. Exactly the two switches above.
    var usesScreenAngles: Bool { isFreeCamera || isPitchEnabled }

    /// Realistic elevation is what makes MapKit round the world off at the
    /// edges, and what puts height into its terrain; flat is what keeps it a
    /// Mercator sheet.
    var elevationStyle: MKMapConfiguration.ElevationStyle {
        hasTerrain ? .realistic : .flat
    }

    /// MapKit's own configuration for this look.
    ///
    /// Points of interest stay excluded everywhere they can be: the map is a
    /// backdrop for traffic, and a scattering of restaurant pins competes with
    /// the aircraft for exactly the same attention. `MKImageryMapConfiguration`
    /// has no POIs to exclude, which is why it is the one case that doesn't set
    /// the filter.
    func configuration() -> MKMapConfiguration {
        let elevation = elevationStyle

        guard resolvedPalette.usesImagery else {
            let configuration = MKStandardMapConfiguration(elevationStyle: elevation)
            configuration.emphasisStyle = isDetailed ? .default : .muted
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        }

        guard projection == .globe else {
            return MKImageryMapConfiguration(elevationStyle: elevation)
        }

        // Hybrid rather than pure imagery: on a globe you are looking at a
        // hemisphere at a time, and without coastline labels there is nothing to
        // tell you which one.
        let configuration = MKHybridMapConfiguration(elevationStyle: elevation)
        configuration.pointOfInterestFilter = .excludingAll
        return configuration
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

/// The black wash: an overlay under everything the app draws, which takes the
/// cartography the rest of the way down without touching a single aircraft on
/// it.
///
/// ## Why this is not a polygon any more
///
/// It was four corners at ±85° and ±180°, which is the whole world as a
/// rectangle and sounds like exactly the right shape. It is not, for two
/// reasons, and between them they are why the black map never quite worked.
///
/// A polygon is a *shape on the map*, so it exists once, in one copy of the
/// world. MapKit's map does not: pan east past the antimeridian and there is
/// another Pacific, and the wash does not follow you into it — so the map goes
/// half dark and half not, along a seam that moves as you scroll. And ±85° is
/// where Mercator gives up on latitude, not where the *drawable* map ends, so
/// even inside its own copy the polygon left a band across the top and the
/// bottom.
///
/// A renderer has neither problem, because it is not asked to draw a shape. It
/// is handed a rectangle and told to fill it, over and over, for every piece of
/// map on screen — every world copy, right to the edges. Filling what you are
/// given is the whole implementation.
enum MapDimming {

    /// The overlay itself. Nothing but a claim on the entire map.
    final class Overlay: NSObject, MKOverlay {
        let coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let boundingMapRect = MKMapRect.world
    }

    /// And the renderer, which fills whatever rectangle of that it is asked
    /// about.
    final class Renderer: MKOverlayRenderer {

        /// Read on every draw rather than baked in, so changing the palette
        /// repaints the wash instead of tearing it down and building another.
        var dimming: CGFloat {
            didSet {
                guard dimming != oldValue else { return }
                setNeedsDisplay()
            }
        }

        init(overlay: MKOverlay, dimming: CGFloat) {
            self.dimming = dimming
            super.init(overlay: overlay)
        }

        override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
            guard dimming > 0 else { return }
            context.setFillColor(UIColor.black.withAlphaComponent(dimming).cgColor)
            // Slightly proud of the rect it was given. MapKit tiles these, and
            // adjacent fills that meet exactly on a fractional boundary leave a
            // seam a fraction of a pixel wide — which on a black map over light
            // cartography is a visible grid.
            context.fill(rect(for: mapRect).insetBy(dx: -1 / zoomScale, dy: -1 / zoomScale))
        }
    }

    static func overlay() -> Overlay { Overlay() }
}
