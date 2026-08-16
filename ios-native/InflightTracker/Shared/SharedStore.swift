import Foundation
import UIKit

/// The app group both processes read: the widget snapshot, and the aircraft
/// photos the widgets are drawn on.
///
/// The photos are the reason this exists at all. A widget's timeline provider
/// *can* make a network request, but doing it means every refresh either waits
/// on the community-photo API or renders without its background — so the app,
/// which is already fetching that photo to put in the flight window, drops a
/// downscaled copy in here on the way past. By the time a widget needs it, it
/// is a local file read.
public enum SharedStore {

    public static let appGroupIdentifier = "group.com.tracker.Inflight"

    /// Nil when the app group isn't provisioned — a mis-signed build, usually.
    /// Every accessor tolerates it and degrades to "no data" rather than
    /// trapping, because the widget process would take the whole tile down.
    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static var snapshotURL: URL? {
        container?.appendingPathComponent("widget-snapshot.json")
    }

    private static var photosDirectory: URL? {
        container?.appendingPathComponent("AircraftPhotos", isDirectory: true)
    }

    // MARK: - Snapshot

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func loadSnapshot() -> WidgetSnapshot {
        guard let url = snapshotURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot
    }

    /// Written atomically: the widget process reads this file on its own
    /// schedule, and a half-written one decodes to nothing at all.
    public static func save(_ snapshot: WidgetSnapshot) {
        guard let url = snapshotURL, let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Aircraft photos

    /// Widest a stored photo is allowed to be.
    ///
    /// Widgets are killed for using around 30 MB, and a decoded full-size
    /// community photo can be most of that on its own. Storing them already
    /// downscaled means the widget's decode is bounded by this rather than by
    /// whatever somebody happened to upload.
    private static let maximumPhotoWidth: CGFloat = 900

    /// How many photos to keep. Each one is a few hundred KB, and the widgets
    /// only ever draw the pinned flight and a handful of friends.
    private static let photoCacheLimit = 40

    private static func photoURL(for key: String) -> URL? {
        photosDirectory?.appendingPathComponent("\(key).jpg")
    }

    public static func photoData(for key: String) -> Data? {
        guard let url = photoURL(for: key) else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func hasPhoto(for key: String) -> Bool {
        guard let url = photoURL(for: key) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// In-process cache in front of the file read.
    ///
    /// `photo(for:)` is called from inside a SwiftUI `body`, which the system
    /// may evaluate several times per render and re-evaluate every minute for
    /// the life of a Live Activity. Without this, each of those is a file read
    /// and a JPEG decode inside a process with a hard memory ceiling and a
    /// render deadline — and blowing either one shows up as a blank banner
    /// rather than as an error.
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 8
        return cache
    }()

    /// Decoded and downscaled ready to draw. Returns nil rather than a
    /// placeholder so callers can choose their own fallback.
    public static func photo(for key: String) -> UIImage? {
        guard !key.isEmpty else { return nil }
        if let cached = memoryCache.object(forKey: key as NSString) { return cached }
        guard let data = photoData(for: key), let image = UIImage(data: data) else { return nil }
        memoryCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Store a photo the app has just fetched, downscaling first.
    ///
    /// Safe to call with the raw bytes off the network: anything that doesn't
    /// decode as an image is dropped rather than written, so a 404 body or an
    /// HTML error page can't end up cached as a "photo" that every later
    /// lookup finds and fails to draw.
    @discardableResult
    public static func storePhoto(_ data: Data, for key: String) -> Bool {
        guard let directory = photosDirectory, let url = photoURL(for: key) else { return false }
        guard let image = UIImage(data: data) else { return false }

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scaled = downscale(image, toWidth: maximumPhotoWidth)
        guard let jpeg = scaled.jpegData(compressionQuality: 0.82) else { return false }

        do {
            try jpeg.write(to: url, options: .atomic)
        } catch {
            return false
        }
        // A replaced photo must not keep serving the old one from memory.
        memoryCache.removeObject(forKey: key as NSString)
        pruneCache()
        return true
    }

    private static func downscale(_ image: UIImage, toWidth width: CGFloat) -> UIImage {
        guard image.size.width > width, image.size.width > 0 else { return image }
        let scale = width / image.size.width
        let target = CGSize(width: width, height: (image.size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1 // already in pixels; a @3x render would undo the point
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Drops the least recently modified photos once the cache is over its
    /// limit. Cheap, and it runs on a write rather than on a read — a widget
    /// asking for a background should never be doing directory enumeration.
    private static func pruneCache() {
        guard let directory = photosDirectory else { return }
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ), files.count > photoCacheLimit else { return }

        let dated = files.map { url -> (URL, Date) in
            let modified = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate
            return (url, modified ?? .distantPast)
        }
        .sorted { $0.1 > $1.1 }

        for (url, _) in dated.dropFirst(photoCacheLimit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
