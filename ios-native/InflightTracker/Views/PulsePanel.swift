import SwiftUI

/// What the server is doing tonight, from the toolbar.
///
/// Every number is counted from the packet the map is drawn from, so nothing
/// here can disagree with what is on screen — and nothing here costs a request.
/// It recounts once per packet rather than once per layout pass: it is a walk
/// over every aircraft on the server, which is cheap a few times a minute and
/// wasteful several times a second.
struct PulsePanel: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// Opening a field from one of the lists — the whole reason the busiest
    /// fields are worth ranking is that you then want to look at one.
    var onSelectAirport: (Airport) -> Void = { _ in }

    @State private var pulse = ServerPulse.empty

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Stats", subtitle: subtitle) {
            headline

            if pulse.total == 0 {
                PanelEmptyState(
                    symbol: "chart.bar",
                    title: "Nothing to count yet",
                    detail: "The first packet has not arrived. This fills in the moment it does."
                )
            } else {
                phases
                altitudes
                airports(title: "BUSIEST DEPARTURES", tallies: pulse.busiestDepartures)
                airports(title: "BUSIEST ARRIVALS", tallies: pulse.busiestArrivals)
                routes
                types
                aircraft
            }

            HintStrip(placement: .stats)

            Text("Counted from the same packet the map is drawn from, so these can never disagree with what is on screen. Nothing here is fetched.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 2)
        }
        .onAppear(perform: recount)
        .onChange(of: feed.lastUpdate) { _, _ in recount() }
    }

    private func recount() {
        pulse = ServerPulse.from(flights: feed.flights, stations: feed.atcStations)
    }

    private var subtitle: String {
        guard feed.status.isLive else { return feed.status.label }
        return feed.server
    }

    // MARK: - The three numbers at the top

    private var headline: some View {
        HStack(spacing: 8) {
            figure(
                "\(pulse.airborne)",
                label: "IN THE AIR",
                detail: pulse.total > 0
                    ? "\(percent(pulse.airborne, of: pulse.total)) of the server"
                    : nil
            )
            figure(
                "\(pulse.onGround)",
                label: "ON THE GROUND",
                detail: pulse.staffedFields > 0
                    ? "\(pulse.staffedFields) staffed field\(pulse.staffedFields == 1 ? "" : "s")"
                    : nil
            )
            figure(
                "\(pulse.controllers)",
                label: "ON FREQUENCY",
                detail: pulse.controllers == 0 ? "Nobody working" : nil
            )
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ value: String, label: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 26, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)

            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textSecondary)
                .flightInfoLine(minimumScale: 0.7)

            Text(detail ?? " ")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.7)
                .opacity(detail == nil ? 0 : 1)
                .accessibilityHidden(detail == nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
    }

    // MARK: - Distributions

    private var phases: some View {
        PanelSection(title: "WHAT EVERYONE IS DOING") {
            let counts = FlightPhase.allCases.map { ($0, pulse.byPhase[$0] ?? 0) }
            let peak = counts.map(\.1).max() ?? 1

            ForEach(Array(counts.enumerated()), id: \.offset) { index, entry in
                if index > 0 { PanelDivider() }
                bar(
                    title: entry.0.label,
                    symbol: entry.0.symbol,
                    count: entry.1,
                    peak: peak,
                    total: pulse.total,
                    tint: theme.accent
                )
            }
        }
    }

    private var altitudes: some View {
        PanelSection(title: "HOW HIGH") {
            let counts = AltitudeBand.all.map { ($0, pulse.byBand[$0] ?? 0) }
            let peak = counts.map(\.1).max() ?? 1

            ForEach(Array(counts.enumerated()), id: \.offset) { index, entry in
                if index > 0 { PanelDivider() }
                bar(
                    title: AltitudeBand.label(for: entry.0),
                    symbol: "arrow.up.and.down",
                    count: entry.1,
                    peak: peak,
                    total: pulse.airborne,
                    // The same colour the map paints a path at this height, so
                    // the chart and the traffic agree on what "high" means.
                    tint: Color(uiColor: AltitudeBand.color(for: entry.0))
                )
            }

            if pulse.airborne > 0 {
                PanelDivider()

                HStack(spacing: 8) {
                    MiniStat(
                        label: "MEDIAN",
                        value: "\(Format.number(pulse.medianAltitudeFeet)) ft",
                        theme: theme
                    )
                    MiniStat(
                        label: "AVERAGE SPEED",
                        value: "\(Format.number(pulse.averageGroundSpeedKnots)) kts",
                        theme: theme,
                        alignment: .trailing
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    private var aircraft: some View {
        PanelSection(title: "WHAT THEY ARE FLYING") {
            let counts = AircraftCategory.allCases.map { ($0, pulse.byCategory[$0] ?? 0) }
            let peak = counts.map(\.1).max() ?? 1

            ForEach(Array(counts.enumerated()), id: \.offset) { index, entry in
                if index > 0 { PanelDivider() }
                bar(
                    title: entry.0.label,
                    symbol: entry.0.symbol,
                    count: entry.1,
                    peak: peak,
                    total: pulse.total,
                    tint: theme.accent
                )
            }
        }
    }

    // MARK: - Rankings

    /// A ranked list of fields, each row opening that field.
    @ViewBuilder
    private func airports(title: String, tallies: [ServerPulse.Tally]) -> some View {
        if !tallies.isEmpty {
            PanelSection(title: title) {
                ForEach(Array(tallies.enumerated()), id: \.element.id) { index, tally in
                    if index > 0 { PanelDivider() }

                    Button {
                        guard let airport = AirportStore.shared.airport(tally.name) else { return }
                        onSelectAirport(airport)
                    } label: {
                        rankRow(tally, peak: tallies.first?.count ?? 1, chevron: true)
                    }
                    .buttonStyle(.plain)
                    .disabled(AirportStore.shared.airport(tally.name) == nil)
                }
            }
        }
    }

    @ViewBuilder
    private var routes: some View {
        if !pulse.busiestRoutes.isEmpty {
            PanelSection(title: "BUSIEST ROUTES") {
                ForEach(Array(pulse.busiestRoutes.enumerated()), id: \.element.id) { index, tally in
                    if index > 0 { PanelDivider() }
                    rankRow(tally, peak: pulse.busiestRoutes.first?.count ?? 1, chevron: false)
                }

                if let longest = pulse.longestRoute {
                    PanelDivider()

                    VStack(alignment: .leading, spacing: 4) {
                        Text("LONGEST IN THE AIR")
                            .font(.system(size: 8.5, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(theme.textDim)

                        Text(longest.name)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .flightInfoLine(minimumScale: 0.7)

                        if let detail = longest.detail {
                            Text(detail)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .flightInfoLine(minimumScale: 0.7)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private var types: some View {
        if !pulse.commonestTypes.isEmpty {
            PanelSection(title: "COMMONEST TYPES") {
                ForEach(Array(pulse.commonestTypes.enumerated()), id: \.element.id) { index, tally in
                    if index > 0 { PanelDivider() }
                    rankRow(tally, peak: pulse.commonestTypes.first?.count ?? 1, chevron: false)
                }
            }
        }
    }

    // MARK: - Rows

    /// A ranked row: what it is, a bar for how much of the top it is, and the
    /// count. The bar is relative to the leader rather than to the whole
    /// server, because the leader is what the eye is comparing against.
    private func rankRow(
        _ tally: ServerPulse.Tally,
        peak: Int,
        chevron: Bool
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tally.name)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.7)

                if let detail = tally.detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }

                track(fraction: peak > 0 ? Double(tally.count) / Double(peak) : 0, tint: theme.accent)
            }

            Spacer(minLength: 6)

            Text("\(tally.count)")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .fixedSize()

            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// A labelled bar: a glyph, a name, the bar itself, and the count with its
    /// share of the whole.
    private func bar(
        title: String,
        symbol: String,
        count: Int,
        peak: Int,
        total: Int,
        tint: Color
    ) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                PanelRowLabel(title: title, symbol: symbol)
                track(fraction: peak > 0 ? Double(count) / Double(peak) : 0, tint: tint)
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)

                Text(percent(count, of: total))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // The count and the share are already on the row; a screen reader
        // should hear one sentence rather than four fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count), \(percent(count, of: total))")
    }

    private func track(fraction: Double, tint: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.trackFill)
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 4)
    }

    private func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "—" }
        let share = Double(value) / Double(total) * 100
        // Under a tenth of a percent still rounds to something, and "0%" beside
        // a non-zero count reads as a bug.
        if value > 0 && share < 1 { return "<1%" }
        return "\(Int(share.rounded()))%"
    }
}
