import Foundation

/// The URLs a widget can send the app to.
///
/// Shared source, compiled into both targets, because this is a contract
/// between two processes: the widget writes these and the app reads them, and
/// the failure mode of them disagreeing is a tap that opens the app to nothing
/// in particular. Neither side ever spells a URL out by hand.
///
/// Query parameters rather than path components on purpose. A flight's id comes
/// from the feed and is whatever the backend says it is; putting an arbitrary
/// string in a path means worrying about slashes and percent-encoding at both
/// ends, and `URLComponents` handles a query item correctly without anyone
/// having to think about it.
public enum InflightLink: Equatable {

    public static let scheme = "inflight"
    private static let host = "open"

    /// One aircraft, by feed id.
    case flight(id: String)

    /// One field, by ICAO.
    case airport(icao: String)

    /// A toolbar panel, for the tiles that are about a list rather than a thing.
    case panel(String)

    public var url: URL? {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host

        switch self {
        case .flight(let id):
            components.queryItems = [URLQueryItem(name: "flight", value: id)]
        case .airport(let icao):
            components.queryItems = [URLQueryItem(name: "airport", value: icao.uppercased())]
        case .panel(let name):
            components.queryItems = [URLQueryItem(name: "panel", value: name)]
        }

        return components.url
    }

    public static func parse(_ url: URL) -> InflightLink? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else { return nil }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }

        if let id = value("flight") { return .flight(id: id) }
        if let icao = value("airport") { return .airport(icao: icao.uppercased()) }
        if let panel = value("panel") { return .panel(panel) }
        return nil
    }
}
