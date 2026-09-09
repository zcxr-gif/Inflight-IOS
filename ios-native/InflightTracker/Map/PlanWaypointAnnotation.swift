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

    /// The line through the fixes, drawn dashed, and white.
    ///
    /// White rather than the blue it used to be, and the same white on a light
    /// map as on a dark one — which is only possible because of `casing`
    /// below. A route line has one job that no colour does better: it is not
    /// the flown track, and the flown track is the coloured thing on this map.
    /// Anything with a hue in it competes with a height band; white does not,
    /// and reads as a drawing over the map rather than as data on it.
    ///
    /// Not quite full strength, so it still gives way to the track laid over
    /// it. The dash is long and the gap short, so this keeps most of the ink a
    /// solid line would have had and wants no compensating for.
    static let line = UIColor(white: 1, alpha: 0.82)

    /// What is drawn under the line, in the same dash and wider.
    ///
    /// This is what buys the white. A white line over Apple's light
    /// cartography — which is a pale grey-green — is very nearly invisible,
    /// and the honest fixes for that are either a colour that is not white or
    /// a shadow under the one that is. This is the shadow: a dark stroke a
    /// couple of points wider than the line and translucent enough to read as
    /// an edge rather than as a second route.
    ///
    /// Present on the dark map too, where it does nothing much and costs
    /// nothing much — the alternative is two dash patterns that have to stay in
    /// step across a trait change, which is a way to be wrong once.
    static let casing = UIColor(white: 0, alpha: 0.38)

    /// The dash the line and its casing share.
    ///
    /// It *must* be the same on both or the casing stops being an edge and
    /// becomes a dotted line beside a dashed one.
    static let dash: [NSNumber] = [7, 4]

    // MARK: - Standing further back

    /// How wide the route line is drawn from a given camera distance.
    ///
    /// ## Why a filed plan has to get quieter as you pull back
    ///
    /// These used to be two constants, and constants are the bug. A stroke set
    /// in points is that many points wide at every zoom, so the filed plan
    /// arrived at the same weight over a whole ocean as it has over a runway —
    /// while the flown track beside it tapers, because a track is not a road
    /// (see `FlownPathStyle`). The two ramps crossed. Pulled back to the view
    /// somebody actually watches a long-haul at, the plan's casing was *wider*
    /// than the track's core, and the map was drawing the intention louder than
    /// the fact.
    ///
    /// So the plan tapers too, and it tapers harder. It is written against the
    /// flown path's own width rather than against numbers of its own, which is
    /// what makes the ordering an invariant instead of a coincidence: whatever
    /// the track is at this distance, the plan is a fixed fraction of it, and
    /// nobody can retune one of the two and quietly invert them again.
    ///
    /// A little over two fifths. Enough to follow a forty-fix route across a
    /// map at a glance, not enough to compete with the line that says where the
    /// aeroplane has been — and at the field it lands on the 1.9 points this
    /// was a constant at for as long as it was one.
    static func lineWidth(forCameraDistance distance: CLLocationDistance) -> CGFloat {
        FlownPathStyle.width(forCameraDistance: distance) * lineShare
    }

    /// What that comes to at the field: the width to start a renderer at
    /// before the camera has said anything.
    static var closeLineWidth: CGFloat { FlownPathStyle.closeWidth * lineShare }

    /// The dark edge under it, in the same dash.
    ///
    /// The gap between the two is what the casing *is* — an edge, not a second
    /// route — so it narrows with everything else rather than staying two
    /// points wide while the line it is edging halves.
    static func casingWidth(forCameraDistance distance: CLLocationDistance) -> CGFloat {
        let line = lineWidth(forCameraDistance: distance)
        return line + max(1.1, line * 1.05)
    }

    /// And the inferred leg, which is a guess and is drawn like one: thinner
    /// than the filed line at every distance.
    static func inferredWidth(forCameraDistance distance: CLLocationDistance) -> CGFloat {
        max(1.1, lineWidth(forCameraDistance: distance) * 0.9)
    }

    /// `lineWidth` at the field is 1.9 against a track of 4.6, and that ratio
    /// is the one being held everywhere else.
    private static let lineShare: CGFloat = 0.41

    /// The fixes themselves, at full strength — a mark you are meant to pick
    /// out and read the name of, rather than a line you are meant to follow.
    ///
    /// White, with the line, so the diamonds and the thread through them read
    /// as one route. They keep a shadow of their own rather than a casing —
    /// see `PlanWaypointView` — for the same reason the line has one: white on
    /// a light map is nothing without something behind it.
    static let fix = UIColor(white: 1, alpha: 1)

    /// The fix being flown to.
    ///
    /// The one mark on a plan that is about *now* rather than about the filing,
    /// so it is the one that gets a colour of its own and a filled diamond. On
    /// a transatlantic plan of forty outlines it is the difference between
    /// reading the route and searching it.
    static let nextFix = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.80, green: 0.48, blue: 0.02, alpha: 1)
            : UIColor(red: 1.00, green: 0.80, blue: 0.35, alpha: 1)
    }

    /// How much is left of a fix already behind the wing. Dimmed rather than
    /// dropped: how much of the route has been flown is legible at a glance,
    /// and the corner is still a real corner.
    static let passedOpacity: CGFloat = 0.45
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

    /// Whether the name is drawn under the diamond. See
    /// `MapFilters.showsPlanFixNames`.
    let showsName: Bool

    /// Whether this is the fix the aircraft is flying to, and whether it is
    /// one already behind it. See `PlanProgress.next`.
    let isNext: Bool
    let isPassed: Bool

    init(
        waypoint: PlanWaypoint,
        showsName: Bool = true,
        isNext: Bool = false,
        isPassed: Bool = false
    ) {
        self.coordinate = waypoint.coordinate
        self.name = waypoint.name
        self.index = waypoint.index
        self.showsName = showsName
        self.isNext = isNext
        self.isPassed = isPassed
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
        //
        // The fix being flown to is lifted above the rest in `apply`: on a
        // plan whose fixes are a few points apart, MapKit's own collision
        // resolution will otherwise drop whichever it feels like — and the one
        // mark here that is about now is never the one to drop.
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
        // The same halo the name already wears, and now for the same reason:
        // the mark is white, and white on a light map or on snow is a shape
        // you have to be told is there. See `PlanStyle.fix`.
        diamond.shadowColor = UIColor.black.cgColor
        diamond.shadowOpacity = 0.7
        diamond.shadowRadius = 2
        diamond.shadowOffset = .zero
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
        label.isHidden = !annotation.showsName || annotation.name.isEmpty

        isNext = annotation.isNext
        displayPriority = annotation.isNext ? .required : .defaultLow
        alpha = annotation.isPassed ? PlanStyle.passedOpacity : 1

        applyColours()
    }

    /// Whether this view is currently drawing the fix being flown to. Held
    /// rather than re-read from the annotation, because `applyColours` is also
    /// what a trait change calls and a reused view's annotation may by then be
    /// a different fix on a different plan.
    private var isNext = false

    private func applyColours() {
        let colour = (isNext ? PlanStyle.nextFix : PlanStyle.fix)
            .resolvedColor(with: traitCollection)
        diamond.strokeColor = colour.cgColor
        // Filled for the fix being flown to, so it is findable on a plan of
        // forty outlines without reading a single name.
        diamond.fillColor = isNext ? colour.cgColor : UIColor.clear.cgColor
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
