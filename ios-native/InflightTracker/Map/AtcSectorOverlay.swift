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
