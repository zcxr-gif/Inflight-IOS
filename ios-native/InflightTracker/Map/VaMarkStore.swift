import UIKit

/// The VA marks the map draws over aeroplanes, and the images behind them.
///
/// Two jobs the map cannot do inline, both for the same reason: the map is
/// asked about every visible aircraft on every diff, several times a minute,
/// and neither the lookup nor the picture can cost a request at that rate.
///
///   * **Which VA** — `VaAdsService.warmPartner` answers from the warm
///     directory, synchronously, on a callsign match alone. See the note there
///     for why the map takes the strict claim and not the hubbed-at fallback.
///   * **The picture** — downloaded once per VA, decoded once, and kept as a
///     small `UIImage` ready to hand straight to a layer.
///
/// Everything here answers immediately or answers nil. A mark that isn't ready
/// is simply not drawn yet, and `observeMarks(_:_:)` is how a map learns it
/// can stop saying nil.
final class VaMarkStore {

    static let shared = VaMarkStore()

    /// Who wants telling, on the main thread, when a logo finishes
    /// downloading — so whatever is drawing the aeroplanes can redraw the ones
    /// that were waiting for it.
    ///
    /// One notification per arrival rather than a per-aircraft observation: a
    /// single VA's logo landing is one redraw of the marks, not two hundred
    /// callbacks.
    ///
    /// A list rather than one slot, and that is not tidiness. Both shapes of
    /// the world draw these marks now — MapKit's annotations and the planet's
    /// canvas — and while only one of them is on screen at a time, a single
    /// `var` makes their setup order decide which one ever hears about a logo.
    /// Keyed by owner so re-registering replaces rather than stacks.
    private var observers: [(owner: ObjectIdentifier, block: () -> Void)] = []

    private init() {}

    /// Registers `block` to run when a logo lands, replacing anything `owner`
    /// registered before. Held until `stopObservingMarks(_:)`; the owner is
    /// only ever an identity here, never retained.
    func observeMarks(_ owner: AnyObject, _ block: @escaping () -> Void) {
        let key = ObjectIdentifier(owner)
        lock.lock()
        observers.removeAll { $0.owner == key }
        observers.append((owner: key, block: block))
        lock.unlock()
    }

    func stopObservingMarks(_ owner: AnyObject) {
        let key = ObjectIdentifier(owner)
        lock.lock()
        observers.removeAll { $0.owner == key }
        lock.unlock()
    }

    private func announceArrival() {
        lock.lock()
        let blocks = observers.map(\.block)
        lock.unlock()
        guard !blocks.isEmpty else { return }
        DispatchQueue.main.async { blocks.forEach { $0() } }
    }

    // MARK: - State

    private let lock = NSLock()

    /// Ad id → the mark, once its image has been decoded.
    private var marks: [String: UIImage] = [:]

    /// Ad ids currently downloading, so forty aeroplanes of the same VA start
    /// one request between them.
    private var inFlight: Set<String> = []

    /// Ad ids whose image failed or was rejected. Not retried: a logo is
    /// decoration, and a VA whose upload will not decode must not cost a
    /// request per redraw forever.
    private var refused: Set<String> = []

    /// The side the mark is drawn at, in points, before the screen's scale.
    /// Downsampled to this on decode — a 512² WebP held per VA, for the fifty
    /// VAs that might be on screen at once, is memory spent on pixels nobody
    /// can see at 18 points.
    private static let markSide: CGFloat = 18

    // MARK: - Lookups

    /// The VA this callsign is flying for, or nil.
    func partner(callsign: String?) -> VaAd? {
        VaAdsService.shared.warmPartner(callsign: callsign)
    }

    /// The mark for a VA, if it has arrived. Asking is also what starts the
    /// download, so the map gets one by asking twice rather than by arranging
    /// anything.
    func mark(for ad: VaAd) -> UIImage? {
        guard let url = ad.logo else { return nil }

        lock.lock()
        if let ready = marks[ad.id] {
            lock.unlock()
            return ready
        }
        if inFlight.contains(ad.id) || refused.contains(ad.id) {
            lock.unlock()
            return nil
        }
        inFlight.insert(ad.id)
        lock.unlock()

        download(url, for: ad.id)
        return nil
    }

    /// The mark for a VA already asked for, by id, or nil.
    ///
    /// For the planet, whose traffic carries the VA's id rather than the whole
    /// listing — three thousand copies of a directory entry, rebuilt on every
    /// packet, to draw the handful of logos on screen. Unlike `mark(for:)` this
    /// never starts a download: the id got onto the aeroplane by way of a
    /// `mark(for:)` that already did.
    func mark(id adId: String) -> UIImage? {
        lock.lock()
        defer { lock.unlock() }
        return marks[adId]
    }

    /// Says the map would like the directory, so `partner(callsign:)` has
    /// something to answer from. Cheap to call repeatedly.
    func warm() {
        VaAdsService.shared.warmDirectory()
    }

    // MARK: - Fetching

    private func download(_ url: URL, for adId: String) {
        URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let self = self else { return }

            let image = Self.decode(data, response: response)

            self.lock.lock()
            self.inFlight.remove(adId)
            if let image = image {
                self.marks[adId] = image
            } else {
                self.refused.insert(adId)
            }
            self.lock.unlock()

            guard image != nil else { return }
            self.announceArrival()
        }.resume()
    }

    /// Decodes the download to a small square, or refuses it.
    ///
    /// The size ceiling is the guard that matters. These are our own uploads —
    /// 512² WebP, capped by the upload pipeline — but the map draws whatever
    /// comes back over somebody's aeroplane, and a decode is the one place a
    /// bad image gets to allocate. Anything that isn't a plausible logo is
    /// refused rather than drawn small.
    private static func decode(_ data: Data?, response: URLResponse?) -> UIImage? {
        guard let data = data, !data.isEmpty, data.count <= 4_000_000 else { return nil }

        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) { return nil }

        guard let image = UIImage(data: data) else { return nil }
        guard image.size.width > 0, image.size.height > 0,
              image.size.width <= 4096, image.size.height <= 4096 else { return nil }

        return downsampled(image)
    }

    /// Fits the logo into the square the map draws, keeping its aspect ratio
    /// and its transparency.
    ///
    /// Fitted rather than filled, for the same reason `VaLogoMark` fits: a
    /// wordmark inside a square upload is wider than it is tall, and filling
    /// would crop the ends off the VA's own name.
    private static func downsampled(_ image: UIImage) -> UIImage? {
        let side = markSide
        let scale = min(side / image.size.width, side / image.size.height)
        let size = CGSize(
            width: max(image.size.width * scale, 1),
            height: max(image.size.height * scale, 1)
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
