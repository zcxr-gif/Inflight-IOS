import SwiftUI
import UIKit
import simd

/// The planet itself: the sphere, every country's outline, the graticule, and
/// the traffic on it.
///
/// A `UIView` drawing into Core Graphics rather than a SwiftUI `Canvas`. Ten
/// thousand border points and a packet of traffic, redrawn while a finger is
/// moving, is more per-frame command recording than a `Canvas` wants to carry —
/// and all of it is stroked paths, which is what `CGContext` is fastest at.
///
/// Everything with a label on it is deliberately *not* drawn here. Airports are
/// SwiftUI views laid over this one, positioned by the same `GlobeCamera`: text
/// and hit targets are what SwiftUI is good at and what a `draw(_:)` is worst
/// at.
struct GlobeCanvas: UIViewRepresentable {

    var camera: GlobeCamera
    var palette: GlobePalette

    /// Where the traffic is, already narrowed by the filters. Positions only —
    /// a dot on a planet has no room to say anything else.
    var traffic: [GlobeTrafficDot]

    func makeUIView(context: Context) -> GlobeCanvasView {
        let view = GlobeCanvasView()
        view.isOpaque = false
        view.backgroundColor = .clear
        // Redrawn rather than scaled, so a border is a sharp hairline at any
        // zoom instead of a stretched bitmap.
        view.contentMode = .redraw
        return view
    }

    func updateUIView(_ view: GlobeCanvasView, context: Context) {
        view.apply(camera: camera, palette: palette, traffic: traffic)
    }
}

/// One aircraft, as much of it as a dot can carry.
struct GlobeTrafficDot: Equatable {

    let position: SIMD3<Float>

    /// What it is painted, when the pilot colouring has an opinion — your own
    /// aeroplane, or somebody you watch. Nil is ordinary traffic.
    let tint: UIColor?

    /// Whether it is the aircraft whose window is open, which is drawn larger
    /// and over the rest.
    let isOpen: Bool
}

final class GlobeCanvasView: UIView {

    private var camera = GlobeCamera()
    private var palette = GlobePalette.night
    private var traffic: [GlobeTrafficDot] = []

    func apply(camera: GlobeCamera, palette: GlobePalette, traffic: [GlobeTrafficDot]) {
        // The traffic array is the expensive comparison and the one most likely
        // to be equal — a packet lands every few seconds where the camera moves
        // every frame — so the cheap fields are checked first.
        let unchanged = camera == self.camera
            && palette == self.palette
            && traffic == self.traffic
        guard !unchanged else { return }

        self.camera = camera
        self.palette = palette
        self.traffic = traffic
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), camera.radius > 0 else { return }

        let basis = camera.basis

        drawSphere(in: context)
        drawRings(GlobeGeometry.graticule, in: context, basis: basis,
                  color: palette.graticule, width: palette.graticuleWidth)
        drawRings(GlobeGeometry.borders, in: context, basis: basis,
                  color: palette.border, width: palette.borderWidth)
        drawLimb(in: context)
        drawTraffic(in: context, basis: basis)
    }

    private var discBox: CGRect {
        CGRect(
            x: camera.center.x - camera.radius,
            y: camera.center.y - camera.radius,
            width: camera.radius * 2,
            height: camera.radius * 2
        )
    }

    // MARK: - The planet

    private func drawSphere(in context: CGContext) {
        context.setFillColor(palette.ocean.cgColor)
        context.fillEllipse(in: discBox)
    }

    /// The thin bright edge where the planet meets space.
    ///
    /// Drawn over the cartography rather than under it, so outlines running to
    /// the limb are finished by a clean arc instead of by whatever the clipper
    /// left within half a pixel of it.
    private func drawLimb(in context: CGContext) {
        context.setStrokeColor(palette.limb.cgColor)
        context.setLineWidth(palette.limbWidth)
        context.strokeEllipse(
            in: discBox.insetBy(dx: palette.limbWidth / 2, dy: palette.limbWidth / 2)
        )
    }

    // MARK: - Lines on it

    /// Every ring, clipped at the horizon.
    ///
    /// The clipping is the part worth being careful about. A segment with one
    /// end on the near side and the other round the back has to stop at the
    /// limb; drawn straight through it becomes a chord across the planet, and
    /// with a coastline's worth of them the globe looks shattered.
    private func drawRings(
        _ rings: [GlobeGeometry.Ring],
        in context: CGContext,
        basis: GlobeCamera.Basis,
        color: UIColor,
        width: CGFloat
    ) {
        guard width > 0 else { return }

        let path = CGMutablePath()
        for ring in rings {
            append(ring, to: path, basis: basis)
        }

        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
    }

    private func append(_ ring: GlobeGeometry.Ring, to path: CGMutablePath, basis: GlobeCamera.Basis) {
        // Wholly round the back: one dot product for an entire country.
        //
        // Only sound for a ring that fits inside a hemisphere, which is what a
        // positive `radiusCosine` means. A ring larger than that — a meridian,
        // which wraps the planet — has no direction the camera can point away
        // from far enough, and the test would cull it wrongly.
        if ring.radiusCosine > 0 {
            let facing = simd_dot(ring.axis, basis.out)
            let reach = (1 - ring.radiusCosine * ring.radiusCosine).squareRoot()
            if facing < -reach { return }
        }

        var previousVector: SIMD3<Float>?
        var previous: GlobeCamera.Projected?
        var isDrawing = false

        for point in ring.points {
            let now = camera.project(point, using: basis)

            guard let lastVector = previousVector, let last = previous else {
                if now.isVisible {
                    path.move(to: now.point)
                    isDrawing = true
                }
                previousVector = point
                previous = now
                continue
            }

            switch (last.isVisible, now.isVisible) {
            case (true, true):
                if !isDrawing {
                    path.move(to: last.point)
                    isDrawing = true
                }
                path.addLine(to: now.point)

            case (true, false):
                if !isDrawing {
                    path.move(to: last.point)
                    isDrawing = true
                }
                path.addLine(to: horizonCrossing(
                    near: last, far: now, nearVector: lastVector, farVector: point, basis: basis
                ))
                isDrawing = false

            case (false, true):
                path.move(to: horizonCrossing(
                    near: now, far: last, nearVector: point, farVector: lastVector, basis: basis
                ))
                path.addLine(to: now.point)
                isDrawing = true

            case (false, false):
                isDrawing = false
            }

            previousVector = point
            previous = now
        }
    }

    /// Where the segment between two directions crosses the horizon.
    ///
    /// The two directions are blended by their depths and renormalised, which
    /// is the point on the sphere between them at the crossing — accurate to
    /// well under a pixel at any radius the globe allows, and two multiplies
    /// rather than a great-circle solve.
    private func horizonCrossing(
        near: GlobeCamera.Projected,
        far: GlobeCamera.Projected,
        nearVector: SIMD3<Float>,
        farVector: SIMD3<Float>,
        basis: GlobeCamera.Basis
    ) -> CGPoint {
        let span = near.depth - far.depth
        guard span > 1e-6 else { return near.point }

        let t = near.depth / span
        let blended = simd_normalize(nearVector + (farVector - nearVector) * t)
        return camera.project(blended, using: basis).point
    }

    // MARK: - Traffic

    private func drawTraffic(in context: CGContext, basis: GlobeCamera.Basis) {
        guard !traffic.isEmpty else { return }

        // Grouped by colour, so a packet of three thousand aircraft is a
        // handful of fills rather than one state change apiece.
        var byTint: [UIColor: CGMutablePath] = [:]
        var open: [CGPoint] = []
        let size = palette.dotRadius

        for dot in traffic {
            let projected = camera.project(dot.position, using: basis)
            guard projected.isVisible else { continue }

            if dot.isOpen {
                open.append(projected.point)
                continue
            }

            let colour = dot.tint ?? palette.traffic
            let path = byTint[colour] ?? CGMutablePath()
            path.addEllipse(in: CGRect(
                x: projected.point.x - size,
                y: projected.point.y - size,
                width: size * 2,
                height: size * 2
            ))
            byTint[colour] = path
        }

        for (colour, path) in byTint {
            context.setFillColor(colour.cgColor)
            context.addPath(path)
            context.fillPath()
        }

        // The open aircraft last and larger, with a ring round it, so it is
        // findable in a packet of three thousand.
        for point in open {
            let outer = size * 3
            context.setStrokeColor(palette.openTraffic.cgColor)
            context.setLineWidth(1.5)
            context.strokeEllipse(in: CGRect(
                x: point.x - outer, y: point.y - outer,
                width: outer * 2, height: outer * 2
            ))
            context.setFillColor(palette.openTraffic.cgColor)
            context.fillEllipse(in: CGRect(
                x: point.x - size * 1.4, y: point.y - size * 1.4,
                width: size * 2.8, height: size * 2.8
            ))
        }
    }
}
