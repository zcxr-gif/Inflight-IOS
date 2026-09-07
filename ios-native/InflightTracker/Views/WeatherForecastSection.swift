import CoreLocation
import SwiftUI
import WeatherKit

/// Apple's half of a field's weather.
///
/// Sits under the METAR rather than replacing it. A METAR is the observation
/// the field filed, in the units an aircraft is flown in; this is everything a
/// METAR has no way to carry — the next hour minute by minute, twenty-four
/// hours of forecast, ten days of outlook, the sky's own timetable, the
/// warnings somebody has issued, and the one piece of arithmetic that turns
/// all of it into a decision: what the wind is doing to each runway.
///
/// One WeatherKit call behind the lot of it. See `AppleWeatherService`.
struct WeatherForecastSection: View {

    let airport: Airport

    /// The field's own report, where it filed one. It wins for the wind — it is
    /// the observation, and it is what the ATIS is reading from — and Apple
    /// answers for the four fields in five that file nothing.
    var metar: Metar? = nil

    @ObservedObject private var weather = AppleWeatherService.shared
    @ObservedObject private var layouts = AirportLayoutStore.shared
    @ObservedObject private var appearance = FlightInfoAppearance.shared
    @ObservedObject private var preferences = WeatherPreferences.shared

    private var theme: FlightInfoTheme { appearance.theme }

    private var key: String { airport.icao }

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
                alerts(snapshot)
                nextHour(snapshot)
                runways
                forecast(snapshot)

                // The long tail, and the one part of this a reader can turn
                // off — Weather settings, "Ten days and the sky". Everything in
                // both sections came down with the forecast above, so hiding
                // them saves scrolling rather than a request.
                if preferences.showsOutlook {
                    outlook(snapshot)
                    sky(snapshot)
                }

                // Everything above came from here. One card, at the foot of
                // the block it attributes — Apple's mark and the link to their
                // legal page are required wherever their data is shown, and
                // this is the end of where it is shown.
                VStack(spacing: 0) {
                    WeatherAttributionRow(attribution: weather.attribution)
                }
                .flightInfoSurface(theme, radius: theme.radiusMedium)
            }
        }
        .task(id: key) {
            weather.load(key: key, coordinate: airport.coordinate)
            // The same pavement the ground chart is drawn from, cached for a
            // month. Asked for here because the wind components need the
            // runways, and this may be the first thing at this field to want
            // them.
            layouts.load(airport)
        }
    }

    // MARK: - Warnings

    @ViewBuilder
    private func alerts(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        if !snapshot.alerts.isEmpty {
            PanelSection(title: snapshot.alerts.count == 1 ? "WEATHER ALERT" : "WEATHER ALERTS") {
                ForEach(snapshot.alerts) { alert in
                    if alert.id != snapshot.alerts.first?.id { PanelDivider() }
                    alertRow(alert)
                }
            }
        }
    }

    private func alertRow(_ alert: AppleWeatherService.Alert) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Self.colour(for: alert.severity))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(alert.summary)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                // Who says so, and about where. An alert with no issuer beside
                // it is a sentence from nowhere, and the agency is most of what
                // tells you how seriously to take the wording.
                Text([alert.region, alert.source].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    // MARK: - The next hour

    /// Minute by minute, where Apple models it — which is a handful of
    /// countries rather than the world, so the section is simply absent
    /// elsewhere rather than empty.
    @ViewBuilder
    private func nextHour(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        if let next = snapshot.nextHour {
            PanelSection(title: "NEXT HOUR") {
                HStack(spacing: 10) {
                    Image(systemName: next.hasPrecipitation ? "cloud.rain.fill" : "checkmark.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(next.hasPrecipitation ? theme.accent : theme.textDim)
                        .frame(width: 18)

                    Text(next.summary)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                // Only where there is something to draw. Sixty flat bars is a
                // graph of nothing, and the line above has already said so.
                if next.hasPrecipitation {
                    PanelDivider()
                    minuteGraph(next)
                }
            }
        }
    }

    private func minuteGraph(_ next: AppleWeatherService.NextHour) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(next.minutes) { minute in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(theme.accent.opacity(0.25 + 0.75 * minute.chance))
                        // Never nothing: a bar of zero height reads as a gap in
                        // the data rather than as a dry minute.
                        .frame(height: max(2, 28 * minute.chance))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 28)

            HStack {
                Text("NOW")
                Spacer(minLength: 8)
                Text("IN 30 MIN")
                Spacer(minLength: 8)
                Text("IN 1 HR")
            }
            .font(.system(size: 8, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(theme.textDim)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Wind on the runways

    /// What the wind is doing to each end of each runway.
    ///
    /// The most useful thing on this panel, and the only part of it that is
    /// arithmetic rather than a reading. Present only where the field's
    /// pavement has been mapped and the wind is actually blowing; a runway
    /// "favoured" by two knots is not information.
    @ViewBuilder
    private var runways: some View {
        if let wind = runwayWind, let layout = layouts.layout(for: key) {
            let components = RunwayWind.components(for: layout, wind: wind)

            if !components.isEmpty {
                PanelSection(title: "WIND ON THE RUNWAYS") {
                    ForEach(Array(components.prefix(6).enumerated()), id: \.element.id) { index, runway in
                        if index > 0 { PanelDivider() }
                        runwayRow(runway, isFavoured: index == 0)
                    }

                    PanelDivider()

                    Text(runwayFootnote)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    /// The METAR's wind where the field filed one, Apple's otherwise.
    private var runwayWind: RunwayWind.Wind? {
        if let metar = metar, let filed = RunwayWind.Wind(metar: metar) { return filed }
        return weather.wind(for: key)
    }

    private var runwayFootnote: String {
        let source = (metar.flatMap { RunwayWind.Wind(metar: $0) } != nil)
            ? "the \(airport.icao) report"
            : "Apple Weather"
        return "Worked from \(source) against the runway centrelines as mapped. True bearings, not the painted numbers — and a wind calculation, not a recommendation."
    }

    private func runwayRow(_ runway: RunwayWind, isFavoured: Bool) -> some View {
        HStack(spacing: 12) {
            Text(runway.designator)
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(isFavoured ? theme.onAccent : theme.textPrimary)
                .frame(minWidth: 38)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isFavoured ? theme.accent : theme.elevatedFill)
                }
                .fixedSize()

            VStack(alignment: .leading, spacing: 3) {
                Text(runway.summary())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(runway.isTailwind ? Self.tailwindColour : theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(String(format: "%03.0f° true", runway.trueBearing))
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textDim)
            }

            Spacer(minLength: 6)

            // Where the wind is going, drawn against the runway it is going
            // across. An arrow is the one representation of a wind nobody has
            // to convert in their head.
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(theme.textSecondary)
                .rotationEffect(.degrees(windArrowRotation(for: runway)))
                .frame(width: 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// The arrow points the way the wind blows, *relative to this runway*.
    ///
    /// Read the row as if the runway ran up the screen away from you. A
    /// headwind then blows towards you and the arrow points down — which is
    /// the unrotated symbol, and why the offset is the raw difference with no
    /// half-turn in it. A tailwind points up, and a wind off the right points
    /// left. Turning the arrow rather than turning the runway keeps six rows
    /// readable at a glance without drawing six little compasses.
    private func windArrowRotation(for runway: RunwayWind) -> Double {
        guard let wind = runwayWind else { return 0 }
        return wind.fromDegrees - runway.trueBearing
    }

    private static let tailwindColour = Color(red: 1.0, green: 0.62, blue: 0.04)

    // MARK: - The next day

    private func forecast(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        PanelSection(title: "FORECAST") {
            hourStrip(snapshot)
            PanelDivider()
            readings(snapshot)
        }
    }

    private func hourStrip(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 15) {
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

                        // The wind, which is the column an aviator reads. The
                        // arrow flies with it; the number is the mean, and the
                        // one after the G is the gust where there is one.
                        Image(systemName: "location.north.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(theme.textSecondary)
                            .rotationEffect(.degrees(hour.windDirectionDegrees + 180))

                        Text(Self.wind(hour, in: preferences.windUnit))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    /// Everything else Apple knows about right now, in a grid.
    ///
    /// Four across and two down rather than a longer strip: these are readings
    /// to be scanned rather than compared, and eight of them in a row would be
    /// a horizontal scroll nobody would find.
    private func readings(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4),
            alignment: .leading,
            spacing: 13
        ) {
            reading("Feels like", Self.temperature(snapshot.apparentTemperatureC, in: preferences.temperatureUnit))
            reading("Dew point", Self.temperature(snapshot.dewPointC, in: preferences.temperatureUnit))
            reading(
                "Spread",
                Self.spread(snapshot.spreadC, in: preferences.temperatureUnit),
                detail: snapshot.spreadC <= 3 ? "close" : nil
            )
            reading("Humidity", "\(Int((snapshot.humidity * 100).rounded()))%")
            reading("Visibility", Self.visibility(snapshot.visibilityMetres))
            reading("Cloud", "\(Int((snapshot.cloudCover * 100).rounded()))%")
            reading(
                "Pressure",
                "\(Int(snapshot.pressureMillibars.rounded()))",
                detail: Self.trend(snapshot.pressureTrend)
            )
            reading("UV", "\(snapshot.uvIndex)", detail: Self.uvBand(snapshot.uvIndex))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private func reading(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.textPrimary)

                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(theme.textDim)
                }
            }
            .flightInfoLine(minimumScale: 0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - The next ten days

    private func outlook(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        PanelSection(title: "TEN DAYS") {
            ForEach(snapshot.days) { day in
                if day.id != snapshot.days.first?.id { PanelDivider() }
                dayRow(day, across: snapshot.days)
            }
        }
    }

    private func dayRow(_ day: AppleWeatherService.Day, across days: [AppleWeatherService.Day]) -> some View {
        // Tight on purpose: eight columns have to fit the narrowest panel this
        // app draws without any of them scaling down to unreadable.
        HStack(spacing: 9) {
            Text(day.id == days.first?.id ? "Today" : Self.dayLabel(day.date))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 42, alignment: .leading)

            Image(systemName: day.symbolName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .frame(width: 20)

            Text(day.precipitationChance >= 0.1
                 ? "\(Int((day.precipitationChance * 100).rounded()))%"
                 : " ")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(theme.accent)
                .frame(width: 28, alignment: .leading)

            Text(Self.dayWind(day, in: preferences.windUnit))
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textDim)
                .frame(width: 48, alignment: .leading)
                .flightInfoLine(minimumScale: 0.7)

            Spacer(minLength: 4)

            Text(Self.temperature(day.lowC, in: preferences.temperatureUnit))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(theme.textDim)

            // The band each day's range covers, against the whole ten days.
            // A column of numbers says which day is warmest; this says by how
            // much, without anybody reading a single figure.
            temperatureBar(day, across: days)

            Text(Self.temperature(day.highC, in: preferences.temperatureUnit))
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func temperatureBar(_ day: AppleWeatherService.Day, across days: [AppleWeatherService.Day]) -> some View {
        let coldest = days.map(\.lowC).min() ?? day.lowC
        let warmest = days.map(\.highC).max() ?? day.highC
        let span = max(1, warmest - coldest)

        let start = (day.lowC - coldest) / span
        let width = max(0.06, (day.highC - day.lowC) / span)

        return GeometryReader { geometry in
            Capsule()
                .fill(theme.accent.opacity(0.55))
                .frame(width: max(4, geometry.size.width * width))
                .offset(x: geometry.size.width * start)
                .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 46, height: 4)
        .background {
            Capsule().fill(theme.stroke)
        }
    }

    // MARK: - Sun and moon

    /// The sky's own timetable for the field.
    ///
    /// Civil twilight is here rather than only sunrise and sunset because it is
    /// the pair of times a night rating is written around — the light by which
    /// a horizon is still visible, which is not the same moment the sun
    /// crosses it.
    @ViewBuilder
    private func sky(_ snapshot: AppleWeatherService.Snapshot) -> some View {
        if let today = snapshot.today {
            PanelSection(title: "SUN AND MOON") {
                HStack(spacing: 0) {
                    skyReading("Sunrise", today.sunrise, symbol: "sunrise.fill")
                    skyReading("Sunset", today.sunset, symbol: "sunset.fill")
                    skyReading("Civil dawn", today.civilDawn, symbol: "sun.horizon.fill")
                    skyReading("Civil dusk", today.civilDusk, symbol: "sun.horizon.fill")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                PanelDivider()

                HStack(spacing: 11) {
                    Image(systemName: Self.moonSymbol(today.moonPhase, at: airport.coordinate))
                        .font(.system(size: 17))
                        .foregroundStyle(theme.textPrimary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.moonName(today.moonPhase))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)

                        Text(Self.moonTimes(today))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textDim)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)

                PanelDivider()

                Text("Times in your own time zone, not the field's.")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
    }

    private func skyReading(_ title: String, _ date: Date?, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)

            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(theme.textDim)
                .flightInfoLine(minimumScale: 0.8)

            Text(date.map(Self.clock) ?? "—")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Writing it down

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

    /// The gap between the air and the dew point, which is the number that
    /// says how close the air is to making cloud or fog. Under about three
    /// degrees is where a pilot starts expecting it.
    ///
    /// A *difference*, so it is scaled rather than converted: five degrees
    /// Celsius of spread is nine of Fahrenheit, not forty-one. Running it
    /// through `convert(fromCelsius:)` would add the freezing-point offset and
    /// turn every dry afternoon into a warning.
    private static func spread(_ celsius: Double, in unit: TemperatureUnit) -> String {
        let clamped = max(0, celsius)
        let scaled = unit == .fahrenheit ? clamped * 9 / 5 : clamped
        return "\(Int(scaled.rounded()))°"
    }

    /// `12G20` in the reader's own unit, or a bare mean where nothing is
    /// gusting. No unit letter: the column is four characters wide and the
    /// setting is the reader's own.
    private static func wind(_ hour: AppleWeatherService.Hour, in unit: WindUnit) -> String {
        let mean = Int(unit.convert(fromKnots: hour.windSpeedKnots).rounded())
        guard let gust = hour.windGustKnots else { return "\(mean)" }

        let gusting = Int(unit.convert(fromKnots: gust).rounded())
        return gusting > mean + 2 ? "\(mean)G\(gusting)" : "\(mean)"
    }

    private static func dayWind(_ day: AppleWeatherService.Day, in unit: WindUnit) -> String {
        let mean = Int(unit.convert(fromKnots: day.windSpeedKnots).rounded())
        let direction = String(format: "%03.0f", day.windDirectionDegrees)
        return "\(direction)°/\(mean)"
    }

    /// The same scale the METAR above writes its own visibility on, so the two
    /// rows on one panel do not contradict each other's units.
    private static func visibility(_ metres: Double) -> String {
        if metres >= 9_999 { return "10 km+" }
        if metres >= 1_000 { return String(format: "%.1f km", metres / 1000) }
        return "\(Int(metres.rounded())) m"
    }

    private static func trend(_ trend: PressureTrend) -> String? {
        switch trend {
        case .rising: return "rising"
        case .falling: return "falling"
        case .steady: return nil
        @unknown default: return nil
        }
    }

    /// The World Health Organization's bands, written out rather than taken
    /// from `UVIndex.ExposureCategory` so the wording matches the rest of this
    /// panel and cannot change under the app.
    private static func uvBand(_ index: Int) -> String? {
        switch index {
        case ..<3: return nil
        case 3..<6: return "moderate"
        case 6..<8: return "high"
        case 8..<11: return "v high"
        default: return "extreme"
        }
    }

    private static func moonName(_ phase: MoonPhase) -> String {
        switch phase {
        case .new: return "New moon"
        case .waxingCrescent: return "Waxing crescent"
        case .firstQuarter: return "First quarter"
        case .waxingGibbous: return "Waxing gibbous"
        case .full: return "Full moon"
        case .waningGibbous: return "Waning gibbous"
        case .lastQuarter: return "Last quarter"
        case .waningCrescent: return "Waning crescent"
        @unknown default: return "Moon"
        }
    }

    /// The moon's symbol, lit from the side it is actually lit from.
    ///
    /// A waxing crescent is lit on the right from Europe and on the left from
    /// New Zealand, and SF Symbols ships both — so a field's own latitude picks
    /// which. It is a detail almost nobody will notice and exactly the sort of
    /// thing that is wrong in every other app.
    private static func moonSymbol(_ phase: MoonPhase, at coordinate: CLLocationCoordinate2D) -> String {
        let inverted = coordinate.latitude < 0 ? ".inverse" : ""

        switch phase {
        case .new: return "moonphase.new.moon"
        case .waxingCrescent: return "moonphase.waxing.crescent\(inverted)"
        case .firstQuarter: return "moonphase.first.quarter\(inverted)"
        case .waxingGibbous: return "moonphase.waxing.gibbous\(inverted)"
        case .full: return "moonphase.full.moon"
        case .waningGibbous: return "moonphase.waning.gibbous\(inverted)"
        case .lastQuarter: return "moonphase.last.quarter\(inverted)"
        case .waningCrescent: return "moonphase.waning.crescent\(inverted)"
        @unknown default: return "moon"
        }
    }

    private static func moonTimes(_ day: AppleWeatherService.Day) -> String {
        let parts = [
            day.moonrise.map { "Up \(clock($0))" },
            day.moonset.map { "down \(clock($0))" }
        ].compactMap { $0 }

        return parts.isEmpty ? "Neither rising nor setting today." : parts.joined(separator: ", ")
    }

    private static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func hourLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
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
