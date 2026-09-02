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

    /// Observed because the airspace layer is Pro, and `showsAtcBoundaries`
    /// resolves against an entitlement this panel cannot otherwise see change.
    @ObservedObject private var entitlements = Entitlements.shared

    @State private var isShowingPaywall = false

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
                    title: "Flown path",
                    symbol: "point.topleft.down.to.point.bottomright.curvepath",
                    detail: "Draws the track an open flight has actually flown, coloured by the height it was at. Fetched from the server so it reaches back to departure, not just to when you opened the app.",
                    isOn: $filters.showsFlownPath
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Day and night",
                    symbol: "moon.stars",
                    detail: "Washes the half of the world that is in darkness, fading in through twilight the way the real edge does rather than stopping at a line. Worked out on the device from the date and the clock — nothing to fetch.",
                    isOn: $filters.showsTerminator
                )

                PanelDivider()

                PanelToggleRow(
                    title: "North Atlantic tracks",
                    symbol: "arrow.left.and.right",
                    detail: "The organised track system, republished twice a day and coloured by letter, with the levels each track is valid at. It is what explains a hundred aircraft flying in parallel lines across the ocean.",
                    isOn: $filters.showsNatTracks
                )
            }

            // MARK: The flight plan
            //
            // Its own card rather than two more rows in AIRPORTS, because it is
            // its own subject: whether the route an open flight filed is drawn
            // over the map, and how much of it is spelled out when it is. It is
            // also the one layer that reads the same on both shapes of the
            // world — the flat map and the planet plot the same fixes with the
            // same names — so it deserves saying once, plainly, rather than
            // being a line in a list about aerodromes.
            PanelSection(title: "FLIGHT PLAN") {
                PanelPickerRow(
                    title: "Route ahead",
                    symbol: "point.topleft.down.curvedto.point.filled.bottomright.up",
                    options: RouteLineMode.allCases,
                    label: { $0.label },
                    detail: filters.routeLine.detail,
                    selection: $filters.routeLine
                )

                // Only where there is a plan being drawn to put names on. Off
                // and Direct have no fixes, so the row would be a switch with
                // nothing to act on — and a switch that does nothing is worse
                // than one that is not there.
                if filters.showsFlightPlan {
                    PanelDivider()

                    PanelToggleRow(
                        title: "Waypoint names",
                        symbol: "textformat.abc",
                        detail: "Names each fix on the plan. Turn it off to keep the diamonds and lose the labels — a long-haul plan is forty of them, and at a zoom that fits the whole route the names cover the route. On the flat map and the planet alike.",
                        isOn: $filters.showsPlanFixNames
                    )
                }
            }

            // MARK: Controlled airspace
            //
            // Its own card, under the plan and above the traffic filters,
            // because it is the one layer here about *people* rather than about
            // aeroplanes or ground — and because it is the only one that is off
            // until asked for, which a row buried in a list of six would not
            // make obvious.
            //
            // Only where the boundary set actually shipped. Every correct
            // build has it, so this is a guard against one that is wrong
            // rather than a state anybody should reach: without it a missing
            // resource gives a switch that turns on, reports on, and draws
            // nothing — and behind a paywall, so the first person to find it
            // has paid for it.
            if AtcBoundaryStore.shared.isBundled {
                PanelSection(title: "CONTROLLED AIRSPACE") {
                    if !entitlements.isPro {
                        ProUpsellRow(feature: .atcBoundaries) { isShowingPaywall = true }
                        PanelDivider()
                    }

                    PanelToggleRow(
                        title: "ATC boundaries",
                        symbol: "square.dashed",
                        detail: "Outlines the airspace of every centre with somebody working it, and names the station on it. Only staffed sectors — the whole boundary network would be a second map over the first. Off until you ask for it.",
                        isOn: atcBoundaries
                    )
                    .proLocked(entitlements.isPro) { isShowingPaywall = true }
                }
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
        .sheet(isPresented: $isShowingPaywall) { ProPanel(highlighted: .atcBoundaries) }
    }

    /// The switch behind the airspace row.
    ///
    /// Shows what is actually *drawn*, so a free account is never looking at a
    /// switch that reads on over a map with no airspace on it. Hoisted out of
    /// the body rather than written as a ternary in the row — see
    /// `MapStyleSettingsPanel.planeShapes`, which is the same shape and the
    /// same reason.
    private var atcBoundaries: Binding<Bool> {
        guard entitlements.isPro else { return .constant(false) }
        return $filters.wantsAtcBoundaries
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
                .flightInfoSurface(theme, in: Capsule(), elevated: true, interactive: true)
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
