import SwiftUI

/// Chrome shared by everything the toolbar opens — ATC, filters, weather and
/// settings.
///
/// The four panels are siblings, so the parts that make them a set live here
/// rather than being written out four times: same header, same section rules,
/// same rows, same ground. A new panel is its content and nothing else.

// MARK: - Scaffold

/// A toolbar panel: a pinned title, a grabber that closes it, and a scroll
/// view of sections underneath.
///
/// There is no cross in the corner any more. The way out is the handle at the
/// top — see `SheetWindow` — which works wherever the list happens to be
/// scrolled to, which is the thing the old panel could not manage.
struct MapPanel<Content: View>: View {

    let title: String

    /// One line under the title saying what this panel is currently looking
    /// at — the server, the aircraft count. Nil when there is nothing useful
    /// to say, which is better than a line of filler.
    var subtitle: String? = nil

    /// Sits opposite the title: a live count, a reset button.
    var accessory: AnyView? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    // Last, so a panel's contents are the trailing closure.
    @ViewBuilder let content: Content

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        SheetWindow(theme: theme) {
            header
        } content: {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(.horizontal, 16)
                // The window runs to the bottom of the screen, so this is the
                // whole clearance under the last section: enough for the home
                // indicator to float over rather than sit on the last row.
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Pins the content to exactly the window's width, which is what
                // stops the panel sliding about sideways.
                //
                // A vertical `ScrollView` is still a `UIScrollView`, and it
                // scrolls — with rubber-banding — in *any* direction its
                // content overflows. Nothing here asks to be wide, but the
                // panels are full of rows whose two ends are `.fixedSize()`
                // around feed strings of arbitrary length, and one long airport
                // name or controller handle is enough to push a row's ideal
                // width past the window. That made the whole panel draggable
                // left and right, springing back when let go. Sizing the
                // content to the container means there is no horizontal
                // overflow to scroll, whatever a row measures.
                .containerRelativeFrame(.horizontal)
            }
            // ...and this stops the vertical rubber-banding on a short panel,
            // so a field with nothing on it no longer bounces against a fixed
            // window — and, more to the point, so a short panel hands a
            // downward drag straight to the window instead of eating it.
            .scrollBounceBehavior(.basedOnSize)
            // On the content rather than on the window. This is a halo behind
            // text, and hung on the window as a whole it would be a drop
            // shadow around an opaque card instead — the ground would be
            // inside the thing being shadowed.
            .flightInfoLegible(theme)
        }
        .environment(\.colorScheme, theme.colorScheme)
    }

    /// Pinned above the scroll view, and part of the handle: a drag anywhere
    /// across the title closes the panel.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.8)
                }
            }

            Spacer(minLength: 8)

            if let accessory = accessory {
                accessory
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 14)
        .flightInfoLegible(theme)
    }
}

// MARK: - Sections and rows

/// A titled group of rows on one card.
struct PanelSection<Content: View>: View {

    let title: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @ViewBuilder let content: Content

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
                .foregroundStyle(theme.textDim)
                .padding(.leading, 2)

            VStack(spacing: 0) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }
}

/// The hairline between two rows on the same card.
struct PanelDivider: View {

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    var body: some View {
        Rectangle()
            .fill(appearance.theme.stroke)
            .frame(height: 1)
    }
}

/// Icon and title, the left-hand side of most rows.
struct PanelRowLabel: View {

    let title: String
    let symbol: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)

            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.8)
        }
    }
}

/// A row that turns something on and off, with an optional line of explanation
/// under it.
struct PanelToggleRow: View {

    let title: String
    let symbol: String
    var detail: String? = nil
    @Binding var isOn: Bool

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle(isOn: $isOn) {
                PanelRowLabel(title: title, symbol: symbol)
            }
            .tint(theme.accent)

            if let detail = detail {
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    // Clears the icon column, so the explanation lines up under
                    // the title rather than under the glyph.
                    .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A row of segmented choices — units, styles.
struct PanelPickerRow<Value: Hashable & Identifiable>: View {

    let title: String
    let symbol: String
    let options: [Value]
    let label: (Value) -> String
    var detail: String? = nil
    @Binding var selection: Value

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            PanelRowLabel(title: title, symbol: symbol)

            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if let detail = detail {
                Text(detail)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// A row that is on or off by tapping it anywhere — used where a whole set is
/// being narrowed and switches would be a column of noise.
struct PanelCheckRow<Trailing: View>: View {

    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// The count or swatch that sits before the tick. Last, so it can be
    /// written as the row's trailing closure.
    @ViewBuilder var trailing: Trailing

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                PanelRowLabel(title: title, symbol: symbol)

                Spacer(minLength: 8)

                trailing

                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isOn ? theme.textPrimary : theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Off reads as off at a glance, without colour doing the work.
        .opacity(isOn ? 1 : 0.55)
    }
}

extension PanelCheckRow where Trailing == EmptyView {

    init(title: String, symbol: String, isOn: Bool, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, isOn: isOn, action: action) { EmptyView() }
    }
}

/// One controller on frequency: the position, who is working it, and how long
/// they have been on.
///
/// Shared rather than private to the ATC panel, because a field's own panel
/// lists the same thing about the same people — two copies of this drift apart
/// the first time either one is touched.
struct PanelFacilityLine: View {

    let facility: AtcFacility

    /// Passed in rather than read from a clock of this row's own. The panels
    /// that show these already tick once a minute to keep "online for" counting
    /// up, and a busy field is a dozen rows that would otherwise each be
    /// running a timer to display the same minute.
    var now: Date = Date()

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        HStack(spacing: 9) {
            Text(facility.kind.code)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textPrimary)
                .frame(width: 38)
                .padding(.vertical, 4)
                .background { Capsule().fill(theme.elevatedFill) }

            Text(facility.controller)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.7)

            Spacer(minLength: 6)

            if let online = facility.onlineLabel(now: now) {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 8.5))
                    Text(online)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                }
                .foregroundStyle(theme.textDim)
                .fixedSize()
            }
        }
    }
}

/// A row whose whole point is the tap: a destination rather than a setting.
/// Icon, title, a line of explanation, and a chevron.
struct PanelActionRow: View {

    let title: String
    let symbol: String
    var detail: String? = nil
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    PanelRowLabel(title: title, symbol: symbol)

                    if let detail = detail {
                        Text(detail)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            // Clears the icon column, so it reads as a line
                            // under the title rather than under the glyph.
                            .padding(.leading, 30)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// What a panel shows when it has nothing to show — an empty ATC list, a
/// search with no hits. A sentence rather than a blank card, so the panel
/// still says what it is for.
struct PanelEmptyState: View {

    let symbol: String
    let title: String
    let detail: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.textDim)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textSecondary)

            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textDim)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .padding(.horizontal, 20)
    }
}
