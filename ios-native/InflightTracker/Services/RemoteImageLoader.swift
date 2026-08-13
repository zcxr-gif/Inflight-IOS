import Combine
import UIKit

/// Downloads and caches an aircraft photo as a `UIImage`.
///
/// The window needs the photo's real dimensions, which `AsyncImage` never
/// exposes: the peak thumbnail sizes itself to the photo's aspect ratio, and
/// the hero letterboxes onto a blurred copy of itself rather than cropping the
/// nose and tail off a wide airliner shot.
final class RemoteImageLoader: ObservableObject {

    @Published private(set) var image: UIImage?

    /// Shared across sheets, so re-opening the same aircraft is instant.
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        return cache
    }()

    private var requested: URL?

    func load(_ url: URL?) {
        guard let url = url else {
            requested = nil
            image = nil
            return
        }

        guard requested != url else { return }
        requested = url

        if let cached = RemoteImageLoader.cache.object(forKey: url as NSURL) {
            image = cached
            return
        }

        image = nil

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let decoded = UIImage(data: data) else { return }
            RemoteImageLoader.cache.setObject(decoded, forKey: url as NSURL)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.requested == url else { return }
                self.image = decoded
            }
        }.resume()
    }
}
