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
        default: return UIColor(white: 0.98, alpha: 0.95)                           // cruise: white
        }
    }
}
