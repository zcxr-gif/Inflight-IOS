import MapKit
import SwiftUI

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

    /// The planet: realistic elevation, free to rotate and tilt, and a sphere
    /// once the camera is far enough back.
    case globe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .flat: return "Flat"
        case .globe: return "Globe"
        }
    }

    var detail: String {
        switch self {
        case .flat: return "The ordinary map, north up."
        case .globe: return "The whole planet, free to spin and tilt. Pull back to see it."
        }
    }

    var symbol: String {
        switch self {
        case .flat: return "map"
        case .globe: return "globe"
        }
    }

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

/// What the map is drawn in.
///
/// Every one of these works under either projection, which is the point of
/// splitting them: a black globe and a satellite flat map are both now things
/// you can ask for.
enum MapPalette: String, CaseIterable, Identifiable {

    /// Follows the app's own light and dark. The default, and what the map did
    /// before there was anything to choose — the map turned when the app did.
    case auto

    /// Daytime cartography, whatever the app itself is set to.
    case light

    /// Night cartography, whatever the app itself is set to.
    case dark

    /// Night cartography washed down towards black. For OLED, and for the map
    /// staying out of the way of the traffic at cruise.
    case black

    /// Imagery. Flat it carries no labels at all, which makes the sprites the
    /// only legible thing on screen; on the globe it keeps coastline names,
    /// because a hemisphere with nothing written on it is a hemisphere you
    /// cannot identify.
    case satellite

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .light: return "Light"
        case .dark: return "Dark"
        case .black: return "Black"
        case .satellite: return "Satellite"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "Turns with the app's own light and dark."
        case .light: return "Daytime cartography, whatever the app is set to."
        case .dark: return "Night cartography, whatever the app is set to."
        case .black: return "Night cartography washed down to near black."
        case .satellite: return "Imagery. Flat it has no labels, so only the aircraft read."
        }
    }

    var symbol: String {
        switch self {
        case .auto: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
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
        case .dark, .black: return .dark
        }
    }

    /// Whether the map is imagery rather than cartography.
    var usesImagery: Bool { self == .satellite }

    /// How much black is washed over the map underneath the traffic.
    ///
    /// MapKit has no blacker configuration than its own dark cartography, so
    /// this is the rest of the way: an overlay under everything the app draws,
    /// which dims the map without touching a single aircraft on it.
    var dimming: CGFloat { self == .black ? 0.42 : 0 }
}

/// The map's whole look: its shape, its colour, and how much of it is drawn.
struct MapLook: Equatable {

    var projection: MapProjection = .flat
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

    var isFreeCamera: Bool { projection.isFreeCamera }
    var dimming: CGFloat { palette.dimming }

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

        guard palette.usesImagery else {
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

/// The black wash, as an overlay.
///
/// A polygon over the whole world rather than a view over the map: overlays
/// draw under every annotation MapKit has, so this dims the cartography and
/// leaves the traffic, the route lines and the field markers at full strength.
/// It is inserted at the bottom of its level, under the weather and the night,
/// so neither of those is dimmed by it either.
enum MapDimming {

    static let title = "map.dimming"

    /// Mercator cannot draw the last five degrees at either pole, so the
    /// corners stop where the map itself does.
    private static let limit: Double = 85

    static func overlay() -> MKPolygon {
        let corners = [
            CLLocationCoordinate2D(latitude: limit, longitude: -180),
            CLLocationCoordinate2D(latitude: limit, longitude: 180),
            CLLocationCoordinate2D(latitude: -limit, longitude: 180),
            CLLocationCoordinate2D(latitude: -limit, longitude: -180)
        ]
        let polygon = MKPolygon(coordinates: corners, count: corners.count)
        polygon.title = title
        return polygon
    }
}
