import Foundation
import MapKit

/// What the map itself is drawn as.
///
/// The Leaflet build let you swap the tile layer under the traffic, and the
/// native rebuild had shipped with one look — muted standard — and no way out
/// of it. Three is the whole useful set: a chart to read routes on, imagery to
/// see where a field actually is, and imagery with the names still on it.
enum MapGroundStyle: String, CaseIterable, Identifiable {

    case standard
    case satellite
    case hybrid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .satellite: return "Satellite"
        case .hybrid: return "Hybrid"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid: return "globe.americas"
        }
    }

    /// The next one round, for the rail's single button. Cycling rather than a
    /// menu: three options is short enough to tap through, and a rail bubble
    /// has no room for a picker.
    var next: MapGroundStyle {
        let all = MapGroundStyle.allCases
        guard let index = all.firstIndex(of: self) else { return .standard }
        return all[(index + 1) % all.count]
    }

    /// MapKit's own configuration for this look.
    ///
    /// Points of interest are excluded throughout: the map is carrying a
    /// couple of thousand aircraft, and every café MapKit knows about is
    /// something else for a plane icon to hide behind.
    ///
    /// `elevated` is the 3D mode. It is part of the configuration rather than a
    /// camera setting, so switching it re-renders the map — which is why the
    /// map view only assigns a configuration when the answer has changed.
    func configuration(elevated: Bool) -> MKMapConfiguration {
        let elevation: MKMapConfiguration.ElevationStyle = elevated ? .realistic : .flat

        switch self {
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: elevation)
            configuration.emphasisStyle = .muted
            configuration.pointOfInterestFilter = .excludingAll
            return configuration

        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: elevation)

        case .hybrid:
            let configuration = MKHybridMapConfiguration(elevationStyle: elevation)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        }
    }
}

/// Map looks that persist between launches, kept apart from `MapFilters` — one
/// is about what is drawn, the other about how the ground under it looks.
final class MapAppearance: ObservableObject {

    static let shared = MapAppearance()

    private static let styleKey = "mapStyle"
    private static let elevatedKey = "mapElevated"
    private static let radarKey = "mapRadarVisible"

    @Published var style: MapGroundStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    /// Terrain in relief, with the camera tilted off vertical. Worth having on
    /// a map of aeroplanes: it is the one setting that shows you what an
    /// aircraft on approach is actually flying over.
    @Published var isElevated: Bool {
        didSet { UserDefaults.standard.set(isElevated, forKey: Self.elevatedKey) }
    }

    /// Precipitation radar under the traffic.
    ///
    /// Persisted like the rest, and the service that feeds it follows this —
    /// off, nothing is fetched at all.
    @Published var isRadarVisible: Bool {
        didSet {
            UserDefaults.standard.set(isRadarVisible, forKey: Self.radarKey)
            RadarService.shared.setActive(isRadarVisible)
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        style = MapGroundStyle(rawValue: defaults.string(forKey: Self.styleKey) ?? "")
            ?? .standard
        isElevated = defaults.bool(forKey: Self.elevatedKey)
        isRadarVisible = defaults.bool(forKey: Self.radarKey)

        // `didSet` does not run for assignments in an initialiser, so the
        // service is told directly — otherwise a radar layer restored from a
        // previous launch would be switched on with nothing fetching frames
        // for it.
        RadarService.shared.setActive(isRadarVisible)
    }

    func cycleStyle() {
        style = style.next
    }
}
