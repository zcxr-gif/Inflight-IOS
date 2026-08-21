import UIKit

/// Draws an aircraft mark into a bitmap.
///
/// The artwork is vector, so an icon is rendered at the size and colour it is
/// actually wanted at rather than cut out of a fixed-resolution sheet — which
/// is what made the old sprites soft on a 3x screen, and what made recolouring
/// one a matter of flattening it to a single flat blob.
///
/// Every mark is drawn twice: once fat in the outline colour, then again in the
/// body colour on top. That is what puts a consistent halo around the whole
/// silhouette — including around the cut-outs an evenodd shape carries — so an
/// aircraft reads on imagery, on a light map and on a dark one without the
/// artwork having to carry an outline of its own.
enum PlaneIconRenderer {

    /// Outline thickness, in points. Wide enough to hold the shape together on
    /// a busy satellite tile, fine enough that a light aircraft is still a
    /// light aircraft rather than a blob — which is a finer line than it sounds
    /// at the size these are drawn, since the outline is a fixed width and the
    /// smallest marks are only a dozen points across.
    static let outlineWidth: CGFloat = 0.9

    /// Drop shadow under the icon, so traffic sits above the map rather than
    /// in it.
    private static let shadowOpacity: CGFloat = 0.35
    private static let shadowBlur: CGFloat = 1.6

    struct Mark {
        let parts: [PlaneArtwork.Part]
        /// Size relative to the rest of the fleet. A 380 draws bigger than a
        /// Cessna, which is the one thing a single normalised sprite size
        /// cannot tell you.
        let scale: CGFloat
        /// Colour the mark insists on, whatever the traffic palette says.
        /// Only the airport pins use it.
        var body: UIColor?
    }

    /// - Parameters:
    ///   - pointSize: the longest side of the drawing, before `mark.scale`.
    ///   - canvas: the bitmap to centre it in. Larger than `pointSize` for
    ///     aircraft, so the annotation stays easy to tap while the aircraft
    ///     itself stays small.
    static func image(
        _ mark: Mark,
        pointSize: CGFloat,
        canvas: CGSize,
        body: UIColor,
        outline: UIColor,
        shadow: Bool
    ) -> UIImage? {
        let paths = mark.parts.map { (path: PlanePath.path(from: $0.path), evenOdd: $0.evenOdd) }
        let bounds = paths.reduce(CGRect.null) { $0.union($1.path.boundingBoxOfPath) }
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let side = pointSize * mark.scale
        let scale = side / max(bounds.width, bounds.height)
        let fill = mark.body ?? body

        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false

        let flat = UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            let cgContext = context.cgContext
            cgContext.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            cgContext.scaleBy(x: scale, y: scale)
            cgContext.translateBy(x: -bounds.midX, y: -bounds.midY)

            // The outline is a stroke in drawing units, so it has to be widened
            // back out by however far the drawing was scaled down.
            cgContext.setLineWidth(outlineWidth * 2 / scale)
            cgContext.setLineJoin(.round)
            cgContext.setLineCap(.round)
            cgContext.setStrokeColor(outline.cgColor)
            cgContext.setFillColor(outline.cgColor)
            for part in paths {
                cgContext.addPath(part.path)
                cgContext.drawPath(using: part.evenOdd ? .eoFillStroke : .fillStroke)
            }

            cgContext.setFillColor(fill.cgColor)
            for part in paths {
                cgContext.addPath(part.path)
                cgContext.drawPath(using: part.evenOdd ? .eoFill : .fill)
            }
        }

        guard shadow else { return flat }

        // Shadowed in a second pass over the finished mark rather than per
        // path: shadowing each piece as it is drawn would shade the pieces
        // drawn under it, which reads as dirt inside the silhouette.
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 0.5),
                blur: shadowBlur,
                color: UIColor.black.withAlphaComponent(shadowOpacity).cgColor
            )
            flat.draw(at: .zero)
        }
    }
}
