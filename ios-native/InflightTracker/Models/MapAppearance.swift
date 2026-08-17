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
    var configuration: MKMapConfiguration {
        switch self {
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.emphasisStyle = .muted
            configuration.pointOfInterestFilter = .excludingAll
            return configuration

        case .satellite:
            return MKImageryMapConfiguration(elevationStyle: .flat)

        case .hybrid:
            let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
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

    @Published var style: MapGroundStyle {
        didSet { UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey) }
    }

    private init() {
        style = MapGroundStyle(rawValue: UserDefaults.standard.string(forKey: Self.styleKey) ?? "")
            ?? .standard
    }

    func cycleStyle() {
        style = style.next
    }
}
