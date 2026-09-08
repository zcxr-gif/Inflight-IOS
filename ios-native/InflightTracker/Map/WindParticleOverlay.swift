import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// How the moving air is drawn.
enum WindParticleStyle {

    /// How many frames of history each streak carries.
    ///
    /// This, and not a length, is what makes a streak say how fast the air is:
    /// every particle draws the same *duration* of its own past, so a hundred
    /// and eighty knots is a long comet and twenty is a dot. Set a length
    /// instead and every streak is the same, and the layer stops carrying any
    /// information that the barbs were not already carrying.
    static let trail = 8

    /// How often the field is stepped.
    ///
    /// Well under the display's rate on purpose. Air is not a sixty-hertz
    /// phenomenon, every step dirties the whole overlay, and the difference
    /// between twenty-four and sixty here is entirely a difference in how much
    /// of the phone the layer is using.
    static let stepsPerSecond: Double = 24

    /// Roughly one particle per this many square points of screen.
    ///
    /// Density is set against the *screen* rather than the world, so a phone
    /// and an iPad look alike and pulling back does not thin the field out
    /// into nothing.
    static let pointsPerParticle: Double = 780
    static let fewestParticles = 260
    static let mostParticles = 1_500

    /// How long a particle lives, in steps, before it is retired and put back
    /// somewhere else.
    ///
    /// Without a lifetime every particle eventually ends up in whatever
    /// convergence the field has — a low, a col, the edge — and the map slowly
    /// empties everywhere else. A spread of lifetimes rather than one, so they
    /// do not all go at once and pulse.
    static let shortestLife = 45
    static let longestLife = 130

    /// How wide a streak is drawn, in points.
    static let width: CGFloat = 1.35

    /// What a hundred knots covers in a second, as a fraction of the screen.
    ///
    /// The one deliberate lie on this layer, and worth being plain about: at
    /// true speed a jet stream crosses a continental view in about eleven
    /// hours, which is not an animation. So the clock is scaled to whatever
    /// the map is showing, and what survives the scaling is the thing actually
    /// worth reading — the *ratios*. Fast air still moves visibly faster than
    /// slow air, the shear across a jet still shows as a shear, and no single
    /// streak is a claim about how long anything takes.
    static let screensPerSecondAt100kt: Double = 1.0 / 11

    /// Streaks, in the two schemes.
    ///
    /// Nearly white on a dark map and nearly black on a light one, both with a
    /// lean towards blue. Deliberately not a hue: the flown path already spends
    /// the map's colour budget on height, the heat layer under this one spends
    /// what is left on magnitude, and a third code would leave a screen with
    /// three legends on it. Direction and motion are what these carry, and
    /// neither needs a colour.
    static func colour(for scheme: ColorScheme) -> UIColor {
        scheme == .light
            ? UIColor(red: 0.10, green: 0.16, blue: 0.26, alpha: 0.62)
            : UIColor(red: 0.86, green: 0.94, blue: 1.00, alpha: 0.78)
    }
}

// ---------------------------------------------------------------------------

/// The particles themselves: where they are, and how they got there.
///
/// ## Where the state lives, and why it is not in the renderer
///
/// A `MKOverlayRenderer` is asked to draw a rectangle, at a scale, possibly off
/// the main thread, possibly several times for one frame as the map splits the
/// screen into tiles. None of that is a clock. So the simulation is stepped
/// exactly once per tick by whoever owns the frame clock, the renderer only
/// ever reads, and the two meet across a lock — the same arrangement the flown
/// path's live head already uses, and for the same reason.
///
/// ## Positions are held twice, on purpose
///
/// The *current* position of each particle is a pair of doubles in map points,
/// because that is what the field is sampled in and map points run to nine
/// figures. The *trail* is floats normalised to the field's own rectangle,
/// because a float has nowhere near the precision to hold a map point and
/// exactly enough to hold a fraction of a rectangle — and the trail is the part
/// that gets copied out to the renderer on every frame, at eight positions per
/// particle. Halving it costs nothing and is the difference between sixty-seven
/// kilobytes a frame and a hundred and thirty.
final class WindParticles {

    private var x: [Double] = []
    private var y: [Double] = []
    private var age: [Int32] = []
    private var life: [Int32] = []

    /// Ring buffer, `trail` positions per particle, normalised into `rect`.
    private var trail: [Float] = []
    private var head = 0
    private var count = 0

    private var field: WindVelocityGrid?
    private var rect = MKMapRect.null

    /// Where new particles are put, and where old ones are considered to have
    /// left. The visible map, as of the last step.
    private var visible = MKMapRect.null

    /// How much the clock is scaled by. See
    /// `WindParticleStyle.screensPerSecondAt100kt`.
    private var timeScale: Double = 1

    private var random = SystemRandomNumberGenerator()
    private let lock = NSLock()

    /// Whether there is anything to draw at all.
    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return field != nil && count > 0
    }

    /// The rectangle the particles live in — the field's, which is also what
    /// the overlay claims.
    var bounds: MKMapRect {
        lock.lock(); defer { lock.unlock() }
        return rect
    }

    // MARK: - Setting up

    /// Point the simulation at a new field. Everything is reseeded: a particle
    /// carried over from the last grid would be drifting on numbers that are no
    /// longer on screen.
    func adopt(field: WindVelocityGrid?, visible: MKMapRect, screenArea: Double) {
        lock.lock()
        defer { lock.unlock() }

        guard let field = field else {
            self.field = nil
            count = 0
            trail = []
            return
        }

        self.field = field
        self.rect = field.rect
        self.visible = visible

        let wanted = min(
            WindParticleStyle.mostParticles,
            max(
                WindParticleStyle.fewestParticles,
                Int(screenArea / WindParticleStyle.pointsPerParticle)
            )
        )

        count = wanted
        x = [Double](repeating: 0, count: wanted)
        y = [Double](repeating: 0, count: wanted)
        age = [Int32](repeating: 0, count: wanted)
        life = [Int32](repeating: 0, count: wanted)
        trail = [Float](repeating: 0, count: wanted * WindParticleStyle.trail * 2)
        head = 0

        for index in 0..<wanted {
            spawn(index)
            // Staggered, so the whole field does not retire on the same step
            // and blink.
            age[index] = Int32.random(in: 0..<life[index], using: &random)
        }
    }

    /// Tell the simulation where the map is now looking, and how fast its clock
    /// should run there.
    func look(at visible: MKMapRect, latitude: CLLocationDegrees) {
        lock.lock()
        defer { lock.unlock() }

        self.visible = visible

        // A hundred knots should cross a fixed fraction of the screen in a
        // second, whatever the screen is showing. Work back from that to the
        // factor the real velocities are multiplied by.
        let metresPerSecond = 100 / WeatherField.knotsPerMetrePerSecond
        let mapPointsPerSecond = metresPerSecond * MKMapPointsPerMeterAtLatitude(latitude)
        guard mapPointsPerSecond > 0, visible.size.width > 0 else { return }

        timeScale = visible.size.width
            * WindParticleStyle.screensPerSecondAt100kt
            / mapPointsPerSecond
    }

    // MARK: - Running

    /// One step. Returns whether anything moved, so a caller with nothing to
    /// show can skip invalidating the overlay.
    @discardableResult
    func step(_ seconds: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let field = field, count > 0, seconds > 0 else { return false }

        let dt = seconds * timeScale
        head = (head + 1) % WindParticleStyle.trail

        for index in 0..<count {
            age[index] += 1

            if age[index] >= life[index] {
                spawn(index)
                continue
            }

            guard let velocity = field.velocity(at: MKMapPoint(x: x[index], y: y[index])) else {
                spawn(index)
                continue
            }

            x[index] += velocity.dx * dt
            y[index] += velocity.dy * dt

            // Out of the model's rectangle, or far enough off screen that
            // keeping it is spending a particle on somewhere nobody is looking.
            let point = MKMapPoint(x: x[index], y: y[index])
            if !rect.contains(point) || !visible.insetBy(dx: -visible.size.width * 0.25,
                                                         dy: -visible.size.height * 0.25).contains(point) {
                spawn(index)
                continue
            }

            record(index)
        }

        return true
    }

    /// Put a particle somewhere new, and flatten its trail onto the new spot.
    ///
    /// Flattened rather than cleared: every position in the ring is set to
    /// where it now is, so the streak has zero length and grows from nothing.
    /// A break flag would do the same job and would have to be read on every
    /// segment of every draw; this costs eight writes, once, at the only moment
    /// it matters.
    private func spawn(_ index: Int) {
        let box = visible.intersects(rect) ? visible.intersection(rect) : rect
        let width = max(box.size.width, 1)
        let height = max(box.size.height, 1)

        x[index] = box.minX + Double.random(in: 0..<1, using: &random) * width
        y[index] = box.minY + Double.random(in: 0..<1, using: &random) * height
        age[index] = 0
        life[index] = Int32.random(
            in: Int32(WindParticleStyle.shortestLife)...Int32(WindParticleStyle.longestLife),
            using: &random
        )

        let nx = Float((x[index] - rect.minX) / max(rect.size.width, 1))
        let ny = Float((y[index] - rect.minY) / max(rect.size.height, 1))
        let base = index * WindParticleStyle.trail * 2
        for step in 0..<WindParticleStyle.trail {
            trail[base + step * 2] = nx
            trail[base + step * 2 + 1] = ny
        }
    }

    private func record(_ index: Int) {
        let at = (index * WindParticleStyle.trail + head) * 2
        trail[at] = Float((x[index] - rect.minX) / max(rect.size.width, 1))
        trail[at + 1] = Float((y[index] - rect.minY) / max(rect.size.height, 1))
    }

    // MARK: - Reading, for the renderer

    struct Snapshot {
        let trail: [Float]
        let alpha: [Float]
        let head: Int
        let count: Int
        let rect: MKMapRect
    }

    /// A copy of everything a draw needs, taken under the lock and read outside
    /// it.
    ///
    /// A copy rather than drawing under the lock, because a draw is milliseconds
    /// and can be asked for on several threads at once, and holding the
    /// simulation still for all of that would make the field stutter whenever
    /// the map decided to re-tile. The copy is about seventy kilobytes.
    func snapshot() -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard field != nil, count > 0 else { return nil }

        var alpha = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let age = Float(self.age[index])
            let life = Float(self.life[index])
            // In over the first few steps and out over the last dozen, so
            // nothing appears or vanishes as a hard dot.
            alpha[index] = min(1, age / 5) * min(1, max(0, life - age) / 14)
        }

        return Snapshot(trail: trail, alpha: alpha, head: head, count: count, rect: rect)
    }
}

// ---------------------------------------------------------------------------

/// The overlay the particles are drawn into.
///
/// It owns the simulation, so that a rebuild of the field replaces both at once
/// and there is never a renderer reading one grid's particles against another
/// grid's rectangle.
final class WindParticleOverlay: NSObject, MKOverlay {

    let particles = WindParticles()
    let boundingMapRect: MKMapRect
    let coordinate: CLLocationCoordinate2D

    init?(field: WindVelocityGrid, visible: MKMapRect, screenArea: Double) {
        let rect = field.rect
        guard rect.size.width > 0, rect.size.height > 0, screenArea > 0 else { return nil }

        boundingMapRect = rect
        coordinate = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        super.init()

        particles.adopt(field: field, visible: visible, screenArea: screenArea)
    }
}

/// Strokes the streaks.
final class WindParticleRenderer: MKOverlayRenderer {

    /// The colour, set by whoever knows which way round the map is drawn.
    var colour: UIColor = WindParticleStyle.colour(for: .dark) {
        didSet { if colour != oldValue { setNeedsDisplay() } }
    }

    /// How many alpha levels the streaks are sorted into before being stroked.
    ///
    /// The whole point of the layer is a thousand short paths, and a thousand
    /// `strokePath` calls is most of a frame. Every particle carries its own
    /// fade, but the eye cannot tell one two-hundredth of an alpha from
    /// another — so they are rounded into a handful of buckets, each bucket
    /// accumulated as one path, and the frame costs six strokes instead of a
    /// thousand.
    private static let buckets = 6

    private var particles: WindParticles { (overlay as! WindParticleOverlay).particles }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        guard let snapshot = particles.snapshot() else { return }
        guard snapshot.rect.size.width > 0, snapshot.rect.size.height > 0 else { return }

        // Only the tile being asked for, with room for a streak that starts
        // outside it and finishes inside.
        let clip = mapRect.insetBy(dx: -mapRect.size.width, dy: -mapRect.size.height)

        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(WindParticleStyle.width / zoomScale)

        let length = WindParticleStyle.trail
        let paths = (0..<Self.buckets).map { _ in CGMutablePath() }
        var used = [Bool](repeating: false, count: Self.buckets)

        for index in 0..<snapshot.count {
            let fade = snapshot.alpha[index]
            guard fade > 0.02 else { continue }

            let bucket = min(Self.buckets - 1, Int(fade * Float(Self.buckets)))
            let base = index * length * 2

            // Oldest first: the ring's head is the newest sample, so the run
            // starts one past it and wraps.
            var started = false
            var previous = CGPoint.zero
            let path = paths[bucket]

            for step in 0..<length {
                let slot = (snapshot.head + 1 + step) % length
                let at = base + slot * 2
                let position = MKMapPoint(
                    x: snapshot.rect.minX + Double(snapshot.trail[at]) * snapshot.rect.size.width,
                    y: snapshot.rect.minY + Double(snapshot.trail[at + 1]) * snapshot.rect.size.height
                )
                guard clip.contains(position) else {
                    started = false
                    continue
                }

                let point = self.point(for: position)
                if !started {
                    path.move(to: point)
                    started = true
                } else {
                    // A step that jumped a long way is a particle that was
                    // respawned mid-trail. Nothing was drawn from where it was
                    // to where it now is, and a line between the two would be
                    // a streak across the map.
                    if abs(point.x - previous.x) + abs(point.y - previous.y) > 400 / zoomScale {
                        path.move(to: point)
                    } else {
                        path.addLine(to: point)
                    }
                }
                previous = point
                used[bucket] = true
            }
        }

        for bucket in 0..<Self.buckets where used[bucket] {
            let fade = CGFloat(bucket) / CGFloat(Self.buckets - 1)
            context.setStrokeColor(colour.withAlphaComponent(colour.cgColor.alpha * fade).cgColor)
            context.addPath(paths[bucket])
            context.strokePath()
        }
    }
}
