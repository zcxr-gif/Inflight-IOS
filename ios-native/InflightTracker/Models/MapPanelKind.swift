import Foundation

/// The places a panel can be opened, and the six the map's home sheet lists.
///
/// Ordered as they are read: who you came to see, then who is working, then
/// where everyone is, then what the server is doing, then what the map draws,
/// then the app itself. Friends leads because it is the only one that is about
/// a person.
///
/// Weather is not on the list. It is a chip on the map's left shoulder, where
/// the one decision it carries — which layer is drawn — is a tap from the map
/// rather than a tap, a sheet and a scroll; its settings panel is the last item
/// in that chip's own menu.
enum MapPanelKind: String, Identifiable, CaseIterable {

    case friends
    case atc
    case airports
    case stats
    case filters
    case weather
    case settings

    var id: String { rawValue }

    /// What the home sheet lists, in order.
    static let sheetItems: [MapPanelKind] = [.friends, .atc, .airports, .stats, .filters, .settings]

    var label: String {
        switch self {
        case .friends: return "Friends"
        case .atc: return "ATC"
        case .airports: return "Airports"
        case .stats: return "Stats"
        case .filters: return "Filters"
        case .weather: return "Weather"
        case .settings: return "Settings"
        }
    }

    /// The line under the label in the sheet. A row in a list has room to say
    /// what it answers, which a five-item bar never did.
    var detail: String {
        switch self {
        case .friends: return "Pilots you are watching"
        case .atc: return "Who is on frequency"
        case .airports: return "Where the server is"
        case .stats: return "What the server is doing"
        case .filters: return "What the map draws"
        case .weather: return "Layers, winds and units"
        case .settings: return "The app itself"
        }
    }

    var symbol: String {
        switch self {
        case .friends: return "person.2.fill"
        case .atc: return "antenna.radiowaves.left.and.right"
        // The same glyph the search results mark an airport with, so the two
        // ways into a field look like the same thing.
        case .airports: return "mappin.and.ellipse"
        case .stats: return "chart.bar.fill"
        case .filters: return "line.3.horizontal.decrease"
        case .weather: return "cloud.sun.fill"
        case .settings: return "gearshape.fill"
        }
    }
}
