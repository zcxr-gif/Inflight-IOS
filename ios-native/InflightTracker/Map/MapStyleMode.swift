import MapKit

/// How the map itself is drawn, underneath the traffic.
///
/// The old web build carried the same idea — `mapStyle` in `mapFilters`, with
/// `applyMapStyleMapping()` swapping Mapbox styles under the aircraft. This is
/// that setting, against MapKit's own configurations, so it costs no tiles and
/// no key.
///
/// `globe` is the one that is more than a repaint: it is what MapKit renders
/// when imagery is paired with realistic elevation and the camera is pulled far
/// enough back — the whole planet, lit and rotatable, with the server's traffic
/// on it. It is a different way to *fly* the map rather than a different palette
/// for it, which is why it also unlocks rotation and pitch.
enum MapStyleMode: String, CaseIterable, Identifiable {

    /// Today's look, and the default: standard cartography with the emphasis
    /// turned down so the map recedes behind the aircraft.
    case muted

    /// The same map at full strength — roads, terrain shading and place names
    /// as MapKit draws them normally. For when the map is the thing you are
    /// reading rather than the backdrop.
    case detailed

    /// Imagery, flat. No labels at all, which makes the sprites the only
    /// legible thing on screen — the reason it is offered.
    case satellite

    /// The planet. Imagery with labels over realistic elevation, free to
    /// rotate and tilt.
    case globe

    var id: String { rawValue }

    var label: String {
        switch self {
        case .muted: return "Muted"
        case .detailed: return "Detailed"
        case .satellite: return "Satellite"
        case .globe: return "Globe"
        }
    }

    var detail: String {
        switch self {
        case .muted:
            return "The map recedes behind the traffic."
        case .detailed:
            return "Roads, terrain and place names at full strength."
        case .satellite:
            return "Imagery with no labels, so only the aircraft read."
        case .globe:
            return "The whole planet, free to spin and tilt. Pull back to see it."
        }
    }

    var symbol: String {
        switch self {
        case .muted: return "map"
        case .detailed: return "map.fill"
        case .satellite: return "globe.americas"
        case .globe: return "globe"
        }
    }

    /// Whether this style is part of Inflight Pro.
    ///
    /// The two standard maps stay free, and they are the two the app has always
    /// had — nobody loses the map they have been using. What Pro buys is the
    /// imagery and the planet, which are the two that are worth going to look
    /// at rather than the two you need.
    var isPro: Bool {
        switch self {
        case .muted, .detailed: return false
        case .satellite, .globe: return true
        }
    }

    /// Whether the camera is free to rotate and tilt in this style.
    ///
    /// Only the globe. Every other style is north-up on purpose: a sprite's
    /// rotation is its true heading, and a map that can be spun means that
    /// rotation has to be corrected against the camera on every frame. The
    /// globe earns that cost because spinning it *is* the feature; a flat map
    /// gains nothing from being crooked.
    var isFreeCamera: Bool { self == .globe }

    /// How far back the camera goes when this style is switched on, in metres,
    /// or nil to leave the camera where it is.
    ///
    /// The globe only looks like a globe from far enough away. Switching to it
    /// from a map framed on one airport would otherwise show a tilted satellite
    /// view of a runway and look like nothing had happened.
    var openingDistance: CLLocationDistance? {
        self == .globe ? 26_000_000 : nil
    }

    /// MapKit's own configuration for this style.
    ///
    /// Points of interest stay excluded everywhere they can be: the map is a
    /// backdrop for traffic, and a scattering of restaurant pins competes with
    /// the aircraft for exactly the same attention. `MKImageryMapConfiguration`
    /// has no POIs to exclude, which is why it is the one case that doesn't
    /// set the filter.
    func configuration() -> MKMapConfiguration {
        switch self {
        case .muted:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.emphasisStyle = .muted
            configuration.pointOfInterestFilter = .excludingAll
            return configuration

        case .detailed:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.emphasisStyle = .default
            configuration.pointOfInterestFilter = .excludingAll
            return configuration

        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: .flat)

        case .globe:
            // Hybrid rather than pure imagery: on a globe you are looking at a
            // hemisphere at a time, and without coastline labels there is
            // nothing to tell you which one.
            let configuration = MKHybridMapConfiguration(elevationStyle: .realistic)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        }
    }
}
