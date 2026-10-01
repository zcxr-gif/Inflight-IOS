@_spi(Experimental) import MapboxMaps
import UIKit

/// The radar and the cloud imagery, as a Mapbox raster layer fed tile by tile.
///
/// ## Why the map does not fetch these itself
///
/// Mapbox will happily fetch a tile template on its own, and that would be the
/// end of every guard this layer has: RainViewer's free tier is a hundred
/// requests a minute per address, and the only thing standing between a pinch
/// across a dozen zooms and a tripped limiter is `WeatherTileBudget`, which a
/// map fetching for itself never consults. Nor would the service ever hear
/// whether its tiles were arriving, which is how the layer explains itself when
/// they are not.
///
/// So this is a *custom* raster source. Mapbox says which tiles it needs; the
/// tiles come from `WeatherTileLoader` — the same budget, the same caches, the
/// same reporting the drawn planet uses — and are handed back as images.
///
/// ## Why zooming in is free
///
/// The source is told where the service's tiles stop, and past that Mapbox
/// overscales the deepest ones on the GPU with linear filtering. A radar field
/// is a smooth field, so it stays one all the way in — no blocks, no request,
/// and nothing to resample on the CPU.
///
/// ## Why the animation does not blink
///
/// A new frame does not replace the source. It replaces the *tiles*, each one
/// as its new picture arrives, and the old picture stays on screen until then.
/// On the second pass round the loop every picture is already in the cache and
/// the swap is immediate; on the first, the map is never empty while it waits.
final class WeatherTileLayer {

    private struct TileKey: Hashable {
        let z: Int
        let x: Int
        let y: Int
    }

    private weak var map: MapboxMap?

    /// The tiles currently being served, and the loader serving them.
    private var loader: WeatherTileLoader?

    /// What the source on the map was built for — the layer and the depth it
    /// was told the service serves. A change to either rebuilds the source.
    private var installedShape: String?

    /// The tiles Mapbox has said it needs, by position.
    private var neededTiles: [TileKey: CanonicalTileID] = [:]

    /// Points the layer at a set of tiles, or takes it off the map.
    func show(_ tiles: MapWeatherTiles?, on map: MapboxMap) {
        self.map = map

        guard let tiles = tiles else {
            remove()
            return
        }

        let next = WeatherTileLoader(tiles: tiles)
        let shape = "\(tiles.layer.rawValue)|\(next.servedZoom)|\(Int(next.tileSize.width))"

        if installedShape != shape || !map.sourceExists(withId: MapLayerStyle.Source.weather) {
            remove()
            loader = next
            install(shape: shape, loader: next, on: map)
            return
        }

        guard loader?.key != next.key else { return }
        loader = next

        // A new frame: every tile on screen is asked for again from the new
        // frame, and replaced as it lands.
        for (key, id) in neededTiles {
            fetch(key, id: id, with: next)
        }
    }

    /// The style was reloaded underneath: the source and its layer went with
    /// it. The next `show` puts them back.
    func styleDidReload() {
        installedShape = nil
        neededTiles.removeAll()
    }

    // MARK: - The source

    private func install(shape: String, loader: WeatherTileLoader, on map: MapboxMap) {
        let client = CustomRasterSourceClient.fromCustomRasterSourceTileStatusChangedCallback { [weak self] tileID, status in
            // Called on a worker thread. Everything this layer holds lives on
            // the main one.
            DispatchQueue.main.async {
                self?.tile(tileID, changedTo: status)
            }
        }

        let options = CustomRasterSourceOptions(
            clientCallback: client,
            minZoom: 0,
            maxZoom: .init(loader.servedZoom),
            tileSize: .init(Int(loader.tileSize.width))
        )

        do {
            try map.addSource(CustomRasterSource(id: MapLayerStyle.Source.weather, options: options))
        } catch {
            NSLog("[Map] weather source could not be added: %@", String(describing: error))
            return
        }

        let opacity = MapWeatherSource.opacity(for: loader.layer)
        let layer: [String: Any] = [
            "id": MapLayerStyle.Layer.weather,
            "type": "raster",
            "source": MapLayerStyle.Source.weather,
            "slot": "middle",
            "paint": [
                "raster-opacity": Double(opacity),
                // A short cross-fade as each tile of a new frame lands, which
                // is what turns a frame change into an animation rather than a
                // flicker.
                "raster-fade-duration": 160,
                "raster-resampling": "linear",
            ] as [String: Any],
        ]

        do {
            try map.addLayer(with: MapLayerStyle.selfLit(layer), layerPosition: MapLayerStyle.weatherPosition(on: map))
        } catch {
            NSLog("[Map] weather layer could not be added: %@", String(describing: error))
            try? map.removeSource(withId: MapLayerStyle.Source.weather)
            return
        }

        installedShape = shape
    }

    private func remove() {
        guard let map = map else { return }
        if map.layerExists(withId: MapLayerStyle.Layer.weather) {
            try? map.removeLayer(withId: MapLayerStyle.Layer.weather)
        }
        if map.sourceExists(withId: MapLayerStyle.Source.weather) {
            try? map.removeSource(withId: MapLayerStyle.Source.weather)
        }
        installedShape = nil
        neededTiles.removeAll()
        loader = nil
    }

    // MARK: - Tiles

    private func tile(_ id: CanonicalTileID, changedTo status: CustomRasterSourceTileStatus) {
        let key = TileKey(z: Int(id.z), x: Int(id.x), y: Int(id.y))

        switch status {
        case .required:
            guard neededTiles[key] == nil else { return }
            neededTiles[key] = id
            if let loader = loader { fetch(key, id: id, with: loader) }

        case .notNeeded, .optional:
            // Handed back so Mapbox can let go of the picture; the tile cache
            // keeps the bytes, so needing it again costs no request.
            guard neededTiles.removeValue(forKey: key) != nil else { return }
            try? map?.setCustomRasterSourceTileData(
                forSourceId: MapLayerStyle.Source.weather,
                // Typed, because a bare nil also fits the core library's own
                // initialiser and the compiler will not choose between them.
                tiles: [CustomRasterSourceTileData(tileId: id, image: nil as UIImage?)]
            )

        default:
            break
        }
    }

    private func fetch(_ key: TileKey, id: CanonicalTileID, with loader: WeatherTileLoader) {
        loader.loadTile(at: WeatherTilePath(x: key.x, y: key.y, z: key.z)) { [weak self] data, _ in
            // Decoded here, off the main thread, where the bytes arrived.
            let image = data.flatMap(UIImage.init(data:))

            DispatchQueue.main.async {
                guard let self = self, let image = image else { return }
                // A frame that has moved on, or a tile that has scrolled away
                // while this one was in the air, is a picture nobody wants.
                guard self.loader === loader, self.neededTiles[key] != nil else { return }
                try? self.map?.setCustomRasterSourceTileData(
                    forSourceId: MapLayerStyle.Source.weather,
                    tiles: [CustomRasterSourceTileData(tileId: id, image: image)]
                )
            }
        }
    }
}
