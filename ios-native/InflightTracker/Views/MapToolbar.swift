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

/// The bar of destinations, inside the dock.
///
/// One piece rather than five floating buttons, so it reads as the app's own
/// furniture — the same call the flight window's map controls make. It carries
/// the state each destination is in: how many positions are open, and whether
/// the map is being filtered, so neither is a surprise you have to open a panel
/// to discover.
///
/// Drawn on a raised surface rather than on its own glass: it sits inside
/// `MapDock`, which is already glass, and glass on glass reads as two cards
/// stacked rather than as a bar on a dock.
///
/// Every measurement here is written down rather than eyeballed, because the
/// thing that went wrong last time was arithmetic. The bar's corner radius has
/// to be the dock's radius less the inset the dock holds it at, or the two
/// curves are not concentric and the bar reads as a rectangle sitting in a
/// rounded box. The five items have to be one size, whatever their glyph and
/// however long their word, or their icons sit on five different lines. And the
/// badges have to hang off a box rather than off a glyph, or a badge appearing
/// nudges the item under it. All three were wrong, which is why the tools did
/// not match the box they were in.
struct MapToolbar: View {

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

    // MARK: - Metrics

    /// The bar's own corner radius: the dock's radius, less the horizontal
    /// padding the dock holds the bar at. Concentric with the card around it.
    static let radius: CGFloat = MapDock.cornerRadius - MapDock.cardInset

    /// How far the items sit inside the bar. The same on all four sides, so the
    /// row is centred in the shape it is drawn on rather than being pushed at
    /// one edge by the dock's uneven padding.
    static let inset: CGFloat = 4

    /// ...and the items' own radius, concentric again with the bar.
    static let itemRadius: CGFloat = radius - inset

    /// The two rows every item is built from, fixed rather than intrinsic.
    ///
    /// `mappin.and.ellipse` is taller than `person.2.fill` and "Airports" is
    /// wider than "ATC"; left to size themselves, the five items came out five
    /// different heights and their glyphs sat on five different lines. Boxed,
    /// they are one row of five identical cells.
    static let iconRow: CGFloat = 20
    static let labelRow: CGFloat = 12
    static let iconBox: CGFloat = 26
    static let rowGap: CGFloat = 4
    static let itemPadding: CGFloat = 6

    /// One item, and then the bar around them.
    ///
    /// Forty-eight and fifty-six. That is not an accident: a system tab bar is
    /// forty-nine points tall, and this is the same furniture doing the same
    /// job. It was sixty-two, which is a bar noticeably fatter than the one
    /// every other app on the phone puts in the same place.
    static let itemHeight: CGFloat = iconRow + rowGap + labelRow + itemPadding * 2
    static let height: CGFloat = itemHeight + inset * 2

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MapPanelKind.barItems) { kind in
                Button {
                    action(kind)
                } label: {
                    item(kind)
                }
                .buttonStyle(ToolbarItemStyle(theme: theme))
                .accessibilityLabel(accessibilityLabel(for: kind))
            }
        }
        .padding(Self.inset)
        // Stated rather than left to the content, so the dock knows how tall
        // its own bar is before either of them has drawn.
        .frame(height: Self.height)
        .flightInfoSurface(theme, radius: Self.radius, elevated: true)
    }

    private func item(_ kind: MapPanelKind) -> some View {
        VStack(spacing: Self.rowGap) {
            Image(systemName: kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                // A fixed box, identical for all five. The badge hangs off the
                // corner of the box rather than off the glyph, so a badge
                // arriving never shifts the item under it and every badge on
                // the bar sits at the same height.
                .frame(width: Self.iconBox, height: Self.iconRow)
                .overlay(alignment: .topTrailing) {
                    badge(for: kind)
                        .offset(x: 4, y: -4)
                }

            // Five of these across the narrowest phone the app runs on, which
            // is room enough to read them properly. Allowed to scale a little
            // before it truncates: a toolbar item whose name is cut in half is
            // an item nobody presses.
            Text(kind.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.75)
                .frame(height: Self.labelRow)
        }
        .padding(.vertical, Self.itemPadding)
        // `minWidth: 0` as well as the maximum, and it is the half that
        // matters. A row of children that are only flexible upwards is divided
        // by how much each of them can give, so "Airports" claimed a wider slot
        // than "ATC" and the five items came out five different widths — which
        // is what put their icons off the centres of their cells. Flexible from
        // nothing to everything, all five are identical, and the bar divides
        // into five equal boxes with a tool centred in each.
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: Self.itemHeight)
        .contentShape(RoundedRectangle(cornerRadius: Self.itemRadius, style: .continuous))
    }

    @ViewBuilder
    private func badge(for kind: MapPanelKind) -> some View {
        switch kind {
        case .friends where friendsAloft > 0:
            count(friendsAloft)

        case .atc where atcCount > 0:
            count(atcCount)

        case .filters where activeFilters > 0:
            Circle()
                .fill(theme.accent)
                .frame(width: 6, height: 6)

        default:
            EmptyView()
        }
    }

    /// A number on a glyph. Written once rather than twice: two copies of this
    /// drift apart the first time either is touched.
    private func count(_ value: Int) -> some View {
        Text(value > 99 ? "99+" : "\(value)")
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(theme.onAccent)
            .padding(.horizontal, 3.5)
            .padding(.vertical, 1.5)
            .background { Capsule().fill(theme.accent) }
            .fixedSize()
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

/// The press.
///
/// The items used to be plain: you pressed one and nothing happened until the
/// panel arrived, which on a slow open reads as a tap that missed. This fills
/// the item's own cell — concentric with the bar, so the highlight is the shape
/// of the box the tool is in rather than a rectangle inside a rounded one.
private struct ToolbarItemStyle: ButtonStyle {

    let theme: FlightInfoTheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: MapToolbar.itemRadius, style: .continuous)
                    .fill(theme.surfaceFill)
                    .opacity(configuration.isPressed ? 1 : 0)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(Motion.control, value: configuration.isPressed)
    }
}
