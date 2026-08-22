import MapKit
import UIKit

/// How the organised tracks are drawn, and how a drawn line says which track
/// it is.
///
/// `MKPolyline` carries a `title` and nothing else, so the track's identity
/// travels in that string and is read back out in the renderer. Same trick the
/// flown path uses for its altitude band.
enum NatTrackStyle {

    /// Prefix on a track polyline's title, so the renderer can tell one from
    /// the flown path, the filed plan and the ground layer.
    static let titlePrefix = "nat:"

    static func title(for track: NatTrack) -> String { "\(titlePrefix)\(track.name)" }

    /// The letter a title carries, or nil if it is not a track at all.
    static func name(fromTitle title: String?) -> String? {
        guard let title = title, title.hasPrefix(titlePrefix) else { return nil }
        return String(title.dropFirst(titlePrefix.count))
    }

    /// One colour per track letter, the same six the web tracker used — so
    /// somebody who knows the map already knows which line is which.
    ///
    /// Deliberately saturated where the rest of this map is monochrome: the
    /// tracks are a published structure rather than something being observed,
    /// and they should not be mistaken for anything an aeroplane is doing.
    static func colour(for name: String) -> UIColor {
        switch name.uppercased().first {
        case "A": return UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1)
        case "B": return UIColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1)
        case "C": return UIColor(red: 0.18, green: 0.80, blue: 0.44, alpha: 1)
        case "D": return UIColor(red: 0.64, green: 0.61, blue: 1.00, alpha: 1)
        case "E": return UIColor(red: 0.90, green: 0.49, blue: 0.13, alpha: 1)
        case "F": return UIColor(red: 0.00, green: 0.81, blue: 0.79, alpha: 1)
        default:  return UIColor(red: 0.20, green: 0.60, blue: 0.86, alpha: 1)
        }
    }

    /// What the label at each end of a track says: the letter, and the levels
    /// it is valid at when the message carried any.
    static func label(for track: NatTrack) -> String {
        guard let levels = track.levelsLabel else { return "NAT \(track.name)" }
        return "NAT \(track.name)  ·  \(levels)"
    }
}
