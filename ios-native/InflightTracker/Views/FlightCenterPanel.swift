import SwiftUI

// MARK: - Where you are in it

/// A page of the Flight Center.
enum FlightCenterPage: Hashable {

    /// Search, what you looked at last, and the server at a glance.
    case home

    /// Every airline on the server, busiest first.
    case airlines

    /// One airline's live fleet.
    case airline(String)

    /// One field's board — arrivals, departures, the apron.
    case airport(String)

    /// The flights between two fields. Either end may be empty: "anywhere".
    case route(from: String, to: String)
}

/// Which page the Flight Center is on, and the way back.
///
/// Held outside the panel rather than in its state, because the panel is torn
/// down every time a flight is opened from it — the dock gives way to the
/// flight window — and coming back to the map should find the Flight Center
/// where it was left, the way coming back to any app's tab does.
@MainActor
final class FlightCenterNavigator: ObservableObject {

    static let shared = FlightCenterNavigator()

    @Published private(set) var stack: [FlightCenterPage] = []

    /// What is in the search field, kept with the page for the same reason.
    @Published var query = ""

    private init() {}

    var page: FlightCenterPage { stack.last ?? .home }

    /// The page "back" goes to, when there is one.
    var previous: FlightCenterPage? {
        guard !stack.isEmpty else { return nil }
        return stack.count >= 2 ? stack[stack.count - 2] : .home
    }

    func push(_ page: FlightCenterPage) {
        guard page != self.page else { return }
        withAnimation(Motion.content) {
            if page == .home {
                stack = []
            } else {
                stack.append(page)
                // A trail long enough for any honest chain of taps — airline,
                // its hub, a route out of it, the airline again — and no
                // longer.
                if stack.count > 16 { stack.removeFirst(stack.count - 16) }
            }
        }
    }

    func back() {
        guard !stack.isEmpty else { return }
        withAnimation(Motion.content) { _ = stack.removeLast() }
    }

    func home() {
        withAnimation(Motion.content) { stack = [] }
    }

    /// Opened from somewhere else in the app, straight onto a page, with
    /// nothing left over from the last visit. Coming back from a flight opened
    /// in here does not come through this, and finds everything as it was.
    func open(_ page: FlightCenterPage) {
        stack = page == .home ? [] : [page]
        query = ""
    }
}

// MARK: - The panel

/// The Flight Center, in the app.
///
/// The web tracker's Flight Center is a website about the server: follow a
/// flight, see an airline's whole live fleet, read a field's arrivals and
/// departures, find what is flying between two places. All of it is answered
/// from the packet the map is already drawn from, so here it is a panel like
/// Friends or ATC — opened inside the dock, its title where the search field
/// was — rather than a web page shown in the app.
///
/// What it does not repeat is the flight page and the field's own panel. A
/// flight opens in the flight window, which already is the web page's flight
/// view and more; a field's weather, frequencies, stands and diagram are one
/// row away in the field's own panel. The Flight Center is the way *to* those —
/// by airline, by route, by board — which is the thing the app did not have.
struct FlightCenterPanel: View {

    /// Open an aircraft's window. The panel stays where it was, for coming
    /// back to.
    let onOpenFlight: (Flight) -> Void

    /// Open a field's own panel — weather, frequencies, stands, the map.
    let onOpenAirport: (Airport) -> Void

    /// The pilot's own profile and logbook, when there is somewhere to go.
    var onOpenProfile: (() -> Void)? = nil

    var presentation: FlightWindowPresentation = .sheet

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var navigator = FlightCenterNavigator.shared
    @ObservedObject private var recents = FlightCenterRecents.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        let page = navigator.page
        let report = airlineReport(for: page)

        MapPanel(
            title: title(for: page, report: report),
            subtitle: subtitle(for: page, report: report),
            accessory: accessory(for: page),
            presentation: presentation
        ) {
            if let previous = navigator.previous {
                FlightCenterBackButton(title: shortTitle(for: previous)) {
                    navigator.back()
                }
            }

            content(for: page, report: report)
        }
        // Keyed by page, so every page opens at its own top rather than at
        // the scroll offset the last one was left at — the same reason the
        // map keys each panel by its kind.
        .id(page)
        .transition(.opacity)
    }

    @ViewBuilder
    private func content(for page: FlightCenterPage, report: FlightCenterAirlineReport?) -> some View {
        switch page {
        case .home:
            FlightCenterHome(actions: actions)
        case .airlines:
            FlightCenterAirlinesPage(actions: actions)
        case .airline:
            if let report {
                FlightCenterAirlinePage(report: report, actions: actions)
            }
        case .airport(let icao):
            if let airport = AirportStore.shared.airport(icao) {
                FlightCenterAirportPage(airport: airport, actions: actions)
            } else {
                PanelSection(title: "FIELD") {
                    PanelEmptyState(
                        symbol: "mappin.slash",
                        title: "Not a field we know",
                        detail: Lf("%@ is not in the airport dataset.", icao)
                    )
                }
            }
        case .route(let from, let to):
            FlightCenterRoutePage(from: from, to: to, actions: actions)
        }
    }

    // MARK: Actions every page shares

    private var actions: FlightCenterActions {
        FlightCenterActions(
            openFlight: { flight in
                recents.note(.init(
                    kind: .flight,
                    key: flight.id,
                    title: flight.displayName,
                    detail: FlightCenterText.route(flight)
                ))
                onOpenFlight(flight)
            },
            openAirline: { icao, name in
                recents.note(.init(kind: .airline, key: icao, title: name, detail: icao))
                navigator.push(.airline(icao))
            },
            openAirport: { airport in
                recents.note(.init(kind: .airport, key: airport.icao, title: airport.icao, detail: airport.name))
                navigator.push(.airport(airport.icao))
            },
            openRoute: { from, to in
                let title = "\(from.isEmpty ? "Any" : from) → \(to.isEmpty ? "Any" : to)"
                recents.note(.init(kind: .route, key: "\(from)-\(to)", title: title, detail: "Route"))
                navigator.push(.route(from: from, to: to))
            },
            openAllAirlines: { navigator.push(.airlines) },
            openFieldPanel: onOpenAirport,
            openProfile: onOpenProfile
        )
    }

    // MARK: Header

    private func airlineReport(for page: FlightCenterPage) -> FlightCenterAirlineReport? {
        guard case .airline(let icao) = page else { return nil }
        return FlightCenterAirlineReport.make(icao: icao, flights: feed.flights)
    }

    private func title(for page: FlightCenterPage, report: FlightCenterAirlineReport?) -> String {
        switch page {
        case .home: return "Flight Center"
        case .airlines: return "Airlines"
        case .airline(let icao): return report?.airline.name ?? AirlineDirectory.name(for: icao)
        case .airport(let icao): return icao
        case .route(let from, let to): return "\(from.isEmpty ? L("Any") : from) → \(to.isEmpty ? L("Any") : to)"
        }
    }

    /// What the back button calls a page: shorter than its title where the
    /// title is a sentence.
    private func shortTitle(for page: FlightCenterPage) -> String {
        switch page {
        case .home: return "Flight Center"
        case .airlines: return "Airlines"
        case .airline(let icao): return icao
        case .airport(let icao): return icao
        case .route(let from, let to): return "\(from.isEmpty ? "…" : from)–\(to.isEmpty ? "…" : to)"
        }
    }

    private func subtitle(for page: FlightCenterPage, report: FlightCenterAirlineReport?) -> String? {
        switch page {
        case .home:
            let count = feed.flights.count
            guard count > 0 else { return feed.server }
            return Lf("%@ aircraft · %@", Format.number(Double(count)), feed.server)
        case .airlines:
            return feed.server
        case .airline(let icao):
            let total = report?.airline.total ?? 0
            let count = total == 1 ? L("1 aircraft") : Lf("%@ aircraft", String(total))
            return "\(icao) · \(count) · \(feed.server)"
        case .airport(let icao):
            return AirportStore.shared.airport(icao)?.name ?? feed.server
        case .route(let from, let to):
            let store = AirportStore.shared
            let start = store.airport(from).map { FlightCenterText.shortName($0) } ?? L("anywhere")
            let end = store.airport(to).map { FlightCenterText.shortName($0) } ?? L("anywhere")
            return Lf("%@ to %@", start, end)
        }
    }

    private func accessory(for page: FlightCenterPage) -> AnyView? {
        if page == .home {
            return AnyView(FlightCenterLivePill().environmentObject(feed))
        }
        // Two pages deep or more, a way straight back to the top.
        guard navigator.stack.count >= 2 else { return nil }
        return AnyView(
            FlightCenterRoundButton(symbol: "house", label: "Flight Center home") {
                navigator.home()
            }
        )
    }
}

/// What a page of the Flight Center can do, handed down rather than each page
/// being given six closures of its own.
struct FlightCenterActions {
    let openFlight: (Flight) -> Void
    let openAirline: (_ icao: String, _ name: String) -> Void
    let openAirport: (Airport) -> Void
    let openRoute: (_ from: String, _ to: String) -> Void
    let openAllAirlines: () -> Void
    let openFieldPanel: (Airport) -> Void
    let openProfile: (() -> Void)?
}

// MARK: - Home

/// The front page: a search field that finds flights, pilots, airlines and
/// fields; a route finder; what you last looked at; and the server at a
/// glance — its busiest fields, the airlines in the air, the busiest routes.
private struct FlightCenterHome: View {

    let actions: FlightCenterActions

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var navigator = FlightCenterNavigator.shared
    @ObservedObject private var recents = FlightCenterRecents.shared

    @State private var digest = FlightCenterDigest.empty
    @State private var results = FlightCenterSearchResults()
    @State private var isFindingRoute = false
    @State private var routeFrom = ""
    @State private var routeTo = ""

    @FocusState private var isSearchFocused: Bool

    private var theme: FlightInfoTheme { appearance.theme }

    private var isSearching: Bool {
        navigator.query.trimmingCharacters(in: .whitespacesAndNewlines).count >= MapSearch.minimumLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            searchCard

            if isSearching {
                searchResults
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.row, value: digest)
        .motion(Motion.content, value: isSearching)
        .onAppear {
            recount()
            research()
        }
        .onChange(of: feed.lastUpdate) { _, _ in
            recount()
            if isSearching { research() }
        }
        .onChange(of: navigator.query) { _, _ in research() }
    }

    // MARK: Search

    private var searchCard: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)

                    TextField("Flight, pilot, airline or airport", text: $navigator.query)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($isSearchFocused)
                    .onSubmit(openFirstResult)

                    if !navigator.query.isEmpty {
                        Button {
                            navigator.query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(theme.textDim)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 46)
                .flightInfoSurface(theme, in: Capsule())

                FlightCenterRoundButton(
                    symbol: isFindingRoute ? "xmark" : "arrow.triangle.swap",
                    label: isFindingRoute ? "Close the route finder" : "Find flights between two airports",
                    side: 46
                ) {
                    withAnimation(Motion.content) { isFindingRoute.toggle() }
                }
            }

            if isFindingRoute {
                routeFinder
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// Two fields and a button: "everything from here to there", with either
    /// end left open meaning anywhere.
    private var routeFinder: some View {
        VStack(spacing: 0) {
            routeField("From", text: $routeFrom, symbol: "airplane.departure")
            FlightCenterDivider(inset: 44)
            routeField("To", text: $routeTo, symbol: "airplane.arrival")
            FlightCenterDivider(inset: 0)

            HStack(spacing: 10) {
                Button {
                    let from = routeFrom
                    routeFrom = routeTo
                    routeTo = from
                } label: {
                    Label("Swap", systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 8)

                Button {
                    let from = resolvedField(routeFrom)
                    let to = resolvedField(routeTo)
                    guard !from.isEmpty || !to.isEmpty else { return }
                    isSearchFocused = false
                    actions.openRoute(from, to)
                } label: {
                    Text("Find flights")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.onAccent)
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background { Capsule().fill(theme.accent) }
                }
                .buttonStyle(.pressable(scale: 0.95))
                .disabled(resolvedField(routeFrom).isEmpty && resolvedField(routeTo).isEmpty)
                .opacity(resolvedField(routeFrom).isEmpty && resolvedField(routeTo).isEmpty ? 0.5 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func routeField(_ title: String, text: Binding<String>, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 20)

            TextField(L(title == "From" ? "From — any airport" : "To — any airport"), text: text)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(theme.textPrimary)
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()

            let field = AirportStore.shared.airport(resolvedField(text.wrappedValue))
            if let field {
                Text(L(FlightCenterText.shortName(field)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
    }

    /// A typed ICAO, or the first field whose name or code starts with what
    /// was typed — "heathrow" is EGLL.
    private func resolvedField(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return "" }
        if let exact = AirportStore.shared.airport(trimmed.uppercased()) { return exact.icao }
        return AirportStore.shared.search(trimmed.uppercased(), limit: 1).first?.icao ?? ""
    }

    private func openFirstResult() {
        if let route = results.route {
            actions.openRoute(route.from, route.to)
        } else if let airline = results.airlines.first, results.flights.first?.callsign?.uppercased() != navigator.query.uppercased() {
            actions.openAirline(airline.icao, airline.name)
        } else if let flight = results.flights.first {
            actions.openFlight(flight)
        } else if let airport = results.airports.first {
            actions.openAirport(airport)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if results.isEmpty {
            PanelSection(title: "RESULTS") {
                PanelEmptyState(
                    symbol: "magnifyingglass",
                    title: "Nothing found",
                    detail: Lf("Nothing on %@ matches “%@”. Try a callsign, a pilot, an airline or an ICAO code.", feed.server, navigator.query)
                )
            }
        } else {
            if let route = results.route {
                PanelSection(title: "ROUTE") {
                    let count = FlightCenterRoute.flights(from: route.from, to: route.to, in: feed.flights).count
                    FlightCenterRouteRow(
                        route: FlightCenterDigest.route(from: route.from, to: route.to, count: count)
                    ) {
                        actions.openRoute(route.from, route.to)
                    }
                }
            }

            if !results.airlines.isEmpty {
                PanelSection(title: "AIRLINES") {
                    ForEach(Array(results.airlines.enumerated()), id: \.element.id) { index, airline in
                        if index > 0 { FlightCenterDivider() }
                        FlightCenterAirlineRow(airline: airline) {
                            actions.openAirline(airline.icao, airline.name)
                        }
                    }
                }
            }

            if !results.airports.isEmpty {
                PanelSection(title: "AIRPORTS") {
                    ForEach(Array(results.airports.enumerated()), id: \.element.icao) { index, airport in
                        if index > 0 { FlightCenterDivider() }
                        let counts = movementCounts(airport.icao)
                        FlightCenterAirportRow(
                            icao: airport.icao,
                            name: FlightCenterText.shortName(airport),
                            flag: airport.flag,
                            inbound: counts.inbound,
                            outbound: counts.outbound
                        ) {
                            actions.openAirport(airport)
                        }
                    }
                }
            }

            if !results.flights.isEmpty {
                PanelSection(
                    title: Lf("FLIGHTS · %@", String(results.flights.count))
                ) {
                    FlightCenterFlightList(flights: results.flights, limit: 25, onOpen: actions.openFlight)
                }
            }
        }
    }

    private func movementCounts(_ icao: String) -> (inbound: Int, outbound: Int) {
        var inbound = 0
        var outbound = 0
        for flight in feed.flights {
            if flight.arrivalIcao?.uppercased() == icao { inbound += 1 }
            if flight.departureIcao?.uppercased() == icao { outbound += 1 }
        }
        return (inbound, outbound)
    }

    // MARK: The server at a glance

    @ViewBuilder
    private var overview: some View {
        FlightCenterTiles {
            FlightCenterTile(value: Format.number(Double(digest.airborne)), number: Double(digest.airborne), label: "IN THE AIR")
            FlightCenterTile(value: Format.number(Double(digest.onGround)), number: Double(digest.onGround), label: "ON THE GROUND")
            FlightCenterTile(value: Format.number(Double(digest.airlineCount)), number: Double(digest.airlineCount), label: "AIRLINES")
            FlightCenterTile(value: Format.number(Double(digest.staffedFields)), number: Double(digest.staffedFields), label: "FIELDS WITH ATC")
        }

        mine

        recentlyViewed

        PanelSection(
            title: "BUSIEST AIRPORTS",
            accessory: AnyView(legend("OUT · IN"))
        ) {
            if digest.airports.isEmpty {
                waiting
            } else {
                ForEach(Array(digest.airports.enumerated()), id: \.element.id) { index, field in
                    if index > 0 { FlightCenterDivider() }
                    FlightCenterAirportRow(
                        icao: field.icao,
                        name: field.name,
                        flag: field.flag,
                        inbound: field.inbound,
                        outbound: field.outbound,
                        isStaffed: field.isStaffed,
                        rank: index + 1
                    ) {
                        if let airport = AirportStore.shared.airport(field.icao) {
                            actions.openAirport(airport)
                        }
                    }
                }
            }
        }

        PanelSection(
            title: "AIRLINES IN THE AIR",
            accessory: AnyView(legend("FLIGHTS"))
        ) {
            if digest.airlines.isEmpty {
                waiting
            } else {
                ForEach(Array(digest.airlines.enumerated()), id: \.element.id) { index, airline in
                    if index > 0 { FlightCenterDivider() }
                    FlightCenterAirlineRow(airline: airline, rank: index + 1) {
                        actions.openAirline(airline.icao, airline.name)
                    }
                }

                if digest.airlineCount > digest.airlines.count {
                    FlightCenterDivider(inset: 0)
                    PanelActionRow(
                        title: Lf("All %@ airlines", String(digest.airlineCount)),
                        symbol: "list.bullet"
                    ) {
                        actions.openAllAirlines()
                    }
                }
            }
        }

        PanelSection(
            title: "BUSIEST ROUTES",
            accessory: AnyView(legend("FLIGHTS"))
        ) {
            if digest.routes.isEmpty {
                waiting
            } else {
                ForEach(Array(digest.routes.enumerated()), id: \.element.id) { index, route in
                    if index > 0 { FlightCenterDivider() }
                    FlightCenterRouteRow(route: route, rank: index + 1) {
                        actions.openRoute(route.from, route.to)
                    }
                }
            }
        }

        if let openProfile = actions.openProfile {
            PanelSection(title: "YOU") {
                PanelActionRow(
                    title: "My flights",
                    symbol: "person.crop.circle",
                    detail: "Your logbook, your hangar and every flight you have flown, on your profile."
                ) {
                    openProfile()
                }
            }
        }
    }

    /// The pilot's own aeroplane, when they are flying one right now.
    @ViewBuilder
    private var mine: some View {
        let identity = PilotIdentity.shared
        if identity.isSet, let flight = feed.flights.first(where: { identity.isMe($0) }) {
            PanelSection(title: "YOU'RE FLYING") {
                FlightCenterFlightRow(flight: flight) { actions.openFlight(flight) }
            }
        }
    }

    /// The last things opened here, as chips. A flight that has since left
    /// the server is not offered.
    @ViewBuilder
    private var recentlyViewed: some View {
        let entries = recents.entries.filter(isAvailable)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("RECENTLY VIEWED")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(theme.textDim)

                    Spacer(minLength: 8)

                    Button("Clear") { recents.clear() }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 2)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(entries) { entry in
                            recentChip(entry)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private func isAvailable(_ entry: FlightCenterRecents.Entry) -> Bool {
        guard entry.kind == .flight else { return true }
        return liveFlight(for: entry) != nil
    }

    private func liveFlight(for entry: FlightCenterRecents.Entry) -> Flight? {
        if let exact = feed.flights.first(where: { $0.id == entry.key }) { return exact }
        return feed.flights.first(where: { $0.displayName == entry.title })
    }

    private func recentChip(_ entry: FlightCenterRecents.Entry) -> some View {
        Button {
            openRecent(entry)
        } label: {
            HStack(spacing: 8) {
                switch entry.kind {
                case .airline:
                    AirlineLogoMark(icao: entry.key, fallback: entry.key, side: 22)
                case .airport:
                    Image(systemName: "building.2.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                case .route:
                    Image(systemName: "arrow.triangle.swap")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                case .flight:
                    Image(systemName: "airplane")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(L(entry.title))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(L(entry.detail))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .lineLimit(1)
                }
                .frame(maxWidth: 150, alignment: .leading)
            }
            .padding(.leading, 10)
            .padding(.trailing, 14)
            .frame(height: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .flightInfoSurface(theme, in: Capsule(), interactive: true)
    }

    private func openRecent(_ entry: FlightCenterRecents.Entry) {
        switch entry.kind {
        case .airline:
            actions.openAirline(entry.key, entry.title)
        case .airport:
            if let airport = AirportStore.shared.airport(entry.key) { actions.openAirport(airport) }
        case .route:
            let ends = entry.key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            if ends.count == 2 { actions.openRoute(ends[0], ends[1]) }
        case .flight:
            if let flight = liveFlight(for: entry) { actions.openFlight(flight) }
        }
    }

    private var waiting: some View {
        PanelEmptyState(
            symbol: "antenna.radiowaves.left.and.right",
            title: feed.status.isLive ? "Nothing to rank yet" : "Waiting for the feed",
            detail: feed.status.isLive
                ? Lf("Fills in as aircraft on %@ file their routes.", feed.server)
                : "The board fills in as soon as the server is reporting."
        )
    }

    private func legend(_ text: String) -> some View {
        Text(L(text))
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(theme.textDim)
    }

    private func recount() {
        let next = FlightCenterDigest.from(flights: feed.flights, stations: feed.atcStations)
        if next != digest { digest = next }
    }

    private func research() {
        results = FlightCenterSearchResults.run(navigator.query, flights: feed.flights)
    }
}

// MARK: - Every airline

private struct FlightCenterAirlinesPage: View {

    let actions: FlightCenterActions

    @EnvironmentObject private var feed: LiveFeed

    @State private var airlines: [FlightCenterAirline] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection(title: Lf("ON THE SERVER · %@", String(airlines.count))) {
                if airlines.isEmpty {
                    PanelEmptyState(
                        symbol: "building.2",
                        title: "No airlines yet",
                        detail: "Airlines appear as soon as aircraft in their liveries or callsigns are on the server."
                    )
                } else {
                    ForEach(Array(airlines.enumerated()), id: \.element.id) { index, airline in
                        if index > 0 { FlightCenterDivider() }
                        FlightCenterAirlineRow(airline: airline, rank: index + 1) {
                            actions.openAirline(airline.icao, airline.name)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: recount)
        .onChange(of: feed.lastUpdate) { _, _ in recount() }
    }

    private func recount() {
        let next = FlightCenterDigest.from(flights: feed.flights, stations: [], limit: 400).airlines
        if next != airlines { airlines = next }
    }
}

// MARK: - One airline

private struct FlightCenterAirlinePage: View {

    let report: FlightCenterAirlineReport
    let actions: FlightCenterActions

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @AppStorage("flightCenter.fleetSort") private var sort: FlightCenterSort = .callsign

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            hero

            FlightCenterTiles {
                FlightCenterTile(value: "\(report.airline.airborne)", number: Double(report.airline.airborne), label: "AIRBORNE")
                FlightCenterTile(value: "\(report.airline.onGround)", number: Double(report.airline.onGround), label: "ON THE GROUND")
                FlightCenterTile(value: "\(report.types.count)", number: Double(report.types.count), label: "TYPES")
            }

            fleet

            if !report.types.isEmpty {
                PanelSection(title: "WHAT THEY'RE FLYING") {
                    let maximum = report.types.first?.count ?? 1
                    ForEach(Array(report.types.enumerated()), id: \.element.id) { index, type in
                        if index > 0 { PanelDivider() }
                        FlightCenterTallyRow(title: type.name, symbol: "airplane", count: type.count, maximum: maximum)
                    }
                }
            }

            if !report.routes.isEmpty {
                PanelSection(title: "ROUTES") {
                    let maximum = report.routes.first?.count ?? 1
                    ForEach(Array(report.routes.enumerated()), id: \.element.id) { index, route in
                        if index > 0 { PanelDivider() }
                        let ends = route.name.split(separator: "-").map(String.init)
                        FlightCenterTallyRow(
                            title: ends.count == 2 ? "\(ends[0]) → \(ends[1])" : route.name,
                            detail: route.detail,
                            symbol: "point.topleft.down.to.point.bottomright.curvepath",
                            count: route.count,
                            maximum: maximum
                        ) {
                            if ends.count == 2 { actions.openRoute(ends[0], ends[1]) }
                        }
                    }
                }
            }

            if !report.hubs.isEmpty {
                PanelSection(title: "FLYING OUT OF") {
                    let maximum = report.hubs.first?.count ?? 1
                    ForEach(Array(report.hubs.enumerated()), id: \.element.id) { index, hub in
                        if index > 0 { PanelDivider() }
                        FlightCenterTallyRow(
                            title: hub.name,
                            detail: hub.detail,
                            symbol: "airplane.departure",
                            count: hub.count,
                            maximum: maximum
                        ) {
                            if let airport = AirportStore.shared.airport(hub.name) { actions.openAirport(airport) }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .motion(Motion.row, value: report.flights.map(\.id))
    }

    /// The airline's logo, big, with its name and code — the head of the web
    /// page's operator view.
    private var hero: some View {
        HStack(spacing: 14) {
            AirlineLogoMark(
                icao: report.airline.icao,
                livery: report.airline.livery,
                fallback: report.airline.icao,
                side: 60
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(L(report.airline.name))
                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)

                HStack(spacing: 6) {
                    FlightCenterChip(text: report.airline.icao)
                    if let top = report.topRoute {
                        let ends = top.name.split(separator: "-").map(String.init)
                        Text(L(ends.count == 2 ? Lf("Busiest: %@ → %@", ends[0], ends[1]) : top.name))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    @ViewBuilder
    private var fleet: some View {
        PanelSection(
            title: Lf("LIVE FLEET · %@", String(report.flights.count)),
            accessory: report.flights.count > 1 ? AnyView(sortMenu) : nil
        ) {
            if report.flights.isEmpty {
                PanelEmptyState(
                    symbol: "airplane.circle",
                    title: "Nothing up right now",
                    detail: Lf("No %@ aircraft are on %@ at the moment.", report.airline.name, feed.server)
                )
            } else {
                FlightCenterFlightList(flights: sort.apply(report.flights), onOpen: actions.openFlight)
            }
        }
    }

    private var sortMenu: some View {
        FlightCenterSortMenu(sort: $sort)
    }
}

/// The order a list of flights is read in, as a small menu beside its title.
struct FlightCenterSortMenu: View {

    @Binding var sort: FlightCenterSort

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(FlightCenterSort.allCases) { option in
                    Label(L(option.label), systemImage: option.symbol).tag(option)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .bold))
                Text(L(sort.label.uppercased()))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
            }
            .foregroundStyle(theme.textSecondary)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Lf("Sorted by %@", L(sort.label)))
    }
}

// MARK: - One field

private struct FlightCenterAirportPage: View {

    let airport: Airport
    let actions: FlightCenterActions

    enum Board: String, CaseIterable, Identifiable {
        case arrivals
        case departures
        case ground

        var id: String { rawValue }

        var label: String {
            switch self {
            case .arrivals: return "Arrivals"
            case .departures: return "Departures"
            case .ground: return "Ground"
            }
        }
    }

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    @State private var board: Board = .arrivals

    private var theme: FlightInfoTheme { appearance.theme }

    private var station: AtcStation? {
        feed.atcStations.first { !$0.isCenter && $0.identifier.uppercased() == airport.icao }
    }

    var body: some View {
        let activity = AirportActivity.at(airport, in: feed.flights.filter { !Flight.isRealWorld(id: $0.id) })

        VStack(alignment: .leading, spacing: 14) {
            hero

            FlightCenterTiles {
                FlightCenterTile(value: "\(activity.inbound.count)", number: Double(activity.inbound.count), label: "INBOUND")
                FlightCenterTile(value: "\(activity.outbound.count)", number: Double(activity.outbound.count), label: "DEPARTED")
                FlightCenterTile(value: "\(activity.onGround.count)", number: Double(activity.onGround.count), label: "ON THE GROUND")
                FlightCenterTile(
                    value: "\(station?.facilities.count ?? 0)",
                    number: Double(station?.facilities.count ?? 0),
                    label: "ATC"
                )
            }

            boardSection(activity)

            airlines(activity)

            routes

            nearby
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(L(airport.flag.isEmpty ? "🏳️" : airport.flag))
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
                    .background {
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(theme.textPrimary.opacity(0.06))
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(L(airport.name))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)

                    HStack(spacing: 6) {
                        FlightCenterChip(text: airport.icao)
                        if station != nil { AtcOnlineBadge(theme: theme) }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(14)

            PanelDivider()

            PanelActionRow(
                title: "Open the field",
                symbol: "map",
                detail: "Weather, frequencies, stands and the diagram — and the field on the map."
            ) {
                actions.openFieldPanel(airport)
            }
        }
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    // MARK: The board

    private func boardSection(_ activity: AirportActivity) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Board", selection: $board) {
                ForEach(Board.allCases) { option in
                    Text(L(boardLabel(option, activity))).tag(option)
                }
            }
            .pickerStyle(.segmented)

            let movements = self.movements(on: board, activity)

            VStack(spacing: 0) {
                if movements.isEmpty {
                    PanelEmptyState(
                        symbol: board == .arrivals ? "airplane.arrival" : board == .departures ? "airplane.departure" : "airplane",
                        title: emptyTitle,
                        detail: feed.status.isLive
                            ? Lf("Nothing on %@ fits this list at %@ right now.", feed.server, airport.icao)
                            : "The board fills in as soon as the server is reporting."
                    )
                } else {
                    FlightCenterFlightList(
                        flights: movements.map(\.flight),
                        limit: 40,
                        detail: { flight in detail(for: flight, in: movements) },
                        onOpen: actions.openFlight
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .flightInfoSurface(theme, radius: theme.radiusMedium)
        }
    }

    private func boardLabel(_ option: Board, _ activity: AirportActivity) -> String {
        let count: Int
        switch option {
        case .arrivals: count = activity.inbound.count
        case .departures: count = activity.outbound.count
        case .ground: count = activity.onGround.count
        }
        return "\(L(option.label)) \(count)"
    }

    private var emptyTitle: String {
        switch board {
        case .arrivals: return "No arrivals"
        case .departures: return "No departures"
        case .ground: return "Nobody on the ground"
        }
    }

    private func movements(on board: Board, _ activity: AirportActivity) -> [AirportActivity.Movement] {
        switch board {
        case .arrivals: return activity.inbound
        case .departures: return activity.outbound
        case .ground: return activity.onGround
        }
    }

    /// The second line of a board row: where it is coming from or going, and
    /// the one number the board is for.
    private func detail(for flight: Flight, in movements: [AirportActivity.Movement]) -> String? {
        guard let movement = movements.first(where: { $0.id == flight.id }) else { return nil }
        let store = AirportStore.shared
        switch board {
        case .arrivals:
            let from = store.airport(flight.departureIcao).map { FlightCenterText.place($0) } ?? (flight.departureIcao ?? L("Unknown origin"))
            if let eta = movement.etaLabel { return Lf("From %@ · lands in %@", from, eta) }
            return Lf("From %@ · not yet airborne", from)
        case .departures:
            let to = store.airport(flight.arrivalIcao).map { FlightCenterText.place($0) } ?? (flight.arrivalIcao ?? L("no destination filed"))
            return Lf("To %@ · %@ NM out", to, Format.number(movement.distanceNM))
        case .ground:
            let state = movement.isTaxiing ? L("Taxiing") : L("Parked")
            if let to = flight.arrivalIcao, !to.isEmpty, to.uppercased() != airport.icao {
                return Lf("%@ · filed for %@", state, to.uppercased())
            }
            guard let pilot = flight.username, !pilot.isEmpty else { return state }
            return "\(state) · \(pilot)"
        }
    }

    // MARK: Who flies here

    @ViewBuilder
    private func airlines(_ activity: AirportActivity) -> some View {
        let tallies = airlineTallies(activity)
        if !tallies.isEmpty {
            PanelSection(title: "AIRLINES HERE NOW") {
                let maximum = tallies.first?.count ?? 1
                ForEach(Array(tallies.enumerated()), id: \.element.icao) { index, tally in
                    if index > 0 { PanelDivider() }
                    FlightCenterTallyRow(
                        title: tally.name,
                        detail: tally.icao,
                        count: tally.count,
                        maximum: maximum
                    ) {
                        actions.openAirline(tally.icao, tally.name)
                    }
                }
            }
        }
    }

    private struct AirlineTally {
        let icao: String
        let name: String
        let count: Int
    }

    private func airlineTallies(_ activity: AirportActivity) -> [AirlineTally] {
        var counts: [String: Int] = [:]
        for movement in activity.inbound + activity.outbound + activity.onGround {
            guard let icao = AirlineDirectory.icao(for: movement.flight) else { continue }
            counts[icao, default: 0] += 1
        }
        var tallies: [AirlineTally] = []
        for (icao, count) in counts {
            tallies.append(AirlineTally(icao: icao, name: AirlineDirectory.name(for: icao), count: count))
        }
        tallies.sort { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.icao < second.icao
        }
        return Array(tallies.prefix(6))
    }

    // MARK: Routes from and to

    @ViewBuilder
    private var routes: some View {
        let outbound = routeTallies(departing: true)
        let inbound = routeTallies(departing: false)

        if !outbound.isEmpty || !inbound.isEmpty {
            PanelSection(title: "ROUTES") {
                PanelActionRow(
                    title: Lf("Everything out of %@", airport.icao),
                    symbol: "airplane.departure"
                ) {
                    actions.openRoute(airport.icao, "")
                }
                PanelDivider()
                PanelActionRow(
                    title: Lf("Everything into %@", airport.icao),
                    symbol: "airplane.arrival"
                ) {
                    actions.openRoute("", airport.icao)
                }

                let maximum = max(outbound.first?.count ?? 0, inbound.first?.count ?? 0, 1)

                ForEach(outbound, id: \.icao) { tally in
                    PanelDivider()
                    FlightCenterTallyRow(
                        title: "\(airport.icao) → \(tally.icao)",
                        detail: tally.name,
                        symbol: "arrow.up.right",
                        count: tally.count,
                        maximum: maximum
                    ) {
                        actions.openRoute(airport.icao, tally.icao)
                    }
                }

                ForEach(inbound, id: \.icao) { tally in
                    PanelDivider()
                    FlightCenterTallyRow(
                        title: "\(tally.icao) → \(airport.icao)",
                        detail: tally.name,
                        symbol: "arrow.down.right",
                        count: tally.count,
                        maximum: maximum
                    ) {
                        actions.openRoute(tally.icao, airport.icao)
                    }
                }
            }
        }
    }

    private struct FieldTally {
        let icao: String
        let name: String?
        let count: Int
    }

    /// The busiest other ends of this field's routes, one direction at a time.
    private func routeTallies(departing: Bool) -> [FieldTally] {
        var counts: [String: Int] = [:]
        for flight in feed.flights where !Flight.isRealWorld(id: flight.id) {
            let from = flight.departureIcao?.uppercased() ?? ""
            let to = flight.arrivalIcao?.uppercased() ?? ""
            guard !from.isEmpty, !to.isEmpty, from != to else { continue }
            if departing, from == airport.icao { counts[to, default: 0] += 1 }
            if !departing, to == airport.icao { counts[from, default: 0] += 1 }
        }
        var tallies: [FieldTally] = []
        for (icao, count) in counts {
            let name = AirportStore.shared.airport(icao).map { FlightCenterText.shortName($0) }
            tallies.append(FieldTally(icao: icao, name: name, count: count))
        }
        tallies.sort { first, second in
            if first.count != second.count { return first.count > second.count }
            return first.icao < second.icao
        }
        return Array(tallies.prefix(4))
    }

    // MARK: Nearby

    @ViewBuilder
    private var nearby: some View {
        let fields = nearbyFields()
        if !fields.isEmpty {
            PanelSection(title: "NEARBY AIRPORTS", accessory: AnyView(nearbyLegend)) {
                ForEach(Array(fields.enumerated()), id: \.element.airport.icao) { index, field in
                    if index > 0 { FlightCenterDivider() }
                    FlightCenterAirportRow(
                        icao: field.airport.icao,
                        name: FlightCenterText.shortName(field.airport),
                        flag: field.airport.flag,
                        inbound: field.inbound,
                        outbound: field.outbound,
                        detail: "\(Format.number(field.distanceNM)) NM"
                    ) {
                        actions.openAirport(field.airport)
                    }
                }
            }
        }
    }

    private var nearbyLegend: some View {
        Text("WITHIN 80 NM")
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(theme.textDim)
    }

    private struct NearbyField {
        let airport: Airport
        let distanceNM: Double
        let inbound: Int
        let outbound: Int
    }

    /// Fields within 80 NM that anybody has filed through, nearest first —
    /// the web page's "nearby airports", and the honest answer to "is the
    /// traffic here or next door".
    private func nearbyFields() -> [NearbyField] {
        let candidates = AirportStore.shared.nearestAirports(to: airport.coordinate, withinNM: 80, limit: 40)
            .filter { $0.icao != airport.icao }
        guard !candidates.isEmpty else { return [] }

        let wanted = Set(candidates.map(\.icao))
        var inbound: [String: Int] = [:]
        var outbound: [String: Int] = [:]
        for flight in feed.flights {
            if let to = flight.arrivalIcao?.uppercased(), wanted.contains(to) { inbound[to, default: 0] += 1 }
            if let from = flight.departureIcao?.uppercased(), wanted.contains(from) { outbound[from, default: 0] += 1 }
        }

        var fields: [NearbyField] = []
        for candidate in candidates {
            let arriving = inbound[candidate.icao] ?? 0
            let leaving = outbound[candidate.icao] ?? 0
            guard arriving + leaving > 0 else { continue }
            fields.append(NearbyField(
                airport: candidate,
                distanceNM: FlightProgress.distanceNM(from: airport.coordinate, to: candidate.coordinate),
                inbound: arriving,
                outbound: leaving
            ))
            if fields.count >= 6 { break }
        }
        return fields
    }
}

// MARK: - A route

private struct FlightCenterRoutePage: View {

    let from: String
    let to: String
    let actions: FlightCenterActions

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var navigator = FlightCenterNavigator.shared

    @AppStorage("flightCenter.routeSort") private var sort: FlightCenterSort = .remaining

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        let flights = FlightCenterRoute.flights(from: from, to: to, in: feed.flights)
        let reverse = from.isEmpty || to.isEmpty
            ? 0
            : FlightCenterRoute.flights(from: to, to: from, in: feed.flights).count
        let airborne = flights.filter { FlightPhase.from($0) != .ground }.count

        VStack(alignment: .leading, spacing: 14) {
            ends

            FlightCenterTiles {
                FlightCenterTile(value: "\(flights.count)", number: Double(flights.count), label: "FLIGHTS")
                FlightCenterTile(value: "\(airborne)", number: Double(airborne), label: "AIRBORNE")
                FlightCenterTile(value: distanceText, label: "DISTANCE")
            }

            PanelSection(
                title: Lf("ON THIS ROUTE · %@", String(flights.count)),
                accessory: flights.count > 1 ? AnyView(FlightCenterSortMenu(sort: $sort)) : nil
            ) {
                if flights.isEmpty {
                    PanelEmptyState(
                        symbol: "point.topleft.down.to.point.bottomright.curvepath",
                        title: "Nobody on this route",
                        detail: Lf("No aircraft on %@ have filed this route right now.", feed.server)
                    )
                } else {
                    FlightCenterFlightList(
                        flights: sort.apply(flights),
                        detail: routeDetail,
                        onOpen: actions.openFlight
                    )
                }
            }

            if !from.isEmpty, !to.isEmpty {
                PanelSection(title: "THE OTHER WAY") {
                    PanelActionRow(
                        title: "\(to) → \(from)",
                        symbol: "arrow.left.arrow.right",
                        detail: reverse == 1 ? L("1 flight right now") : Lf("%@ flights right now", String(reverse))
                    ) {
                        actions.openRoute(to, from)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Both ends, big: the route card's own layout, codes either side of the
    /// aeroplane.
    private var ends: some View {
        let store = AirportStore.shared
        let start = store.airport(from)
        let end = store.airport(to)

        return HStack(alignment: .top, spacing: 10) {
            endpoint(code: from, airport: start, alignment: .leading)

            VStack(spacing: 4) {
                Image(systemName: "airplane")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.accent)
                Capsule()
                    .fill(theme.trackFill)
                    .frame(width: 60, height: 3)
            }
            .padding(.top, 12)

            endpoint(code: to, airport: end, alignment: .trailing)
        }
        .padding(14)
        .flightInfoSurface(theme, radius: theme.radiusMedium)
    }

    private func endpoint(code: String, airport: Airport?, alignment: HorizontalAlignment) -> some View {
        Button {
            if let airport { actions.openAirport(airport) }
        } label: {
            VStack(alignment: alignment, spacing: 3) {
                Text(L(code.isEmpty ? "ANY" : code))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundStyle(code.isEmpty ? theme.textDim : theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                Text(L(airport.map { FlightCenterText.shortName($0) } ?? (code.isEmpty ? "Any airport" : "")))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(alignment == .leading ? .leading : .trailing)

                if let airport, !airport.flag.isEmpty {
                    Text(L(airport.flag)).font(.system(size: 14))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.97))
        .disabled(airport == nil)
    }

    private var distanceText: String {
        let store = AirportStore.shared
        guard let start = store.airport(from), let end = store.airport(to) else { return "—" }
        return "\(Format.number(FlightProgress.distanceNM(from: start.coordinate, to: end.coordinate))) NM"
    }

    /// With one end open, the row says which other end it has; with both
    /// filled, who is flying it and how far along they are.
    private func routeDetail(_ flight: Flight) -> String? {
        if from.isEmpty || to.isEmpty {
            return FlightCenterText.route(flight)
        }
        var parts: [String] = []
        if let progress = FlightProgress(flight: flight), FlightPhase.from(flight) != .ground {
            parts.append(Lf("%@%% flown", String(Int((progress.fraction * 100).rounded()))))
        } else {
            parts.append(L(flight.groundSpeedKnots >= 5 ? "Taxiing" : "On the ground"))
        }
        if let pilot = flight.username, !pilot.isEmpty { parts.append(pilot) }
        return parts.joined(separator: " · ")
    }
}
