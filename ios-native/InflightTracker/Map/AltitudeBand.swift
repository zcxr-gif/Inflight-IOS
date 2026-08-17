import UIKit

/// Height bands used to colour a flown path, following the Capacitor build's
/// 3D path renderer (`old/www/flownPath3D.js`, `ALTITUDE_STOPS`) in shape: low
/// and slow reads hot, cruise reads pale.
///
/// The old ramp finished on blue and indigo. This one runs orange to white
/// instead, keeping the height reading without putting blue on the map.
///
/// Banded rather than interpolated per sample, so the map draws a handful of
/// polylines instead of one per breadcrumb.
enum AltitudeBand {

    /// Every band, low to high. The map filters offer exactly these, so the
    /// heights you can filter by and the heights the path is coloured by are
    /// the same set of numbers.
    static let all = [0, 1, 2, 3]

    /// How the band reads as a range of feet.
    static func label(for band: Int) -> String {
        switch band {
        case 0: return "Below 10,000"
        case 1: return "10,000 – 25,000"
        case 2: return "25,000 – 40,000"
        default: return "Above 40,000"
        }
    }

    /// Band index for an altitude, from ground to the flight levels.
    static func band(forFeet feet: Double) -> Int {
        guard feet.isFinite else { return 0 }
        if feet < 10_000 { return 0 }
        if feet < 25_000 { return 1 }
        if feet < 40_000 { return 2 }
        return 3
    }

    static func color(for band: Int) -> UIColor {
        switch band {
        case 0: return UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 0.95)  // low: hot orange
        case 1: return UIColor(red: 0.980, green: 0.749, blue: 0.184, alpha: 0.95)  // amber
        case 2: return UIColor(red: 0.988, green: 0.898, blue: 0.667, alpha: 0.95)  // pale gold
        default:
            // Cruise is the cold end of the ramp — the band with no heat left
            // in it — which on a dark map is white and on a light one has to be
            // ink, or the highest band is the one you cannot see. The three
            // warm bands read on either ground and stay fixed.
            return UIColor { traits in
                traits.userInterfaceStyle == .light
                    ? UIColor(white: 0.16, alpha: 0.95)
                    : UIColor(white: 0.98, alpha: 0.95)
            }
        }
    }
}
