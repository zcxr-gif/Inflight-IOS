import UIKit

/// A meteorological wind barb, drawn the way a chart draws one.
///
/// The staff points along the direction the wind is coming *from* — so a barb
/// leaning north-west is a north-westerly — and the feathers sit at the far
/// end of it: a filled pennant for each fifty knots, a full feather for each
/// ten, and a half feather for the last five. A circle on its own is calm.
///
/// Drawn as a path rather than as a rotated arrow glyph because the feathers
/// *are* the reading: an arrow would need a number beside it to say anything,
/// and this says it in the shape.
///
/// On the map each barb is a symbol: the glyph is rendered once per five knots
/// pointing north, and Mapbox turns it to the wind's direction on the GPU —
/// against the map rather than the screen, so it stays true on a spun globe.
enum WindBarbGlyph {

    /// Length of the staff, before any feathers.
    private static let staff: CGFloat = 26

    /// The side of the square a barb is drawn in, in points.
    static let side: CGFloat = 78

    /// Cool grey-blue: legible on land, on water and on imagery, and nothing
    /// like the colours the traffic or the routes are drawn in.
    static let colour = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.10, green: 0.25, blue: 0.42, alpha: 0.92)
            : UIColor(red: 0.72, green: 0.86, blue: 1.00, alpha: 0.92)
    }

    /// The speed a barb is drawn at, rounded to the five knots a barb can say.
    static func bucket(forKnots knots: Double) -> Int {
        guard knots.isFinite else { return 0 }
        return min(Int((max(knots, 0) / 5).rounded()) * 5, 400)
    }

    /// A barb for one five-knot bucket, pointing north, with its shadow baked
    /// in — rendered once and handed to the map as a symbol image.
    static func image(knots bucket: Int, isLight: Bool) -> UIImage {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let shape = path(speedKnots: Double(bucket), directionDegrees: 0, in: bounds)
        let ink = colour.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: isLight ? .light : .dark)
        )

        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            let cg = context.cgContext
            // The map underneath is anything from ocean to imagery, so the
            // barb carries its own separation from it.
            cg.setShadow(offset: .zero, blur: 4, color: UIColor.black.withAlphaComponent(0.6).cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.setLineWidth(1.6)
            cg.setStrokeColor(ink.cgColor)
            cg.setFillColor(ink.cgColor)
            cg.addPath(shape.cgPath)
            // Filled pennants need a fill; everything else is stroke only, and
            // a closed pennant filled in the same colour reads as solid.
            cg.drawPath(using: .fillStroke)
        }
    }

    /// The barb, in the view's own coordinates, already rotated.
    ///
    /// Built as a path rather than by rotating the layer so the pennants stay
    /// filled triangles rather than sheared ones, and so the whole thing is one
    /// shape with one shadow.
    ///
    /// Shared with the planet, which draws its own barbs into a `CGContext`:
    /// a barb that means fifty knots on one shape of the world and something
    /// else on the other is not a chart symbol at all.
    static func path(
        speedKnots: Double,
        directionDegrees: Double,
        in bounds: CGRect
    ) -> UIBezierPath {
        let path = UIBezierPath()
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let speed = speedKnots.isFinite ? max(speedKnots, 0) : 0

        // Under three knots there is nothing to point: a ring is the chart
        // symbol for calm, and it says "measured, and it is nothing" where an
        // absent barb would say "not measured".
        guard speed >= 3 else {
            path.append(UIBezierPath(arcCenter: centre, radius: 4, startAngle: 0, endAngle: .pi * 2, clockwise: true))
            return path
        }

        // Screen direction of the staff: the wind's origin. North is up, and
        // y grows downward.
        let radians = (directionDegrees.isFinite ? directionDegrees : 0) * .pi / 180
        let along = CGPoint(x: CGFloat(sin(radians)), y: CGFloat(-cos(radians)))
        // The feathers hang off one side of the staff, square to it.
        let across = CGPoint(x: -along.y, y: along.x)

        let tip = CGPoint(x: centre.x + along.x * staff, y: centre.y + along.y * staff)
        path.move(to: centre)
        path.addLine(to: tip)

        // Rounded to the nearest five, which is the resolution a barb has.
        var remaining = Int((speed / 5).rounded()) * 5
        // Distance back down the staff from the tip, so the feathers stack
        // from the far end inwards the way a chart draws them.
        var offset: CGFloat = 0
        let spacing: CGFloat = 5
        let feather: CGFloat = 11

        func point(at distance: CGFloat, out: CGFloat) -> CGPoint {
            CGPoint(
                x: tip.x - along.x * distance + across.x * out,
                y: tip.y - along.y * distance + across.y * out
            )
        }

        while remaining >= 50 {
            // A filled triangle: two sides drawn, closed back along the staff.
            path.move(to: point(at: offset, out: 0))
            path.addLine(to: point(at: offset + spacing, out: feather))
            path.addLine(to: point(at: offset + spacing * 2, out: 0))
            path.close()
            remaining -= 50
            offset += spacing * 2 + 1
        }

        while remaining >= 10 {
            path.move(to: point(at: offset, out: 0))
            path.addLine(to: point(at: offset + spacing, out: feather))
            remaining -= 10
            offset += spacing
        }

        if remaining >= 5 {
            // A half feather, and it never sits at the very tip — a lone five
            // knots is drawn one step in, so it cannot be misread as a full
            // one that failed to draw.
            if offset == 0 { offset = spacing }
            path.move(to: point(at: offset, out: 0))
            path.addLine(to: point(at: offset + spacing / 2, out: feather / 2))
        }

        return path
    }
}
