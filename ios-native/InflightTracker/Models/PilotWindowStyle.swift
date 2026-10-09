import Foundation
import SwiftUI

/// "Your window, seen by others": how a pilot has styled the flight window
/// everybody else sees for their flight.
///
/// The same row the website reads (`pilot_window_style`, see
/// `supabase/sql/pilot-window-style.sql` in the tracker): a painted theme,
/// free; or, with Pro, their own window colour and a photo behind the window,
/// with how strongly the colour is laid over it. The server blanks the Pro
/// values while the pilot is not Pro, so nothing here checks.
struct PilotWindowStyle: Decodable, Equatable {

    let handle: String
    let isPro: Bool
    let theme: BannerPreset?
    /// `#rrggbb`, or nil.
    let colour: String?
    let photoPath: String?
    /// 0.2 … 0.9.
    let dim: Double

    private enum Keys: String, CodingKey {
        case handle
        case isPro = "is_pro"
        case theme = "window_theme"
        case colour = "window_color"
        case photoPath = "window_bg_path"
        case dim = "window_bg_dim"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        handle = try c.decode(String.self, forKey: .handle)
        isPro = (try? c.decode(Bool.self, forKey: .isPro)) ?? false
        theme = (try? c.decode(String.self, forKey: .theme)).flatMap(BannerPreset.init(rawValue:))
        let hex = (try? c.decode(String.self, forKey: .colour))?.lowercased()
        colour = hex.flatMap { $0.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil ? $0 : nil }
        photoPath = try? c.decode(String.self, forKey: .photoPath)
        let raw = (try? c.decode(Double.self, forKey: .dim)) ?? 60
        dim = min(max(raw, 20), 90) / 100
    }

    var photoURL: URL? { AppConfig.profileImageURL(bucket: "pilot-banners", path: photoPath) }

    var hasLook: Bool { theme != nil || colour != nil || photoPath != nil }

    /// The window colour the look implies: the pilot's own colour, or their
    /// theme's top stop taken most of the way down towards night so the window
    /// stays calm — the web's `ownerColor`.
    var windowColourHex: String? {
        if let colour = colour { return colour }
        guard let theme = theme else { return nil }
        return Self.mix(Self.stops(theme)[0], "#0e1014", 0.55)
    }

    /// The web's preset stops, to the hex, so a theme paints the same on both.
    static func stops(_ theme: BannerPreset) -> [String] {
        switch theme {
        case .dusk: return ["#2b336b", "#944f70", "#eb8c5c"]
        case .dawn: return ["#1f3d70", "#5c8cb8", "#facc99"]
        case .flightLevel: return ["#0d1c45", "#295999", "#9ecced"]
        case .night: return ["#080a1f", "#1a2147", "#404773"]
        case .desert: return ["#6b4229", "#c28547", "#f2d499"]
        case .ocean: return ["#05334c", "#0d6b82", "#70c2bf"]
        }
    }

    /// `mixHex`: a toward b by t.
    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let ca = HorizonColour(hex: a), cb = HorizonColour(hex: b)
        let channel = { (x: Double, y: Double) in Int(((x + (y - x) * t) * 255).rounded()) }
        return String(
            format: "#%02x%02x%02x",
            channel(ca.red, cb.red), channel(ca.green, cb.green), channel(ca.blue, cb.blue)
        )
    }
}
