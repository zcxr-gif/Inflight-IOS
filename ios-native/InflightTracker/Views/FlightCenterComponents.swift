import SwiftUI

/// The pieces every page of the Flight Center is built from.
///
/// Deliberately the app's own vocabulary rather than the web page's: the
/// dock's rows (a badge, a rounded callsign, a type chip, one figure on the
/// right), the stats' tiles, the panels' cards. The Flight Center on the web
/// is a page of tables; here it is the same information read the way every
/// other list in the app is read, so it feels like part of the map rather than
/// a website that has been let in.

// MARK: - A flight

/// One aircraft in a list: whose it is, what it is, where it is going, and the
/// one number a list of flights is read for — how high it is.
struct FlightCenterFlightRow: View {

    let flight: Flight

    /// Replaces the route-and-pilot line, for a list that already says the
    /// route — a route's own page, a field's departures.
    var detail: String? = nil

    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        let figure = FlightCenterText.altitude(flight)

        Button(action: action) {
            HStack(spacing: 12) {
                AirlineLogoMark(
                    icao: AirlineDirectory.icao(for: flight),
                    livery: flight.liveryName,
                    fallback: FlightCenterText.monogram(flight),
                    side: 38
                )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L(flight.displayName))
                            .font(.system(size: 15.5, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        if !flight.aircraftName.isEmpty {
                            FlightCenterChip(text: flight.aircraftName)
                        }
                    }

                    Text(L(secondLine))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FlightCenterFigure(
                    value: figure.value,
                    unit: figure.unit,
                    caption: FlightCenterText.minutesToGo(flight).map { FlightCenterText.duration(minutes: $0) }
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this flight")
    }

    private var secondLine: String {
        if let detail { return detail }
        let route = FlightCenterText.route(flight)
        guard let pilot = flight.username, !pilot.isEmpty else { return route }
        return "\(L(route)) · \(pilot)"
    }
}

/// A list of flights on one card, with a cap and a line saying how many more
/// there are — a fleet of three hundred is not a list anybody scrolls.
struct FlightCenterFlightList: View {

    let flights: [Flight]
    var limit: Int = 60
    var detail: ((Flight) -> String?)? = nil
    let onOpen: (Flight) -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var showsAll = false

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        let shown = showsAll ? flights : Array(flights.prefix(limit))

        VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, flight in
                if index > 0 { FlightCenterDivider() }
                FlightCenterFlightRow(flight: flight, detail: detail?(flight)) {
                    onOpen(flight)
                }
            }

            if flights.count > shown.count {
                FlightCenterDivider(inset: 0)
                Button {
                    withAnimation(Motion.content) { showsAll = true }
                } label: {
                    HStack(spacing: 6) {
                        Text(Lf("Show all %@", Format.number(Double(flights.count))))
                            .font(.system(size: 12.5, weight: .semibold))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Small parts

/// The type chip from the dock's rows.
struct FlightCenterChip: View {

    let text: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Text(L(text))
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(theme.textSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay { Capsule().stroke(theme.stroke, lineWidth: 1) }
    }
}

/// The figure at the end of a row, its unit under it, and an optional third
/// line in the accent — time to go, on a flight.
struct FlightCenterFigure: View {

    let value: String
    var unit: String = ""
    var caption: String? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
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

            if let caption {
                Text(L(caption))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.accent)
                    .monospacedDigit()
            }
        }
        .fixedSize()
    }
}

/// The hairline between rows, inset past the badge column the way the dock's
/// lists are.
struct FlightCenterDivider: View {

    var inset: CGFloat = 64

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    var body: some View {
        Rectangle()
            .fill(appearance.theme.stroke)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// One headline number: the stats panel's tile.
struct FlightCenterTile: View {

    let value: String

    /// The number behind it, so it rolls rather than swaps. Nil for a tile
    /// whose value is a word — a route, a type.
    var number: Double? = nil

    let label: String

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            figure
                .font(.system(size: number == nil ? 15 : 22, weight: .heavy, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .flightInfoLine(minimumScale: 0.5)
                .frame(height: 26, alignment: .bottomLeading)

            Text(L(label))
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .flightInfoSurface(theme, radius: theme.radiusSmall)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(L(label)): \(value)")
    }

    @ViewBuilder
    private var figure: some View {
        if let number {
            Text(L(value)).motionFigure(number)
        } else {
            Text(L(value))
        }
    }
}

/// A row of up to four tiles.
struct FlightCenterTiles<Content: View>: View {

    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) {
            content
        }
    }
}

/// A counted thing with its share of the biggest, as a bar under the name: a
/// type in a fleet, a route, a field. Tappable when there is somewhere to go.
struct FlightCenterTallyRow: View {

    let title: String
    var detail: String? = nil
    var symbol: String? = nil
    let count: Int

    /// The largest count in the list, for the length of the bar.
    let maximum: Int

    var action: (() -> Void)? = nil

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        if let action {
            Button(action: action) { label(chevron: true) }
                .buttonStyle(.pressable(scale: 0.985))
        } else {
            label(chevron: false)
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(spacing: 10) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 20)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(L(title))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .layoutPriority(1)

                    if let detail {
                        Text(L(detail))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Text("\(count)")
                        .font(.system(size: 14, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .fixedSize()
                }

                GeometryReader { proxy in
                    let share = maximum > 0 ? CGFloat(count) / CGFloat(maximum) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(theme.trackFill)
                        Capsule()
                            .fill(theme.accent)
                            .frame(width: max(proxy.size.width * share, 4))
                    }
                }
                .frame(height: 4)
            }

            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A field in a list: its flag, its name and code, and its movements.
struct FlightCenterAirportRow: View {

    let icao: String
    let name: String
    let flag: String
    let inbound: Int
    let outbound: Int
    var isStaffed: Bool = false

    /// The rank, for a board. Nil for a plain list.
    var rank: Int? = nil

    /// A third count, for a list that is about the apron too.
    var detail: String? = nil

    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(L(flag.isEmpty ? "🏳️" : flag))
                    .font(.system(size: 22))
                    .frame(width: 38, height: 38)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(theme.textPrimary.opacity(0.06))
                    }

                if let rank {
                    Text("\(rank)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(L(name))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)

                        FlightCenterChip(text: icao)

                        if isStaffed { AtcOnlineBadge(theme: theme) }
                    }

                    HStack(spacing: 14) {
                        movement(outbound, symbol: "airplane.departure")
                        movement(inbound, symbol: "airplane.arrival")
                        if let detail {
                            Text(L(detail))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textDim)
                                .lineLimit(1)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(name), \(outbound) departing, \(inbound) arriving\(isStaffed ? ", controlled" : "")"
        )
        .accessibilityAddTraits(.isButton)
    }

    private func movement(_ count: Int, symbol: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(count == 0 ? theme.textDim : theme.textSecondary)
    }
}

/// An airline in a list: its logo, its name and code, what it has up.
struct FlightCenterAirlineRow: View {

    let airline: FlightCenterAirline
    var rank: Int? = nil
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AirlineLogoMark(icao: airline.icao, livery: airline.livery, fallback: airline.icao, side: 38)

                if let rank {
                    Text("\(rank)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L(airline.name))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .lineLimit(1)
                            .layoutPriority(1)

                        FlightCenterChip(text: airline.icao)
                    }

                    Text(L(line))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FlightCenterFigure(value: "\(airline.total)", unit: airline.total == 1 ? "FLIGHT" : "FLIGHTS")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this airline's fleet")
    }

    private var line: String {
        guard airline.total > 0 else { return "Nothing on the server right now" }
        return Lf("%@ in the air · %@ on the ground", String(airline.airborne), String(airline.onGround))
    }
}

/// A route in a list: both ends, how far, how many are on it.
struct FlightCenterRouteRow: View {

    let route: FlightCenterDigest.RouteRow
    var rank: Int? = nil
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 38, height: 38)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(theme.textPrimary.opacity(0.06))
                    }

                if let rank {
                    Text("\(rank)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textDim)
                        .frame(width: 16)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L(route.from))
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(theme.textDim)
                        Text(L(route.to))
                            .font(.system(size: 15, weight: .heavy, design: .rounded))
                        if let distance = route.distanceNM {
                            FlightCenterChip(text: "\(Format.number(distance)) NM")
                        }
                    }
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)

                    Text(L(names))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                FlightCenterFigure(value: "\(route.count)", unit: route.count == 1 ? "FLIGHT" : "FLIGHTS")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.985))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the flights on this route")
    }

    private var names: String {
        let from = route.fromName ?? route.from
        let to = route.toName ?? route.to
        return Lf("%@ to %@", from, to)
    }
}

/// The way back up the Flight Center: a pill naming the page it returns to,
/// the shape of the system's own back button.
struct FlightCenterBackButton: View {

    let title: String
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 12, weight: .bold))
                Text(L(title))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.95))
        .flightInfoSurface(theme, in: Capsule(), elevated: true, interactive: true)
        .accessibilityLabel(Lf("Back to %@", title))
    }
}

/// A round control for the header — home, sort, swap.
struct FlightCenterRoundButton: View {

    let symbol: String
    let label: String
    var side: CGFloat = 32
    let action: () -> Void

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: side > 40 ? 15 : 13, weight: .bold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: side, height: side)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable(scale: 0.92))
        .flightInfoSurface(theme, in: Circle(), elevated: true, interactive: true)
        .accessibilityLabel(L(label))
    }
}

/// The feed's state, as the web Flight Center's live pill: a dot and a word.
struct FlightCenterLivePill: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(feed.status.isLive ? Color.green : theme.textDim)
                .frame(width: 7, height: 7)
                .shadow(color: feed.status.isLive ? Color.green.opacity(0.7) : .clear, radius: 4)

            Text(L(feed.status.isLive ? "LIVE" : feed.status.label.uppercased()))
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.8)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .motionWords(feed.status.label)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .flightInfoSurface(theme, in: Capsule(), elevated: true)
        .motion(Motion.content, value: feed.status.isLive)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Lf("Feed %@", feed.status.label))
    }
}

// MARK: - From a flight window

/// The web flight page's two buttons — "Airline fleet" and "Flights on this
/// route" — under the route card, opening the Flight Center on that airline
/// or that route.
///
/// Each says how many there are before it is tapped, so it is information as
/// well as a way somewhere: "BAW · 42 up" answers the question it would have
/// been opened to ask.
struct FlightCenterLinks: View {

    let flight: Flight
    let theme: FlightInfoTheme
    let onOpen: (FlightCenterPage) -> Void

    @EnvironmentObject private var feed: LiveFeed

    var body: some View {
        let airline = AirlineDirectory.icao(for: flight)
        let from = flight.departureIcao?.uppercased() ?? ""
        let to = flight.arrivalIcao?.uppercased() ?? ""
        let hasRoute = !from.isEmpty && !to.isEmpty && from != to

        if airline != nil || hasRoute {
            HStack(spacing: 8) {
                if let airline {
                    let fleet = feed.flights.filter { AirlineDirectory.icao(for: $0) == airline }.count
                    link(
                        title: Lf("%@ fleet", airline),
                        detail: fleet == 1 ? L("1 flying") : Lf("%@ flying", String(fleet)),
                        accessibility: Lf("Open the %@ fleet in the Flight Center", airline)
                    ) {
                        AirlineLogoMark(icao: airline, livery: flight.liveryName, fallback: airline, side: 26)
                    } action: {
                        onOpen(.airline(airline))
                    }
                }

                if hasRoute {
                    let count = FlightCenterRoute.flights(from: from, to: to, in: feed.flights).count
                    link(
                        title: "\(from) → \(to)",
                        detail: count == 1 ? L("Only this flight") : Lf("%@ on this route", String(count)),
                        accessibility: Lf("Open the flights from %@ to %@ in the Flight Center", from, to)
                    ) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 26, height: 26)
                            .background {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(theme.textPrimary.opacity(0.08))
                            }
                    } action: {
                        onOpen(.route(from: from, to: to))
                    }
                }
            }
        }
    }

    private func link<Badge: View>(
        title: String,
        detail: String,
        accessibility: String,
        @ViewBuilder badge: () -> Badge,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                badge()

                VStack(alignment: .leading, spacing: 1) {
                    Text(L(title))
                        .font(.system(size: 12.5, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(L(detail))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous))
        }
        .buttonStyle(.pressable(scale: 0.97))
        .flightInfoSurface(theme, radius: theme.radiusSmall, interactive: true)
        .accessibilityLabel(L(accessibility))
    }
}
