import Foundation
import UIKit

/// Photographs of the aircraft in the sky, kept for as long as the sky view is.
///
/// The markers used to be the map's sprites — the little white plan-view
/// drawings — which are right on a map, where you are looking down at traffic
/// from above and a shape pointing the way it is flying is the whole of what
/// you need. Held up at the sky you are looking at the *side* of an aeroplane,
/// and the thing that tells you which one it is is a picture of it.
///
/// Two lookups, both already in the app and both already cached: the photo
/// service turns a type and a livery into a URL, and the image loader turns a
/// URL into a picture. What this adds is the bit neither of them does — asking
/// once per *kind* of aeroplane rather than once per aeroplane.
///
/// A sky with forty aircraft in it is rarely forty different types. Ten 737s in
/// the same livery are one lookup and one download, shared by all ten markers,
/// which is the difference between this being free and it being forty requests
/// every time somebody opens the view.
final class SkyPhotos: ObservableObject {

    /// Pictures by kind — `type|livery`, the same key the photo service uses.
    @Published private(set) var images: [String: UIImage] = [:]

    /// Kinds already asked about, whether or not the answer was a picture.
    /// A type with no photograph anywhere is a lookup worth not repeating for
    /// every packet for as long as the view is open.
    private var asked: Set<String> = []

    /// Shared with the flight window, so an aircraft whose photo was already
    /// fetched for its window is on screen the instant the sky opens.
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 80
        return cache
    }()

    static func key(type: String, livery: String) -> String { "\(type)|\(livery)" }

    func image(for key: String) -> UIImage? { images[key] }

    /// Asks for anything in this sky that has not been asked about yet.
    ///
    /// Called with the shortlist rather than one at a time, so the de-duplication
    /// happens before any work does.
    func load(_ kinds: [(type: String, livery: String)]) {
        for kind in kinds {
            let key = Self.key(type: kind.type, livery: kind.livery)

            guard !asked.contains(key) else { continue }
            asked.insert(key)

            if let cached = Self.cache.object(forKey: key as NSString) {
                images[key] = cached
                continue
            }

            resolve(key: key, type: kind.type, livery: kind.livery)
        }
    }

    /// Type and livery to a URL, then the URL to a picture.
    private func resolve(key: String, type: String, livery: String) {
        AircraftPhotoService.shared.photos(type: type, livery: livery) { [weak self] photos in
            guard let self = self, let url = photos.first?.url else { return }

            URLSession.shared.dataTask(with: url) { data, _, _ in
                guard let data = data, let decoded = UIImage(data: data) else { return }
                Self.cache.setObject(decoded, forKey: key as NSString)

                DispatchQueue.main.async { [weak self] in
                    self?.images[key] = decoded
                }
            }
            .resume()
        }
    }

    /// Dropped when the view closes. The pictures themselves stay in the shared
    /// cache — what goes is this view's own map of them, so a sky reopened over
    /// different traffic does not carry the last one's aeroplanes into it.
    func clear() {
        images = [:]
        asked = []
    }
}
