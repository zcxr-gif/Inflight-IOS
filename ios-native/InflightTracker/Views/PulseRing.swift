import SwiftUI
import UIKit

/// A ring that swells out of a dot and fades, over and over — the "this is
/// live" ping.
///
/// Core Animation rather than a SwiftUI `repeatForever`. SwiftUI drives its
/// own animations from the main thread: a forever animation is a frame of
/// SwiftUI work, and a fresh commit of the window it sits in, at the display's
/// full rate for as long as it is on screen — which for the flight window is
/// the whole time somebody is watching an aeroplane, over a map that wants
/// every one of those frames. Handed to Core Animation the ring runs in the
/// render server and costs the app nothing per frame.
struct PulseRing: UIViewRepresentable {

    var color: Color
    /// How far the ring swells, as a multiple of the dot.
    var scale: CGFloat = 2.6
    var opacity: Float = 0.6
    var duration: CFTimeInterval = 2.4

    func makeUIView(context: Context) -> PulseRingView {
        let view = PulseRingView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PulseRingView, context: Context) {
        view.configure(
            color: UIColor(color),
            scale: scale,
            opacity: opacity,
            duration: duration,
            animates: !context.environment.accessibilityReduceMotion
        )
    }
}

final class PulseRingView: UIView {

    private let ring = CAShapeLayer()
    private var animates = true
    private var scale: CGFloat = 2.6
    private var peak: Float = 0.6
    private var duration: CFTimeInterval = 2.4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        layer.addSublayer(ring)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(color: UIColor, scale: CGFloat, opacity: Float, duration: CFTimeInterval, animates: Bool) {
        ring.fillColor = color.cgColor
        let changed = self.animates != animates || self.scale != scale
            || self.peak != opacity || self.duration != duration
        self.animates = animates
        self.scale = scale
        self.peak = opacity
        self.duration = duration
        if changed { restart() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds).cgPath
        CATransaction.commit()
    }

    /// A layer animation is taken off when the view leaves the window, and a
    /// view coming back — the window reopening, the app returning from the
    /// background — has to put it back.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    private func restart() {
        ring.removeAllAnimations()
        guard window != nil, animates else {
            ring.opacity = 0
            return
        }
        ring.opacity = 0

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = scale

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = peak
        fade.toValue = 0

        let pulse = CAAnimationGroup()
        pulse.animations = [grow, fade]
        pulse.duration = duration
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pulse.repeatCount = .infinity
        pulse.isRemovedOnCompletion = false
        ring.add(pulse, forKey: "pulse")
    }
}
