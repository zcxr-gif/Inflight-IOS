import MapKit
import UIKit

/// One frame of weather, as map tiles.
///
/// The URL shape is RainViewer's, and it is documented in
/// `old/www/rainviewer.txt`:
///
///     {host}{path}/{size}/{z}/{x}/{y}/{colour}/{smooth}_{snow}.png
struct MapWeatherTiles: Equatable {

    let host: String
    let frame: WeatherFrame
    let layer: MapWeatherLayer

    /// Identity for the map's diff: the frame's path already changes with
    /// every frame and every layer serves different paths, so this is enough
    /// to say "the tiles on screen are the wrong ones".
    ///
    /// Two things beyond the frame are part of it, and both are there because a
    /// tile MapKit has already been given is a tile it will not ask for again:
    ///
    /// - the **served depth**, because everything past it is resampled from the
    ///   deepest tile that exists, so a depth that has moved means every derived
    ///   tile on the map was built from the wrong ancestor;
    /// - the service's **token**, which moves when tiles that came back empty
    ///   are worth asking for again — after a cooldown, most of all.
    ///
    /// Without them the overlay carried on serving whatever it had until the
    /// frame happened to change, which made noticing either one no difference
    /// at all.
    var key: String {
        let service = RainViewerService.shared
        return """
        \(layer.rawValue)|\(host)\(frame.path)\
        |z\(MapWeatherSource.maximumZoom(for: layer))|g\(service.tilesToken)
        """
    }
}

/// The tiles for whichever weather layer is on.
///
/// Two services behind one overlay: RainViewer's radar frames, and NASA's
/// daily satellite composites. They agree on nothing except that a tile is a
/// square PNG or JPEG at a z/x/y — so this builds each one's URL its own way,
/// at each one's own tile size, and everything above it stays the same.
///
/// ## Why this answers for zooms the services do not serve
///
/// Neither service serves anywhere near the depth this map zooms to. RainViewer
/// stops at zoom 7 and NASA at 8; the map goes to twenty. Something has to fill
/// the gap, and how it is filled was the whole of what made these layers
/// unpleasant to zoom.
///
/// What used to happen was two things at once. `MKTileOverlay` was told its
/// `maximumZ`, so MapKit stopped asking past it and *magnified its own raster*
/// of the deepest tiles — a whole screen of nearest-neighbour blocks, growing
/// coarser with every step in. And the map watched the span and took the
/// overlay off entirely once it decided the magnification had gone too far,
/// which meant a layer that vanished mid-pinch, came back at a different zoom
/// than it left, and re-fetched a screenful of tiles every time it did.
///
/// So neither happens now. This overlay answers for **every** zoom: past the
/// depth the service serves it fetches the deepest ancestor that does exist,
/// crops the part of it the requested tile covers, and resamples that to a full
/// tile with smooth interpolation. The renderer is handed a real tile for the
/// path it asked for at every zoom, so there is no magnified raster and no
/// blocks — a radar field, which is a smooth field to begin with, stays a
/// smooth field. And because one ancestor serves every child under it out of
/// the caches below, zooming in past the service's depth costs no network at
/// all.
///
/// And the layer is not faded out on top of that any more. It used to be — see
/// the note in `MapWeatherSource` — which meant the resampling above was doing
/// its work at zooms where nothing was drawn to see it. The alpha is one
/// constant per layer now, the same way the web tracker's is, so the radar is
/// still on the map when you are looking at an approach.
///
/// ## What all of that rests on
///
/// The served depth. Everything above is a picture built from the deepest tile
/// that exists, so if this asks for a depth the service does not serve, there is
/// no ancestor, and "softens as you close in" becomes "vanishes as you close
/// in" — with a screenful of refused requests per zoom step behind it, tripping
/// a meter that then refuses the zooms which *were* working. That is exactly
/// what happened when RainViewer's ceiling moved to 7 and this was still asking
/// for 8. So two things changed: the depth is now the service's rather than a
/// guess (`RainViewerService.servedRadarZoom`, which comes down on its own if
/// the tiles disagree), and every request this makes is counted first — see
/// `WeatherTileBudget`.
final class RainViewerTileOverlay: MKTileOverlay {

    /// RainViewer's colour schemes, by number. Four is the one that reads as
    /// weather radar to anybody who has seen a forecast, and it is what the web
    /// tracker asks for.
    private static let radarColourScheme = 4

    /// How big a tile each service is asked for.
    ///
    /// RainViewer serves its mosaic at either size and the web tracker takes
    /// the larger, which is twice the detail per tile over the same ground for
    /// one request rather than four. GIBS's `GoogleMapsCompatible` matrix set
    /// is 256 and only 256 — asking it for 512 is a 404.
    private static func tileSide(for layer: MapWeatherLayer) -> CGFloat {
        layer == .satellite ? 256 : 512
    }

    private let tiles: MapWeatherTiles

    /// The deepest zoom the service behind this layer actually serves.
    /// Everything past it is resampled from here.
    private let servedZ: Int

    /// What these tiles are, taken once.
    ///
    /// `MapWeatherTiles.key` now asks the service two questions to build itself,
    /// and this is asked on every tile — for the derived cache — from whatever
    /// thread MapKit is rasterising on. Taken at init instead, so it is a string
    /// comparison rather than two locks per tile, and so an overlay's identity
    /// cannot change underneath the tiles it has already handed out. Anything
    /// that *should* change it builds a new overlay, which is the whole point of
    /// the key.
    private let identity: String

    init(tiles: MapWeatherTiles) {
        self.tiles = tiles
        self.servedZ = MapWeatherSource.maximumZoom(for: tiles.layer)
        self.identity = tiles.key
        super.init(urlTemplate: nil)

        // The map underneath still has to be readable through it: this draws
        // over the basemap, not instead of it.
        canReplaceMapContent = false
        minimumZ = 0
        // Deliberately not the service's depth. Telling MapKit where the tiles
        // stop is telling it to magnify its own raster past that point, which
        // is exactly the blockiness this class exists to avoid — so it is told
        // that tiles exist everywhere, and `loadTile` makes that true.
        maximumZ = 20
        let side = Self.tileSide(for: tiles.layer)
        tileSize = CGSize(width: side, height: side)
    }

    var key: String { identity }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        if tiles.layer == .satellite {
            return SatelliteImagery.url(frame: tiles.frame, z: path.z, x: path.x, y: path.y)
                ?? Self.nowhere
        }

        // Smoothing on, which suits a field rather than a set of pixels, and
        // snow in its own colours.
        let string = """
        \(tiles.host)\(tiles.frame.path)/\(Int(tileSize.width))\
        /\(path.z)/\(path.x)/\(path.y)/\(Self.radarColourScheme)/1_1.png
        """

        // `MKTileOverlay` demands a URL rather than an optional, and the only
        // way these strings fail to be one is a host the service invented. A
        // URL that resolves to nothing draws nothing, which is the same
        // outcome and reached without a crash.
        return URL(string: string) ?? Self.nowhere
    }

    private static let nowhere = URL(string: "https://tilecache.rainviewer.com/")!

    // MARK: - Where tiles are kept

    /// The network cache.
    ///
    /// Its own store, and a large one. Overriding `loadTile` takes the fetch
    /// away from `MKTileOverlay`, which has a tile cache built for exactly this
    /// — and the first version of that override handed the job to
    /// `URLSession.shared`, whose cache is a few megabytes shared with every
    /// other request the app makes. Aircraft photographs evict tiles the moment
    /// they land, so every pan and every frame of an animation went back to the
    /// network: the service throttles, tiles come back empty, and the layer
    /// flickers in and out.
    ///
    /// A tile's URL names its own frame — RainViewer's carries a timestamp,
    /// NASA's a date — so no tile ever changes under its address, and the cache
    /// can be believed rather than revalidated. That is what makes the second
    /// pass of an animation loop cost nothing at all.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "weather-tiles"
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        // A screenful of tiles asked for at once is a burst a rate limiter
        // notices. Four at a time fills the map in much the same wall time and
        // looks far less like an attack.
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    /// Decoded source tiles, by URL.
    ///
    /// This is the cache that makes zooming in free. One tile at the service's
    /// deepest zoom is the ancestor of four at the next zoom, sixteen at the
    /// one after and so on, so a screenful of deep tiles is a handful of
    /// ancestors between them — decoded once here rather than re-decoded from
    /// the URL cache's bytes for every child.
    ///
    /// Thirty-two rather than the sixty-four it held while these were 256
    /// pixels: a decoded 512 tile is four times the pixels, and the visible map
    /// at the served depth is a handful of tiles either way. This is a pan's
    /// worth of headroom, not a copy of the world.
    private static let sources = ImageCache(limit: 32)

    /// Finished tiles, by the path they were built for.
    ///
    /// Small, and worth having: a pan back over ground just left, or a pinch
    /// that settles at a zoom it passed through, gets its tiles without
    /// resampling them again.
    private static let derived = DataCache(limit: 192)

    /// A tiny bounded cache. `NSCache` rather than a dictionary, so a memory
    /// warning empties it rather than the app being killed for holding it.
    private final class ImageCache {
        private let store = NSCache<NSString, UIImage>()
        init(limit: Int) { store.countLimit = limit }
        func image(for key: String) -> UIImage? { store.object(forKey: key as NSString) }
        func set(_ image: UIImage, for key: String) { store.setObject(image, forKey: key as NSString) }
    }

    private final class DataCache {
        private let store = NSCache<NSString, NSData>()
        init(limit: Int) { store.countLimit = limit }
        func data(for key: String) -> Data? { store.object(forKey: key as NSString) as Data? }
        func set(_ data: Data, for key: String) { store.setObject(data as NSData, forKey: key as NSString) }
    }

    // MARK: - Serving a tile

    /// Fetches a tile, or builds one from the deepest ancestor that exists.
    ///
    /// `MKTileOverlay` will do the fetching itself, and did — but it swallows
    /// the answer. A tier that has been withdrawn serves the index listing the
    /// frames and then refuses every image, and the map's own version of that
    /// is a layer switched on, drawing nothing, explaining nothing. So the
    /// fetch is here, and it tells the service whether the request produced a
    /// tile.
    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, Error?) -> Void
    ) {
        // Inside the depth the service serves, this is an ordinary fetch and
        // the bytes go straight through — no decode, no redraw, nothing between
        // the network and the renderer.
        guard path.z > servedZ else {
            fetch(at: path, reportingFailures: true) { data, error in
                result(data, error)
            }
            return
        }

        let derivedKey = "\(key)|\(path.z)/\(path.x)/\(path.y)"
        if let ready = Self.derived.data(for: derivedKey) {
            result(ready, nil)
            return
        }

        // The ancestor: the same ground, at the deepest zoom that has a tile
        // for it.
        let depth = path.z - servedZ
        let ancestor = MKTileOverlayPath(
            x: path.x >> depth,
            y: path.y >> depth,
            z: servedZ,
            contentScaleFactor: path.contentScaleFactor
        )

        source(at: ancestor) { [weak self] image in
            guard let self = self, let image = image else {
                result(nil, Self.refusal(status: 0))
                return
            }

            guard let data = self.crop(image, of: ancestor, to: path, depth: depth) else {
                result(nil, Self.refusal(status: 0))
                return
            }

            Self.derived.set(data, for: derivedKey)
            result(data, nil)
        }
    }

    /// Ancestor fetches already in the air, by URL, with everyone waiting on
    /// each.
    ///
    /// Without this a screenful of deep tiles is twenty requests for the four
    /// ancestors between them, all fired before any of them has landed and so
    /// all missing the cache — which is precisely the burst the connection
    /// limit above exists to avoid. One request per ancestor, and the other
    /// nineteen tiles wait on it.
    private static let pendingLock = NSLock()
    private static var pending: [String: [(UIImage?) -> Void]] = [:]

    /// The decoded ancestor, from the cache or from the network.
    private func source(
        at path: MKTileOverlayPath,
        completion: @escaping (UIImage?) -> Void
    ) {
        let address = url(forTilePath: path).absoluteString

        if let ready = Self.sources.image(for: address) {
            completion(ready)
            return
        }

        Self.pendingLock.lock()
        if Self.pending[address] != nil {
            Self.pending[address]?.append(completion)
            Self.pendingLock.unlock()
            return
        }
        Self.pending[address] = [completion]
        Self.pendingLock.unlock()

        fetch(at: path, reportingFailures: true) { data, _ in
            let image = data.flatMap(UIImage.init(data:))
            if let image = image { Self.sources.set(image, for: address) }

            Self.pendingLock.lock()
            let waiting = Self.pending.removeValue(forKey: address) ?? []
            Self.pendingLock.unlock()

            for hand in waiting { hand(image) }
        }
    }

    /// How far either side of the wanted region the resampling is given to work
    /// with, in pixels of the ancestor.
    ///
    /// The reason there is a margin at all: at eight zooms past the service the
    /// region wanted is a single pixel of the ancestor, and one pixel scaled up
    /// is a flat square. Handing the resampler the pixels *around* it as well is
    /// what turns a magnified radar blob back into a soft edge instead of a
    /// step. Four, which is past the reach of any resampling filter Core
    /// Graphics has, so a tile built from a patch is the same tile it would
    /// have been built from the whole ancestor — including at its own edges,
    /// where a margin that was too small would show as a seam against the tile
    /// next door.
    private static let resampleMargin: CGFloat = 4

    /// The part of `image` that `path` covers, resampled to a whole tile.
    ///
    /// ## Why this takes a patch rather than the whole ancestor
    ///
    /// The first version drew the entire ancestor magnified and let the context
    /// clip it, which got the margin above for free and was fine for the first
    /// few zooms past the service. It stopped being fine further in. The draw
    /// rect is the ancestor's size times two to the power of the depth, so at
    /// the zooms this map actually reaches it was asking Core Graphics to
    /// interpolate a rectangle *millions of points across* to fill one 512-pixel
    /// tile — per tile, for a screenful of tiles, on every step of a pinch. That
    /// is the stutter and the memory spike that made these layers unpleasant to
    /// zoom even when every tile was arriving.
    ///
    /// So the patch is cut out of the ancestor first — the wanted region plus
    /// the margin, a handful of pixels at depth — and only the patch is
    /// magnified. The pixels that reach the tile are the same ones by the same
    /// filter; what changes is that the work no longer grows with how far in the
    /// map has gone.
    private func crop(
        _ image: UIImage,
        of ancestor: MKTileOverlayPath,
        to path: MKTileOverlayPath,
        depth: Int
    ) -> Data? {
        guard let source = image.cgImage, source.width > 0, source.height > 0 else { return nil }

        let size = tileSize
        let factor = CGFloat(1 << depth)

        // Where this tile sits inside its ancestor, in tiles...
        let column = CGFloat(path.x - (ancestor.x << depth))
        let row = CGFloat(path.y - (ancestor.y << depth))

        // ...and how much of the ancestor's own pixels that is. Below one pixel
        // at the deeper zooms, which is exactly why the margin matters.
        let across = CGFloat(source.width)
        let down = CGFloat(source.height)
        let window = across / factor
        let windowDown = down / factor

        let margin = Self.resampleMargin
        let wanted = CGRect(
            x: column * window - margin,
            y: row * windowDown - margin,
            width: window + margin * 2,
            height: windowDown + margin * 2
        )

        // Clipped to the ancestor at its edges, and rounded outwards to whole
        // pixels. Only the margin is ever lost to this — the tile's own region
        // is inside the ancestor by construction — so every tile still comes out
        // fully covered.
        let bounds = CGRect(x: 0, y: 0, width: across, height: down)
        let taken = wanted.intersection(bounds).integral
        guard !taken.isEmpty, let patch = source.cropping(to: taken) else { return nil }

        // Ancestor pixels to tile points.
        let scale = size.width / window
        let scaleDown = size.height / windowDown

        // Where the patch lands, given that it starts a margin's worth above and
        // to the left of the tile's own region.
        let destination = CGRect(
            x: (taken.minX - column * window) * scale,
            y: (taken.minY - row * windowDown) * scaleDown,
            width: taken.width * scale,
            height: taken.height * scaleDown
        )

        let format = UIGraphicsImageRendererFormat.default()
        // One pixel per point. The source has no more detail than this and an
        // @2x tile of magnified radar is twice the memory for none of it.
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)

        let tile = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            UIImage(cgImage: patch).draw(in: destination)
        }

        return tile.pngData()
    }

    /// The meter this layer's requests are counted against, or nil for a
    /// service that does not meter.
    ///
    /// NASA's GIBS has no quota, no key and no account. Rationing it would draw
    /// the cloud layer worse to protect an allowance that does not exist.
    private var budget: WeatherTileBudget? {
        tiles.layer == .satellite ? nil : WeatherTileBudget.rainViewer
    }

    /// One request, and a note to the service about how it went.
    ///
    /// The budget is asked first, and a request it turns down does not become a
    /// hole in the map: it is re-aimed at the tile cache instead, which answers
    /// for everything already seen and costs the service nothing. That is what
    /// makes a cooldown survivable — panning around during one still draws the
    /// ground you have already been over, rather than blanking the layer and
    /// asking the service to confirm the blanking, tile by tile.
    private func fetch(
        at path: MKTileOverlayPath,
        reportingFailures reports: Bool,
        completion: @escaping (Data?, Error?) -> Void
    ) {
        let address = url(forTilePath: path)
        let meter = budget
        let permitted = meter?.permits(address.absoluteString) ?? true
        // Held rather than read off `self` inside the callback: the overlay is
        // swapped on every frame of the animation, and a tile request that
        // outlives its overlay should not be what keeps it alive.
        let layer = tiles.layer

        var request = URLRequest(url: address)
        if !permitted {
            // Whatever is in the cache, and nothing over the wire. A miss here
            // completes with an error and no request made, which is exactly the
            // outcome wanted.
            request.cachePolicy = .returnCacheDataDontLoad
        }

        Self.session.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let isImage = (200..<300).contains(status) && (data?.isEmpty == false)

            // A request that was never made says nothing about the service. It
            // is not counted against it, and it never becomes the sentence over
            // the map explaining why the layer is empty — the budget's own
            // reason for holding back is already that sentence.
            if permitted {
                meter?.note(address: address.absoluteString, status: status, failed: !isImage)
                if reports {
                    RainViewerService.shared.noteTile(
                        status: status,
                        failed: !isImage,
                        zoom: path.z,
                        layer: layer
                    )
                }
            }

            guard isImage else {
                // MapKit wants one or the other, and an empty 200 is as much a
                // failure as a refusal — it just has no error to hand on.
                completion(nil, error ?? Self.refusal(status: status))
                return
            }

            completion(data, nil)
        }.resume()
    }

    private static func refusal(status: Int) -> Error {
        NSError(
            domain: "com.tracker.Inflight.tiles",
            code: status,
            userInfo: [NSLocalizedDescriptionKey: "The tile service returned \(status)."]
        )
    }
}
