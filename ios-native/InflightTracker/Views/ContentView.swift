import CoreLocation
import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var filters = MapFilters.shared
    @ObservedObject private var weatherPreferences = WeatherPreferences.shared
    @ObservedObject private var friends = FriendsStore.shared
    @ObservedObject private var push = PushService.shared

    @State private var selection: SelectedFlight?

    /// Height the peak state needs for its own content, reported back by the
    /// window once it has measured itself.
    @State private var peakHeight = FlightInfoLayout.basePeakHeight

    /// Which phase the info window is in. Owned here so it can be reset to the
    /// peak state each time a different aircraft is tapped.
    @State private var detent: PresentationDetent = .height(FlightInfoLayout.basePeakHeight)

    /// Latest camera request from the chrome around the map.
    @State private var mapCommand: MapCommand?

    /// Whether the map is staying with the open aircraft. Lives here rather
    /// than in the map so it can be turned off by the things that contradict
    /// it — framing a whole route, or closing the window entirely.
    @State private var isFollowing = false

    /// The flight an open field panel was reached from, so it can be gone back
    /// to. Nil whenever the field was opened from anywhere with nothing behind
    /// it — the search results, the ATC panel, the board.
    @State private var airportOrigin: SelectedFlight?

    /// What has been typed into the search field at the top of the map.
    @State private var query = ""

    /// Weather for the field the map is over, and for the open flight's route.
    @StateObject private var weather = WeatherModel()
    @State private var isWeatherExpanded = false

    /// Playback of the open aircraft's own track, started from the window and
    /// watched on the map.
    @StateObject private var replay = FlightReplay()

    private var theme: FlightInfoTheme { appearance.theme }

    private var peakDetent: PresentationDetent { .height(peakHeight) }

    /// What the sheet is showing. A view can only present one thing at a time,
    /// so the flight window, the toolbar's panels and a field all share this
    /// rather than each carrying their own `.sheet`.
    ///
    /// The flight case's id doesn't change with the aircraft, which is what
    /// lets tapping a second plane swap the window's contents instead of
    /// dismissing and re-presenting the sheet — a re-presentation loses the
    /// peak detent and comes back at full height.
    private enum WindowSheet: Identifiable, Equatable {
        case flight
        case panel(MapPanelKind)

        /// A field — from the search results, the ATC panel, the board, or an
        /// open flight's route card. Carries the ICAO rather than the `Airport`
        /// so the case stays `Equatable` and cheap; the dataset resolves it
        /// back when the sheet is built.
        case airport(String)

        var id: String {
            switch self {
            case .flight: return "flight"
            case .panel(let kind): return kind.rawValue
            case .airport(let icao): return "airport|\(icao)"
            }
        }
    }

    @State private var sheet: WindowSheet?

    /// The traffic the map draws: the packet, narrowed by the filters, with the
    /// open aircraft kept whatever they say.
    private var visibleFlights: [Flight] {
        filters.apply(to: feed.flights, keeping: selection?.id)
    }

    /// Search runs over the whole packet rather than `visibleFlights` — a
    /// callsign you have typed out in full is one you want found, not one the
    /// altitude filter gets to hide.
    private var results: [MapSearchResult] {
        MapSearch.results(for: query, in: feed.flights, limit: 6)
    }

    /// Watched pilots the feed can currently see, for the toolbar's badge.
    /// Counted over the whole packet rather than `visibleFlights` — a friend
    /// hidden by an altitude filter is still flying.
    private var friendsAloft: Int {
        let watched = Set(friends.friends)
        guard !watched.isEmpty else { return 0 }
        var seen = Set<String>()
        for flight in feed.flights {
            guard let username = flight.username?.lowercased(), watched.contains(username) else { continue }
            seen.insert(username)
        }
        return seen.count
    }

    var body: some View {
        ZStack(alignment: .top) {
            TrackerMapView(
                flights: visibleFlights,
                selection: $selection,
                command: mapCommand,
                bottomInset: selection == nil ? MapToolbar.reservedHeight : peakHeight,
                replayFrame: replay.frame,
                // A replay is driving the camera down the old track; following
                // the live aircraft at the same time would be two things
                // fighting over one map.
                isFollowing: isFollowing && !replay.isActive
            )
            .ignoresSafeArea()

            // Map chrome, top down: search always, then the weather chip while
            // an aircraft is open — it reports on where that aircraft is, so
            // there is nothing for it to say without one.
            VStack(alignment: .leading, spacing: 10) {
                MapSearchField(
                    query: $query,
                    results: results,
                    theme: theme,
                    onSelect: open
                )

                if selection != nil, weatherPreferences.isChipVisible {
                    WeatherChip(model: weather, theme: theme, isExpanded: $isWeatherExpanded)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            mapControls
            mapToolbar
            replayBar
        }
        .animation(.easeInOut(duration: 0.22), value: selection?.id)
        .animation(.easeInOut(duration: 0.22), value: replay.isActive)
        .onChange(of: selection?.id) { _, id in
            // A replay belongs to the aircraft it was started from, and to the
            // window that drew the track under it. Opening another aircraft,
            // or closing the window, ends it rather than leaving a ghost
            // flying a path nothing on screen refers to.
            if replay.isActive, id != replay.flightId { replay.stop() }

            // Following is about one aircraft. Another one — or none — is not
            // something to carry the mode over to.
            isFollowing = false

            detent = peakDetent

            if id == nil {
                if sheet == .flight { sheet = nil }
            } else if sheet != .flight {
                sheet = .flight
            }

            isWeatherExpanded = false
            updateWeather(force: true)
        }
        // The aircraft keeps moving while its window is open, so the field it
        // is passing is re-resolved as it goes. The model only refetches once
        // the position has actually moved on.
        .onChange(of: feed.lastUpdate) { _, _ in
            // Keeps the home-screen tiles fed. Cheap on every packet — the
            // bridge does the throttling, because only it knows what a widget
            // would actually notice.
            WidgetBridge.shared.update(flights: feed.flights)

            guard selection != nil else { return }
            updateWeather()
        }
        // A tapped notification names a pilot; the map goes and finds them.
        .onChange(of: push.pendingPilot) { _, username in
            guard let username = username else { return }
            push.pendingPilot = nil
            openPilot(username)
        }
        // Whatever takes the sheet away — a drag, or a panel opening — also
        // lets the map go of the aircraft.
        .onChange(of: sheet) { _, value in
            if value != .flight, selection != nil { selection = nil }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .flight:
                Group {
                    if let selected = selection {
                        FlightDetailView(
                            flightId: selected.id,
                            peakHeight: $peakHeight,
                            onReplay: { track in startReplay(of: selected.id, track: track) },
                            onSelectAirport: { field in openAirport(field, from: selected) }
                        )
                            // Resets the window's own state per aircraft
                            // without taking the sheet down with it.
                            .id(selected.id)
                            .environmentObject(feed)
                    }
                }
                .presentationDetents([peakDetent, .large], selection: $detent)
                .presentationDragIndicator(.visible)
                .flightInfoSheetInteraction(upThrough: peakDetent)
                // Belt and braces: however the sheet came to be on screen, it
                // starts in the peak state.
                .onAppear { detent = peakDetent }

            case .panel(let kind):
                panel(kind)

            case .airport(let icao):
                // Resolved here rather than carried in the case: the sheet can
                // outlive the search result it was opened from, and an ICAO the
                // dataset doesn't have is nothing to present.
                if let airport = AirportStore.shared.airport(icao) {
                    AirportPanel(
                        airport: airport,
                        onShowOnMap: { field in
                            // Same order as the other panels: close first, then
                            // move, so the field isn't framed underneath the
                            // sheet it was picked in.
                            sheet = nil
                            focus(on: field.coordinate, spanMeters: 90_000)
                        },
                        onSelectFlight: { flight in
                            sheet = nil
                            selection = SelectedFlight(id: flight.id)
                            focus(on: flight.coordinate, spanMeters: 240_000)
                        },
                        origin: airportReturn
                    )
                    .environmentObject(feed)
                }
            }
        }
        // The detent set changes with the measurement, so the selection has to
        // move to the new value or the sheet snaps to whatever is left.
        .onChange(of: peakHeight) { _, height in
            guard detent != .large else { return }
            detent = .height(height)
        }
        .onAppear { feed.connect() }
    }

    // MARK: - Panels

    @ViewBuilder
    private func panel(_ kind: MapPanelKind) -> some View {
        switch kind {
        case .friends:
            FriendsPanel { flight in
                // Close first, then move: the map's edge padding is sized for
                // the toolbar rather than for a half-height sheet, so the
                // aircraft would otherwise be framed underneath the panel it
                // was picked in.
                sheet = nil
                selection = SelectedFlight(id: flight.id)
                focus(on: flight.coordinate, spanMeters: 240_000)
            }
            .environmentObject(feed)

        // Both of these hand off to the field's own panel rather than closing
        // and moving the map, which the field's first row does anyway. The
        // sheet's identity changes, so this dismisses and re-presents — fine
        // between panels, which carry no detent to lose, and the reason the
        // flight case deliberately keeps one id for every aircraft.
        case .atc:
            AtcPanel { airport in
                openAirport(airport)
            }
            .environmentObject(feed)

        case .airports:
            AirportsPanel { airport in
                openAirport(airport)
            }
            .environmentObject(feed)

        case .filters:
            FiltersPanel()
                .environmentObject(feed)

        case .weather:
            WeatherSettingsPanel(model: weather)

        case .settings:
            SettingsPanel()
                .environmentObject(feed)
        }
    }

    // MARK: - Fields

    /// Open a field, remembering the flight it was opened from.
    ///
    /// The sheet's identity changes, which dismisses the flight window and —
    /// through the selection watcher below — lets go of the aircraft. That is
    /// the behaviour every other panel wants; here it is the thing `origin`
    /// exists to undo.
    private func openAirport(_ airport: Airport, from flight: SelectedFlight?) {
        airportOrigin = flight
        sheet = .airport(airport.icao)
    }

    /// Open a field from somewhere with nothing to come back to.
    private func openAirport(_ airport: Airport) {
        openAirport(airport, from: nil)
    }

    /// The back row for the field panel, when there is a flight behind it.
    ///
    /// Named from the packet rather than from whatever the callsign was when
    /// the field was opened, so a flight that has since stopped reporting is
    /// still offered — going back to it lands on the window's own "this flight
    /// has ended" state, which is a better answer than the row quietly
    /// vanishing.
    private var airportReturn: AirportPanel.Origin? {
        guard let origin = airportOrigin else { return nil }

        let label = feed.flights.first { $0.id == origin.id }?.displayName ?? "the flight"

        return AirportPanel.Origin(label: label) {
            // One assignment does it: the selection watcher puts the flight
            // window back up, resets the detent and re-reads the weather, the
            // same as it would for any other way of opening an aircraft.
            selection = origin
        }
    }

    // MARK: - Search

    /// Acting on a search result: each kind opens its own window.
    ///
    /// An aircraft is brought into view straight away, since what was picked is
    /// quite possibly not on screen at all. A field isn't: its panel is what
    /// was actually asked for — who is controlling, what is inbound, what is on
    /// the apron — and moving the map under a half-height sheet would frame the
    /// airport somewhere behind it. The panel's own first row does the move,
    /// once the sheet is out of the way.
    private func open(_ result: MapSearchResult) {
        switch result {
        case .flight(let flight):
            selection = SelectedFlight(id: flight.id)
            focus(on: flight.coordinate, spanMeters: 240_000)

        case .airport(let airport):
            // Searching is live over an open flight window, so this can be a
            // swap rather than a fresh presentation. Changing the sheet's
            // identity dismisses and re-presents, which is exactly what the
            // flight case avoids — but what it is avoiding is losing the peak
            // detent, and a panel has no detent state to lose.
            //
            // No origin: a field typed into the search field was not arrived at
            // from anywhere, even if a flight window happened to be open behind
            // it. Offering to go "back" to an aircraft nobody navigated from
            // would be inventing a history.
            selection = nil
            openAirport(airport)
        }
    }

    /// Open the aircraft a notification was about.
    ///
    /// The pilot may well not be in the packet: the push arrives within
    /// seconds of the event, and the app may have been launched by the tap and
    /// still be connecting. Nothing happens in that case rather than something
    /// misleading — the friends panel is where they can be looked up once the
    /// feed has caught up.
    private func openPilot(_ username: String) {
        let wanted = username.lowercased()
        guard let flight = feed.flights.first(where: { $0.username?.lowercased() == wanted }) else { return }
        sheet = nil
        selection = SelectedFlight(id: flight.id)
        focus(on: flight.coordinate, spanMeters: 240_000)
    }

    // MARK: - Replay

    /// Starts playback and gets out of its way: the window drops back to its
    /// peak so the map — which is the thing being watched — is most of the
    /// screen, and the camera is put on the start of the track.
    private func startReplay(of flightId: String, track: [TrackPoint]) {
        guard track.count >= FlightReplay.minimumPoints else { return }

        let title = feed.flights.first { $0.id == flightId }?.displayName ?? "Flight"
        replay.start(flightId: flightId, title: title, points: track)

        detent = peakDetent

        if let first = track.first {
            focus(on: first.coordinate, spanMeters: 320_000)
        }
    }

    @ViewBuilder
    private var replayBar: some View {
        if replay.isActive {
            ReplayBar(replay: replay, theme: theme)
                .padding(.horizontal, 14)
                // Clears the info window when one is open, and the bottom of
                // the screen when the replay has outlived it.
                .padding(.bottom, selection == nil ? 6 : peakHeight + 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private func focus(on coordinate: CLLocationCoordinate2D, spanMeters: Double) {
        mapCommand = MapCommand(
            kind: .focus(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                spanMeters: spanMeters
            )
        )
    }

    /// Weather follows the open aircraft: the field it is passing, and both
    /// ends of its route.
    private func updateWeather(force: Bool = false) {
        guard let selected = selection,
              let flight = feed.flights.first(where: { $0.id == selected.id }) else { return }

        weather.updateNearby(to: flight.coordinate, force: force)
        weather.updateRoute(departure: flight.departureIcao, arrival: flight.arrivalIcao)
    }

    // MARK: - Bottom chrome

    /// The toolbar, along the bottom while the map is the whole screen. With an
    /// aircraft open the info window is sitting over this, so it gives way to
    /// the window's own controls rather than hiding behind it.
    @ViewBuilder
    private var mapToolbar: some View {
        if selection == nil {
            VStack(spacing: 8) {
                // Above the bar rather than over the map proper: it is an
                // aside about the chrome it is sitting on, and anywhere else
                // it would be something laid over the traffic. The map's
                // reserved inset is not grown to match — hints retire, and
                // permanently shrinking where the map can frame things for
                // something that goes away would be the wrong trade.
                HintStrip(placement: .map, isFloating: true)

                MapToolbar(
                    theme: theme,
                    atcCount: feed.atcCount,
                    activeFilters: filters.activeCount,
                    friendsAloft: friendsAloft
                ) { kind in
                    sheet = .panel(kind)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // The keyboard is the search field's business. Without this the bar
            // rides up on top of it while a query is being typed.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Sits above the peak state while an aircraft is open. At the full window
    /// the sheet covers this corner anyway, so there is nothing to hide.
    ///
    /// A running replay takes the corner: it is driving the camera itself, and
    /// its bar wants the room these buttons would be sitting in.
    @ViewBuilder
    private var mapControls: some View {
        if selection != nil, !replay.isActive {
            // One grouped control rather than free-floating circles: it reads
            // as part of the window's chrome instead of two loose buttons.
            VStack(spacing: 0) {
                mapButton(
                    "viewfinder",
                    isFollowing ? "Stop following this aircraft" : "Follow this aircraft",
                    isOn: isFollowing
                ) {
                    isFollowing.toggle()
                    // Turning it on takes the map to the aircraft straight
                    // away. Follow itself only acts once the aircraft has
                    // drifted out of the middle of the view, which from a map
                    // pointed somewhere else entirely would leave the mode
                    // looking like it had done nothing.
                    if isFollowing { mapCommand = MapCommand(kind: .centerOnFlight) }
                }

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                mapButton("location.fill", "Centre on aircraft") {
                    mapCommand = MapCommand(kind: .centerOnFlight)
                }

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                mapButton("arrow.down.left.and.arrow.up.right", "Show whole route") {
                    // Framing the whole route and staying with the aircraft are
                    // different intents, and following would pull the camera
                    // back off the route within a packet or two of getting
                    // there.
                    isFollowing = false
                    mapCommand = MapCommand(kind: .fitRoute)
                }
            }
            .frame(width: 44)
            // The follow button fills itself when it is on, and it is the top
            // of the stack. Glass draws behind its content rather than
            // clipping it, so without this the accent squares off the hub's
            // rounded corners.
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(.trailing, 16)
            .padding(.bottom, peakHeight + 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
        }
    }

    /// `isOn` is for the one control in the hub that is a mode rather than a
    /// move. It reads as on the way every other switched-on thing in the app
    /// does — filled with the accent, glyph knocked out of it — so the state is
    /// legible without colour carrying the meaning.
    private func mapButton(
        _ symbol: String,
        _ label: String,
        isOn: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? theme.onAccent : theme.textPrimary)
                .frame(width: 44, height: 42)
                .background {
                    if isOn { Rectangle().fill(theme.accent) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

}
