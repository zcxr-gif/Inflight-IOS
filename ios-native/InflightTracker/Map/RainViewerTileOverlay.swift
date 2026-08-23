import MapKit

/// One frame of weather, as map tiles.
///
/// `MKTileOverlay` handles the fetching, the caching and the scaling; all this
/// has to do is say where a tile lives. The URL shape is RainViewer's, and it
/// is documented in `old/www/rainviewer.txt`:
///
///     {host}{path}/{size}/{z}/{x}/{y}/{colour}/{smooth}_{snow}.png
struct MapWeatherTiles: Equatable {

    let host: String
    let frame: RainViewerService.Frame
    let layer: MapWeatherLayer

    /// Identity for the map's diff: the frame's path already changes with
    /// every frame and every layer serves different paths, so this is enough
    /// to say "the tiles on screen are the wrong ones".
    var key: String { "\(layer.rawValue)|\(host)\(frame.path)" }
}

/// The tiles for whichever weather layer is on.
///
/// Two services behind one overlay: RainViewer's radar frames, and NASA's
/// daily satellite composites. They agree on nothing except that a tile is a
/// 256-pixel PNG or JPEG at a z/x/y — so this builds each one's URL its own
/// way and everything above it stays the same.
final class RainViewerTileOverlay: MKTileOverlay {

    /// RainViewer's colour schemes, by number. Four is the one that reads as
    /// weather radar to anybody who has seen a forecast.
    private static let radarColourScheme = 4

    private let tiles: MapWeatherTiles

    init(tiles: MapWeatherTiles) {
        self.tiles = tiles
        super.init(urlTemplate: nil)

        // The map underneath still has to be readable through it: this draws
        // over the basemap, not instead of it.
        canReplaceMapContent = false
        minimumZ = 0
        maximumZ = MapWeatherSource.maximumZoom(for: tiles.layer)
        tileSize = CGSize(width: 256, height: 256)
    }

    var key: String { tiles.key }

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

    /// Fetches a tile, and says what came back.
    ///
    /// `MKTileOverlay` will do this itself, and did — but it swallows the
    /// answer. A tier that has been withdrawn serves the index listing the
    /// frames and then refuses every image, and the map's own version of that
    /// is a layer switched on, drawing nothing, explaining nothing. Everything
    /// here is what the base class does; the only addition is telling the
    /// service whether the request actually produced a tile.
    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, Error?) -> Void
    ) {
        let request = URLRequest(url: url(forTilePath: path))

        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let isImage = (200..<300).contains(status) && (data?.isEmpty == false)

            RainViewerService.shared.noteTile(status: status, failed: !isImage)

            guard isImage else {
                // MapKit wants one or the other, and an empty 200 is as much a
                // failure as a refusal — it just has no error to hand on.
                result(nil, error ?? Self.refusal(status: status))
                return
            }

            result(data, nil)
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
