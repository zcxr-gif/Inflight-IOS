import CoreLocation
import Foundation
import WeatherKit

/// Everything Apple will say about a place.
///
/// The METAR beside this stays where it is and stays first: it is the
/// observation the field itself filed, in the units an aircraft is flown in,
/// and nothing here replaces it. What this adds is the half a METAR cannot —
/// what the weather is about to do, what it is doing at the four fields in
/// five that file nothing at all, and whether anyone has issued a warning
/// about it.
///
/// ## One call, everything in it
///
/// `weather(for:)` without a query list returns the whole `Weather` value:
/// current conditions, the next hour minute by minute, the hourly and daily
/// forecasts, and the alerts. It is **one** WeatherKit call — the same one the
/// old three-dataset request cost — and it is why this app can afford to show
/// runway wind components, a ten-day outlook and civil twilight without asking
/// Apple three more times.
///
/// The minute forecast is the exception that is allowed to be missing: Apple
/// only models it over a few countries, and outside them `minuteForecast` is
/// nil. Nothing else here is optional.
///
/// WeatherKit needs the capability on the App ID as well as the entitlement in
/// the bundle. Without it every request fails at runtime, which is why a
/// failure here is a section that quietly does not appear rather than an error
/// laid over a working panel.
///
/// Apple's terms require the attribution mark and a link to their legal page
/// wherever this data is shown — `WeatherAttributionRow` is that, and it is
/// not optional.
final class AppleWeatherService: ObservableObject {

    static let shared = AppleWeatherService()

    // MARK: - What a place's weather is

    /// One hour of the forecast, in the units an aircraft is flown in.
    ///
    /// Knots and metres rather than the km/h an earlier version carried,
    /// because every other wind in this app is in knots and
    /// `WindUnit.convert(fromKnots:)` is what writes them.
    struct Hour: Identifiable {
        let date: Date
        let temperatureC: Double
        let dewPointC: Double
        let symbolName: String
        let conditionLabel: String
        /// 0...1.
        let precipitationChance: Double
        let precipitationAmountMM: Double
        let snowfallAmountMM: Double
        let windSpeedKnots: Double
        let windGustKnots: Double?
        let windDirectionDegrees: Double
        let visibilityMetres: Double
        /// 0...1.
        let cloudCover: Double
        let pressureMillibars: Double
        let uvIndex: Int
        let isDaylight: Bool
        var id: Date { date }
    }

    /// One day of the outlook, and the sky's own timetable for it.
    struct Day: Identifiable {
        let date: Date
        let symbolName: String
        let conditionLabel: String
        let highC: Double
        let lowC: Double
        /// 0...1.
        let precipitationChance: Double
        let precipitationAmountMM: Double
        let windSpeedKnots: Double
        let windGustKnots: Double?
        let windDirectionDegrees: Double
        let uvIndex: Int

        /// Apple's own sun events for this exact position — which is the point
        /// of taking them from here rather than from `SolarPosition`. That one
        /// answers "is it light where this aeroplane is" for the whole map at
        /// once and has to be cheap; this is a field, and a field deserves the
        /// real times.
        let sunrise: Date?
        let sunset: Date?
        /// When there is enough light to see the horizon, and when there stops
        /// being. The times a night rating is written around.
        let civilDawn: Date?
        let civilDusk: Date?

        let moonPhase: MoonPhase
        let moonrise: Date?
        let moonset: Date?

        var id: Date { date }
    }

    /// The next hour, minute by minute — where Apple models it at all.
    ///
    /// Built from `precipitationChance` rather than `precipitationIntensity`.
    /// The intensity is documented in millimetres per hour but carried in a
    /// `Measurement<UnitSpeed>` with no matching named unit, so reading its
    /// `value` means trusting an unstated convention. A chance is a chance in
    /// any locale, and "will it rain on the walk to the aeroplane" is the
    /// question this answers.
    struct NextHour {
        struct Minute: Identifiable {
            let date: Date
            /// 0...1.
            let chance: Double
            var id: Date { date }
        }

        let minutes: [Minute]
        /// What kind of precipitation, where there is any.
        let kind: String?
        /// One line: what changes in the next hour, and when.
        let summary: String
        /// Whether anything is worth drawing a graph for.
        var hasPrecipitation: Bool { minutes.contains { $0.chance >= 0.1 } }
    }

    struct Alert: Identifiable {
        let summary: String
        let severity: WeatherSeverity
        /// Who issued it — "National Weather Service", "Met Office".
        let source: String
        /// The area it covers, where the issuing agency named one.
        let region: String?
        let detailsURL: URL?
        var id: String { summary }
    }

    struct Snapshot {

        // What it is doing now.
        let conditionLabel: String
        let symbolName: String
        let temperatureC: Double
        let apparentTemperatureC: Double
        let dewPointC: Double
        /// 0...1.
        let humidity: Double
        let pressureMillibars: Double
        let pressureTrend: PressureTrend
        let uvIndex: Int
        /// 0...1.
        let cloudCover: Double
        let visibilityMetres: Double
        let windSpeedKnots: Double
        let windDirectionDegrees: Double
        let windGustKnots: Double?
        let isDaylight: Bool

        // What it is about to do.
        let nextHour: NextHour?
        let hours: [Hour]
        let days: [Day]
        let alerts: [Alert]

        let fetched: Date

        /// Today, for the sun and moon rows. The first day of the outlook is
        /// the current one — Apple starts the daily forecast at midnight local.
        var today: Day? { days.first }

        /// The spread between air and dew point, which is what says how close
        /// the air is to making cloud or fog. Under about 3 °C is the number a
        /// pilot reads as "expect it".
        var spreadC: Double { temperatureC - dewPointC }
    }

    /// The two or three things a place that would show a METAR needs when
    /// there is no METAR to show.
    ///
    /// Deliberately close to the shape of a report: a symbol, a temperature, a
    /// sentence and a wind. The chip and the panels draw either without caring
    /// which they were handed, beyond saying whose it is.
    struct Conditions: Equatable {
        let temperatureC: Double
        let symbolName: String
        let label: String
        let windSpeedKnots: Double
        let windDirectionDegrees: Double
        let windGustKnots: Double?

        /// `240° @ 12G20 kt`, written exactly the way `Metar.windLabel` writes
        /// one.
        ///
        /// The same format on purpose: the weather chip can be showing a filed
        /// report for one field and Apple's model for the next, and a line that
        /// changes shape depending on where the number came from is a line
        /// nobody can read at a glance.
        func windLabel(in unit: WindUnit) -> String {
            func convert(_ knots: Double) -> Int { Int(unit.convert(fromKnots: knots).rounded()) }

            let mean = convert(windSpeedKnots)
            guard mean >= 1 else { return "Calm" }

            let heading = String(format: "%03.0f°", windDirectionDegrees)

            guard let gust = windGustKnots, convert(gust) > mean else {
                return "\(heading) @ \(mean) \(unit.label)"
            }
            return "\(heading) @ \(mean)G\(convert(gust)) \(unit.label)"
        }
    }

    enum State {
        case idle
        case loading
        case ready(Snapshot)
        /// Includes a build with no WeatherKit capability, which is the most
        /// likely reason to land here.
        case unavailable
    }

    @Published private(set) var states: [String: State] = [:]

    /// Apple's mark and legal link.
    ///
    /// Nil only until it arrives. Nothing on screen waits on it —
    /// `WeatherAttributionRow` draws the  Weather wordmark and a link to
    /// Apple's own legal page from `Self.legalPageURL` in the meantime —
    /// because the mark is a *requirement* wherever this data is shown, and a
    /// requirement that vanishes when a CDN is slow is not one that has been met.
    @Published private(set) var attribution: WeatherAttribution?

    /// Apple's legal attribution page, as a constant.
    ///
    /// The framework hands back the same page on `WeatherAttribution.legalPageURL`,
    /// and that one is preferred wherever it has arrived. This is what the row
    /// links to before it does — and if it never does. A mark fetch that failed
    /// is not a reason to show WeatherKit data with no way through to Apple's
    /// terms.
    static let legalPageURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    /// Hourly forecasts do not change faster than this, and a panel reopened
    /// twice in a minute should not spend two calls.
    private static let lifetime: TimeInterval = 15 * 60

    /// How far ahead the strip reads. A day, so the scroll covers a night stop
    /// and tomorrow morning's departure rather than stopping at teatime.
    private static let hourCount = 24

    /// How far ahead the outlook reads. Apple serves ten days.
    private static let dayCount = 10

    private var inFlight: Set<String> = []

    /// The mark fetch, while one is running. One at a time, and not repeated
    /// once it has landed.
    private var attributionFetch: Task<Void, Never>?

    private init() {}

    // MARK: - The mark

    /// Fetches Apple's attribution mark, once.
    ///
    /// Its own call rather than something `load` does on the side, because the
    /// two are needed at different moments: a screen showing a cached forecast
    /// asks for no weather at all, and used to therefore never ask for the mark
    /// either. Safe to call from any `task` that is about to put WeatherKit
    /// data on screen — already fetched or already fetching both do nothing,
    /// and a fetch that failed is retried by the next caller rather than
    /// leaving the mark permanently missing.
    func loadAttribution() {
        guard attribution == nil, attributionFetch == nil else { return }

        attributionFetch = Task { [weak self] in
            let mark = try? await WeatherKit.WeatherService.shared.attribution

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.attributionFetch = nil
                if let mark = mark { self.attribution = mark }
            }
        }
    }

    // MARK: - Reading what has been fetched

    func state(for key: String) -> State { states[key] ?? .idle }

    func snapshot(for key: String) -> Snapshot? {
        if case .ready(let snapshot) = state(for: key),
           Date().timeIntervalSince(snapshot.fetched) < Self.lifetime {
            return snapshot
        }
        return nil
    }

    /// What it is doing at a place right now, when something else was supposed
    /// to say and could not.
    ///
    /// The METAR stays first everywhere this is used: it is the observation the
    /// field itself filed, in the units an aircraft is flown in. This is for the
    /// large majority of the world's airfields that file nothing at all, where
    /// the alternative on screen was an em dash.
    func conditions(for key: String) -> Conditions? {
        guard let snapshot = snapshot(for: key) else { return nil }
        return Conditions(
            temperatureC: snapshot.temperatureC,
            symbolName: snapshot.symbolName,
            label: snapshot.conditionLabel,
            windSpeedKnots: snapshot.windSpeedKnots,
            windDirectionDegrees: snapshot.windDirectionDegrees,
            windGustKnots: snapshot.windGustKnots
        )
    }

    /// The wind Apple has for a place, in the shape `RunwayWind` wants.
    ///
    /// Nil below two knots: a runway "favoured" by a wind that is not blowing
    /// is an arrow pointing at nothing, and calm is the honest answer.
    func wind(for key: String) -> RunwayWind.Wind? {
        guard let snapshot = snapshot(for: key), snapshot.windSpeedKnots >= 2 else { return nil }
        return RunwayWind.Wind(
            fromDegrees: snapshot.windDirectionDegrees,
            speedKnots: snapshot.windSpeedKnots,
            gustKnots: snapshot.windGustKnots
        )
    }

    // MARK: - Fetching

    /// Loads a point's weather. Safe to call on every appearance: fresh, in
    /// flight, or already refused all do nothing.
    func load(key: String, coordinate: CLLocationCoordinate2D) {
        // Before the early returns, not after: the mark is owed the moment
        // anything intends to show this data, including the appearance that
        // finds a fresh snapshot already cached and fetches no weather at all.
        loadAttribution()

        switch state(for: key) {
        case .loading, .unavailable: return
        case .ready(let snapshot) where Date().timeIntervalSince(snapshot.fetched) < Self.lifetime: return
        default: break
        }
        guard !inFlight.contains(key) else { return }

        inFlight.insert(key)
        states[key] = .loading

        Task { [weak self] in
            let snapshot = await Self.fetch(coordinate)

            // Weak again on the way in rather than reaching for the outer
            // closure's `self`, which is a mutable capture crossing into
            // concurrent code — a warning today and an error under Swift 6.
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.inFlight.remove(key)
                self.states[key] = snapshot.map(State.ready) ?? .unavailable
            }
        }
    }

    private static func fetch(_ coordinate: CLLocationCoordinate2D) async -> Snapshot? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            // The whole thing, in one call. See the note on the type.
            let weather = try await WeatherKit.WeatherService.shared.weather(for: location)

            let current = weather.currentWeather
            let now = Date()

            let hours = weather.hourlyForecast
                .filter { $0.date >= now.addingTimeInterval(-1800) }
                .prefix(hourCount)
                .map(Self.hour)

            let days = weather.dailyForecast
                .prefix(dayCount)
                .map { day in Self.day(day, at: coordinate) }

            return Snapshot(
                conditionLabel: current.condition.description,
                symbolName: current.symbolName,
                temperatureC: current.temperature.converted(to: .celsius).value,
                apparentTemperatureC: current.apparentTemperature.converted(to: .celsius).value,
                dewPointC: current.dewPoint.converted(to: .celsius).value,
                humidity: current.humidity,
                pressureMillibars: current.pressure.converted(to: .millibars).value,
                pressureTrend: current.pressureTrend,
                uvIndex: current.uvIndex.value,
                cloudCover: current.cloudCover,
                visibilityMetres: current.visibility.converted(to: .meters).value,
                windSpeedKnots: current.wind.speed.converted(to: .knots).value,
                windDirectionDegrees: current.wind.direction.converted(to: .degrees).value,
                windGustKnots: current.wind.gust?.converted(to: .knots).value,
                isDaylight: current.isDaylight,
                nextHour: weather.minuteForecast.flatMap(Self.nextHour),
                hours: hours,
                days: days,
                alerts: (weather.weatherAlerts ?? []).map {
                    Alert(
                        summary: $0.summary,
                        severity: $0.severity,
                        source: $0.source,
                        region: $0.region,
                        detailsURL: $0.detailsURL
                    )
                },
                fetched: Date()
            )
        } catch {
            return nil
        }
    }

    private static func hour(_ hour: HourWeather) -> Hour {
        Hour(
            date: hour.date,
            temperatureC: hour.temperature.converted(to: .celsius).value,
            dewPointC: hour.dewPoint.converted(to: .celsius).value,
            symbolName: hour.symbolName,
            conditionLabel: hour.condition.description,
            precipitationChance: hour.precipitationChance,
            precipitationAmountMM: hour.precipitationAmount.converted(to: .millimeters).value,
            snowfallAmountMM: hour.snowfallAmount.converted(to: .millimeters).value,
            windSpeedKnots: hour.wind.speed.converted(to: .knots).value,
            windGustKnots: hour.wind.gust?.converted(to: .knots).value,
            windDirectionDegrees: hour.wind.direction.converted(to: .degrees).value,
            visibilityMetres: hour.visibility.converted(to: .meters).value,
            cloudCover: hour.cloudCover,
            pressureMillibars: hour.pressure.converted(to: .millibars).value,
            uvIndex: hour.uvIndex.value,
            isDaylight: hour.isDaylight
        )
    }

    private static func day(_ day: DayWeather, at coordinate: CLLocationCoordinate2D) -> Day {
        Day(
            date: day.date,
            symbolName: day.symbolName,
            conditionLabel: day.condition.description,
            highC: day.highTemperature.converted(to: .celsius).value,
            lowC: day.lowTemperature.converted(to: .celsius).value,
            precipitationChance: day.precipitationChance,
            precipitationAmountMM: day.precipitationAmount.converted(to: .millimeters).value,
            windSpeedKnots: day.wind.speed.converted(to: .knots).value,
            windGustKnots: day.wind.gust?.converted(to: .knots).value,
            windDirectionDegrees: day.wind.direction.converted(to: .degrees).value,
            uvIndex: day.uvIndex.value,
            sunrise: day.sun.sunrise,
            sunset: day.sun.sunset,
            civilDawn: day.sun.civilDawn,
            civilDusk: day.sun.civilDusk,
            moonPhase: day.moon.phase,
            moonrise: day.moon.moonrise,
            moonset: day.moon.moonset
        )
    }

    /// Reads the minute forecast into something a bar chart and one sentence
    /// can be drawn from.
    ///
    /// The sentence is the part worth having. A graph of the next hour is only
    /// useful if you look at it; "rain starting in about 12 minutes" is useful
    /// to somebody walking past the screen.
    private static func nextHour(_ forecast: Forecast<MinuteWeather>) -> NextHour? {
        let minutes = forecast.map { NextHour.Minute(date: $0.date, chance: $0.precipitationChance) }
        guard !minutes.isEmpty else { return nil }

        // Spelled out rather than `!= .none`, which in a generic context can
        // just as well mean `Optional.none`.
        let kind = forecast.first(where: { $0.precipitation != WeatherKit.Precipitation.none })
            .map { Self.label(for: $0.precipitation) }

        // A tenth is the threshold everywhere else in this app's weather, and
        // it is roughly where a forecast stops being a rounding artefact.
        let threshold = 0.1
        let isWetNow = minutes.first.map { $0.chance >= threshold } ?? false
        let word = kind ?? "Rain"

        let summary: String
        if isWetNow {
            if let dry = minutes.first(where: { $0.chance < threshold }) {
                summary = "\(word) easing \(Self.relative(dry.date))."
            } else {
                summary = "\(word) for the next hour."
            }
        } else if let wet = minutes.first(where: { $0.chance >= threshold }) {
            summary = "\(word) starting \(Self.relative(wet.date))."
        } else {
            summary = "Nothing falling in the next hour."
        }

        return NextHour(minutes: minutes, kind: kind, summary: summary)
    }

    /// "in 12 minutes", "in a minute", "now" — the tail of the sentence above.
    private static func relative(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
        if minutes <= 0 { return "now" }
        if minutes == 1 { return "in a minute" }
        return "in \(minutes) minutes"
    }

    private static func label(for precipitation: WeatherKit.Precipitation) -> String {
        switch precipitation {
        case .none: return "Rain"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .sleet: return "Sleet"
        case .hail: return "Hail"
        case .mixed: return "Sleet"
        @unknown default: return "Rain"
        }
    }
}
