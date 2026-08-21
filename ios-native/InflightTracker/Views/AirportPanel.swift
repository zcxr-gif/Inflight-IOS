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
    @ObservedObject private var widgets = WidgetBridge.shared
    @ObservedObject private var gateStore = GateStore.shared
    @StateObject private var imageLoader = RemoteImageLoader()

    /// The field's photograph, once the backend has answered about it. Nil
    /// covers both "no picture" and "not asked yet" — the header simply has no
    /// image in either case, which is the same thing to look at.
    @State private var imageURL: URL?
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
            hero

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

                PanelDivider()

                // One pinned field at a time, so this is a toggle rather than a
                // list to manage: pinning a second field replaces the first,
                // which is the same bargain the flight tile makes.
                Button {
                    widgets.pinAirport(isPinned ? nil : airport.icao)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            PanelRowLabel(
                                title: isPinned ? "Pinned to home screen" : "Pin to home screen",
                                symbol: isPinned ? "square.grid.2x2.fill" : "square.grid.2x2"
                            )

                            Text(isPinned
                                 ? "The Airport widget is showing \(airport.icao)."
                                 : "Puts this field's traffic, ATC and weather on the Airport widget.")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .padding(.leading, 30)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 8)

                        if isPinned {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            frequencies

            weather

            WeatherForecastSection(key: airport.icao, coordinate: airport.coordinate)

            gates(activity)

            traffic(activity)

            HintStrip(placement: .airport)
        }
        .onAppear {
            if let cached = WeatherService.shared.cached(airport.icao) {
                metar = cached
                hasWeatherAnswer = true
            }
            loadMetar()
            loadImage()
            gateStore.load(airport)
        }
        .animation(.easeInOut(duration: 0.25), value: imageLoader.image != nil)
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

    /// The field's own photograph, when the backend has one.
    ///
    /// Drawn only once an image has actually arrived — no placeholder, no
    /// spinner, no reserved band. A field with no picture is the common case,
    /// and holding a grey rectangle open for one that is never coming is worse
    /// than the panel simply starting at its first card.
    @ViewBuilder
    private var hero: some View {
        if let image = imageLoader.image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                        .strokeBorder(theme.stroke, lineWidth: 1)
                }
                .overlay(alignment: .bottomLeading) {
                    // The name rides the photo rather than repeating under it —
                    // the header above is the ICAO, and this is the one place
                    // the field's full name is worth the room.
                    Text(airport.name)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .flightInfoLine(minimumScale: 0.7)
                }
                .transition(.opacity)
        }
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
                    category(metar)
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

    /// What the field is good for, in the colour the map is drawing its ICAO
    /// in — which is what makes the four colours out there mean something.
    private func category(_ metar: Metar) -> some View {
        let category = metar.flightCategory

        return HStack(spacing: 10) {
            Text(category.rawValue)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(uiColor: category.colour))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(Color(uiColor: category.colour).opacity(0.16))
                }

            Text(category.detail)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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

    private var isPinned: Bool { widgets.isAirportPinned(airport.icao) }

    private var isDaylight: Bool { SolarPosition.isDaylight(at: airport.coordinate) }

    private func loadImage() {
        // Seeded from the cache so a field looked at twice draws its photo
        // immediately rather than fading it in again.
        if let known = AirportImageService.shared.cached(airport.icao) {
            imageURL = known
            imageLoader.load(known)
            return
        }

        AirportImageService.shared.image(for: airport.icao) { url in
            imageURL = url
            imageLoader.load(url)
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

    // MARK: - Gates

    /// Which stands are occupied, and by whom.
    ///
    /// The feed says nothing about stands, so this is worked out the only way
    /// available: OpenStreetMap says where the field's stands are, and an
    /// aircraft parked on one is at it. Which means the answer is only as good
    /// as the mapping — a field nobody has mapped shows nothing, and says so
    /// rather than looking broken.
    @ViewBuilder
    private func gates(_ activity: AirportActivity) -> some View {
        switch gateStore.state(for: airport.icao) {
        case .idle, .loading:
            PanelSection(title: "GATES") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking up stands…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }

        case .failed:
            PanelSection(title: "GATES") {
                PanelEmptyState(
                    symbol: "mappin.slash",
                    title: "Stand data unavailable",
                    detail: "The stand lookup could not be reached. Reopen this field to try again."
                )
            }

        case .ready(let mapped):
            let occupancy = GateOccupancy.match(gates: mapped, onGround: activity.onGround)

            if mapped.isEmpty {
                PanelSection(title: "GATES") {
                    PanelEmptyState(
                        symbol: "mappin.slash",
                        title: "No stands mapped",
                        detail: "OpenStreetMap has no gates or parking positions for \(airport.icao)."
                    )
                }
            } else {
                PanelSection(title: "GATES · \(occupancy.occupied.count) of \(occupancy.total) in use") {
                    if occupancy.isEmpty {
                        PanelEmptyState(
                            symbol: "airplane.circle",
                            title: "Every stand is clear",
                            detail: standFootnote(occupancy)
                        )
                    } else {
                        ForEach(occupancy.occupied) { spot in
                            if spot.id != occupancy.occupied.first?.id { PanelDivider() }
                            GateRow(
                                spot: spot,
                                theme: theme,
                                action: { onSelectFlight(spot.flight) }
                            )
                        }

                        if occupancy.unmatched > 0 {
                            PanelDivider()
                            Text(standFootnote(occupancy))
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        }
    }

    /// The parked traffic this cannot place. Worth saying out loud: on a field
    /// whose remote stands nobody has mapped, the gate list is a fraction of
    /// what is actually parked, and a reader should know that.
    private func standFootnote(_ occupancy: GateOccupancy) -> String {
        guard occupancy.unmatched > 0 else {
            return "\(occupancy.total) stands mapped at \(airport.icao)."
        }
        let aircraft = occupancy.unmatched == 1 ? "1 aircraft is" : "\(occupancy.unmatched) aircraft are"
        return "\(aircraft) parked away from a mapped stand."
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

/// One occupied stand: which one, and what is on it.
private struct GateRow: View {

    let spot: GateOccupancy.Occupied
    let theme: FlightInfoTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                // The stand's own name, set as the label a jetway carries.
                Text(spot.gate.ref)
                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(theme.textPrimary)
                    .frame(minWidth: 42, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text(spot.flight.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .flightInfoLine()

                    Text(aircraftLine)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .flightInfoLine()
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aircraftLine: String {
        let parts = [spot.flight.aircraftName, spot.flight.liveryName].filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown aircraft" : parts.joined(separator: " · ")
    }
}
