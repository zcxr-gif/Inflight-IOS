import CoreLocation
import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var filters = MapFilters.shared
    @ObservedObject private var weatherPreferences = WeatherPreferences.shared

    @State private var selection: SelectedFlight?

    /// Height the peak state needs for its own content, reported back by the
    /// window once it has measured itself.
    @State private var peakHeight = FlightInfoLayout.basePeakHeight

    /// Which phase the info window is in. Owned here so it can be reset to the
    /// peak state each time a different aircraft is tapped.
    @State private var detent: PresentationDetent = .height(FlightInfoLayout.basePeakHeight)

    /// Latest camera request from the chrome around the map.
    @State private var mapCommand: MapCommand?

    /// What has been typed into the search field at the top of the map.
    @State private var query = ""

    /// Weather for the field the map is over, and for the open flight's route.
    @StateObject private var weather = WeatherModel()
    @State private var isWeatherExpanded = false

    private var theme: FlightInfoTheme { appearance.theme }

    private var peakDetent: PresentationDetent { .height(peakHeight) }

    /// What the sheet is showing. A view can only present one thing at a time,
    /// so the flight window and the toolbar's four panels share this rather
    /// than each carrying their own `.sheet`.
    ///
    /// The flight case's id doesn't change with the aircraft, which is what
    /// lets tapping a second plane swap the window's contents instead of
    /// dismissing and re-presenting the sheet — a re-presentation loses the
    /// peak detent and comes back at full height.
    private enum WindowSheet: Identifiable, Equatable {
        case flight
        case panel(MapPanelKind)

        var id: String {
            switch self {
            case .flight: return "flight"
            case .panel(let kind): return kind.rawValue
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

    var body: some View {
        ZStack(alignment: .top) {
            TrackerMapView(
                flights: visibleFlights,
                selection: $selection,
                command: mapCommand,
                bottomInset: selection == nil ? MapToolbar.reservedHeight : peakHeight
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
        }
        .animation(.easeInOut(duration: 0.22), value: selection?.id)
        .onChange(of: selection?.id) { _, id in
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
            guard selection != nil else { return }
            updateWeather()
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
                        FlightDetailView(flightId: selected.id, peakHeight: $peakHeight)
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
        case .atc:
            AtcPanel { airport in
                // Closing first, then moving: the map's edge padding is sized
                // for the toolbar rather than for a half-height sheet, so the
                // field would otherwise land under the panel it was picked in.
                sheet = nil
                focus(on: airport.coordinate, spanMeters: 60_000)
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

    // MARK: - Search

    /// Acting on a search result: aircraft open their window, fields just move
    /// the map. Both bring the target into view, since what was picked is
    /// quite possibly not on screen at all.
    private func open(_ result: MapSearchResult) {
        switch result {
        case .flight(let flight):
            selection = SelectedFlight(id: flight.id)
            focus(on: flight.coordinate, spanMeters: 240_000)

        case .airport(let airport):
            selection = nil
            focus(on: airport.coordinate, spanMeters: 90_000)
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
            MapToolbar(
                theme: theme,
                atcCount: feed.atcCount,
                activeFilters: filters.activeCount
            ) { kind in
                sheet = .panel(kind)
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
    @ViewBuilder
    private var mapControls: some View {
        if selection != nil {
            // One grouped control rather than free-floating circles: it reads
            // as part of the window's chrome instead of two loose buttons.
            VStack(spacing: 0) {
                mapButton("location.fill", "Centre on aircraft") {
                    mapCommand = MapCommand(kind: .centerOnFlight)
                }

                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                mapButton("arrow.down.left.and.arrow.up.right", "Show whole route") {
                    mapCommand = MapCommand(kind: .fitRoute)
                }
            }
            .frame(width: 44)
            .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
            .padding(.trailing, 16)
            .padding(.bottom, peakHeight + 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomTrailing)))
        }
    }

    private func mapButton(
        _ symbol: String,
        _ label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 44, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

}
