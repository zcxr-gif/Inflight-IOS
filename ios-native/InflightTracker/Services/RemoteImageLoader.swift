import Combine
import ImageIO
import UIKit

/// A downloaded picture, decoded where it was downloaded.
///
/// `UIImage(data:)` decodes nothing. It wraps the compressed bytes, and the
/// pixels are unpacked the first time the picture is drawn — on the main
/// thread, inside the frame that shows it. For an aircraft photograph that is
/// a JPEG a thousand-odd pixels across, unpacked in the middle of the flight
/// window growing out of the dock, and again for the blurred copy behind it.
/// Decoded here instead, on the network callback's own queue, the picture
/// arrives on the main thread as a bitmap ready to draw.
enum DecodedImage {

    /// Decodes `data` now, on the calling thread.
    ///
    /// `longestSide` caps the picture's longer edge in pixels, scaling it down
    /// if it is bigger and leaving it alone if not — nothing is ever scaled
    /// up. Nil decodes it whole, for pictures whose terms ask that they be
    /// shown as they were served.
    static func from(_ data: Data, longestSide: CGFloat? = nil) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
            var options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let longestSide { options[kCGImageSourceThumbnailMaxPixelSize] = longestSide }
            if let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: decoded)
            }
        }
        // Whatever ImageIO would not read, the old way — decoded here all the
        // same rather than on the first frame that draws it.
        guard let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }
}

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

    /// The longest side a picture is kept at, in pixels. Wider than any screen
    /// draws these — a photograph across a Pro Max is under thirteen hundred,
    /// across an iPad under two and a half thousand — so nothing on screen
    /// changes; what it stops is a banner uploaded straight off a camera being
    /// held as a forty-megabyte bitmap in a cache of sixty.
    private static let longestSide: CGFloat = 2_400

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
            guard let data = data,
                  let decoded = DecodedImage.from(data, longestSide: RemoteImageLoader.longestSide)
            else { return }
            RemoteImageLoader.cache.setObject(decoded, forKey: url as NSURL)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.requested == url else { return }
                self.image = decoded
            }
        }.resume()
    }
}
