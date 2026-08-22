import Foundation
import SwiftUI

/// Which of the two instruments is on screen.
///
/// The pair is deliberately one *or* the other rather than both at once: on a
/// phone, two displays side by side are two displays nobody can read, and the
/// old web tracker only got away with it because it was drawing them on a
/// desktop.
enum InstrumentDisplay: String, CaseIterable, Identifiable {

    /// Primary flight display — attitude, speed, height, heading.
    case pfd

    /// Navigation display — where the aeroplane is going and what is around it.
    case navigation

    var id: String { rawValue }

    /// What the switch says. The abbreviations, because that is what they are
    /// called by everyone who would go looking for them.
    var label: String {
        switch self {
        case .pfd: return "PFD"
        case .navigation: return "ND"
        }
    }

    var longLabel: String {
        switch self {
        case .pfd: return "Primary flight display"
        case .navigation: return "Navigation display"
        }
    }

    var symbol: String {
        switch self {
        case .pfd: return "airplane.circle"
        case .navigation: return "location.north.line"
        }
    }
}

/// How the navigation display draws the world.
enum NavigationDisplayMode: String, CaseIterable, Identifiable {

    /// The forward fan, aircraft at the bottom. What you would fly with.
    case arc

    /// The full compass, aircraft in the middle. Better for seeing what is
    /// behind you, which on a tracker is most of the traffic.
    case rose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .arc: return "ARC"
        case .rose: return "ROSE"
        }
    }
}

/// The instrument panel's own settings.
///
/// Separate from `MapFilters`, which is about the map, and from
/// `FlightInfoAppearance`, which is about how the app is painted: this is a
/// feature that is either in the flight window or not, plus the two choices —
/// which display, how far it reaches — that somebody changes while reading it.
/// All of it persists, because an instrument you set up once is one you meant
/// to keep.
final class InstrumentPreferences: ObservableObject {

    static let shared = InstrumentPreferences()

    private static let enabledKey = "instruments.enabled"
    private static let displayKey = "instruments.display"
    private static let modeKey = "instruments.navigationMode"
    private static let rangeKey = "instruments.rangeNM"
    private static let trafficKey = "instruments.showsTraffic"

    /// The ranges the display offers, in nautical miles — the same ladder every
    /// airliner ND has, so the numbers are the ones a pilot expects to find.
    static let ranges: [Double] = [10, 20, 40, 80, 160, 320]

    /// Whether the flight window carries the instruments at all.
    ///
    /// On by default. The whole complaint this answers is that there was no way
    /// to see them; shipping the switch off would have fixed nothing anybody
    /// could find.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// Which display the card opens on. Follows whatever you last switched to,
    /// so the panel comes back the way you left it.
    @Published var display: InstrumentDisplay {
        didSet { UserDefaults.standard.set(display.rawValue, forKey: Self.displayKey) }
    }

    @Published var navigationMode: NavigationDisplayMode {
        didSet { UserDefaults.standard.set(navigationMode.rawValue, forKey: Self.modeKey) }
    }

    /// How far the navigation display reaches, in nautical miles.
    @Published var rangeNM: Double {
        didSet { UserDefaults.standard.set(rangeNM, forKey: Self.rangeKey) }
    }

    /// Whether other aircraft from the feed are drawn on the navigation
    /// display. On by default — a tracker's ND with no traffic on it is a
    /// compass.
    @Published var showsTraffic: Bool {
        didSet { UserDefaults.standard.set(showsTraffic, forKey: Self.trafficKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        display = InstrumentDisplay(rawValue: defaults.string(forKey: Self.displayKey) ?? "") ?? .pfd
        navigationMode = NavigationDisplayMode(rawValue: defaults.string(forKey: Self.modeKey) ?? "")
            ?? .arc
        showsTraffic = defaults.object(forKey: Self.trafficKey) as? Bool ?? true

        // 40 NM is the ND range most of a flight is flown on, and the one the
        // old web display opened at.
        let stored = defaults.object(forKey: Self.rangeKey) as? Double
        rangeNM = Self.ranges.contains(stored ?? 0) ? (stored ?? 40) : 40
    }

    /// The next range up or down the ladder, or the current one at either end.
    func range(steppedBy step: Int) -> Double {
        guard let index = Self.ranges.firstIndex(of: rangeNM) else { return 40 }
        let wanted = min(max(index + step, 0), Self.ranges.count - 1)
        return Self.ranges[wanted]
    }
}
