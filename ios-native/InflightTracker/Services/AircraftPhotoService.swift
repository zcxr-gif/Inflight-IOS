import Foundation

struct AircraftPhoto: Equatable {
    let url: URL
    let contributor: String?
    let tailNumber: String?
}

/// Resolves the Infinite Flight community photo for an aircraft type + livery.
///
/// Same endpoint the web tracker calls (`/api/aircraft/lookup`), and the same
/// tolerant reading of the response: the backend has returned both a bare
/// object and a single-element array, and both `imageUrl` and `imageUrls`.
/// Only the first image is used — the detail sheet shows one hero photo.
final class AircraftPhotoService {

    static let shared = AircraftPhotoService()

    private var cache: [String: AircraftPhoto?] = [:]
    private let lock = NSLock()

    private init() {}

    private struct Entry: Decodable {
        struct Contributor: Decodable {
            let name: String?
        }

        let imageUrl: String?
        let imageUrls: [String]?
        let contributorName: String?
        let imageContributors: [Contributor]?
        let tailNumber: String?

        var firstImageURL: URL? {
            let candidates = (imageUrls ?? []) + [imageUrl].compactMap { $0 }
            for candidate in candidates {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let url = URL(string: trimmed) { return url }
            }
            return nil
        }

        var firstContributor: String? {
            let name = imageContributors?.compactMap({ $0.name }).first ?? contributorName
            guard let name = name, !name.isEmpty else { return nil }
            return name
        }
    }

    /// Cached lookup. `completion` is always called on the main thread; a nil
    /// result means "no photo", which is cached too so a miss isn't re-fetched.
    func photo(type: String, livery: String, completion: @escaping (AircraftPhoto?) -> Void) {
        let key = "\(type)|\(livery)"

        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            DispatchQueue.main.async { completion(cached) }
            return
        }
        lock.unlock()

        guard !type.isEmpty,
              var components = URLComponents(string: "\(AppConfig.apiBaseURLString)/api/aircraft/lookup")
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "livery", value: livery)
        ]

        guard let url = components.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let resolved = Self.decode(data)

            self?.lock.lock()
            self?.cache[key] = resolved
            self?.lock.unlock()

            DispatchQueue.main.async { completion(resolved) }
        }
        .resume()
    }

    private static func decode(_ data: Data?) -> AircraftPhoto? {
        guard let data = data else { return nil }

        let decoder = JSONDecoder()
        let entry: Entry?

        if let list = try? decoder.decode([Entry].self, from: data) {
            entry = list.first
        } else {
            entry = try? decoder.decode(Entry.self, from: data)
        }

        guard let entry = entry, let url = entry.firstImageURL else { return nil }

        return AircraftPhoto(
            url: url,
            contributor: entry.firstContributor,
            tailNumber: entry.tailNumber
        )
    }
}
