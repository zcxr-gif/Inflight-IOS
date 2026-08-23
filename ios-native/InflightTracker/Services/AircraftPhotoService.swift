import Foundation

struct AircraftPhoto: Equatable {
    let url: URL
    let contributor: String?
    let tailNumber: String?
}

/// Resolves the Infinite Flight community photos for an aircraft type + livery.
///
/// Same endpoint the web tracker calls (`/api/aircraft/lookup`), and the same
/// tolerant reading of the response: the backend has returned both a bare
/// object and a single-element array, and both `imageUrl` and `imageUrls`.
///
/// All of them are kept now. The lookup has always answered with a list —
/// several photographs of the same type in the same livery, each with its own
/// contributor — and the app used to take the first and throw the rest away.
/// The window's header is a gallery, and everything else that wants one
/// picture asks for `photo` and gets the first, which is what it always got.
final class AircraftPhotoService {

    static let shared = AircraftPhotoService()

    private var cache: [String: [AircraftPhoto]] = [:]
    private let lock = NSLock()

    /// As many as the header will page through. The lookup answers with a
    /// handful; this is a bound rather than a limit anybody should reach, so a
    /// type with a hundred photographs of it cannot turn one window into a
    /// hundred image downloads.
    static let maximumPhotos = 10

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

        /// Every usable image, in the order the backend gave them, each paired
        /// with whoever took it.
        ///
        /// The contributors arrive as a list alongside the URLs, so they are
        /// matched by position — and where that list is short, or absent, or
        /// the URL came from the older single-image field, the entry falls back
        /// to the response's one `contributorName`. Duplicates are dropped,
        /// because a backend that answers with both fields tends to repeat the
        /// first image in each.
        var images: [AircraftPhoto] {
            let candidates = (imageUrls ?? []) + [imageUrl].compactMap { $0 }

            var seen = Set<String>()
            var out: [AircraftPhoto] = []

            for (index, candidate) in candidates.enumerated() {
                let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty,
                      seen.insert(trimmed).inserted,
                      let url = URL(string: trimmed)
                else { continue }

                out.append(
                    AircraftPhoto(
                        url: url,
                        contributor: contributor(at: index),
                        tailNumber: tailNumber
                    )
                )

                if out.count >= AircraftPhotoService.maximumPhotos { break }
            }

            return out
        }

        private func contributor(at index: Int) -> String? {
            let named = imageContributors?.indices.contains(index) == true
                ? imageContributors?[index].name
                : nil

            guard let name = (named ?? contributorName), !name.isEmpty else { return nil }
            return name
        }
    }

    /// The first photograph, for everything that shows one: the peak's
    /// thumbnail, the widgets, a profile's fleet, the live banner.
    func photo(type: String, livery: String, completion: @escaping (AircraftPhoto?) -> Void) {
        photos(type: type, livery: livery) { completion($0.first) }
    }

    /// Cached lookup. `completion` is always called on the main thread; an
    /// empty result means "no photos", which is cached too so a miss isn't
    /// re-fetched.
    func photos(type: String, livery: String, completion: @escaping ([AircraftPhoto]) -> Void) {
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
            DispatchQueue.main.async { completion([]) }
            return
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "livery", value: livery)
        ]

        guard let url = components.url else {
            DispatchQueue.main.async { completion([]) }
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

    private static func decode(_ data: Data?) -> [AircraftPhoto] {
        guard let data = data else { return [] }

        let decoder = JSONDecoder()
        let entry: Entry?

        if let list = try? decoder.decode([Entry].self, from: data) {
            entry = list.first
        } else {
            entry = try? decoder.decode(Entry.self, from: data)
        }

        return entry?.images ?? []
    }
}
