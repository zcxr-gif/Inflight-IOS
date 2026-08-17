import SwiftUI

/// The row of chips under the search field.
///
/// Every narrowing anyone actually reaches for, one tap away, without opening a
/// panel over the map to get at it. The filters panel is still where the whole
/// model lives — altitude bands, individual phases, the counts — and this is
/// the handful of shapes that panel gets put into over and over.
///
/// Each chip reads its own lit state back off the live filter rather than
/// holding one, so the row and the panel cannot disagree: narrow to military in
/// the panel and the Military chip lights up on its own.
struct MapQuickFilters: View {

    let theme: FlightInfoTheme

    /// Counted per chip over the packet, so a chip can say how much of the
    /// server it would leave you with. Passed in already tallied — the row is
    /// redrawn on every feed tick, and walking the traffic once per chip is
    /// eight passes for a number nobody reads that closely.
    let counts: [MapFilters.QuickFilter: Int]

    @ObservedObject private var filters = MapFilters.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(MapFilters.QuickFilter.allCases) { quick in
                    chip(quick)
                }
            }
            .padding(.horizontal, 2)
            // Room for the lit chip's own edge, which the scroll view would
            // otherwise clip flush.
            .padding(.vertical, 2)
        }
        // Deliberately clipping: the row ends where the rail's bubbles begin,
        // and content allowed to draw past that would slide underneath them.
        .environment(\.colorScheme, .dark)
    }

    private func chip(_ quick: MapFilters.QuickFilter) -> some View {
        let isOn = filters.isActive(quick)
        let count = counts[quick]

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                filters.toggle(quick)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark" : quick.symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isOn ? theme.onAccent : theme.textSecondary)

                Text(quick.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(isOn ? theme.onAccent : theme.textPrimary)
                    .fixedSize()

                // Only where it means something. "All traffic" is the whole
                // packet and the connection strip already says that; a chip
                // that would leave you nothing says so, which is the one case
                // where the number changes what you do.
                if let count = count, quick != .all {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(isOn ? theme.onAccent.opacity(0.7) : theme.textDim)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background {
                if isOn { Capsule().fill(theme.accent) }
            }
            .flightInfoChrome(theme, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel(quick, count: count))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func accessibilityLabel(_ quick: MapFilters.QuickFilter, count: Int?) -> String {
        guard let count = count, quick != .all else { return quick.label }
        return "\(quick.label), \(count) aircraft"
    }

    /// How many aircraft each chip would leave on the map.
    ///
    /// One pass over the packet for all eight, because this is recomputed every
    /// time the feed publishes. Each chip is counted on its own terms rather
    /// than combined with whatever else is currently set — the number answers
    /// "how much is this", not "how much would be left after everything else
    /// I have already turned off".
    static func counts(for flights: [Flight]) -> [MapFilters.QuickFilter: Int] {
        var counts: [MapFilters.QuickFilter: Int] = [:]

        for flight in flights {
            counts[.all, default: 0] += 1

            if FlightPhase.from(flight) != .ground {
                counts[.airborne, default: 0] += 1
            }

            if flight.arrivalIcao?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                counts[.filed, default: 0] += 1
            }

            switch AircraftCategory.from(spriteKey: flight.spriteKey) {
            case .airliner: counts[.airliners, default: 0] += 1
            case .regional: counts[.regional, default: 0] += 1
            case .light: counts[.light, default: 0] += 1
            case .military: counts[.military, default: 0] += 1
            case .helicopter: counts[.helicopters, default: 0] += 1
            }
        }

        return counts
    }
}
