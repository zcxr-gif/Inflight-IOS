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

    var body: some View {
        let activity = self.activity

        MapPanel(
            title: airport.icao,
            subtitle: subtitle(for: activity),
            accessory: airport.flag.isEmpty ? nil : AnyView(flag)
        ) {
            PanelSection(title: "FIELD") {
                PanelActionRow(
                    title: "Show on map",
                    symbol: "location.magnifyingglass",
                    detail: airport.name
                ) {
                    onShowOnMap(airport)
                }
            }

            frequencies

            weather

            traffic(activity)
        }
        .onAppear {
            if let cached = WeatherService.shared.cached(airport.icao) {
                metar = cached
                hasWeatherAnswer = true
            }
            loadMetar()
        }
        .onReceive(clock) { tick in
            now = tick
            // The service holds a report for ten minutes, so this costs a
            // dictionary lookup nine times out of ten and picks up the new
            // hour's observation on the tenth.
            loadMetar()
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

    // MARK: - Weather

    private var weather: some View {
        PanelSection(title: "WEATHER") {
            if let metar = metar {
                VStack(alignment: .leading, spacing: 0) {
                    report(metar)
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
