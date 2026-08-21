import CoreLocation
import Foundation

/// The one place that talks to OpenStreetMap.
///
/// Two features read airport detail out of OSM — which stands a field has, and
/// where its pavement is — and both want the same things: a query around a
/// point, a polite timeout, and an answer that is either elements or nothing.
/// Sharing it means one place decides how this app behaves toward a service it
/// is a guest of.
enum Overpass {

    static let endpoint = URL(string: "https://overpass-api.de/api/interpreter")!

    /// Wide enough for the fields that sprawl — remote stands and second
    /// runway complexes sit a long way from the terminal core.
    static let searchRadiusMetres = 7000

    /// Runs a query and hands back its elements, or nil if the lookup failed.
    ///
    /// Nil is distinct from an empty array on purpose: empty means the field
    /// genuinely has nothing mapped, which is an answer worth caching, and nil
    /// means we never got one.
    static func elements(_ query: String) async -> [[String: Any]]? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "data=\(query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            .data(using: .utf8)
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return (root["elements"] as? [[String: Any]]) ?? []
        } catch {
            return nil
        }
    }

    /// `around:` clause for a field, so the queries read the same way.
    static func around(_ coordinate: CLLocationCoordinate2D) -> String {
        "around:\(searchRadiusMetres),\(coordinate.latitude),\(coordinate.longitude)"
    }
}
