import CoreLocation
import SwiftUI
// For `WeatherAttribution`, which the attribution row is handed. Named here
// rather than relied on through another file's import.
import WeatherKit

/// Weather where the map is looking, top left.
///
/// Collapsed it is the field being passed over: conditions, temperature, ICAO
/// and wind. Tapped, it opens out to add both ends of whatever route is open,
/// each marked day or night, so a long-haul's destination weather is one tap
/// away from the map.
///
/// Most of the world's airfields file no METAR at all, and this used to answer
/// for them with an em dash and the field's name — which is the chip appearing
/// not to work, over an aircraft that is perfectly well somewhere with weather.
/// Apple fills those in. The report always wins where there is one: it is the
/// observation the field itself made, in the units an aircraft is flown in,
/// and Apple's is a model's answer for the same patch of ground.
struct WeatherChip: View {

    @ObservedObject var model: WeatherModel
    let theme: FlightInfoTheme

    @Binding var isExpanded: Bool

    @ObservedObject private var preferences = WeatherPreferences.shared
    @ObservedObject private var apple = AppleWeatherService.shared

    /// What the chip is about: the field being passed, plus both ends of the
    /// route when that is switched on.
    private var stations: [WeatherModel.Station] {
        guard preferences.showsRouteEnds else { return [model.nearby].compactMap { $0 } }
        return [model.nearby, model.departure, model.arrival].compactMap { $0 }
    }

    /// Whichever of those have no report of their own, for Apple to answer.
    private var unreported: [WeatherModel.Station] {
        stations.filter { $0.metar == nil }
    }

    /// Changes when the set of fields waiting on Apple changes, and at no other
    /// time — so the fetch is asked for once per field rather than once per
    /// redraw of a chip that is following a moving aeroplane.
    private var pendingKey: String {
        unreported.map(\.airport.icao).joined(separator: "|")
    }

    /// Whether anything on screen is Apple's rather than the field's. Their
    /// terms require the mark wherever the data is shown, and the mark lives in
    /// the opened card — so this is also what makes the chip open.
    private var isShowingApple: Bool {
        stations.contains { $0.metar == nil && apple.conditions(for: $0.airport.icao) != nil }
    }

    /// There is something to open into when the chip would say more than it
    /// already does — a route with both ends filed, or Apple data that owes an
    /// attribution. One station and a report is the collapsed chip over again,
    /// so it stays shut and stops being a button.
    private var isExpandable: Bool { stations.count >= 2 || isShowingApple }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let nearby = model.nearby {
                if isExpandable {
                    Button {
                        withAnimation(Motion.control) {
                            isExpanded.toggle()
                        }
                    } label: {
                        summary(for: nearby)
                    }
                    .buttonStyle(.plain)
                } else {
                    summary(for: nearby)
                }
            }

            if isExpanded, isExpandable {
                expanded
            }
        }
        .environment(\.colorScheme, theme.colorScheme)
        .task(id: pendingKey) {
            for station in unreported {
                apple.load(key: station.airport.icao, coordinate: station.airport.coordinate)
            }
        }
    }

    // MARK: - What a station is showing

    /// Apple's answer for a station, or nil when the field filed its own.
    private func fallback(for station: WeatherModel.Station) -> AppleWeatherService.Conditions? {
        guard station.metar == nil else { return nil }
        return apple.conditions(for: station.airport.icao)
    }

    private func symbol(for station: WeatherModel.Station) -> String {
        if let metar = station.metar { return metar.symbol(isDaylight: station.isDaylight) }
        if let apple = fallback(for: station) { return apple.symbolName }
        return station.isDaylight ? "sun.max.fill" : "moon.stars.fill"
    }

    private func temperature(for station: WeatherModel.Station) -> String {
        if let metar = station.metar { return metar.temperatureLabel(in: preferences.temperatureUnit) }
        guard let apple = fallback(for: station) else { return "—" }
        return "\(Int(preferences.temperatureUnit.convert(fromCelsius: apple.temperatureC).rounded()))°"
    }

    /// The line under the code: the wind where there is a report, what it is
    /// doing where there is only Apple, and the field's name where there is
    /// neither.
    private func detail(for station: WeatherModel.Station) -> String {
        if let metar = station.metar {
            return "\(metar.conditionLabel) · \(metar.windLabel(in: preferences.windUnit))"
        }
        return fallback(for: station)?.label ?? station.airport.name
    }

    // MARK: - Collapsed

    private func summary(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol(for: station))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 22)

            Text(temperature(for: station))
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()

            VStack(alignment: .leading, spacing: 1) {
                Text(station.airport.icao)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textSecondary)

                Text(detail(for: station))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.8)
            }
            .frame(maxWidth: 118, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // One control, so it gets the system's press response: the glass bends
        // towards the finger and the light on it moves.
        .flightInfoChrome(theme, in: Capsule(), interactive: true)
        .contentShape(Capsule())
    }

    // MARK: - Expanded

    private var expanded: some View {
        VStack(spacing: 0) {
            ForEach(stations) { station in
                if station.id != stations.first?.id {
                    Rectangle()
                        .fill(theme.stroke)
                        .frame(height: 1)
                }
                row(for: station)
            }

            // Apple's terms: their mark wherever their data is. It is why the
            // chip opens at all when a field has no report of its own.
            if isShowingApple {
                Rectangle()
                    .fill(theme.stroke)
                    .frame(height: 1)

                WeatherAttributionRow(attribution: apple.attribution)
            }
        }
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: theme.radiusMedium, style: .continuous))
        .frame(maxWidth: 268, alignment: .leading)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func row(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: station))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(station.role.label)
                        .font(.system(size: 8.5, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(theme.textDim)

                    Text(station.airport.icao)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.textPrimary)

                    dayNight(for: station)
                }

                Text(detail(for: station))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(temperature(for: station))
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func dayNight(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 3) {
            Image(systemName: station.isDaylight ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 7))
            Text(station.isDaylight ? "DAY" : "NIGHT")
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            Capsule().fill(theme.elevatedFill)
        }
        .fixedSize()
    }
}
