import SwiftUI
// For `WeatherAttribution`, which the attribution row is handed.
import WeatherKit

/// Weather settings, from the last item in the weather chip's menu.
///
/// The units and the chip are about how a report *reads* rather than which
/// reports are fetched, so the sample at the top is live and changing a unit
/// rewrites it under your finger with no round trip.
///
/// The layers below are the other kind of setting: they put weather on the map
/// itself, and each one costs network while it is on. They are here rather than
/// under the filters because this is the button somebody presses when they are
/// looking for weather.
struct WeatherSettingsPanel: View {

    /// The weather the map is currently showing, so the settings can be judged
    /// against a real report rather than an invented one.
    @ObservedObject var model: WeatherModel

    @ObservedObject private var preferences = WeatherPreferences.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    /// What the tile service is actually serving. RainViewer has been
    /// withdrawing its free tier in stages, and a layer it has stopped serving
    /// should not be offered as a switch that draws nothing.
    @ObservedObject private var tiles = RainViewerService.shared

    @ObservedObject private var apple = AppleWeatherService.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// The layers there is any point offering. Off is always in; a withdrawn
    /// layer stays in only while it is the one selected, because a picker whose
    /// selection is not among its options draws blank.
    private var layers: [MapWeatherLayer] {
        // `tiles` is observed rather than asked: the router reads it, and this
        // needs re-running when what it says changes.
        _ = tiles.state
        return MapWeatherLayer.allCases.filter {
            MapWeatherSource.isAvailable($0) || $0 == preferences.mapLayer
        }
    }

    /// What to say under the layer picker: why the chosen one is drawing
    /// nothing, if it is, and otherwise what it is.
    private var layerDetail: String {
        guard preferences.mapLayer != .off else { return preferences.mapLayer.detail }

        if !MapWeatherSource.isAvailable(preferences.mapLayer) {
            return "\(preferences.mapLayer.label) is not being served just now — the map draws nothing for it. RainViewer has been withdrawing its free layers in stages."
        }

        // The frames exist and the images behind them do not, which is the
        // failure that used to be completely silent.
        if let failure = tiles.tileFailure {
            return "\(preferences.mapLayer.label): \(failure)"
        }

        return preferences.mapLayer.detail
    }

    var body: some View {
        MapPanel(title: "Weather", subtitle: subtitle) {
            if let station = model.nearby {
                PanelSection(title: "SAMPLE") {
                    sample(for: station)

                    // Whose reading it is, when it is not the field's own.
                    if station.metar == nil, apple.conditions(for: station.airport.icao) != nil {
                        PanelDivider()
                        WeatherAttributionRow(attribution: apple.attribution)
                    }
                }
            }

            PanelSection(title: "UNITS") {
                PanelPickerRow(
                    title: "Temperature",
                    symbol: "thermometer.medium",
                    options: TemperatureUnit.allCases,
                    label: { $0.label },
                    selection: $preferences.temperatureUnit
                )

                PanelDivider()

                PanelPickerRow(
                    title: "Wind speed",
                    symbol: "wind",
                    options: WindUnit.allCases,
                    label: { $0.label },
                    detail: "Reports are issued in knots; the others are converted for reading.",
                    selection: $preferences.windUnit
                )
            }

            PanelSection(title: "LAYERS") {
                PanelPickerRow(
                    title: "Weather layer",
                    symbol: "cloud.rain",
                    options: layers,
                    label: { $0.label },
                    detail: layerDetail,
                    selection: $preferences.mapLayer
                )

                // Radar only. The satellite's frames are whole days, and they
                // are there to be dragged through rather than played.
                if preferences.mapLayer == .radar {
                    PanelDivider()

                    PanelToggleRow(
                        title: "Animate",
                        symbol: "play.circle",
                        detail: "Runs through the two hours of frames behind the newest one. The strip over the map says which frame is drawn, and can be dragged.",
                        isOn: $preferences.animatesRadar
                    )
                }
            }

            PanelSection(title: "WINDS ALOFT") {
                PanelToggleRow(
                    title: "Wind barbs",
                    symbol: "wind",
                    detail: "A grid of model wind across whatever the map is showing, drawn as chart barbs — a pennant is fifty knots, a full feather ten, a half five.",
                    isOn: $preferences.showsWinds
                )

                if preferences.showsWinds {
                    PanelDivider()

                    PanelPickerRow(
                        title: "Level",
                        symbol: "arrow.up.and.down",
                        options: WindLevel.allCases,
                        label: { $0.label },
                        detail: "\(preferences.windLevel.longLabel) — the \(preferences.windLevel.pressureLevel) level, which is about where traffic at \(Format.number(Double(preferences.windLevel.approximateFeet))) ft is flying.",
                        selection: $preferences.windLevel
                    )
                }
            }

            PanelSection(title: "ON THE MAP") {
                PanelToggleRow(
                    title: "Field conditions",
                    symbol: "thermometer.sun",
                    detail: "Writes each marked field\'s wind and temperature under its code, once the map is close enough to read them. The reports are already on the device, so this costs nothing.",
                    isOn: $preferences.showsFieldConditions
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Weather chip",
                    symbol: "cloud.sun.fill",
                    detail: "The pill top left while an aircraft is open, reporting the field it is passing.",
                    isOn: $preferences.isChipVisible
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Include route ends",
                    symbol: "arrow.left.arrow.right",
                    detail: "Opening the chip adds the departure and arrival fields to the one being passed.",
                    isOn: $preferences.showsRouteEnds
                )
                .disabled(!preferences.isChipVisible)
                .opacity(preferences.isChipVisible ? 1 : 0.45)
            }

            HintStrip(placement: .weather)

            Text("Reports come from VATSIM's METAR service, the same source the tracker has always used, and each station issues one an hour. Where a field files none — which is most of the world's airfields — the reading is Apple's, and says so. The radar tiles are RainViewer's; the satellite imagery is from NASA's Global Imagery Browse Services, part of their Earth Science Data and Information System; the winds aloft are Open-Meteo's model data. None of it costs anything to use.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 2)
        }
        // The layer picker offers what is actually being served, and with every
        // layer off nothing else would ever ask. One small index document, when
        // somebody opens the panel that shows the switch.
        .onAppear { tiles.refresh() }
        .task(id: model.nearby?.airport.icao) {
            guard let station = model.nearby, station.metar == nil else { return }
            apple.load(key: station.airport.icao, coordinate: station.airport.coordinate)
        }
    }

    private var subtitle: String {
        guard let station = model.nearby else { return "No field in range" }
        if station.metar == nil, sampleFallback != nil {
            return "Nearest field · \(station.airport.icao)"
        }
        return "Nearest report · \(station.airport.icao)"
    }

    private func sampleTemperature(for station: WeatherModel.Station) -> String {
        if let metar = station.metar {
            return metar.temperatureLabel(in: preferences.temperatureUnit)
        }
        guard let apple = sampleFallback else { return "—" }
        return "\(Int(preferences.temperatureUnit.convert(fromCelsius: apple.temperatureC).rounded()))°"
    }

    /// Apple's answer for the sampled field, when the field files nothing.
    private var sampleFallback: AppleWeatherService.Conditions? {
        guard let station = model.nearby, station.metar == nil else { return nil }
        return apple.conditions(for: station.airport.icao)
    }

    /// The live report, written the way the current settings write it.
    private func sample(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 12) {
            Image(systemName: station.metar?.symbol(isDaylight: station.isDaylight)
                  ?? sampleFallback?.symbolName
                  ?? (station.isDaylight ? "sun.max.fill" : "moon.stars.fill"))
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 26))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(station.airport.icao)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.textPrimary)

                    if !station.airport.flag.isEmpty {
                        Text(station.airport.flag).font(.system(size: 10))
                    }
                }

                Text(station.metar.map { "\($0.conditionLabel) · \($0.windLabel(in: preferences.windUnit))" }
                     ?? sampleFallback?.label
                     ?? station.airport.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(sampleTemperature(for: station))
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}
