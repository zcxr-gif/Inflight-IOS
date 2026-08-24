import SwiftUI

/// The places a panel can be opened, and the five of them the toolbar carries.
///
/// Ordered as they are read: who you came to see, then who is working, then
/// where everyone is, then what the map is showing, then the app itself.
/// Friends leads because it is the only one that is about a person.
///
/// Stats and weather are still panels — a widget can link straight to either,
/// and both are still opened from somewhere — but neither takes a place on the
/// bar any more. Weather is a chip on the map's left shoulder, beside the map
/// style and the ruler on its right; the stats come up on a handle above the
/// bar, where they cost nothing until they are pulled.
enum MapPanelKind: String, Identifiable, CaseIterable {

    case friends
    case atc
    case airports
    case stats
    case filters
    case weather
    case settings

    var id: String { rawValue }

    /// What the bar itself shows, in order.
    static let barItems: [MapPanelKind] = [.friends, .atc, .airports, .filters, .settings]

    var label: String {
        switch self {
        case .friends: return "Friends"
        case .atc: return "ATC"
        case .airports: return "Airports"
        case .stats: return "Stats"
        case .filters: return "Filters"
        case .weather: return "Weather"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .friends: return "person.2.fill"
        case .atc: return "antenna.radiowaves.left.and.right"
        // The same glyph the search results mark an airport with, so the two
        // ways into a field look like the same thing.
        case .airports: return "mappin.and.ellipse"
        case .stats: return "chart.bar.fill"
        case .filters: return "line.3.horizontal.decrease"
        case .weather: return "cloud.sun.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The bar along the bottom of the map.
///
/// One piece of chrome rather than four floating buttons, so it reads as the
/// app's own furniture — the same call the flight window's map controls make.
/// It carries the state each destination is in: how many positions are open,
/// and whether the map is being filtered, so neither is a surprise you have to
/// open a panel to discover.
struct MapToolbar: View {

    /// How much of the bottom of the map the bar covers, including the stats
    /// handle sitting on top of it and the gap underneath. The map keeps this
    /// much clear when it frames something, the same way it keeps clear of the
    /// flight window.
    static let reservedHeight: CGFloat = 108

    /// The strip immediately above the bar, kept empty for Apple's "Legal"
    /// link.
    ///
    /// MapKit draws the link in the bottom-left corner of whatever the map's
    /// layout margins leave it, and Apple's terms require it to stay visible
    /// and tappable — so the map lifts it to just above the bar, and the chrome
    /// in the two bottom corners starts above this lane rather than on top of
    /// it.
    static let legalLane: CGFloat = 20

    let theme: FlightInfoTheme

    /// Positions currently open, badged on ATC. Zero shows nothing rather than
    /// a zero, which would read as a broken feed.
    let atcCount: Int

    /// How many of the filter groups are narrowed. Marked rather than counted
    /// out on the bar itself — the point is that the map is not showing
    /// everything.
    let activeFilters: Int

    /// Watched pilots currently in the air. Badged for the same reason ATC is:
    /// it is the one number you would open the panel to find out.
    let friendsAloft: Int

    let action: (MapPanelKind) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MapPanelKind.barItems) { kind in
                Button {
                    action(kind)
                } label: {
                    item(kind)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: kind))
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
    }

    private func item(_ kind: MapPanelKind) -> some View {
        VStack(spacing: 5) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(height: 18)
                // Overlaid on the glyph's corner rather than laid out in the
                // row, so a badge appearing never shifts the four items about.
                .overlay(alignment: .topTrailing) {
                    badge(for: kind)
                        .offset(x: 9, y: -7)
                }

            // Five of these across the narrowest phone the app runs on, which
            // is room enough to read them properly again — the label shrank to
            // nine point when there were seven. It is still allowed to scale
            // before it truncates: a toolbar item whose name is cut in half is
            // an item nobody presses.
            Text(kind.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.65)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func badge(for kind: MapPanelKind) -> some View {
        switch kind {
        case .friends where friendsAloft > 0:
            Text(friendsAloft > 99 ? "99+" : "\(friendsAloft)")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background { Capsule().fill(theme.accent) }
                .fixedSize()

        case .atc where atcCount > 0:
            Text(atcCount > 99 ? "99+" : "\(atcCount)")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(theme.onAccent)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background { Capsule().fill(theme.accent) }
                .fixedSize()

        case .filters where activeFilters > 0:
            Circle()
                .fill(theme.accent)
                .frame(width: 6, height: 6)

        default:
            EmptyView()
        }
    }

    private func accessibilityLabel(for kind: MapPanelKind) -> String {
        switch kind {
        case .friends where friendsAloft > 0:
            return "Friends, \(friendsAloft) flying"
        case .atc where atcCount > 0:
            return "ATC, \(atcCount) positions open"
        case .filters where activeFilters > 0:
            return "Filters, \(activeFilters) active"
        default:
            return kind.label
        }
    }
}
