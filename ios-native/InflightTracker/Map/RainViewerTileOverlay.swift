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

final class RainViewerTileOverlay: MKTileOverlay {

    /// How deep the free tier serves.
    ///
    /// RainViewer's published schedule takes free users to zoom 7 from January
    /// 2026, having been 10 since September 2025. Set to the lower of the two
    /// deliberately: `MKTileOverlay` scales a coarse tile up to fill a closer
    /// zoom, so asking too shallow costs sharpness, while asking too deep gets
    /// a 404 and draws *nothing* — and a weather layer that vanishes when you
    /// zoom in is a bug report, where a soft one is a known limit.
    static let maximumFreeZoom = 7

    /// RainViewer's colour schemes, by number. Four is the one that reads as
    /// weather radar to anybody who has seen a forecast; satellite has to be
    /// zero, which is the only scheme its data is served in.
    private static let radarColourScheme = 4
    private static let satelliteColourScheme = 0

    private let tiles: MapWeatherTiles

    init(tiles: MapWeatherTiles) {
        self.tiles = tiles
        super.init(urlTemplate: nil)

        // The map underneath still has to be readable through it: this draws
        // over the basemap, not instead of it.
        canReplaceMapContent = false
        minimumZ = 0
        maximumZ = Self.maximumFreeZoom
        tileSize = CGSize(width: 256, height: 256)
    }

    var key: String { tiles.key }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let colour = tiles.layer == .satellite
            ? Self.satelliteColourScheme
            : Self.radarColourScheme

        // Smoothing on for radar, which is a field rather than a set of
        // pixels; snow shown in its own colours. Satellite takes neither, and
        // the service requires both to be zero for it.
        let options = tiles.layer == .satellite ? "0_0" : "1_1"

        let string = """
        \(tiles.host)\(tiles.frame.path)/\(Int(tileSize.width))\
        /\(path.z)/\(path.x)/\(path.y)/\(colour)/\(options).png
        """

        // `MKTileOverlay` demands a URL rather than an optional, and the only
        // way this string fails to be one is a host the service invented. A
        // URL that resolves to nothing draws nothing, which is the same
        // outcome and reached without a crash.
        return URL(string: string) ?? URL(string: "https://tilecache.rainviewer.com/")!
    }
}
