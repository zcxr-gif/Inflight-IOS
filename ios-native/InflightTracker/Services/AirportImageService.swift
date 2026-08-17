import Foundation

/// The photograph of a field.
///
/// The Capacitor build drew one at the top of every airport window —
/// `fetchAirportData()` in `old/www/flight.js`, which reads `imageUrl` off
/// `/api/airports/{ICAO}` on the same backend the aircraft photos come from.
/// The native rebuild never carried it across; this is that endpoint.
///
/// Read the same tolerant way `AircraftPhotoService` reads its sibling: that
/// backend has been seen returning a bare object and a single-element array,
/// and both `imageUrl` and `imageUrls`, so all four shapes are accepted rather
/// than assuming the one that happened to come back first.
final class AirportImageService {

    static let shared = AirportImageService()

    /// ICAO → image, with misses cached as `nil`. Most fields have no photo,
    /// and re-asking on every open would be a request per panel for an answer
    /// that is not going to change.
    private var cache: [String: URL?] = [:]
    private let lock = NSLock()

    private init() {}

    private struct Entry: Decodable {

        let imageUrl: String?
        let imageUrls: [String]?

        var firstImageURL: URL? {
            let candidates = (imageUrls ?? []) + [imageUrl].compactMap { $0 }
            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let url = URL(string: trimmed) else { continue }
                // The field is a free-text string on somebody else's server;
                // only http(s) is going anywhere near an image loader.
                guard url.scheme == "https" || url.scheme == "http" else { continue }
                return url
            }
            return nil
        }
    }

    /// What is already known, without going to the network. Lets a panel paint
    /// a field it has opened before instantly, and lets the widget bridge skip
    /// work it has already done.
    func cached(_ icao: String) -> URL? {
        let key = icao.uppercased()
        lock.lock()
        defer { lock.unlock() }
        return cache[key] ?? nil
    }

    /// `completion` always lands on the main thread. Nil means the field has no
    /// picture, which is the common case and is cached as such.
    func image(for icao: String, completion: @escaping (URL?) -> Void) {
        let key = icao.uppercased()

        lock.lock()
        if let known = cache[key] {
            lock.unlock()
            DispatchQueue.main.async { completion(known) }
            return
        }
        lock.unlock()

        guard !key.isEmpty,
              let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(AppConfig.apiBaseURLString)/api/airports/\(encoded)")
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            var resolved: URL?

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(status), let data = data {
                let decoder = JSONDecoder()
                // Bare object first, then the single-element array the same
                // backend sometimes answers with.
                if let entry = try? decoder.decode(Entry.self, from: data) {
                    resolved = entry.firstImageURL
                } else if let entries = try? decoder.decode([Entry].self, from: data) {
                    resolved = entries.compactMap({ $0.firstImageURL }).first
                }
            }

            self?.lock.lock()
            self?.cache[key] = resolved
            self?.lock.unlock()

            DispatchQueue.main.async { completion(resolved) }
        }
        .resume()
    }
}
