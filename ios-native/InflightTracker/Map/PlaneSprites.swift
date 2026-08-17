import UIKit

/// Cuts individual plane icons out of the sprite sheet shipped with the app.
///
/// `markers.png` and `sprite-uvs.json` are copied straight from the web
/// tracker, so the aircraft on this map are pixel-for-pixel the icons the old
/// build used. The UV table stores `[x, y, width, height]` as ratios of the
/// sheet, exactly as `loadSpriteSheetAndGenerateIcons()` consumed them.
///
/// All access happens on the main thread (MapKit delegate callbacks and
/// SwiftUI body evaluation).
final class PlaneSprites {

    static let shared = PlaneSprites()

    private let sheet: CGImage?
    private let uvs: [String: [Double]]
    private var cache: [String: UIImage] = [:]

    private init() {
        if let url = Bundle.main.url(forResource: "markers", withExtension: "png"),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            sheet = image.cgImage
        } else {
            sheet = nil
        }

        if let url = Bundle.main.url(forResource: "sprite-uvs", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: [Double]].self, from: data) {
            uvs = decoded
        } else {
            uvs = [:]
        }
    }

    /// Whether the sprite sheet and its UV table both loaded. Used by the
    /// status strip so a packaging mistake is visible instead of silent.
    var isReady: Bool { sheet != nil && !uvs.isEmpty }

    /// Icon for an aircraft, padded into a larger transparent canvas so the
    /// annotation stays easy to tap while the plane itself stays small.
    /// `selected` swaps in the sheet's `_S` highlight variant.
    ///
    /// `tint` repaints the icon in one flat colour, for the aircraft the user
    /// has asked to pick out — their own, and the pilots they watch. It is a
    /// silhouette rather than a wash: the sprites carry their own liveries, and
    /// a colour laid over one is neither the livery nor the colour. The whole
    /// point is to be findable at a glance in a screen full of traffic, which a
    /// solid shape is and a tinted photograph is not. This is also what the web
    /// build did — Mapbox recoloured the icon outright.
    func icon(forKey key: String, selected: Bool, tint: UIColor? = nil) -> UIImage? {
        let resolvedKey = selected && uvs["\(key)_S"] != nil ? "\(key)_S" : key

        // Tinted icons are cached under their own colour, so the untinted sheet
        // is never evicted by somebody cycling through colour choices.
        let cacheKey = tint.map { "\(resolvedKey)|\($0.tintCacheKey)" } ?? resolvedKey
        if let cached = cache[cacheKey] { return cached }

        guard let sheet = sheet,
              let uv = uvs[resolvedKey], uv.count == 4,
              let cropped = crop(sheet: sheet, uv: uv) else { return nil }

        var image = pad(cropped)
        if let tint = tint { image = Self.painted(image, in: tint) }

        cache[cacheKey] = image
        return image
    }

    /// The icon's own shape, filled flat.
    ///
    /// Drawn as colour-then-`destinationIn` rather than with a template
    /// rendering mode: an `MKAnnotationView` takes a plain `UIImage` and has no
    /// tint colour to resolve a template against, so the colour has to be baked
    /// into the bitmap.
    private static func painted(_ image: UIImage, in color: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = false

        return UIGraphicsImageRenderer(size: image.size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: image.size)
            color.setFill()
            context.fill(bounds)
            image.draw(in: bounds, blendMode: .destinationIn, alpha: 1)
        }
    }

    private func crop(sheet: CGImage, uv: [Double]) -> CGImage? {
        let sheetWidth = CGFloat(sheet.width)
        let sheetHeight = CGFloat(sheet.height)

        let rect = CGRect(
            x: (CGFloat(uv[0]) * sheetWidth).rounded(.down),
            y: (CGFloat(uv[1]) * sheetHeight).rounded(.down),
            width: (CGFloat(uv[2]) * sheetWidth).rounded(.down),
            height: (CGFloat(uv[3]) * sheetHeight).rounded(.down)
        )

        guard rect.width >= 1, rect.height >= 1,
              rect.maxX <= sheetWidth, rect.maxY <= sheetHeight else { return nil }

        return sheet.cropping(to: rect)
    }

    private func pad(_ cropped: CGImage) -> UIImage {
        let canvas = CGSize(width: AppConfig.iconCanvasSize, height: AppConfig.iconCanvasSize)
        let side = AppConfig.iconPointSize
        let target = CGRect(
            x: (canvas.width - side) / 2,
            y: (canvas.height - side) / 2,
            width: side,
            height: side
        )

        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            UIImage(cgImage: cropped).draw(in: target)
        }
    }
}

extension UIColor {

    /// A short, stable string for this colour, for use in a cache key.
    ///
    /// Rounded to the nearest 1/255 on purpose: colours arrive here from a
    /// `Color` round-tripped through user defaults, and two that are a
    /// floating-point hair apart are the same colour to look at. Without the
    /// rounding a slider drag would mint a new cache entry per frame.
    var tintCacheKey: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return description
        }
        let scale = { (value: CGFloat) in Int((value * 255).rounded()) }
        return "\(scale(red)),\(scale(green)),\(scale(blue)),\(scale(alpha))"
    }
}
