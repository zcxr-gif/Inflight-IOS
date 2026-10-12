import CoreLocation
import SwiftUI

/// Weather where the open aircraft is, top left.
///
/// Collapsed it is the field being passed over: conditions, temperature, ICAO
/// and wind. Tapped, it opens into the same card the map's own weather pill
/// does — the field's weather, today's high and low, the air quality and the
/// next few hours — with both ends of whatever route is open underneath, each
/// marked day or night. See `StationWeatherCard`, which `ContentView` draws
/// under the top row so it has the whole width to open into.
///
/// Most of the world's airfields file no METAR at all, and this used to answer
/// for them with an em dash and the field's name — which is the chip appearing
/// not to work, over an aircraft that is perfectly well somewhere with weather.
/// The forecast model fills those in. The report always wins where there is
/// one: it is the observation the field itself made, in the units an aircraft
/// is flown in, and the model's is a computation for the same patch of ground.
struct WeatherChip: View {

    @ObservedObject var model: WeatherModel
    let theme: FlightInfoTheme

    @Binding var isExpanded: Bool

    @ObservedObject private var preferences = WeatherPreferences.shared
    @ObservedObject private var forecast = ForecastService.shared

    /// What the chip is about: the field being passed, plus both ends of the
    /// route when that is switched on.
    private var stations: [WeatherModel.Station] {
        model.stations(includingRouteEnds: preferences.showsRouteEnds)
    }

    /// Whichever of those have no report of their own, for the model to answer.
    private var unreported: [WeatherModel.Station] {
        stations.filter { $0.metar == nil }
    }

    /// Changes when the set of fields waiting on the model changes, and at no
    /// other time — so the fetch is asked for once per field rather than once
    /// per redraw of a chip that is following a moving aeroplane.
    private var pendingKey: String {
        unreported.map(\.airport.icao).joined(separator: "|")
    }

    var body: some View {
        Group {
            if let nearby = model.nearby {
                Button {
                    withAnimation(Motion.control) {
                        isExpanded.toggle()
                    }
                } label: {
                    summary(for: nearby)
                }
                .buttonStyle(.plain)
                .accessibilityHint(L(isExpanded ? "Hides the forecast" : "Shows the forecast"))
            }
        }
        .environment(\.colorScheme, theme.colorScheme)
        .task(id: pendingKey) {
            for station in unreported {
                forecast.load(key: station.airport.icao, coordinate: station.airport.coordinate)
            }
        }
    }

    // MARK: - Collapsed

    private func summary(for station: WeatherModel.Station) -> some View {
        let temperature = station.temperatureLabel(forecast: forecast, unit: preferences.temperatureUnit)

        // The same readout as the map's own pill: the field's code where the
        // map's has the air quality, and its wind after it.
        return WeatherReadout(
            theme: theme,
            symbol: station.symbol(forecast: forecast),
            temperature: temperature,
            tag: station.airport.icao,
            detail: station.compactWind(forecast: forecast, windUnit: preferences.windUnit),
            isModelled: station.modelled(forecast) != nil
        )
    }
}

// MARK: - What a station is showing

extension WeatherModel {

    /// The field being passed, and both ends of the route when asked for.
    func stations(includingRouteEnds: Bool) -> [Station] {
        guard includingRouteEnds else { return [nearby].compactMap { $0 } }
        return [nearby, departure, arrival].compactMap { $0 }
    }
}

extension WeatherModel.Station {

    /// The model's answer for a station, or nil when the field filed its own.
    func modelled(_ forecast: ForecastService) -> ForecastService.Conditions? {
        guard metar == nil else { return nil }
        return forecast.conditions(for: airport.icao)
    }

    func symbol(forecast: ForecastService) -> String {
        if let metar { return metar.symbol(isDaylight: isDaylight) }
        if let modelled = modelled(forecast) { return modelled.symbolName }
        return isDaylight ? "sun.max.fill" : "moon.stars.fill"
    }

    /// The temperature in Celsius, from the report where there is one.
    func temperatureC(forecast: ForecastService) -> Double? {
        if let metar { return metar.temperatureC }
        return modelled(forecast)?.temperatureC
    }

    func temperatureLabel(forecast: ForecastService, unit: TemperatureUnit) -> String {
        guard let celsius = temperatureC(forecast: forecast) else { return "—" }
        return "\(Int(unit.convert(fromCelsius: celsius).rounded()))°"
    }

    /// The conditions alone, from whichever source answered.
    func conditionLabel(forecast: ForecastService) -> String? {
        if let metar { return metar.conditionLabel }
        return modelled(forecast)?.label
    }

    /// The wind as a readout writes it — `240°/12kt`, `240°/12G20kt`, `CALM`
    /// — from whichever source answered, or nil where neither did.
    func compactWind(forecast: ForecastService, windUnit: WindUnit) -> String? {
        let label: String
        if let metar {
            label = metar.windLabel(in: windUnit)
        } else if let modelled = modelled(forecast) {
            label = modelled.windLabel(in: windUnit)
        } else {
            return nil
        }
        if label == "Calm" { return "CALM" }
        return label
            .replacingOccurrences(of: " @ ", with: "/")
            .replacingOccurrences(of: " ", with: "")
    }

    /// The line under the code: conditions and wind from whichever source
    /// answered, and the field's name where neither did.
    ///
    /// The model carries a wind too, so this says one where it used to stop at
    /// the conditions — the same shape as the report's line, because half the
    /// point of the chip is comparing two fields at a glance.
    func detail(forecast: ForecastService, windUnit: WindUnit) -> String {
        if let metar {
            return "\(metar.conditionLabel) · \(metar.windLabel(in: windUnit))"
        }
        guard let modelled = modelled(forecast) else { return airport.name }
        return "\(modelled.label) · \(modelled.windLabel(in: windUnit))"
    }
}

// MARK: - Opened

/// What the flight window's chip opens into: the field being passed, as the
/// same card the map's pill opens, with both ends of the route underneath.
///
/// The headline is the field's own report where it filed one; the high and
/// low, the air quality and the hours are the forecast's, which is loaded for
/// the field here whether or not it filed — a report says what the weather is,
/// never what it is about to do.
struct StationWeatherCard: View {

    @ObservedObject var model: WeatherModel
    let theme: FlightInfoTheme
    /// On a panel's surface rather than as glass over the map — see
    /// `WeatherCard.isInset`.
    var isInset: Bool = false

    @ObservedObject private var preferences = WeatherPreferences.shared
    @ObservedObject private var forecast = ForecastService.shared

    private var routeEnds: [WeatherModel.Station] {
        model.stations(includingRouteEnds: preferences.showsRouteEnds).filter { $0.role != .nearby }
    }

    var body: some View {
        if let station = model.nearby {
            let snapshot = forecast.snapshot(for: station.airport.icao)
            let isLoading: Bool = {
                if case .loading = forecast.state(for: station.airport.icao) { return true }
                return false
            }()

            WeatherCard(
                theme: theme,
                title: station.airport.name,
                badge: station.airport.icao,
                symbolName: station.metar?.symbol(isDaylight: station.isDaylight)
                    ?? snapshot?.symbolName
                    ?? station.symbol(forecast: forecast),
                condition: station.conditionLabel(forecast: forecast)
                    ?? snapshot?.conditionLabel
                    ?? "—",
                temperatureC: station.temperatureC(forecast: forecast) ?? snapshot?.temperatureC,
                isModelled: station.metar == nil,
                snapshot: snapshot,
                isLoading: isLoading,
                isInset: isInset
            ) {
                ForEach(routeEnds) { end in
                    PanelDivider()
                    row(for: end)
                }
            }
            .task(id: station.airport.icao) {
                forecast.load(key: station.airport.icao, coordinate: station.airport.coordinate)
            }
            .task(id: routeEnds.map(\.airport.icao).joined(separator: "|")) {
                for end in routeEnds where end.metar == nil {
                    forecast.load(key: end.airport.icao, coordinate: end.airport.coordinate)
                }
            }
        }
    }

    private func row(for station: WeatherModel.Station) -> some View {
        let temperature = station.temperatureLabel(forecast: forecast, unit: preferences.temperatureUnit)

        return HStack(spacing: 10) {
            Image(systemName: station.symbol(forecast: forecast))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 17))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L(station.role.label))
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(theme.textDim)

                    Text(L(station.airport.icao))
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(theme.textPrimary)

                    // Per row, because this card mixes sources: a field that
                    // filed a report and one that did not sit one above the
                    // other.
                    if station.modelled(forecast) != nil {
                        ForecastSourceMark(colour: theme.textDim)
                    }

                    dayNight(for: station)
                }

                Text(L(station.detail(forecast: forecast, windUnit: preferences.windUnit)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.75)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(L(temperature))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()
                .motionWords(temperature)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func dayNight(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 3) {
            Image(systemName: station.isDaylight ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 7))
            Text(L(station.isDaylight ? "DAY" : "NIGHT"))
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
