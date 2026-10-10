import SwiftUI

/// What the dock has to say once it is pulled up: the lists worth scrolling
/// through while nothing in particular is open.
///
/// Every row is counted out of the packet the map is drawn from, the same as
/// the stats — nothing is fetched, so nothing here can disagree with the map.
/// Built in one pass, once per packet, and only while the sheet is up.
struct MapDockDigest: Equatable {

    struct FlightRow: Identifiable, Equatable {
        let id: String
        let callsign: String
        /// The airline's letters off the front of the callsign, for the badge.
        let code: String
        let type: String
        let livery: String
        let route: String
        /// The figure the list is ranked on, and its unit underneath.
        let figure: String
        let unit: String
    }

    struct AirportRow: Identifiable, Equatable {
        let icao: String
        let name: String
        let flag: String
        let departures: Int
        let arrivals: Int
        let isStaffed: Bool

        var id: String { icao }
    }

    var friends: [FlightRow] = []
    var longest: [FlightRow] = []
    var landingSoon: [FlightRow] = []
    var airports: [AirportRow] = []

    static let empty = MapDockDigest()

    /// How many rows each list keeps. A screenful, not a census.
    private static let listLength = 8

    /// How close to the field a flight has to be to count as landing soon.
    private static let landingRadiusNM: Double = 160

    static func from(
        flights: [Flight],
        stations: [AtcStation],
        watched: Set<String>
    ) -> MapDockDigest {
        let store = AirportStore.shared

        var friends: [(Flight, String)] = []
        var longest: [(Flight, Double, Airport, Airport)] = []
        var landing: [(Flight, Double, Airport, Airport)] = []
        var departures: [String: Int] = [:]
        var arrivals: [String: Int] = [:]

        for flight in flights where !Flight.isRealWorld(id: flight.id) {
            let from = flight.departureIcao?.uppercased() ?? ""
            let to = flight.arrivalIcao?.uppercased() ?? ""
            if !from.isEmpty { departures[from, default: 0] += 1 }
            if !to.isEmpty { arrivals[to, default: 0] += 1 }

            let isAirborne = FlightPhase.from(flight) != .ground

            if let name = flight.username?.lowercased(), watched.contains(name) {
                friends.append((flight, flight.username ?? name))
            }

            guard isAirborne,
                  let start = store.airport(from),
                  let end = store.airport(to) else { continue }

            let leg = FlightProgress.distanceNM(from: start.coordinate, to: end.coordinate)
            longest.append((flight, leg, start, end))

            let remaining = FlightProgress.distanceNM(from: flight.coordinate, to: end.coordinate)
            if remaining < landingRadiusNM, flight.groundSpeedKnots > 60, flight.verticalSpeedFPM < 500 {
                landing.append((flight, remaining / flight.groundSpeedKnots * 60, start, end))
            }
        }

        let staffed = Set(stations.filter { !$0.isCenter }.map { $0.identifier.uppercased() })

        var digest = MapDockDigest()

        digest.friends = friends
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
            .map { flight, name in
                row(
                    flight,
                    title: name,
                    route: routeText(flight, store: store),
                    figure: flight.altitudeFeet > 100 ? Format.number(flight.altitudeFeet) : "GND",
                    unit: flight.altitudeFeet > 100 ? "FT" : ""
                )
            }

        digest.longest = longest
            // Ties broken by id, so two flights on one route do not swap places
            // between packets.
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
            .prefix(listLength)
            .map { flight, leg, start, end in
                row(
                    flight,
                    title: flight.displayName,
                    route: Lf("%@ to %@", place(start), place(end)),
                    figure: Format.number(leg),
                    unit: "NM"
                )
            }

        digest.landingSoon = landing
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
            .prefix(listLength)
            .map { flight, minutes, start, end in
                row(
                    flight,
                    title: flight.displayName,
                    route: Lf("%@ to %@", place(start), place(end)),
                    figure: "\(max(Int(minutes.rounded()), 1))",
                    unit: "MIN"
                )
            }

        let ranked = Set(departures.keys).union(arrivals.keys)
            .map { icao in (icao: icao, out: departures[icao, default: 0], inbound: arrivals[icao, default: 0]) }
            .sorted { lhs, rhs in
                let left = lhs.out + lhs.inbound, right = rhs.out + rhs.inbound
                return left != right ? left > right : lhs.icao < rhs.icao
            }

        for field in ranked {
            guard digest.airports.count < listLength else { break }
            // A field the offline dataset does not have has no name and no
            // panel to open, so it is passed over rather than listed as a code.
            guard let airport = store.airport(field.icao) else { continue }
            digest.airports.append(AirportRow(
                icao: field.icao,
                name: airport.name,
                flag: airport.flag,
                departures: field.out,
                arrivals: field.inbound,
                isStaffed: staffed.contains(field.icao)
            ))
        }

        return digest
    }

    private static func row(
        _ flight: Flight,
        title: String,
        route: String,
        figure: String,
        unit: String
    ) -> FlightRow {
        FlightRow(
            id: flight.id,
            callsign: title,
            code: airlineCode(flight.callsign ?? flight.username ?? ""),
            type: flight.aircraftName,
            livery: flight.liveryName,
            route: route,
            figure: figure,
            unit: unit
        )
    }

    /// "Heathrow EGLL", trimmed of the words every airport name carries.
    private static func place(_ airport: Airport) -> String {
        var name = airport.name
        for word in [" International Airport", " Airport", " International", " Intl"] {
            name = name.replacingOccurrences(of: word, with: "")
        }
        return "\(name) \(airport.icao)"
    }

    private static func routeText(_ flight: Flight, store: AirportStore) -> String {
        if let start = store.airport(flight.departureIcao), let end = store.airport(flight.arrivalIcao) {
            return Lf("%@ to %@", place(start), place(end))
        }
        if let end = store.airport(flight.arrivalIcao) { return Lf("To %@", place(end)) }
        return flight.aircraftName.isEmpty ? "No flight plan" : flight.aircraftName
    }

    /// The letters before the flight number — "BAW" out of "BAW11" — or the
    /// first two of whatever the callsign is.
    private static func airlineCode(_ callsign: String) -> String {
        let letters = callsign.uppercased().prefix { $0.isLetter }
        return String(letters.isEmpty ? callsign.uppercased().prefix(2) : letters.prefix(3))
    }
}

/// The body of the pulled-up dock: the numbers, then the lists.
struct MapDockSections: View {

    @EnvironmentObject private var feed: LiveFeed

    let theme: FlightInfoTheme
    let watched: Set<String>
    let onOpenStats: () -> Void
    let onOpenFlight: (String) -> Void
    let onOpenAirport: (String) -> Void
    let onPanel: (MapPanelKind) -> Void

    @State private var digest = MapDockDigest.empty

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            quickRow

            if !digest.friends.isEmpty {
                section("Friends Flying", symbol: "person.2.fill") {
                    flightRows(digest.friends, ranked: false)
                }
            }

            section("Right Now", symbol: "dot.radiowaves.left.and.right") {
                StatsPanel(theme: theme, onOpenFull: onOpenStats)
                    .padding(12)
                    .background(card)
            }

            if !digest.longest.isEmpty {
                section("Longest Flights", symbol: "globe.europe.africa.fill") {
                    flightRows(digest.longest, ranked: true)
                }
            }

            if !digest.landingSoon.isEmpty {
                section("Landing Soon", symbol: "airplane.arrival") {
                    flightRows(digest.landingSoon, ranked: true)
                }
            }

            if !digest.airports.isEmpty {
                section("Busiest Airports", symbol: "building.2.fill") {
                    VStack(spacing: 0) {
                        ForEach(Array(digest.airports.enumerated()), id: \.element.id) { index, field in
                            if index > 0 { divider }
                            Button { onOpenAirport(field.icao) } label: {
                                airportRow(field, rank: index + 1)
                            }
                            .buttonStyle(.pressable(scale: 0.98))
                        }
                    }
                    .background(card)
                }
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 16)
        .motion(Motion.row, value: digest)
        .onAppear(perform: recount)
        .onChange(of: feed.lastUpdate) { _, _ in recount() }
        .onChange(of: watched) { _, _ in recount() }
    }

    // MARK: - Pieces

    /// The places people go from the map most, as tiles rather than as a
    /// second row of the bar.
    private var quickRow: some View {
        HStack(spacing: 8) {
            quickTile("Weather", symbol: "cloud.sun.fill") { onPanel(.weather) }
            quickTile("Stats", symbol: "chart.bar.fill") { onOpenStats() }
            quickTile("Plans", symbol: "calendar") { onPanel(.plans) }
        }
    }

    private func quickTile(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(height: 20)
                Text(L(title))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .flightInfoLine(minimumScale: 0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(card)
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        }
        .buttonStyle(.pressable(scale: 0.96))
    }

    private func section<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(L(title))
            } icon: {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
            }
            .font(.system(size: 19, weight: .bold, design: .rounded))
            .foregroundStyle(theme.textSecondary)
            .padding(.leading, 4)
            .accessibilityAddTraits(.isHeader)

            content()
        }
    }

    private func flightRows(_ rows: [MapDockDigest.FlightRow], ranked: Bool) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { divider }
                Button { onOpenFlight(row.id) } label: {
                    flightRow(row, rank: ranked ? index + 1 : nil)
                }
                .buttonStyle(.pressable(scale: 0.98))
            }
        }
        .background(card)
    }

    private func flightRow(_ row: MapDockDigest.FlightRow, rank: Int?) -> some View {
        HStack(spacing: 12) {
            airlineBadge(row)

            if let rank { rankText(rank) }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L(row.callsign))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if !row.type.isEmpty { chip(row.type) }
                }

                Text(L(row.route))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            figure(row.figure, unit: row.unit)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this flight")
    }

    private func airportRow(_ field: MapDockDigest.AirportRow, rank: Int) -> some View {
        HStack(spacing: 12) {
            Text(L(field.flag.isEmpty ? "🏳️" : field.flag))
                .font(.system(size: 24))
                .frame(width: 38, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.textPrimary.opacity(0.06))
                }

            rankText(rank)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L(field.name))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    chip(field.icao)
                }

                HStack(spacing: 14) {
                    traffic(field.departures, symbol: "airplane.departure")
                    traffic(field.arrivals, symbol: "airplane.arrival")
                    if field.isStaffed {
                        Label("ATC", systemImage: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(field.name), \(field.departures) departing, \(field.arrivals) arriving\(field.isStaffed ? ", controlled" : "")"
        )
        .accessibilityAddTraits(.isButton)
    }

    /// The airline's own colour where we hold one, its letters on top.
    private func airlineBadge(_ row: MapDockDigest.FlightRow) -> some View {
        let colours = AirlineAccent.colours(forLivery: row.livery, isLight: theme.isLight)
        return Text(L(row.code))
            .font(.system(size: row.code.count > 2 ? 11 : 13, weight: .heavy, design: .rounded))
            .foregroundStyle(colours?.ink ?? theme.textPrimary)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .padding(4)
            .frame(width: 38, height: 38)
            .background {
                Circle().fill(colours?.tint ?? theme.textPrimary.opacity(0.1))
            }
    }

    private func rankText(_ rank: Int) -> some View {
        Text("\(rank)")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.textDim)
            .frame(width: 16)
    }

    private func chip(_ text: String) -> some View {
        Text(L(text))
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { Capsule().stroke(theme.stroke, lineWidth: 1) }
    }

    private func figure(_ value: String, unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(L(value))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
            if !unit.isEmpty {
                Text(L(unit))
                    .font(.system(size: 8.5, weight: .bold))
                    .tracking(0.6)
                    .foregroundStyle(theme.textDim)
            }
        }
        .fixedSize()
    }

    private func traffic(_ count: Int, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(theme.textSecondary)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
            .padding(.leading, 64)
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
            .fill(theme.surfaceFill)
            .overlay {
                RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous)
                    .stroke(theme.stroke, lineWidth: 1)
            }
    }

    private func recount() {
        let next = MapDockDigest.from(flights: feed.flights, stations: feed.atcStations, watched: watched)
        if next != digest { digest = next }
    }
}
