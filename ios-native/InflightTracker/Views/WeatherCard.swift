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

/// The index on its coloured scale, with a marker where the reading is.
struct AirQualityBar: View {

    let index: Int

    private static let track: CGFloat = 6
    private static let marker: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.width - Self.marker, 0)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(colors: AirQuality.colours, startPoint: .leading, endPoint: .trailing))
                    .frame(height: Self.track)

                Circle()
                    .fill(.white)
                    .overlay { Circle().stroke(.black.opacity(0.35), lineWidth: 1.5) }
                    .frame(width: Self.marker, height: Self.marker)
                    .offset(x: travel * AirQuality.position(index))
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: Self.marker)
        .accessibilityHidden(true)
    }
}

// MARK: - The card

/// A place's weather as one card, the way Maps opens its weather pill: the
/// conditions and the temperature, today's high and low, the air quality, and
/// the next few hours.
///
/// Used for the map's own pill and for the flight window's chip, so the two
/// open into the same thing. What goes in the headline is the caller's — a
/// field's filed report wins over the model where there is one — and the
/// forecast fills in the rest.
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
        self.footer = footer()
    }

    private static var hourCount: Int { 4 }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if let index = snapshot?.airQualityIndex {
                divider
                airQuality(index)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
            }

            if let snapshot, !upcoming(in: snapshot).isEmpty {
                divider
                hourly(snapshot)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 12)
            } else if isLoading {
                divider
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }

            footer

            if snapshot != nil {
                divider
                ForecastSourceRow()
            }
        }
        .frame(maxWidth: 440)
        .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .environment(\.colorScheme, theme.colorScheme)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.stroke)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }

    // MARK: - Headline

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 34))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 46)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(L(title))
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    if let badge {
                        Text(L(badge))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(theme.textSecondary)
                    }

                    if isModelled {
                        ForecastSourceMark(colour: theme.textDim)
                    }
                }

                Text(L(condition))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)

                if let chance = snapshot?.today?.precipitationChance {
                    Text(Lf("Chance of Rain: %@", "\(Int((chance * 100).rounded()))%"))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 0) {
                Text(L(degrees(temperatureC)))
                    .font(.system(size: 50, weight: .thin))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize()
                    .motionWords(degrees(temperatureC))

                if let today = snapshot?.today {
                    Text(Lf("H:%@ L:%@", degrees(today.highC), degrees(today.lowC)))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: - Air quality

    private func airQuality(_ index: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(L("AQI"))
                    .font(.system(size: 15, weight: .bold))
                Text(L("\(index)"))
                    .font(.system(size: 15))
            }
            .foregroundStyle(theme.textPrimary)
            .fixedSize()

            AirQualityBar(index: index)

            // The short names as they are; the long ones wrap rather than
            // squeezing the bar to nothing.
            if AirQuality.label(index).count <= 10 {
                Text(L(AirQuality.label(index)))
                    .font(.system(size: 15))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize()
            } else {
                Text(L(AirQuality.label(index)))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 110, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Air quality index \(index), \(AirQuality.label(index))"))
    }

    // MARK: - The next few hours

    private struct Slot: Identifiable {
        let id: Int
        let label: String
        let symbolName: String
        let temperatureC: Double?
        let isNow: Bool
    }

    private func upcoming(in snapshot: ForecastService.Snapshot) -> [ForecastService.Hour] {
        let now = Date()
        return Array(snapshot.hours.filter { $0.date > now }.prefix(Self.hourCount))
    }

    private func slots(_ snapshot: ForecastService.Snapshot) -> [Slot] {
        // In the place's own hours, the way somebody standing there would read
        // them — the same as the forecast section does.
        let formatter = DateFormatter()
        formatter.timeZone = snapshot.timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")

        let now = Slot(
            id: 0,
            label: "Now",
            symbolName: symbolName,
            temperatureC: temperatureC ?? snapshot.temperatureC,
            isNow: true
        )
        let later = upcoming(in: snapshot).enumerated().map { offset, hour in
            Slot(
                id: offset + 1,
                label: formatter.string(from: hour.date),
                symbolName: hour.symbolName,
                temperatureC: hour.temperatureC,
                isNow: false
            )
        }
        return [now] + later
    }

    private func hourly(_ snapshot: ForecastService.Snapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(slots(snapshot)) { slot in
                VStack(spacing: 10) {
                    Text(L(slot.label))
                        .font(.system(size: 15, weight: slot.isNow ? .semibold : .regular))
                        .foregroundStyle(slot.isNow ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)

                    Image(systemName: slot.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 20))
                        .foregroundStyle(theme.textPrimary)
                        .frame(height: 24)

                    Text(L(degrees(slot.temperatureC)))
                        .font(.system(size: 16, weight: slot.isNow ? .semibold : .regular))
                        .foregroundStyle(theme.textPrimary)
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
        isLoading: Bool = false
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
            footer: { EmptyView() }
        )
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
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Image(systemName: reading.snapshot.symbolName)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 17))
                    Text(L(temperature))
                        .font(.system(size: 21, weight: .medium))
                        .fixedSize()
                        .motionWords(temperature)
                }
                .foregroundStyle(theme.textPrimary)

                if let index = reading.snapshot.airQualityIndex {
                    HStack(spacing: 5) {
                        Text(L("AQI \(index)"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        Circle()
                            .fill(AirQuality.colour(index))
                            .frame(width: 7, height: 7)
                    }
                } else {
                    Text(L(reading.snapshot.conditionLabel))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .flightInfoChrome(theme, in: RoundedRectangle(cornerRadius: 16, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
