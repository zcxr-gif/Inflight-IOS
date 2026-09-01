import MapKit
import UIKit

/// How staffed airspace is drawn: a faint tint inside, a clean line round the
/// edge, and the station named at the middle.
///
/// The colours are the web tracker's, deliberately — see
/// `old/www/atcHighlights.js` and `initializeMapBoundaries` in
/// `old/www/flight.js`. A green wash for "somebody is working this" and a cyan
/// edge, which is what an aeronautical chart draws a boundary in. Somebody who
/// has used the web tracker should recognise their own map.
enum AtcSectorStyle {

    /// The wash inside a staffed sector. Very faint on purpose: it lies under
    /// the whole traffic picture, and airspace that competes with the aircraft
    /// in it is airspace drawn wrong.
    static let fill = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.13, green: 0.55, blue: 0.30, alpha: 0.10)
            : UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 0.12)
    }

    /// The edge. The one part of this that is meant to be followed with the
    /// eye, so it is the part that carries the colour.
    static let border = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.01, green: 0.41, blue: 0.63, alpha: 0.75)
            : UIColor(red: 0.40, green: 0.91, blue: 0.98, alpha: 0.70)
    }

    static let borderWidth: CGFloat = 1.1

    /// The station's own name, over the middle of its airspace.
    static let label = UIColor { traits in
        traits.userInterfaceStyle == .light
            ? UIColor(red: 0.01, green: 0.35, blue: 0.54, alpha: 1)
            : UIColor(red: 0.62, green: 0.94, blue: 1.00, alpha: 1)
    }
}

/// One staffed sector, as the overlays that draw it.
///
/// Plain `MKPolygon`s carrying a title, which is how the terminator's bands are
/// already told apart in the same renderer — rather than an `MKPolygon`
/// subclass. Both work; this one matches what is here, and the title is doing
/// no work beyond identification because every ring of every staffed sector is
/// drawn identically. The sector's own id goes on the end of it so an overlay
/// is still identifiable when something looks wrong with one.
enum AtcSectorOverlay {

    /// The prefix every sector ring's title starts with.
    static let titlePrefix = "atc-sector|"

    /// Whether an overlay's title marks it as staffed airspace. The same shape
    /// as `Terminator.isBand`, which answers the same question one branch below
    /// it in the same renderer.
    static func isSector(_ title: String?) -> Bool {
        title?.hasPrefix(titlePrefix) == true
    }

    /// Every ring of one sector, ready to add to the map.
    static func rings(of sector: AtcSector) -> [MKPolygon] {
        sector.rings.compactMap { ring in
            guard ring.count >= 3 else { return nil }
            var points = ring
            let polygon = MKPolygon(coordinates: &points, count: points.count)
            polygon.title = titlePrefix + sector.id
            return polygon
        }
    }
}

/// The station name, written over the middle of its airspace.
///
/// Its own annotation rather than a `title` on the overlay, because MapKit
/// draws no text for an overlay at all — and because this is the half of the
/// feature that answers "who is on", which is the half a boundary on its own
/// cannot say.
final class AtcSectorLabelAnnotation: NSObject, MKAnnotation {

    let coordinate: CLLocationCoordinate2D

    /// The station, and who is working it.
    let text: String

    /// The boundary id, which is what makes two sectors with the same station
    /// name — a split FIR — two annotations rather than one.
    let sectorId: String

    init(_ active: AtcActiveSector) {
        self.coordinate = active.sector.label
        self.text = active.label
        self.sectorId = active.sector.id
        super.init()
    }
}

final class AtcSectorLabelView: MKAnnotationView {

    static let reuseIdentifier = "atcSectorLabel"

    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)

        canShowCallout = false
        // Nothing to open. The ATC panel is where a controller is tapped
        // through to, and a label floating over an ocean is a poor second way
        // in — so a tap here falls through to whatever is underneath, which is
        // usually an aeroplane.
        isEnabled = false

        // Below the fields and well below the traffic. This names a volume of
        // sky; the aerodromes and the aircraft in it are the things somebody is
        // actually looking for.
        displayPriority = .defaultLow
        collisionMode = .circle

        frame = CGRect(x: 0, y: 0, width: 160, height: 16)
        label.frame = bounds
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.75
        // The same halo the runway designators and the plan's fixes carry: the
        // map underneath is anything from ocean to imagery.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.85
        label.layer.shadowRadius = 2.5
        label.layer.shadowOffset = .zero
        addSubview(label)

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: AtcSectorLabelView, _) in
            view.applyColours()
        }

        applyColours()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(_ annotation: AtcSectorLabelAnnotation) {
        label.text = annotation.text
    }

    private func applyColours() {
        label.textColor = AtcSectorStyle.label.resolvedColor(with: traitCollection)
    }
}
