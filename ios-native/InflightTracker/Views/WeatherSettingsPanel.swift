import SwiftUI

/// Weather settings, from the toolbar's weather button.
///
/// Everything here is about how a report reads, not which reports are fetched —
/// so the sample at the top is live, and changing a unit rewrites it under your
/// finger with no round trip.
struct WeatherSettingsPanel: View {

    /// The weather the map is currently showing, so the settings can be judged
    /// against a real report rather than an invented one.
    @ObservedObject var model: WeatherModel

    @ObservedObject private var preferences = WeatherPreferences.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        MapPanel(title: "Weather", subtitle: subtitle) {
            if let station = model.nearby {
                PanelSection(title: "SAMPLE") {
                    sample(for: station)
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

            PanelSection(title: "ON THE MAP") {
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

            Text("Reports come from VATSIM's METAR service, the same source the tracker has always used. Each station issues one an hour.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(theme.textDim)
                .padding(.horizontal, 2)
        }
    }

    private var subtitle: String {
        guard let station = model.nearby else { return "No field in range" }
        return "Nearest report · \(station.airport.icao)"
    }

    /// The live report, written the way the current settings write it.
    private func sample(for station: WeatherModel.Station) -> some View {
        HStack(spacing: 12) {
            Image(systemName: station.metar?.symbol(isDaylight: station.isDaylight)
                  ?? (station.isDaylight ? "sun.max.fill" : "moon.stars.fill"))
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
                     ?? station.airport.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .flightInfoLine(minimumScale: 0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(station.metar?.temperatureLabel(in: preferences.temperatureUnit) ?? "—")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
                .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}
