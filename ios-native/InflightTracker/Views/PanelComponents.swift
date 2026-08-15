import SwiftUI

/// Chrome shared by everything the toolbar opens — ATC, filters, weather and
/// settings.
///
/// The four panels are siblings, so the parts that make them a set live here
/// rather than being written out four times: same header, same section rules,
/// same rows, same ground. A new panel is its content and nothing else.

// MARK: - Scaffold

/// A toolbar panel: title, optional standfirst, a close button, and a scroll
/// view of sections.
struct MapPanel<Content: View>: View {

    let title: String

    /// One line under the title saying what this panel is currently looking
    /// at — the server, the aircraft count. Nil when there is nothing useful
    /// to say, which is better than a line of filler.
    var subtitle: String? = nil

    /// Sits opposite the title: a live count, a reset button.
    var accessory: AnyView? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @Environment(\.dismiss) private var dismiss

    // Last, so a panel's contents are the trailing closure.
    @ViewBuilder let content: Content

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                content
            }
            .padding(16)
            // The panels are opened from a bar at the bottom of the screen, so
            // the last section wants clearance from the home indicator the
            // sheet is sitting over.
            .padding(.bottom, 16)
        }
        .background { theme.windowFill.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

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

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background { Circle().fill(theme.surfaceFill) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
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
