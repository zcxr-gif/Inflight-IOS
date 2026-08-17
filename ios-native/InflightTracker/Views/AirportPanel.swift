import Combine
import SwiftUI

/// One field, opened from the search results.
///
/// Searching an ICAO used to move the map and stop there, which answered
/// "where is it" and nothing else. The interesting questions about an airport
/// are all about its traffic — who is controlling, what is on the way in, what
/// has just left, what is sitting on the apron — and every one of those is
/// already on the device: the packet the feed last published, the controllers
/// on their own channel, and the offline airport dataset. So this is a reading
/// of what the app already knows rather than anything new being fetched, and
/// the only thing here that touches the network is the field's METAR.
///
/// Tapping any aircraft on it opens that aircraft's own window, which is where
/// the search result used to be a dead end.
struct AirportPanel: View {

    let airport: Airport

    /// Take the map to the field. Closes the panel first — the map's edge
    /// padding is sized for the toolbar rather than for a half-height sheet, so
    /// the field would otherwise be framed underneath this.
    let onShowOnMap: (Airport) -> Void

    /// Open one of the aircraft listed here.
    let onSelectFlight: (Flight) -> Void

    /// The flight this field was reached from, when it was reached from one.
    ///
    /// Opening a field replaces whatever sheet was up, so arriving here from an
    /// aircraft's route card costs you the aircraft. That is fine from the
    /// search results or the board, where there was nothing to come back to,
    /// and not fine from a flight — which is why the way back is carried in
    /// rather than assumed.
    var origin: Origin? = nil

    /// Where the panel was opened from, and how to get back to it.
    struct Origin {
        /// What to call it on the row — a callsign, normally.
        let label: String
        let action: () -> Void
    }

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var weatherPreferences = WeatherPreferences.shared

    /// The field's own report. Seeded from the cache so a field looked at twice
    /// draws its weather immediately, then replaced when the fetch lands.
    @State private var metar: Metar?

    /// Whether the weather service has answered about this field yet.
    ///
    /// Most of the world's strips have never filed a METAR, and from an empty
    /// `metar` that is indistinguishable from a fetch still in the air. They
    /// read very differently, so the card waits to be told which it is instead
    /// of announcing "no report" for the second before one arrives.
    @State private var hasWeatherAnswer = false

    /// The field's photograph and the details the bundled dataset never
    /// carried — city, elevation, airspace class, 3D buildings. Nil until the
    /// lookup answers, which is what lets the hero tell "still asking" from
    /// "nothing to show".
    @State private var info: AirportInfo?

    /// The field's ATIS, when a controller is running one. Nil throughout for
    /// the great majority of fields, which is why there is no empty state for
    /// it — the section simply isn't there.
    @State private var atis: Atis?

    /// Re-read once a minute so "online for" counts up and the report is
    /// refreshed while the panel is open. The traffic lists are redrawn by the
    /// feed itself.
    @State private var now = Date()

    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var theme: FlightInfoTheme { appearance.theme }

    /// Recomputed per redraw rather than held in state: it is a filtered pass
    /// over the packet, and holding it would mean keeping it in step with a
    /// feed that republishes every few seconds.
    private var activity: AirportActivity {
        AirportActivity.at(airport, in: feed.flights)
    }

    /// The controllers working this field, when any are. Matched on the
    /// station's identifier, which for an airfield is its ICAO.
    private var station: AtcStation? {
        feed.atcStations.first { !$0.isCenter && $0.identifier == airport.icao }
    }

    /// Every open runway here, longest first. Read from the bundled dataset, so
    /// this costs a dictionary lookup and works with no connectivity at all.
    private var runways: [Runway] {
        RunwayStore.shared.runways(at: airport.icao)
    }

    var body: some View {
        // Both are walked more than once by the sections below, and the body
        // is re-run on every feed tick — read once here rather than three
        // times per redraw.
        let activity = self.activity
        let runways = self.runways

        MapPanel(
            title: airport.icao,
            subtitle: subtitle(for: activity),
            accessory: airport.flag.isEmpty ? nil : AnyView(flag)
        ) {
            // The photograph and the figures under it are one header, grouped
            // rather than listed — and the panel's own builder only takes ten
            // things, which these two would otherwise both spend.
            VStack(alignment: .leading, spacing: 14) {
                AirportHero(
                    airport: airport,
                    info: info,
                    isControlled: station != nil,
                    category: metar?.flightCategory,
                    theme: theme
                )

                AirportStatStrip(
                    inbound: activity.inbound.count,
                    outbound: activity.outbound.count,
                    onGround: activity.onGround.count,
                    longestRunway: runways.first,
                    theme: theme
                )
            }

            PanelSection(title: "FIELD") {
                // First, above the map row: it is the way out of somewhere you
                // arrived at by a tap, and burying that under the field's own
                // actions is how a panel becomes a trap.
                if let origin = origin {
                    PanelActionRow(
                        title: "Back to \(origin.label)",
                        symbol: "chevron.backward",
                        action: origin.action
                    )

                    PanelDivider()
                }

                PanelActionRow(
                    title: "Show on map",
                    symbol: "location.magnifyingglass",
                    detail: airport.name
                ) {
                    onShowOnMap(airport)
                }
            }

            frequencies

            atisSection

            weather

            runwaySection(runways)

            details(runways)

            traffic(activity)

            HintStrip(placement: .airport)
        }
        .onAppear {
            if let cached = WeatherService.shared.cached(airport.icao) {
                metar = cached
                hasWeatherAnswer = true
            }
            // Seeded from the cache so a field opened twice draws its
            // photograph on the first frame instead of fading one in again.
            info = AirportInfoService.shared.cached(airport.icao)
            atis = AtisService.shared.cached(airport.icao, server: feed.server)
            loadMetar()
            loadInfo()
            loadAtis()
        }
        .onReceive(clock) { tick in
            now = tick
            // The service holds a report for ten minutes, so this costs a
            // dictionary lookup nine times out of ten and picks up the new
            // hour's observation on the tenth.
            loadMetar()
            // The ATIS is reissued whenever conditions change and its service
            // holds one for two minutes, so this actually re-asks — which is
            // the point. An information letter you are reading should be the
            // one currently being broadcast.
            loadAtis()
        }
    }

    private func subtitle(for activity: AirportActivity) -> String {
        let movements = activity.movementCount
        guard movements > 0 else { return "\(airport.name) · \(feed.server)" }
        let label = movements == 1 ? "1 aircraft" : "\(movements) aircraft"
        return "\(label) · \(feed.server)"
    }

    /// Sits opposite the ICAO in the header. Left off entirely for the handful
    /// of entries whose country didn't resolve, rather than holding a gap open
    /// for a placeholder.
    private var flag: some View {
        Text(airport.flag)
            .font(.system(size: 22))
            .accessibilityHidden(true)
    }

    // MARK: - On frequency

    /// Only drawn when somebody is working the field. An empty state here would
    /// be a card saying "no ATC" on every quiet airport in the world, which is
    /// most of them — the absence of the section is the same information,
    /// without the furniture.
    @ViewBuilder
    private var frequencies: some View {
        if let station = station {
            PanelSection(title: "ON FREQUENCY") {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(station.facilities) { facility in
                        PanelFacilityLine(facility: facility, now: now)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - ATIS

    /// Only there while one is being broadcast, which is only while somebody is
    /// controlling. Nothing is said for a field without one — the absence is
    /// the same information as a card announcing "no ATIS" on every quiet
    /// airport in the world.
    @ViewBuilder
    private var atisSection: some View {
        if let atis = atis {
            PanelSection(title: atis.information.map { "ATIS · INFORMATION \($0)" } ?? "ATIS") {
                VStack(alignment: .leading, spacing: 0) {
                    if atis.hasStructure {
                        atisChips(atis)
                        PanelDivider()
                    }

                    if let remarks = atis.remarks {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.bubble")
                                .font(.system(size: 11))
                                .foregroundStyle(theme.textSecondary)

                            Text(remarks)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        PanelDivider()
                    }

                    // The broadcast as written. Same call as the raw METAR
                    // below it: the parser above reads what it recognises, and
                    // everything it didn't is still here to be read.
                    Text(atis.raw)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                }
            }
        }
    }

    /// Runways in use and what to expect on the way in — the reason anyone
    /// listens to the thing.
    private func atisChips(_ atis: Atis) -> some View {
        HStack(spacing: 8) {
            if let landing = atis.landingRunways {
                atisChip("LANDING", value: landing, symbol: "airplane.arrival")
            }

            if let departing = atis.departingRunways {
                atisChip("DEPARTING", value: departing, symbol: "airplane.departure")
            }

            if let approach = atis.approach {
                atisChip("APPROACH", value: approach, symbol: "arrow.down.right")
            }

            Spacer(minLength: 0)

            if let time = atis.time {
                Text(time)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textDim)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func atisChip(_ label: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 8, weight: .semibold))
                Text(label)
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.5)
            }
            .foregroundStyle(theme.textDim)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.7)
        }
        .fixedSize()
    }

    private func loadAtis() {
        AtisService.shared.atis(for: airport.icao, server: feed.server) { fetched in
            atis = fetched
        }
    }

    // MARK: - Weather

    private var weather: some View {
        PanelSection(title: "WEATHER") {
            if let metar = metar {
                VStack(alignment: .leading, spacing: 0) {
                    report(metar)
                    PanelDivider()
                    facts(metar)
                    PanelDivider()
                    raw(metar)
                }
            } else {
                Text(hasWeatherAnswer
                     ? "No report filed for \(airport.icao)."
                     : "Checking for a report…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
            }
        }
    }

    private func report(_ metar: Metar) -> some View {
        HStack(spacing: 12) {
            Image(systemName: metar.symbol(isDaylight: isDaylight))
                .font(.system(size: 24))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(metar.conditionLabel)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .flightInfoLine(minimumScale: 0.8)

                Text(conditions(metar))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.75)
            }

            Spacer(minLength: 8)

            Text(metar.temperatureLabel(in: weatherPreferences.temperatureUnit))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The three figures a pilot reads the report for, under the headline:
    /// what the field is legally good for, how low the cloud is, and how close
    /// the air is to fogging over.
    ///
    /// The category is derived here rather than reported — no METAR contains
    /// the word — which is the fix for what the web build did: it searched the
    /// raw text for "IFR" and found it nowhere, so every field read VFR.
    private func facts(_ metar: Metar) -> some View {
        HStack(spacing: 10) {
            if let category = metar.flightCategory {
                VStack(alignment: .leading, spacing: 3) {
                    FlightCategoryBadge(category: category)

                    Text(category.detail)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.7)
                }
            }

            Spacer(minLength: 6)

            fact("CEILING", value: metar.ceilingLabel)

            if let spread = metar.dewPointSpreadC {
                fact(
                    "SPREAD",
                    value: "\(Int(spread.rounded()))°",
                    // A degree or two between temperature and dew point is fog
                    // forming, which is the whole reason to show the number.
                    caption: spread <= 2 ? "Fog likely" : nil
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func fact(_ label: String, value: String, caption: String? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.textDim)

            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)

            if let caption = caption {
                Text(caption)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .fixedSize()
    }

    /// The report as it was written. Kept because it is the only thing on the
    /// panel that says something the parser dropped — runway state, trends,
    /// remarks — and anyone reading a field's weather in an ICAO panel can read
    /// a METAR.
    private func raw(_ metar: Metar) -> some View {
        Text(metar.raw)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.textDim)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
    }

    private func conditions(_ metar: Metar) -> String {
        var parts = [metar.windLabel(in: weatherPreferences.windUnit)]
        if let visibility = metar.visibilityLabel { parts.append(visibility) }
        return parts.joined(separator: " · ")
    }

    private var isDaylight: Bool { SolarPosition.isDaylight(at: airport.coordinate) }

    // MARK: - Runways

    /// Only drawn where the dataset has runways, which is most fields but not
    /// all — heliports and water aerodromes have none surveyed, and an empty
    /// card saying so would be furniture.
    @ViewBuilder
    private func runwaySection(_ runways: [Runway]) -> some View {
        if !runways.isEmpty {
            let favoured = FavouredRunway.best(for: runways, metar: metar)

            PanelSection(title: runways.count == 1 ? "RUNWAY" : "RUNWAYS · \(runways.count)") {
                ForEach(runways) { runway in
                    if runway.id != runways.first?.id { PanelDivider() }
                    RunwayCard(runway: runway, favoured: favoured, theme: theme)
                }

                if favoured != nil {
                    PanelDivider()

                    Text("Favoured end is the one with the most wind down it, from the field's own report. Headings are true, so a runway number won't always match to the degree.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - Details

    /// The reference figures: where it is, how high, what airspace, what time
    /// it is there. The same grid the web tracker's airport window carried
    /// under its tabs, kept because every line of it is a thing you would
    /// otherwise leave the app to look up.
    @ViewBuilder
    private func details(_ runways: [Runway]) -> some View {
        let rows = detailRows(runways)

        if !rows.isEmpty {
            PanelSection(title: "DETAILS") {
                ForEach(rows) { row in
                    if row.id != rows.first?.id { PanelDivider() }

                    HStack(spacing: 10) {
                        PanelRowLabel(title: row.label, symbol: row.symbol)

                        Spacer(minLength: 8)

                        Text(row.value)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                }
            }
        }
    }

    /// Built rather than laid out, so a line the backend didn't answer is
    /// absent instead of being an em dash. The coordinates always resolve —
    /// they come from the bundled dataset — so the grid is never empty.
    private func detailRows(_ runways: [Runway]) -> [DetailRow] {
        var rows: [DetailRow] = [
            DetailRow(
                label: "Coordinates",
                symbol: "location.circle",
                value: String(
                    format: "%.3f, %.3f",
                    airport.coordinate.latitude,
                    airport.coordinate.longitude
                )
            )
        ]

        if let elevation = info?.elevationLabel {
            rows.append(DetailRow(label: "Elevation", symbol: "arrow.up.and.down", value: elevation))
        }

        if let airspace = info?.airspaceClass, !airspace.isEmpty {
            rows.append(DetailRow(label: "Airspace", symbol: "chart.bar.fill", value: "Class \(airspace)"))
        }

        if let zone = info?.timezoneLabel {
            rows.append(DetailRow(label: "Timezone", symbol: "globe", value: zone))
        }

        if !airport.countryCode.isEmpty {
            rows.append(DetailRow(label: "Country", symbol: "flag", value: airport.countryCode.uppercased()))
        }

        if !runways.isEmpty {
            rows.append(DetailRow(label: "Runways", symbol: "road.lanes", value: "\(runways.count)"))
        }

        return rows
    }

    /// One line of the details grid. Identified by its label, which is unique
    /// within the grid and stable across the lookup landing — so a row
    /// appearing when the backend answers doesn't re-key the ones already
    /// drawn.
    private struct DetailRow: Identifiable {
        let label: String
        let symbol: String
        let value: String

        var id: String { label }
    }

    private func loadInfo() {
        AirportInfoService.shared.info(for: airport.icao) { resolved in
            info = resolved
        }
    }

    private func loadMetar() {
        WeatherService.shared.metar(for: airport.icao) { fetched in
            hasWeatherAnswer = true

            // Nil is both "this field has never filed one" and "that request
            // failed", and the card keeps whatever it last had either way: on
            // the minute tick, a single failed fetch shouldn't wipe a report
            // that was on screen a second ago.
            guard let fetched = fetched else { return }
            metar = fetched
        }
    }

    // MARK: - Traffic

    @ViewBuilder
    private func traffic(_ activity: AirportActivity) -> some View {
        if activity.isEmpty {
            PanelSection(title: "TRAFFIC") {
                PanelEmptyState(
                    symbol: "airplane.circle",
                    title: feed.status.isLive ? "Nothing here right now" : "Waiting for the feed",
                    detail: feed.status.isLive
                        ? "No aircraft on \(feed.server) are at \(airport.icao) or filed through it."
                        : "The field's traffic appears as soon as the server is reporting."
                )
            }
        } else {
            movements(
                title: "INBOUND",
                symbol: "airplane.arrival",
                movements: activity.inbound
            )

            movements(
                title: "DEPARTED",
                symbol: "airplane.departure",
                movements: activity.outbound
            )

            movements(
                title: "ON THE GROUND",
                symbol: "airplane",
                movements: activity.onGround
            )
        }
    }

    @ViewBuilder
    private func movements(
        title: String,
        symbol: String,
        movements: [AirportActivity.Movement]
    ) -> some View {
        if !movements.isEmpty {
            PanelSection(title: "\(title) · \(movements.count)") {
                ForEach(movements) { movement in
                    if movement.id != movements.first?.id { PanelDivider() }
                    MovementRow(
                        movement: movement,
                        symbol: symbol,
                        theme: theme,
                        action: { onSelectFlight(movement.flight) }
                    )
                }
            }
        }
    }
}

/// One aircraft on a field's panel: who it is, what it is, and the one number
/// that matters for the list it is in — time to run for an arrival, distance
/// out for a departure, what it is doing for anything on the ground.
private struct MovementRow: View {

    let movement: AirportActivity.Movement
    let symbol: String
    let theme: FlightInfoTheme
    let action: () -> Void

    private var flight: Flight { movement.flight }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.textDim)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(flight.displayName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine(minimumScale: 0.8)

                    Text(identity)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine(minimumScale: 0.75)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(headline)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize()

                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(flight.displayName), \(headline) \(detail)")
    }

    /// The aircraft and who is flying it. The type is the more useful of the
    /// two on a field's list — it is what you are looking at on the apron — so
    /// it leads.
    private var identity: String {
        let type = flight.aircraftName.isEmpty ? "Unknown type" : flight.aircraftName
        guard let pilot = flight.username, !pilot.isEmpty else { return type }
        return "\(type) · \(pilot)"
    }

    /// The number the row is for. An arrival's is its time to run; everything
    /// else falls back to the geometry, which is all there is to say about an
    /// aircraft that hasn't filed a destination or is sitting still.
    private var headline: String {
        if let eta = movement.etaLabel { return eta }
        if movement.distanceNM < 1 { return "At field" }
        return "\(Format.number(movement.distanceNM)) NM"
    }

    private var detail: String {
        if movement.etaLabel != nil {
            return "\(Format.number(movement.distanceNM)) NM out"
        }

        if flight.groundSpeedKnots < AirportActivity.flyingSpeedKnots {
            return movement.isTaxiing ? "Taxiing" : "Parked"
        }

        return "\(Format.number(flight.altitudeFeet)) ft"
    }
}
