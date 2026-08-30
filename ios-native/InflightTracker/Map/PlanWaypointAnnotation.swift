import MapKit
import UIKit

/// How the filed plan is drawn on the map: one colour for the line and the
/// fixes on it, so the two read as one route.
///
/// Quieter than the flown path on purpose. The coloured track behind an
/// aircraft is what it has actually done; this is what the pilot said they
/// would do, and when both are on screen the statement of intent should be the
/// one that gives way.
enum PlanStyle {

    /// The line through the fixes, drawn dashed.
    ///
    /// Well under the fixes, which are full strength: the diamonds are what you
    /// read, and the line is what joins them. The dash is long and the gap
    /// short, so this keeps most of the ink a solid line would have had and
    /// wants no compensating for.
    static let line = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.15, green: 0.40, blue: 0.75, alpha: 0.55)
            : UIColor(red: 0.55, green: 0.75, blue: 1.00, alpha: 0.55)
    }

    /// The fixes themselves, at full strength — a mark you are meant to pick
    /// out and read the name of, rather than a line you are meant to follow.
    static let fix = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.11, green: 0.33, blue: 0.68, alpha: 1)
            : UIColor(red: 0.68, green: 0.84, blue: 1.00, alpha: 1)
    }
}

/// One fix on a filed plan.
///
/// Its own annotation rather than the runway designator's label, which is what
/// it used to borrow: a fix is a *place on a route*, and a route drawn as a
/// line with bare names floating beside it is a line with bare names floating
/// beside it. The diamond is what makes it read as a plan.
final class PlanWaypointAnnotation: NSObject, MKAnnotation {

    let coordinate: CLLocationCoordinate2D
    let name: String

    /// Position along the plan. Two fixes can share a name — a hold, a
    /// procedure rejoining the airway it left — and MapKit would otherwise be
    /// handed two annotations it has every reason to treat as one.
    let index: Int

    init(waypoint: PlanWaypoint) {
        self.coordinate = waypoint.coordinate
        self.name = waypoint.name
        self.index = waypoint.index
        super.init()
    }
}

final class PlanWaypointView: MKAnnotationView {

    static let reuseIdentifier = "planWaypoint"

    /// Distance from the middle of the diamond to each of its points.
    private static let diamondRadius: CGFloat = 5

    private let label = UILabel()
    private let diamond = CAShapeLayer()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false
        // Nothing to open: tapping a fix should fall through to whatever is
        // behind it, which is usually the aircraft flying to it.
        isEnabled = false

        // Above the pavement, below the traffic. The route is the reason the
        // aeroplane is where it is, and the aeroplane is still the point.
        displayPriority = .defaultLow
        collisionMode = .circle

        frame = CGRect(x: 0, y: 0, width: 82, height: 32)

        // The diamond sits at the top of the view and the name hangs under it,
        // so the offset below can put the diamond itself — not the middle of
        // the view — on the fix.
        diamond.frame = CGRect(x: 0, y: 0, width: frame.width, height: 14)
        diamond.fillColor = UIColor.clear.cgColor
        diamond.lineWidth = 1.6
        diamond.lineJoin = .round
        layer.addSublayer(diamond)

        label.frame = CGRect(x: 0, y: 15, width: frame.width, height: 15)
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        // The map underneath is anything from snow to ocean to imagery, and a
        // halo is what keeps five characters legible over all of them.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.85
        label.layer.shadowRadius = 2
        label.layer.shadowOffset = .zero
        addSubview(label)

        // Shifts the view down so the diamond, not the view's middle, lands on
        // the coordinate.
        centerOffset = CGPoint(x: 0, y: frame.height / 2 - 7)

        // `CGColor` carries no trait information, so a dynamic `UIColor`
        // resolved into a layer freezes at whatever the map was when it was
        // drawn. This is what unfreezes it when the app is switched between
        // light and dark.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PlanWaypointView, _) in
            view.applyColours()
        }

        applyColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: PlanWaypointAnnotation) {
        label.text = annotation.name
    }

    private func applyColours() {
        let colour = PlanStyle.fix.resolvedColor(with: traitCollection)
        diamond.strokeColor = colour.cgColor
        label.textColor = colour

        let centre = CGPoint(x: diamond.bounds.midX, y: 7)
        let radius = Self.diamondRadius
        let path = UIBezierPath()
        path.move(to: CGPoint(x: centre.x, y: centre.y - radius))
        path.addLine(to: CGPoint(x: centre.x + radius, y: centre.y))
        path.addLine(to: CGPoint(x: centre.x, y: centre.y + radius))
        path.addLine(to: CGPoint(x: centre.x - radius, y: centre.y))
        path.close()
        diamond.path = path.cgPath
    }
}
