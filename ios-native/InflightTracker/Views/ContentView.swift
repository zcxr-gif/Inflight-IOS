import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var feed: LiveFeed
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @State private var selection: SelectedFlight?

    /// Height the peak state needs for its own content, reported back by the
    /// window once it has measured itself.
    @State private var peakHeight = FlightInfoLayout.basePeakHeight

    /// Which phase the info window is in. Owned here so it can be reset to the
    /// peak state each time a different aircraft is tapped.
    @State private var detent: PresentationDetent = .height(FlightInfoLayout.basePeakHeight)

    /// Latest camera request from the buttons beside the info window.
    @State private var mapCommand: MapCommand?

    /// Weather for the field the map is over, and for the open flight's route.
    @StateObject private var weather = WeatherModel()
    @State private var isWeatherExpanded = false

    private var peakDetent: PresentationDetent { .height(peakHeight) }

    /// What the one sheet is showing. A view can only present one thing at a
    /// time, so the flight window and the controls hub share this rather than
    /// each carrying their own `.sheet`.
    ///
    /// The flight case's id doesn't change with the aircraft, which is what
    /// lets tapping a second plane swap the window's contents instead of
    /// dismissing and re-presenting the sheet — a re-presentation loses the
    /// peak detent and comes back at full height.
    private enum WindowSheet: String, Identifiable {
        case flight
        case hub

        var id: String { rawValue }
    }

    @State private var sheet: WindowSheet?

    var body: some View {
        ZStack(alignment: .top) {
            TrackerMapView(
                flights: feed.flights,
                selection: $selection,
                command: mapCommand,
                bottomInset: selection == nil ? 0 : peakHeight
            )
            .ignoresSafeArea()

            // Map chrome. The left of this row belongs to search; the weather
            // chip only takes it while an aircraft is open, and reports on
            // where that aircraft is rather than where the map is looking.
            HStack(alignment: .top, spacing: 12) {
                if selection != nil {
                    WeatherChip(model: weather, theme: appearance.theme, isExpanded: $isWeatherExpanded)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }

                Spacer(minLength: 8)

                ControlHubButton { sheet = .hub }
                    .environmentObject(feed)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            mapControls
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
        // Whatever takes the sheet away — a drag, or the hub opening — also
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

            case .hub:
                ControlHubPanel()
                    .environmentObject(feed)
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

    /// Weather follows the open aircraft: the field it is passing, and both
    /// ends of its route.
    private func updateWeather(force: Bool = false) {
        guard let selected = selection,
              let flight = feed.flights.first(where: { $0.id == selected.id }) else { return }

        weather.updateNearby(to: flight.coordinate, force: force)
        weather.updateRoute(departure: flight.departureIcao, arrival: flight.arrivalIcao)
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
                    .fill(appearance.theme.stroke)
                    .frame(height: 1)

                mapButton("arrow.down.left.and.arrow.up.right", "Show whole route") {
                    mapCommand = MapCommand(kind: .fitRoute)
                }
            }
            .frame(width: 44)
            .flightInfoChrome(
                appearance.theme,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .environment(\.colorScheme, .dark)
            .padding(.trailing, 16)
            .padding(.bottom, peakHeight + 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
                .foregroundStyle(appearance.theme.textPrimary)
                .frame(width: 44, height: 42)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

}
