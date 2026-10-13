import CoreImage
import SwiftUI
import UIKit

/// A photograph drawn blurred — blurred once, small, and scaled up, rather
/// than blurred by the GPU on every frame that composites it.
///
/// `.blur` on an image is a filter, and Core Animation applies a filter every
/// time it composites the screen, whether or not the picture under it changed.
/// Behind the flight window that is every frame: the map underneath is
/// animating at sixty or a hundred and twenty a second, so the window's photo
/// was re-blurred at that rate for as long as the window was up. Blurred once
/// here instead, it is an ordinary bitmap to the compositor. A blur has no fine
/// detail to lose, so a copy a few dozen pixels across, scaled up, is the same
/// picture.
///
/// Until that copy is ready — the first frame or two — it is the live blur, as
/// before. Once there is a copy of this photograph, it stays up while a new one
/// is made for a changed size, so a window being pulled never flickers between
/// the two.
struct PreBlurredImage: View {

    let image: UIImage

    /// The blur, in points, as drawn.
    let radius: CGFloat

    /// How many points the picture's shorter side is drawn across — what the
    /// radius is relative to.
    let shortSide: CGFloat

    @State private var made: Made?

    private struct Made {
        /// Held, not just named, so the photograph it was made from cannot be
        /// freed and another take its address.
        let source: UIImage
        let relative: Int
        let image: UIImage
    }

    private struct Key: Equatable {
        let source: ObjectIdentifier
        let relative: Int
    }

    /// The radius as a share of the shorter side, in thousandths, in steps of
    /// five — so a window being resized asks for a new copy every so often
    /// rather than on every frame.
    private var relative: Int {
        let thousandths = radius / max(shortSide, 1) * 1000
        return max(Int((thousandths / 5).rounded()) * 5, 5)
    }

    var body: some View {
        let wanted = relative
        Group {
            if let made, made.source === image {
                Image(uiImage: made.image)
                    .resizable()
                    .interpolation(.medium)
                    .scaledToFill()
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: radius, opaque: true)
            }
        }
        .task(id: Key(source: ObjectIdentifier(image), relative: wanted)) {
            if let made, made.source === image, made.relative == wanted { return }
            let source = image
            guard let blurred = await Self.blurred(source, relative: CGFloat(wanted) / 1000),
                  !Task.isCancelled
            else { return }
            made = Made(source: source, relative: wanted, image: blurred)
        }
    }

    /// The shorter side of a picture scaled to fill a frame, in points.
    static func filledShortSide(of image: UIImage, in frame: CGSize) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return max(min(frame.width, frame.height), 1) }
        let scale = max(frame.width / size.width, frame.height / size.height)
        return min(size.width, size.height) * scale
    }

    // MARK: - Making the copy

    /// The copy's shorter side, in pixels.
    private static let copySide: CGFloat = 64

    private static let context = CIContext(options: [.cacheIntermediates: false])

    private static func blurred(_ image: UIImage, relative: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.make(image, relative: relative))
            }
        }
    }

    /// Shrunk to `copySide` across, then blurred by the same share of that as
    /// the radius is of the side drawn. Edges clamped, as `opaque: true` does,
    /// so it does not fade to nothing at the frame.
    private static func make(_ image: UIImage, relative: CGFloat) -> UIImage? {
        // Only a picture the right way up: every photograph this is handed is
        // decoded upright (see `DecodedImage`), and one that is not keeps the
        // live blur rather than being drawn on its side.
        guard image.imageOrientation == .up, let cgImage = image.cgImage else { return nil }
        let shortSide = CGFloat(min(cgImage.width, cgImage.height))
        guard shortSide > 0 else { return nil }

        var picture = CIImage(cgImage: cgImage)
        let scale = min(copySide / shortSide, 1)
        if scale < 1 {
            picture = picture.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: 1,
            ])
        }
        let extent = picture.extent.integral
        let sigma = Double(relative * shortSide * scale)
        let output = picture
            .clampedToExtent()
            .applyingGaussianBlur(sigma: sigma)
            .cropped(to: extent)

        guard let rendered = context.createCGImage(output, from: extent) else { return nil }
        return UIImage(cgImage: rendered)
    }
}
