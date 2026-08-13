import UIKit

/// Height bands used to colour a flown path, carried over from the Capacitor
/// build's 3D path renderer (`old/www/flownPath3D.js`, `ALTITUDE_STOPS`): low
/// and slow reads warm, cruise reads cool.
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
        case 0: return UIColor(red: 0.976, green: 0.451, blue: 0.086, alpha: 0.95)  // #f97316
        case 1: return UIColor(red: 0.980, green: 0.800, blue: 0.082, alpha: 0.95)  // #facc15
        case 2: return UIColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.95)  // #38bdf8
        default: return UIColor(red: 0.506, green: 0.549, blue: 0.973, alpha: 0.95) // #818cf8
        }
    }
}
