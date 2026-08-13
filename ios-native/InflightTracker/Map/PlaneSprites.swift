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
    func icon(forKey key: String, selected: Bool) -> UIImage? {
        let resolvedKey = selected && uvs["\(key)_S"] != nil ? "\(key)_S" : key
        if let cached = cache[resolvedKey] { return cached }

        guard let sheet = sheet,
              let uv = uvs[resolvedKey], uv.count == 4,
              let cropped = crop(sheet: sheet, uv: uv) else { return nil }

        let image = pad(cropped)
        cache[resolvedKey] = image
        return image
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
