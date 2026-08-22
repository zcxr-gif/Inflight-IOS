import MapKit
import UIKit

/// One end of a measured leg.
final class MeasurePoint: NSObject, MKAnnotation {

    let coordinate: CLLocationCoordinate2D

    /// A or B. The line between them says everything else, but two identical
    /// dots leave the bearing ambiguous — a leg has a direction, and this is
    /// which way round it runs.
    let letter: String

    init(coordinate: CLLocationCoordinate2D, letter: String) {
        self.coordinate = coordinate
        self.letter = letter
        super.init()
    }
}

/// A ringed dot with its letter in it, drawn to be found on any basemap.
final class MeasurePointView: MKAnnotationView {

    static let reuseIdentifier = "measurePoint"

    private static let side: CGFloat = 24

    private let label = UILabel()
    private let ring = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false
        // A measuring pin is not a destination. Tapping it should reach the
        // map underneath, which in measuring mode means moving the leg.
        isEnabled = false
        // The one thing on the map that must never be collided away: it is
        // where the person measuring just tapped.
        displayPriority = .required
        collisionMode = .circle

        frame = CGRect(x: 0, y: 0, width: Self.side, height: Self.side)

        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).cgPath
        ring.lineWidth = 2
        ring.shadowColor = UIColor.black.cgColor
        ring.shadowOpacity = 0.5
        ring.shadowRadius = 2
        ring.shadowOffset = .zero
        layer.addSublayer(ring)

        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 11, weight: .heavy)
        addSubview(label)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: MeasurePointView, _) in
            view.applyColours()
        }
        applyColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: MeasurePoint) {
        label.text = annotation.letter
    }

    private func applyColours() {
        let ink = MeasureStyle.line.resolvedColor(with: traitCollection)
        ring.strokeColor = ink.cgColor
        ring.fillColor = MeasureStyle.pinFill.resolvedColor(with: traitCollection).cgColor
        label.textColor = ink
    }
}

/// How a measured leg is drawn, in a colour nothing else on the map uses.
///
/// It has to be unmistakable — a ruler is a thing you put down and pick up
/// again, and for the moments it is there it should be the most obvious line
/// on screen. That is the opposite of every other overlay here, which are all
/// deliberately quiet.
enum MeasureStyle {

    static let title = "measure"

    static let line = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.85, green: 0.20, blue: 0.45, alpha: 1)
            : UIColor(red: 1.00, green: 0.45, blue: 0.65, alpha: 1)
    }

    static let pinFill = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(white: 1, alpha: 0.95)
            : UIColor(white: 0.10, alpha: 0.95)
    }
}
