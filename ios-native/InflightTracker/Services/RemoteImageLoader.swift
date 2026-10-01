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

    /// How long the picture on screen is kept while its replacement is found.
    ///
    /// Zero lets go at once, which is what every caller had and what most of
    /// them still want. The flight window asks for a moment: tapping from one
    /// aeroplane to the next used to blank the photograph to the placeholder
    /// and then bring the new one up a beat later — two changes where there is
    /// one — because the lookup for the next photograph clears the URL before
    /// it has the next one to give. Held for the grace, a photograph that is
    /// already cached or arrives quickly replaces the last one directly, and
    /// the views cross-fade picture into picture. One that takes longer still
    /// gives way to the placeholder, so a slow network never leaves the wrong
    /// aeroplane on screen under the new callsign for more than the grace.
    private let handoverGrace: TimeInterval

    /// The clear that is waiting out the grace, if one is.
    private var pendingRelease: DispatchWorkItem?

    init(handoverGrace: TimeInterval = 0) {
        self.handoverGrace = handoverGrace
    }

    func load(_ url: URL?) {
        guard let url = url else {
            requested = nil
            release()
            return
        }

        guard requested != url else { return }
        requested = url

        if let cached = RemoteImageLoader.cache.object(forKey: url as NSURL) {
            settle(cached)
            return
        }

        release()

        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let decoded = UIImage(data: data) else { return }
            RemoteImageLoader.cache.setObject(decoded, forKey: url as NSURL)

            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.requested == url else { return }
                self.settle(decoded)
            }
        }.resume()
    }

    /// The next picture is here: it replaces whatever is on screen, and any
    /// clear still waiting out its grace is called off.
    private func settle(_ next: UIImage) {
        pendingRelease?.cancel()
        pendingRelease = nil
        image = next
    }

    /// Lets go of the picture on screen — at once, or once the grace is up.
    ///
    /// A clear already counting down is left to finish rather than restarted,
    /// so a run of lookups in quick succession cannot keep an old photograph
    /// up indefinitely.
    private func release() {
        guard image != nil else { return }

        guard handoverGrace > 0 else {
            image = nil
            return
        }

        guard pendingRelease == nil else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingRelease = nil
            self.image = nil
        }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + handoverGrace, execute: work)
    }
}
