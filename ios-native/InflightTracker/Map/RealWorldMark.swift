import SwiftUI
import UIKit

/// What real-world traffic is painted, wherever it is drawn.
///
/// One colour, in one place, read by the flat map, the planet, the banner over
/// the map and the settings screen. That is the point of it being here rather
/// than a literal at each of those: the whole argument for letting real
/// aeroplanes onto a simulator's map is that you can always tell which is
/// which, and four files each picking their own green is how that stops being
/// true.
///
/// ## Why this colour
///
/// It has to be a colour nothing else on the map already means. Ordinary
/// traffic is near-white, the open aircraft is amber, your own aeroplane is
/// amber, the watchlist is amethyst, and a field with somebody on frequency is
/// blue. A saturated mint is none of those, holds up against dark cartography,
/// light cartography and satellite imagery alike, and does not read as a
/// warning — real traffic is a feature, not an alarm.
enum RealWorldMark {

    /// The body colour of a real aeroplane's mark. The outline is left alone:
    /// it is what makes any of these sprites legible over imagery.
    static let body = UIColor(red: 0.16, green: 0.88, blue: 0.64, alpha: 1)

    /// The same colour for SwiftUI chrome — the banner, and the settings row.
    static let tint = Color(uiColor: body)
}

extension Flight {

    /// The colour this aeroplane is painted when no pilot highlighting has an
    /// opinion about it.
    ///
    /// Nil for simulator traffic, which is exactly what it was before any of
    /// this existed: the sprite sheet's own near-white. Real traffic gets the
    /// mint above, so a map carrying both says which is which without a legend.
    ///
    /// Deliberately the *fallback* rather than an override. Pilot highlighting
    /// is about people — your own aeroplane, the pilots you watch — and none of
    /// those can be a real-world aircraft, so the two never actually compete;
    /// writing it this way round simply means that if they ever did, the person
    /// would win.
    var originTint: UIColor? {
        origin == .realWorld ? RealWorldMark.body : nil
    }
}
