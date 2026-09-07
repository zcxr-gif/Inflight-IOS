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

/// The  Weather wordmark, drawn in text.
///
/// What the attribution row falls back to, and what the collapsed weather chip
/// carries. U+F8FF is the Apple logo on every Apple platform, so this is the
/// trademark itself rather than a description of it — and unlike the combined
/// mark it needs no network, which is the whole reason it exists: the
/// requirement is on the screen showing the data, and a screen that shows the
/// data while an image is still downloading is a screen with no attribution on
/// it.
struct AppleWeatherWordmark: View {

    var size: CGFloat = 10
    var colour: Color

    var body: some View {
        Text(" Weather")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(colour)
            .fixedSize()
            .accessibilityLabel("Apple Weather")
    }
}

/// Apple's mark and the link to their legal page.
///
/// Required wherever WeatherKit data is shown — not a courtesy, a term of use.
/// Both halves are required, and both are therefore unconditional here:
///
/// - **The mark.** Apple's own combined image where it has arrived, because it
///   is the artwork they would rather see; the  Weather wordmark until then, and
///   for good if the fetch never lands. There is no state in which this row
///   draws neither.
/// - **The link.** `WeatherAttribution.legalPageURL` where the framework has
///   answered, and `AppleWeatherService.legalPageURL` — the same page, as a
///   constant — where it has not. It used to be dropped entirely on that path,
///   which meant a slow or failed mark fetch produced a compliant-looking row
///   with no way through to Apple's terms.
struct WeatherAttributionRow: View {

    let attribution: WeatherAttribution?

    @ObservedObject private var appearance = FlightInfoAppearance.shared

    private var theme: FlightInfoTheme { appearance.theme }

    /// Apple's own artwork, in the shade that reads against this theme.
    private var markURL: URL? {
        guard let attribution = attribution else { return nil }
        return theme.isLight ? attribution.combinedMarkLightURL : attribution.combinedMarkDarkURL
    }

    var body: some View {
        HStack(spacing: 8) {
            if let markURL = markURL {
                AsyncImage(url: markURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    // The wordmark, not a blank: the mark is owed for as long
                    // as the data is up, including while the image is on its way.
                    AppleWeatherWordmark(colour: theme.textDim)
                }
                .frame(height: 14)
            } else {
                AppleWeatherWordmark(colour: theme.textDim)
            }

            Spacer(minLength: 8)

            Link("Legal", destination: attribution?.legalPageURL ?? AppleWeatherService.legalPageURL)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .task { AppleWeatherService.shared.loadAttribution() }
    }
}
