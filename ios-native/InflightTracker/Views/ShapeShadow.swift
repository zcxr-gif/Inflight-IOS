import SwiftUI
import UIKit

/// A drop shadow cast by a shape's outline alone, drawn by Core Animation
/// from that outline rather than from whatever is inside it.
///
/// What `.shadow` costs depends on what it is put on. On a window — a scroll
/// view, photographs, glass — there is no outline to go by, so the shadow is
/// worked out from the alpha of everything the window draws, in a pass of its
/// own off the screen, on every frame the screen is composited. Over a map that
/// redraws as it moves and as its traffic flies, that is every frame. Given the
/// outline up front (`shadowPath`), Core Animation draws the same blur without
/// rendering anything to find it.
///
/// Laid behind the surface it belongs to, it looks the same: the shadow sits
/// under the whole outline, as the one cast by the surface itself did, so
/// glass over it frosts the same shade it always frosted.
struct ShapeShadow<S: Shape>: UIViewRepresentable {

    let shape: S
    let color: Color
    let radius: CGFloat
    var x: CGFloat = 0
    var y: CGFloat = 0

    func makeUIView(context: Context) -> ShapeShadowView {
        ShapeShadowView()
    }

    func updateUIView(_ view: ShapeShadowView, context: Context) {
        let shape = self.shape
        view.outline = { shape.path(in: $0).cgPath }
        view.layer.shadowColor = UIColor(color).cgColor
        view.layer.shadowOpacity = 1
        view.layer.shadowRadius = radius
        view.layer.shadowOffset = CGSize(width: x, height: y)
        view.applyOutline()
    }
}

final class ShapeShadowView: UIView {

    /// The outline, for the bounds it is laid out at.
    var outline: ((CGRect) -> CGPath)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyOutline()
    }

    func applyOutline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let outline, bounds.width > 0, bounds.height > 0 {
            layer.shadowPath = outline(bounds)
        } else {
            layer.shadowPath = nil
        }
        CATransaction.commit()
    }
}

/// A window's drop shadow, as a value it can be handed — see `bornFromDock`.
struct WindowShadow {
    var color: Color
    var radius: CGFloat
    var y: CGFloat
}
