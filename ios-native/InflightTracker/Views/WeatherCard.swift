import SwiftUI

// MARK: - Air quality

/// The US Air Quality Index, the way it is read: six bands, each with the name
/// and colour the EPA gives it.
enum AirQuality {

    /// Where each band starts, and the top of the scale.
    private static let breakpoints: [Double] = [0, 50, 100, 150, 200, 300, 500]

    /// One colour per band, softened a touch from the EPA's own so they sit on
    /// glass rather than shouting from it.
    static let colours: [Color] = [
        Color(red: 0.30, green: 0.85, blue: 0.39),
        Color(red: 1.00, green: 0.84, blue: 0.04),
        Color(red: 1.00, green: 0.58, blue: 0.00),
        Color(red: 1.00, green: 0.23, blue: 0.19),
        Color(red: 0.69, green: 0.32, blue: 0.87),
        Color(red: 0.55, green: 0.07, blue: 0.20)
    ]

    private static let labels = [
        "Good", "Moderate", "Unhealthy for Sensitive Groups",
        "Unhealthy", "Very Unhealthy", "Hazardous"
    ]

    private static func band(_ index: Int) -> Int {
        let value = Double(index)
        return (1..<breakpoints.count - 1).first { value <= breakpoints[$0] }.map { $0 - 1 }
            ?? colours.count - 1
    }

    static func label(_ index: Int) -> String { labels[band(index)] }

    static func colour(_ index: Int) -> Color { colours[band(index)] }

    /// Where on the bar the reading falls, 0...1. Every band is given the same
    /// width, the way the index is drawn everywhere — on a linear scale "Good"
    /// would be a tenth of the bar and the half that matters would be a sliver.
    static func position(_ index: Int) -> Double {
        let value = min(max(Double(index), 0), breakpoints.last ?? 500)
        let bands = Double(breakpoints.count - 1)
        for band in 0..<(breakpoints.count - 1) {
            let lower = breakpoints[band]
            let upper = breakpoints[band + 1]
            if value <= upper {
                return (Double(band) + (value - lower) / (upper - lower)) / bands
            }
        }
        return 1
    }
}

// MARK: - The card

/// A place's weather as one card: the sky and the temperature, the handful of
/// readings worth a glance, and the next few hours.
///
/// Set the way the rest of the app writes weather rather than the way the
/// system's Weather app does — the small tracked labels and rounded figures of
/// the flight window's forecast section, readings in a row of columns rather
/// than "H: L:" prose, and the air quality as a figure with its colour beside
/// it rather than a gradient slider. It is the same information the forecast
/// section carries, at a glance's length, so opening the full section reads as
/// more of this card rather than as a different app.
///
/// Used for the map's own pill, the flight window's chip and the flight
/// window's own weather row, so all three open into the same thing. What goes
/// in the headline is the caller's — a field's filed report wins over the
/// model where there is one — and the forecast fills in the rest.
struct WeatherCard<Footer: View>: View {

    let theme: FlightInfoTheme
    let title: String
    /// Small, beside the title — an ICAO, where the place is a field.
    let badge: String?
    let symbolName: String
    let condition: String
    let temperatureC: Double?
    /// Whether the headline is the model's rather than an observation, which
    /// is marked beside the title the same way the chip marks it.
    let isModelled: Bool
    let snapshot: ForecastService.Snapshot?
    let isLoading: Bool
    /// Drawn on a panel's surface rather than floating over the map as glass:
    /// the flight window's own row, where the card sits among the window's
    /// other sections and a pane of glass would be a hole in it.
    var isInset: Bool = false
    let footer: Footer

    @ObservedObject private var preferences = WeatherPreferences.shared

    init(
        theme: FlightInfoTheme,
        title: String,
        badge: String? = nil,
        symbolName: String,
        condition: String,
        temperatureC: Double?,
        isModelled: Bool,
        snapshot: ForecastService.Snapshot?,
        isLoading: Bool = false,
        isInset: Bool = false,
        @ViewBuilder footer: () -> Footer
    ) {
        self.theme = theme
        self.title = title
        self.badge = badge
        self.symbolName = symbolName
        self.condition = condition
        self.temperatureC = temperatureC
        self.isModelled = isModelled
        self.snapshot = snapshot
        self.isLoading = isLoading
        self.isInset = isInset
        self.footer = footer()
    }

    /// Hours after now, beside it. Six fit a phone's width at these sizes
    /// without the strip having to scroll.
    private static var hourCount: Int { 5 }

    var body: some View {
        let card = VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 13)
                .padding(.bottom, 12)

            if let snapshot {
                PanelDivider()
                readings(snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            }

            if let snapshot, !upcoming(in: snapshot).isEmpty {
                PanelDivider()
                hourly(snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
            } else if isLoading {
                PanelDivider()
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }

            footer

            if snapshot != nil {
                PanelDivider()
                ForecastSourceRow()
            }
        }
        .frame(maxWidth: 440)

        if isInset {
            card.flightInfoSurface(theme, radius: theme.radiusMedium)
        } else {
            card
                .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: theme.radiusLarge, style: .continuous))
                .environment(\.colorScheme, theme.colorScheme)
        }
    }

    // MARK: - Headline

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Text(L("WEATHER"))
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(theme.textDim)

                if let badge {
                    Text(L(badge))
                        .font(.system(size: 9.5, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background { Capsule().stroke(theme.stroke, lineWidth: 1) }
                }

                if isModelled {
                    ForecastSourceMark(colour: theme.textDim)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .center, spacing: 12) {
                Image(systemName: symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background {
                        RoundedRectangle(cornerRadius: theme.radiusSmall, style: .continuous)
                            .fill(theme.accent.opacity(0.14))
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(L(title))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(L(condition))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(L(degrees(temperatureC)))
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize()
                    .motionWords(degrees(temperatureC))
            }
        }
    }

    // MARK: - Readings

    /// The few numbers worth a glance, in the forecast section's own columns:
    /// the day's range, the wind, the chance of rain and the air.
    private func readings(_ snapshot: ForecastService.Snapshot) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let today = snapshot.today {
                reading("High / low", "\(degrees(today.highC)) \(degrees(today.lowC))")
            } else {
                reading("Feels like", degrees(snapshot.apparentTemperatureC))
            }

            reading("Wind", wind(snapshot), detail: preferences.windUnit.label)

            if let chance = snapshot.today?.precipitationChance {
                reading("Rain", "\(Int((chance * 100).rounded()))%")
            } else {
                reading("Humidity", "\(Int((snapshot.humidity * 100).rounded()))%")
            }

            if let index = snapshot.airQualityIndex {
                reading("Air", "\(index)", dot: AirQuality.colour(index))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(L("Air quality index \(index), \(AirQuality.label(index))"))
            } else {
                reading("Feels like", degrees(snapshot.apparentTemperatureC))
            }
        }
    }

    private func reading(
        _ title: String,
        _ value: String,
        detail: String? = nil,
        dot: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L(title.uppercased()))
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                }

                Text(L(value))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)

                if let detail {
                    Text(L(detail))
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
            }
            .flightInfoLine(minimumScale: 0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The next few hours

    private struct Slot: Identifiable {
        let id: Int
        let label: String
        let symbolName: String
        let temperatureC: Double?
        let precipitationChance: Double
        let isNow: Bool
    }

    private func upcoming(in snapshot: ForecastService.Snapshot) -> [ForecastService.Hour] {
        let now = Date()
        return Array(snapshot.hours.filter { $0.date > now }.prefix(Self.hourCount))
    }

    private func slots(_ snapshot: ForecastService.Snapshot) -> [Slot] {
        // In the place's own hours, the way somebody standing there would read
        // them, and on the forecast section's 24-hour clock.
        let formatter = DateFormatter()
        formatter.timeZone = snapshot.timeZone
        formatter.dateFormat = "HH"

        let now = Slot(
            id: 0,
            label: "NOW",
            symbolName: symbolName,
            temperatureC: temperatureC ?? snapshot.temperatureC,
            precipitationChance: 0,
            isNow: true
        )
        let later = upcoming(in: snapshot).enumerated().map { offset, hour in
            Slot(
                id: offset + 1,
                label: formatter.string(from: hour.date),
                symbolName: hour.symbolName,
                temperatureC: hour.temperatureC,
                precipitationChance: hour.precipitationChance,
                isNow: false
            )
        }
        return [now] + later
    }

    private func hourly(_ snapshot: ForecastService.Snapshot) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(slots(snapshot)) { slot in
                VStack(spacing: 5) {
                    Text(L(slot.label))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(slot.isNow ? theme.accent : theme.textDim)
                        .lineLimit(1)

                    Image(systemName: slot.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 16))
                        .foregroundStyle(theme.textPrimary)
                        .frame(height: 20)

                    Text(L(degrees(slot.temperatureC)))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)

                    // Only where there is something to say, the same as the
                    // forecast section's strip.
                    Text(L(slot.precipitationChance >= 0.1
                         ? "\(Int((slot.precipitationChance * 100).rounded()))%"
                         : " "))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Units

    private func degrees(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return "\(Int(preferences.temperatureUnit.convert(fromCelsius: celsius).rounded()))°"
    }

    /// `240° 12`, or with the gust where there is one: `240° 12G20`. The unit
    /// is the reading's detail, beside it.
    private func wind(_ snapshot: ForecastService.Snapshot) -> String {
        let unit = preferences.windUnit
        let mean = Int(unit.convert(fromKnots: snapshot.windSpeedKnots).rounded())
        let direction = String(format: "%03.0f°", snapshot.windDirectionDegrees)
        guard let gust = snapshot.windGustKnots else { return "\(direction) \(mean)" }
        let gusting = Int(unit.convert(fromKnots: gust).rounded())
        return gusting > mean + 2 ? "\(direction) \(mean)G\(gusting)" : "\(direction) \(mean)"
    }
}

extension WeatherCard where Footer == EmptyView {
    init(
        theme: FlightInfoTheme,
        title: String,
        badge: String? = nil,
        symbolName: String,
        condition: String,
        temperatureC: Double?,
        isModelled: Bool,
        snapshot: ForecastService.Snapshot?,
        isLoading: Bool = false,
        isInset: Bool = false
    ) {
        self.init(
            theme: theme,
            title: title,
            badge: badge,
            symbolName: symbolName,
            condition: condition,
            temperatureC: temperatureC,
            isModelled: isModelled,
            snapshot: snapshot,
            isLoading: isLoading,
            isInset: isInset,
            footer: { EmptyView() }
        )
    }
}

// MARK: - The readout

/// The weather as one line of a readout: the sky as a glyph, the temperature,
/// and after a hairline the one thing worth reading next — a field's code and
/// its wind, or the air quality where there is no field.
///
/// The app's own shape rather than the system's weather widget: one short
/// capsule of glass, the figures set in the rounded and monospaced faces the
/// rest of the app's readouts use, small enough to sit in a corner of the map
/// without being the thing on it. The map's pill and the flight window's chip
/// are both this, so the two read as one control in two places.
struct WeatherReadout: View {

    let theme: FlightInfoTheme
    let symbol: String
    let temperature: String
    /// Set small and heavy, the way the app writes a code: `EGLL`, `AQI`.
    var tag: String? = nil
    /// Beside the tag: the air quality's colour.
    var dot: Color? = nil
    /// After the tag, in the monospaced face: `240°/12kt`, `31`.
    var detail: String? = nil
    /// The figures are the model's rather than an observation — marked the
    /// way every other place in the app marks it.
    var isModelled = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 16)

            Text(L(temperature))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .monospacedDigit()
                .fixedSize()
                .motionWords(temperature)

            if tag != nil || detail != nil {
                Rectangle()
                    .fill(theme.stroke)
                    .frame(width: 1, height: 13)

                HStack(spacing: 4) {
                    if let tag {
                        Text(L(tag))
                            .font(.system(size: 9.5, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize()
                            .motionWords(tag)
                    }

                    if isModelled {
                        ForecastSourceMark(colour: theme.textDim)
                    }

                    if let dot {
                        Circle()
                            .fill(dot)
                            .frame(width: 6, height: 6)
                    }

                    if let detail {
                        Text(L(detail))
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textDim)
                            .lineLimit(1)
                            .fixedSize()
                            .motionWords(detail)
                    }
                }
            }
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.leading, 9)
        .padding(.trailing, 11)
        .padding(.vertical, 6)
        // One control, so it gets the system's press response.
        .flightInfoChrome(theme, in: Capsule(), interactive: true)
        .contentShape(Capsule())
        .environment(\.colorScheme, theme.colorScheme)
    }
}

// MARK: - The map's pill

/// The weather where the map is looking, top left, while nothing is open and
/// the map is close enough to be looking at a place. Tapped, it opens into
/// `AreaWeatherCard`.
struct AreaWeatherPill: View {

    let reading: AreaWeather.Reading
    let theme: FlightInfoTheme
    @Binding var isExpanded: Bool

    @ObservedObject private var preferences = WeatherPreferences.shared

    private var temperature: String {
        "\(Int(preferences.temperatureUnit.convert(fromCelsius: reading.snapshot.temperatureC).rounded()))°"
    }

    var body: some View {
        Button {
            withAnimation(Motion.control) { isExpanded.toggle() }
        } label: {
            if let index = reading.snapshot.airQualityIndex {
                WeatherReadout(
                    theme: theme,
                    symbol: reading.snapshot.symbolName,
                    temperature: temperature,
                    tag: "AQI",
                    dot: AirQuality.colour(index),
                    detail: "\(index)"
                )
            } else {
                WeatherReadout(theme: theme, symbol: reading.snapshot.symbolName, temperature: temperature)
            }
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, theme.colorScheme)
        .accessibilityLabel(L("Weather here, \(temperature), \(reading.snapshot.conditionLabel)"))
        .accessibilityHint(L(isExpanded ? "Hides the forecast" : "Shows the forecast"))
    }
}

/// What the map's pill opens into.
struct AreaWeatherCard: View {

    let reading: AreaWeather.Reading
    let theme: FlightInfoTheme

    var body: some View {
        WeatherCard(
            theme: theme,
            title: reading.name ?? "This area",
            symbolName: reading.snapshot.symbolName,
            condition: reading.snapshot.conditionLabel,
            temperatureC: reading.snapshot.temperatureC,
            isModelled: false,
            snapshot: reading.snapshot
        )
    }
}

// MARK: - Where they stand on the map

/// The map's pill, in the top row's left corner: watched here rather than from
/// `ContentView`, so a settle that changes the weather redraws a pill rather
/// than the whole screen.
///
/// Fades in once the map is close enough to be looking at a place, and out
/// again when it is pulled back past that — and takes its card with it.
struct AreaWeatherPillSlot: View {

    @ObservedObject var area: AreaWeather
    let theme: FlightInfoTheme
    /// The chip is switched on, the flat map is showing, and nothing is open.
    let isEnabled: Bool
    @Binding var isExpanded: Bool

    private var isShowing: Bool { isEnabled && area.isZoomedIn && area.reading != nil }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if isShowing, let reading = area.reading {
                AreaWeatherPill(reading: reading, theme: theme, isExpanded: $isExpanded)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: isShowing)
        .onChange(of: isShowing) { _, showing in
            if !showing, isExpanded {
                withAnimation(Motion.control) { isExpanded = false }
            }
        }
    }
}

/// The map pill's card, under the top row so it has the width to open into.
/// A tap on it puts it away again, the same as a tap on the map.
struct AreaWeatherCardSlot: View {

    @ObservedObject var area: AreaWeather
    let theme: FlightInfoTheme
    let isEnabled: Bool
    @Binding var isExpanded: Bool

    var body: some View {
        if isEnabled, isExpanded, area.isZoomedIn, let reading = area.reading {
            AreaWeatherCard(reading: reading, theme: theme)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(Motion.control) { isExpanded = false }
                }
                .onAppear { area.refreshIfStale() }
        }
    }
}
