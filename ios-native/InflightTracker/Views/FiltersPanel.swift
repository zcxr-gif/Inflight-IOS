import SwiftUI

/// What the map is drawing, from the toolbar's filters button.
///
/// The count in the header is live: it is the same filter the map is applying,
/// run against the packet on screen, so turning a phase off shows immediately
/// how much of the server that was.
struct FiltersPanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var filters = MapFilters.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// One pass over the packet for everything the panel counts: how much
    /// survives the filter, and how much sits in each phase. Walked once here
    /// rather than once per row, since this is re-read on every feed tick the
    /// panel is open for.
    private var tally: (shown: Int, byPhase: [FlightPhase: Int], byCategory: [AircraftCategory: Int]) {
        var shown = 0
        var byPhase: [FlightPhase: Int] = [:]
        var byCategory: [AircraftCategory: Int] = [:]

        for flight in feed.flights {
            if filters.matches(flight) { shown += 1 }
            byPhase[FlightPhase.from(flight), default: 0] += 1
            byCategory[AircraftCategory.from(spriteKey: flight.spriteKey), default: 0] += 1
        }

        return (shown, byPhase, byCategory)
    }

    var body: some View {
        let tally = self.tally

        MapPanel(
            title: "Filters",
            subtitle: "\(tally.shown) of \(feed.flights.count) aircraft shown",
            accessory: filters.isFiltering ? AnyView(resetButton) : nil
        ) {
            PanelSection(title: "AIRPORTS") {
                PanelToggleRow(
                    title: "Show airports",
                    symbol: "mappin.and.ellipse",
                    detail: "Marks fields with somebody on frequency, and the busiest of the rest. Tap one to open it.",
                    isOn: $filters.showsAirports
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Ground layout",
                    symbol: "point.topleft.down.curvedto.point.bottomright.up",
                    detail: "Draws runways, taxiways and terminals with their names once the map is over a field. From OpenStreetMap, so it is as good as the field's mapping.",
                    isOn: $filters.showsGroundLayout
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Filed waypoints",
                    symbol: "point.topleft.down.curvedto.point.filled.bottomright.up",
                    detail: "Plots the fixes on an open flight's filed plan, named, with the route through them. Procedures are expanded to the fixes they contain. Most pilots file nothing, and nothing is drawn when they haven't.",
                    isOn: $filters.showsFlightPlan
                )
            }

            PanelSection(title: "PHASE") {
                ForEach(FlightPhase.allCases, id: \.self) { phase in
                    if phase != FlightPhase.allCases.first { PanelDivider() }

                    PanelCheckRow(
                        title: phase.label,
                        symbol: phase.symbol,
                        isOn: filters.phases.contains(phase),
                        action: { filters.toggle(phase) }
                    ) {
                        count(of: tally.byPhase[phase] ?? 0)
                    }
                }
            }

            PanelSection(title: "AIRCRAFT") {
                ForEach(AircraftCategory.allCases) { category in
                    if category != AircraftCategory.allCases.first { PanelDivider() }

                    PanelCheckRow(
                        title: category.label,
                        symbol: category.symbol,
                        isOn: filters.categories.contains(category),
                        action: { filters.toggle(category: category) }
                    ) {
                        count(of: tally.byCategory[category] ?? 0)
                    }
                }
            }

            PanelSection(title: "ALTITUDE") {
                ForEach(AltitudeBand.all, id: \.self) { band in
                    if band != AltitudeBand.all.first { PanelDivider() }

                    PanelCheckRow(
                        title: AltitudeBand.label(for: band),
                        symbol: "arrow.up.and.down",
                        isOn: filters.bands.contains(band),
                        action: { filters.toggle(band: band) }
                    ) {
                        // The same colour the map paints a flown path at this
                        // height, so the filter and the track agree on what
                        // this band is.
                        Circle()
                            .fill(Color(uiColor: AltitudeBand.color(for: band)))
                            .frame(width: 7, height: 7)
                    }
                }
            }

            PanelSection(title: "ROUTE") {
                PanelToggleRow(
                    title: "Filed destination only",
                    symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    detail: "Hides aircraft with nothing filed — sightseeing, pattern work, and anything parked.",
                    isOn: $filters.filedRouteOnly
                )
            }

            Text("Filters only change what is drawn. The feed is unchanged, so nothing has to be re-fetched when you turn one back on.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 2)

            HintStrip(placement: .filters)
        }
    }

    private var resetButton: some View {
        Button {
            filters.reset()
        } label: {
            Text("RESET")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background { Capsule().fill(theme.elevatedFill) }
        }
        .buttonStyle(.plain)
    }

    /// How many aircraft a row currently accounts for. Dim and monospaced —
    /// it is a number to glance at, not the point of the row.
    private func count(of value: Int) -> some View {
        Text("\(value)")
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.textDim)
            .fixedSize()
    }
}
