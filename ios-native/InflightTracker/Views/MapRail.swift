import SwiftUI

/// The bubbles down the top right of the map.
///
/// One grouped stack of glass rather than three loose circles, the same call
/// the flight window's centring controls make in the opposite corner — so the
/// two read as the same piece of furniture on either side of the screen, and
/// the map keeps its middle.
///
/// Everything here is available at all times, with an aircraft open or without
/// one. That is the point of moving it: the toolbar along the bottom is gone
/// the moment a flight window is up, which used to take the filters with it.
struct MapRail: View {

    let theme: FlightInfoTheme

    /// Weather for wherever the map is looking, and for an open flight's
    /// route. The bubble is the face of this.
    @ObservedObject var weather: WeatherModel

    @Binding var isWeatherExpanded: Bool

    /// How many filter groups are narrowed, marked with a dot rather than
    /// counted — the point is that the map is not showing everything.
    let activeFilters: Int

    let onFilters: () -> Void

    @ObservedObject private var preferences = WeatherPreferences.shared
    @ObservedObject private var mapAppearance = MapAppearance.shared

    /// What the expanded card lists: the field being reported on, plus the
    /// open route's ends when there is one and the setting allows it.
    private var stations: [WeatherModel.Station] {
        guard let nearby = weather.nearby else { return [] }
        guard preferences.showsRouteEnds else { return [nearby] }
        return [nearby, weather.departure, weather.arrival].compactMap { $0 }
    }

    /// Weather has a bubble when there is a report to put on it. Small fields
    /// file nothing, and a bubble showing an em dash is a button that does not
    /// reward the tap.
    private var showsWeather: Bool {
        preferences.isChipVisible && weather.nearby != nil
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            rail

            if isWeatherExpanded, !stations.isEmpty {
                WeatherStationList(stations: stations, theme: theme)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .environment(\.colorScheme, .dark)
    }

    private var rail: some View {
        VStack(spacing: 0) {
            if showsWeather, let nearby = weather.nearby {
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        isWeatherExpanded.toggle()
                    }
                } label: {
                    WeatherBubbleFace(station: nearby, theme: theme)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(weatherAccessibilityLabel(for: nearby))
                .accessibilityAddTraits(isWeatherExpanded ? .isSelected : [])

                MapRailDivider(theme: theme)
            }

            MapRailButton(
                symbol: "line.3.horizontal.decrease",
                label: activeFilters > 0 ? "Filters, \(activeFilters) active" : "Filters",
                theme: theme,
                badge: activeFilters > 0,
                action: onFilters
            )

            MapRailDivider(theme: theme)

            MapRailButton(
                symbol: mapAppearance.style.symbol,
                label: "Map style: \(mapAppearance.style.label). Tap for \(mapAppearance.style.next.label)",
                theme: theme
            ) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    mapAppearance.cycleStyle()
                }
            }
        }
        .frame(width: 44)
        // Glass draws behind its content rather than clipping it, so without
        // this the weather bubble's own fill squares off the rail's corners.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func weatherAccessibilityLabel(for station: WeatherModel.Station) -> String {
        guard let metar = station.metar else {
            return "Weather at \(station.airport.icao)"
        }
        return "Weather at \(station.airport.icao), \(metar.conditionLabel), "
            + metar.temperatureLabel(in: preferences.temperatureUnit)
    }
}

/// One button in a rail or hub: a glyph in a 44-point square, with an optional
/// dot for a state you would otherwise have to open the panel to discover.
///
/// Shared by the rail on the right and the centring hub on the left, so the two
/// stacks can't drift apart the first time either is touched.
struct MapRailButton: View {

    let symbol: String
    let label: String
    let theme: FlightInfoTheme

    /// Filled with the accent, glyph knocked out — how every switched-on thing
    /// in the app reads, so the state carries without colour doing the work.
    var isOn: Bool = false

    /// A dot on the glyph's corner. For state that is worth marking but not
    /// worth counting.
    var badge: Bool = false

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isOn ? theme.onAccent : theme.textPrimary)
                .frame(width: 44, height: 42)
                .overlay(alignment: .topTrailing) {
                    if badge {
                        Circle()
                            .fill(isOn ? theme.onAccent : theme.accent)
                            .frame(width: 6, height: 6)
                            .padding(.top, 9)
                            .padding(.trailing, 9)
                    }
                }
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

/// The hairline between two buttons in a stack.
struct MapRailDivider: View {

    let theme: FlightInfoTheme

    var body: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
    }
}
