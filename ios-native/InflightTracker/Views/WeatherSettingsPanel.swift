import SwiftUI

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

    @ObservedObject private var forecast = ForecastService.shared

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
                    if sampleFallback != nil {
                        PanelDivider()
                        ForecastSourceRow()
                    }

                    // And when the forecast service answered with nothing at
                    // all, why.
                    //
                    // Everything the model feeds — the forecast, the outlook,
                    // the sun and the moon — is drawn only where there is data
                    // to draw, so a field it could not answer for shows no
                    // weather and says nothing about why. This is the one place
                    // that says it.
                    if let failure = forecast.lastFailure {
                        PanelDivider()

                        Text(failure)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(theme.textDim)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
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
                        detail: animateDetail,
                        isOn: $preferences.animatesRadar
                    )
                }
            }

            // Three ways of drawing one grid, and they compose: barbs are the
            // numbers, the streaks are the motion, the wash is the magnitude.
            // All of them come off the same request — see `WindsAloftStore` —
            // so turning a second one on costs nothing the first was not
            // already spending.
            PanelSection(title: "WINDS ALOFT") {
                PanelToggleRow(
                    title: "Wind barbs",
                    symbol: "wind",
                    detail: "A grid of model wind across whatever the map is showing, drawn as chart barbs — a pennant is fifty knots, a full feather ten, a half five.",
                    isOn: $preferences.showsWinds
                )

                PanelDivider()

                PanelToggleRow(
                    title: "Moving air",
                    symbol: "aqi.medium",
                    detail: "Draws the air as streaks running the way it is going, with the fast ones longer. The clock is scaled so the movement reads at whatever the map is showing — the speeds are true against each other, not against a watch.",
                    isOn: $preferences.showsWindParticles
                )

                PanelDivider()

                PanelPickerRow(
                    title: "Field",
                    symbol: "square.stack.3d.down.right",
                    options: WeatherHeat.allCases,
                    label: { $0.label },
                    detail: preferences.windHeat.detail,
                    selection: $preferences.windHeat
                )

                if preferences.showsAnyWind {
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

            PanelSection(title: "ON A FIELD") {
                PanelToggleRow(
                    title: "Ten days and the sky",
                    symbol: "calendar",
                    detail: "Adds the ten-day outlook and the sun, twilight and moon times to an airport's panel, under the forecast. The outlook came down with the forecast and the sky is arithmetic, so this only decides how far the panel scrolls.",
                    isOn: $preferences.showsOutlook
                )
            }

            HintStrip(placement: .weather)

            Text("Reports come from VATSIM's METAR service, the same source the tracker has always used, and each station issues one an hour. Where a field files none — which is most of the world's airfields — the reading is Open-Meteo's model, and says so; the same request carries the forecast and the outlook, and the sun and moon times are worked out on the device. Severe-weather warnings come from the National Weather Service, which covers the United States and nowhere else. The radar tiles are RainViewer's; the satellite imagery is from NASA's Global Imagery Browse Services, part of their Earth Science Data and Information System; the winds aloft are Open-Meteo's too. None of it costs anything to use.")
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
            forecast.load(key: station.airport.icao, coordinate: station.airport.coordinate)
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
        guard let modelled = sampleFallback else { return "—" }
        return "\(Int(preferences.temperatureUnit.convert(fromCelsius: modelled.temperatureC).rounded()))°"
    }

    /// The model's answer for the sampled field, when the field files nothing.
    private var sampleFallback: ForecastService.Conditions? {
        guard let station = model.nearby, station.metar == nil else { return nil }
        return forecast.conditions(for: station.airport.icao)
    }

    /// The live report, written the way the current settings write it.
    /// What the animate row says, which depends on which shape the world is.
    ///
    /// On the planet the loop is held: a frame of radar there is a whole
    /// software raster of the visible face of the sphere, and two a second is
    /// not something to ask a phone for. See `MapWeatherModel.report(drawnPlanet:)`.
    /// Said outright rather than left as a switch that appears to do nothing.
    private var animateDetail: String {
        let base = "Runs through the two hours of frames behind the newest one. Off, the map draws the newest frame and nothing else, which is a seventh of the tiles and what the free tier is comfortable serving. The strip over the map says which frame is drawn either way, and can be dragged."
        guard appearance.resolvedMapStyle.isDrawn else { return base }
        return base + " Held on the planet, which draws each frame itself rather than in tiles — the newest is shown, and the strip still scrubs."
    }

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

                    // The sample is whichever source answered for the nearest
                    // field, and the panel is a place people come to compare
                    // the two. Saying which one is on screen costs a glyph, and
                    // the credit row below names it in full.
                    if sampleFallback != nil {
                        ForecastSourceMark(size: 10, colour: theme.textDim)
                    }
                }

                Text(station.metar.map { "\($0.conditionLabel) · \($0.windLabel(in: preferences.windUnit))" }
                     ?? sampleFallback.map { "\($0.label) · \($0.windLabel(in: preferences.windUnit))" }
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
