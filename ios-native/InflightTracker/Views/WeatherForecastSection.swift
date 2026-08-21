import CoreLocation
import SwiftUI
import WeatherKit

/// Apple's half of a field's weather: what it is about to do, and whether
/// anyone has warned about it.
///
/// Sits under the METAR rather than replacing it. A METAR is the observation
/// the field filed, in the units an aircraft is flown in; this is the forecast
/// and the alerts, which a METAR has no way to carry.
struct WeatherForecastSection: View {

    let key: String
    let coordinate: CLLocationCoordinate2D

    @ObservedObject private var weather = AppleWeatherService.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var preferences = WeatherPreferences.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        Group {
            switch weather.state(for: key) {
            case .idle, .loading:
                EmptyView()

            case .unavailable:
                // Silent. A build without the WeatherKit capability would
                // otherwise carry an apology on every field it opens.
                EmptyView()

            case .ready(let snapshot):
                if !snapshot.alerts.isEmpty {
                    PanelSection(title: "WEATHER ALERTS") {
                        ForEach(snapshot.alerts) { alert in
                            if alert.id != snapshot.alerts.first?.id { PanelDivider() }
                            alertRow(alert)
                        }
                    }
                }

                PanelSection(title: "FORECAST") {
                    hourStrip(snapshot)
                    PanelDivider()
                    detail(snapshot)
                    PanelDivider()
                    WeatherAttributionRow(attribution: weather.attribution)
                }
            }
        }
        .task(id: key) {
            weather.load(key: key, coordinate: coordinate)
        }
    }

    private func hourStrip(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(snapshot.hours) { hour in
                    VStack(spacing: 5) {
                        Text(Self.hourLabel(hour.date))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(theme.textDim)

                        Image(systemName: hour.symbolName)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: 17))
                            .foregroundStyle(theme.textPrimary)
                            .frame(height: 20)

                        Text(Self.temperature(hour.temperatureC, in: preferences.temperatureUnit))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(theme.textPrimary)

                        // Only where there is something to say. A column of
                        // zeroes down a dry afternoon is noise.
                        Text(hour.precipitationChance >= 0.1
                             ? "\(Int((hour.precipitationChance * 100).rounded()))%"
                             : " ")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func detail(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        HStack(spacing: 0) {
            reading("Feels like", Self.temperature(snapshot.apparentTemperatureC, in: preferences.temperatureUnit))
            reading("Humidity", "\(Int((snapshot.humidity * 100).rounded()))%")
            reading("Pressure", "\(Int(snapshot.pressureMillibars.rounded())) hPa")
            reading("UV", "\(snapshot.uvIndex)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func reading(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alertRow(_ alert: AppleWeatherService.Alert) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.colour(for: alert.severity))

            Text(alert.summary)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            if let url = alert.detailsURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textDim)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private static func colour(for severity: WeatherSeverity) -> Color {
        switch severity {
        case .extreme, .severe: return Color(red: 1.0, green: 0.35, blue: 0.30)
        case .moderate: return Color(red: 1.0, green: 0.62, blue: 0.04)
        default: return Color(red: 0.36, green: 0.68, blue: 1.00)
        }
    }

    /// Written the way the METAR above it writes one, so two temperatures on
    /// the same panel do not disagree about their own units.
    private static func temperature(_ celsius: Double, in unit: TemperatureUnit) -> String {
        "\(Int(unit.convert(fromCelsius: celsius).rounded()))°"
    }

    private static func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

/// Apple's mark and the link to their legal page.
///
/// Required wherever WeatherKit data is shown — not a courtesy, a term of use.
/// Drawn from the URLs the framework itself hands back, so it stays whatever
/// Apple currently requires rather than a copy of it baked into the bundle.
struct WeatherAttributionRow: View {

    let attribution: WeatherAttribution?

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    var body: some View {
        HStack(spacing: 8) {
            if let attribution = attribution {
                AsyncImage(
                    url: theme.isLight
                        ? attribution.combinedMarkLightURL
                        : attribution.combinedMarkDarkURL
                ) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(height: 14)

                Spacer(minLength: 8)

                Link("Legal", destination: attribution.legalPageURL)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textDim)
            } else {
                Text("Weather data from Apple Weather")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                Spacer(minLength: 8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
