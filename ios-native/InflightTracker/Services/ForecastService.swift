import CoreLocation
import Foundation

/// Everything a field's weather is, beyond the report it filed.
///
/// ## Why this is not WeatherKit any more
///
/// It was, and the arrangement never worked. WeatherKit needs its capability on
/// the App ID as well as the entitlement in the bundle, and without it the
/// framework refuses every request *locally* — the call never leaves the device.
/// From the outside that is indistinguishable from a service that is down, and
/// from inside the app it was a set of sections that quietly did not appear. The
/// giveaway was Apple's own dashboard: zero calls, for a feature that was
/// supposedly being used on every airport panel anybody opened.
///
/// So the forecast comes from Open-Meteo instead, which this app was already
/// talking to for the winds aloft — see `WindsAloftStore`. No key, no
/// entitlement, no capability to forget to tick on a portal, nothing to fail at
/// runtime in a way that looks like an empty panel. The one request per field
/// this used to cost is the one request per field it still costs.
///
/// The METAR beside it stays where it is and stays first: it is the observation
/// the field itself filed, in the units an aircraft is flown in. What this adds
/// is the half a METAR cannot — what the weather is about to do, what it is
/// doing at the four fields in five that file nothing at all, and whether
/// anyone has issued a warning about it.
///
/// ## What is not in the answer, and where it comes from instead
///
/// A model gives you numbers, not a rendered product, so two things WeatherKit
/// handed over finished are worked out here:
///
/// - **The condition and its symbol** come from the WMO present-weather code,
///   through `WeatherCode`. That is the international table, so a field's own
///   filed report and the model's answer for the field next to it now draw the
///   same weather the same way.
/// - **The sun, the twilight and the moon** come from `SkyAlmanac`, which is
///   arithmetic rather than a request. None of it was ever weather; it was in
///   the daily record only because that is where WeatherKit happened to put it.
///   Worked out on the device it also answers over an ocean with no signal.
///
/// Open-Meteo asks for attribution — it is CC-BY — and `ForecastSourceRow` is
/// that. One line and a link, rather than the two-part trademark-and-legal
/// arrangement the old provider required on every card.
final class ForecastService: ObservableObject {

    static let shared = ForecastService()

    // MARK: - What a place's weather is

    /// One hour of the forecast, in the units an aircraft is flown in.
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
        /// Nil where the model behind the answer carries no visibility field,
        /// which several of them do not.
        let visibilityMetres: Double?
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

        /// Worked out for this exact position rather than fetched. See
        /// `SkyAlmanac`.
        let sunrise: Date?
        let sunset: Date?
        /// When there is enough light to see the horizon, and when there stops
        /// being. The times a night rating is written around.
        let civilDawn: Date?
        let civilDusk: Date?

        let moonPhase: SkyAlmanac.MoonPhase
        let moonrise: Date?
        let moonset: Date?

        var id: Date { date }
    }

    /// The next couple of hours, a quarter of an hour at a time.
    ///
    /// An hour minute by minute is what the old provider modelled, over a
    /// handful of countries and nowhere else — so most of the world got no
    /// section at all. Open-Meteo's fifteen-minute series covers everywhere: at
    /// high resolution where a rapid-refresh model is running, interpolated from
    /// the hourly elsewhere. Two hours of it is a longer look ahead than the
    /// hour that replaced, which is the right trade for a strip that answers
    /// "do I need to hurry".
    struct NearTerm {

        struct Step: Identifiable {
            let date: Date
            /// Millimetres falling in this quarter hour.
            let amountMM: Double
            var id: Date { date }
        }

        let steps: [Step]
        /// What kind of precipitation, where there is any.
        let kind: String?
        /// One line: what changes in the next two hours, and when.
        let summary: String

        /// A tenth of a millimetre in a quarter hour is where a forecast stops
        /// being a rounding artefact and starts being drizzle.
        static let threshold: Double = 0.1

        /// Whether anything is worth drawing a graph for.
        var hasPrecipitation: Bool { steps.contains { $0.amountMM >= Self.threshold } }

        /// The wettest quarter hour in the window, which is what the bars are
        /// drawn against — a fixed scale would flatten drizzle to nothing and
        /// clip a squall.
        var peakMM: Double { steps.map(\.amountMM).max() ?? 0 }
    }

    /// How serious a warning is, in the four bands every issuing agency uses.
    enum AlertSeverity: String {
        case extreme
        case severe
        case moderate
        case minor
    }

    struct Alert: Identifiable {
        let summary: String
        let severity: AlertSeverity
        /// Who issued it.
        let source: String
        /// The area it covers, where the issuing agency named one.
        let region: String?
        var id: String { summary }
    }

    /// Which way the pressure is going, read off the last three hours the way a
    /// report's own tendency group is.
    enum PressureTrend {
        case rising
        case falling
        case steady
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
        let visibilityMetres: Double?
        let windSpeedKnots: Double
        let windDirectionDegrees: Double
        let windGustKnots: Double?
        let isDaylight: Bool

        // What it is about to do.
        let nearTerm: NearTerm?
        let hours: [Hour]
        let days: [Day]
        let alerts: [Alert]

        /// The field's own zone, so the strip and the outlook are labelled in
        /// the hours somebody standing on that ground would call them.
        let timeZone: TimeZone

        let fetched: Date

        /// Today, for the sun and moon rows.
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
        /// report for one field and a model's answer for the next, and a line
        /// that changes shape depending on where the number came from is a line
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
        case unavailable
    }

    @Published private(set) var states: [String: State] = [:]

    /// Why the last request failed, if it did.
    ///
    /// A failure on screen is a section that quietly does not appear, which is
    /// the right behaviour and unreadable from outside — "the service is down"
    /// and "this build has no forecast at all" look identical. So the reason is
    /// kept, and Weather settings shows it. Cleared by the first request that
    /// succeeds, so it never outlives the problem it describes.
    @Published private(set) var lastFailure: String?

    /// Where the data comes from, for the credit row. Open-Meteo's licence is
    /// CC-BY: a named source and a link, which is all of it.
    static let sourceName = "Open-Meteo"
    static let sourceURL = URL(string: "https://open-meteo.com/")!

    /// Hourly forecasts do not change faster than this, and a panel reopened
    /// twice in a minute should not spend two calls.
    private static let lifetime: TimeInterval = 15 * 60

    /// How far ahead the strip reads. A day, so the scroll covers a night stop
    /// and tomorrow morning's departure rather than stopping at teatime.
    private static let hourCount = 24

    /// How far ahead the outlook reads.
    private static let dayCount = 10

    private var inFlight: Set<String> = []

    private init() {}

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
    /// The METAR stays first everywhere this is used. This is for the large
    /// majority of the world's airfields that file nothing at all, where the
    /// alternative on screen was an em dash.
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

    /// The wind the model has for a place, in the shape `RunwayWind` wants.
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
        switch state(for: key) {
        case .loading: return
        case .ready(let snapshot) where Date().timeIntervalSince(snapshot.fetched) < Self.lifetime: return
        default: break
        }
        guard !inFlight.contains(key) else { return }

        inFlight.insert(key)
        states[key] = .loading

        Task { [weak self] in
            let (snapshot, failure) = await Self.fetch(coordinate)

            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.inFlight.remove(key)
                self.states[key] = snapshot.map(State.ready) ?? .unavailable
                self.lastFailure = snapshot == nil ? failure : nil
            }
        }
    }

    /// The weather, and — when there is none — why not.
    private static func fetch(
        _ coordinate: CLLocationCoordinate2D
    ) async -> (Snapshot?, String?) {
        guard let url = url(for: coordinate) else {
            return (nil, "The forecast request could not be built for this position.")
        }

        do {
            // The warnings are a different agency on a different continent, so
            // they are their own request — and a failed one is a missing card
            // rather than a missing forecast. Started first so the two are in
            // the air together.
            async let warnings = alerts(near: coordinate)

            let (data, response) = try await URLSession.shared.data(from: url)

            if let status = (response as? HTTPURLResponse)?.statusCode,
               !(200..<300).contains(status) {
                return (nil, "The forecast service returned \(status).")
            }

            guard let snapshot = parse(data, at: coordinate, alerts: await warnings) else {
                return (nil, "The forecast service answered with nothing this panel could read.")
            }

            return (snapshot, nil)
        } catch {
            return (nil, "The forecast could not be fetched: \((error as NSError).localizedDescription)")
        }
    }

    /// One call, everything in it.
    ///
    /// Open-Meteo answers for as many variables as the URL names, so the
    /// current conditions, the fifteen-minute series, twenty-four hours of
    /// forecast and ten days of outlook are one request between them — which is
    /// what makes all four affordable rather than one of them.
    private static func url(for coordinate: CLLocationCoordinate2D) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")

        let current = [
            "temperature_2m", "relative_humidity_2m", "apparent_temperature",
            "is_day", "weather_code", "cloud_cover", "pressure_msl",
            "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m"
        ]

        let hourly = [
            "temperature_2m", "relative_humidity_2m", "dew_point_2m",
            "precipitation_probability", "precipitation", "snowfall",
            "weather_code", "cloud_cover", "visibility", "pressure_msl",
            "wind_speed_10m", "wind_direction_10m", "wind_gusts_10m",
            "uv_index", "is_day"
        ]

        let daily = [
            "weather_code", "temperature_2m_max", "temperature_2m_min",
            "precipitation_probability_max", "precipitation_sum",
            "wind_speed_10m_max", "wind_gusts_10m_max",
            "wind_direction_10m_dominant", "uv_index_max"
        ]

        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
            URLQueryItem(name: "current", value: current.joined(separator: ",")),
            URLQueryItem(name: "hourly", value: hourly.joined(separator: ",")),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "daily", value: daily.joined(separator: ",")),
            // Knots, because every other wind in this app is in knots and
            // `WindUnit.convert(fromKnots:)` is what writes them.
            URLQueryItem(name: "wind_speed_unit", value: "kn"),
            // Integers rather than local ISO strings, so picking the hour
            // nearest now is arithmetic instead of date parsing.
            URLQueryItem(name: "timeformat", value: "unixtime"),
            // The field's own zone. It decides where the daily buckets fall —
            // "Today" should mean the day it is where the aeroplane is — and it
            // comes back as an offset the panel labels its hours with.
            URLQueryItem(name: "timezone", value: "auto"),
            // Enough of the past for a three-hour pressure tendency, which is
            // the interval a report's own tendency group is read over.
            URLQueryItem(name: "past_hours", value: "6"),
            URLQueryItem(name: "forecast_days", value: "\(dayCount)")
        ]

        return components?.url
    }

    // MARK: - Reading the answer

    private static func parse(
        _ data: Data,
        at coordinate: CLLocationCoordinate2D,
        alerts: [Alert]
    ) -> Snapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let hourly = root["hourly"] as? [String: Any],
              let times = hourly["time"] as? [Double], !times.isEmpty
        else { return nil }

        let offset = (root["utc_offset_seconds"] as? NSNumber)?.intValue ?? 0
        let timeZone = TimeZone(secondsFromGMT: offset) ?? .current

        let now = Date()
        let stamp = now.timeIntervalSince1970

        func number(_ container: [String: Any], _ name: String) -> Double? {
            guard let value = (container[name] as? NSNumber)?.doubleValue,
                  value.isFinite else { return nil }
            return value
        }

        /// One hourly series, as a value at an index — nil where the model
        /// behind the answer carries no such field, which is what a null in the
        /// array means.
        func series(_ name: String, at index: Int) -> Double? {
            guard let values = hourly[name] as? [Any], index >= 0, index < values.count,
                  let value = (values[index] as? NSNumber)?.doubleValue,
                  value.isFinite else { return nil }
            return value
        }

        // The hour the strip and the readings are anchored on. `past_hours`
        // puts several behind it, so this is a search rather than the first.
        guard let anchor = times.indices.min(by: {
            abs(times[$0] - stamp) < abs(times[$1] - stamp)
        }) else { return nil }

        let temperature = number(current, "temperature_2m") ?? series("temperature_2m", at: anchor) ?? 0
        let humidity = (number(current, "relative_humidity_2m") ?? 0) / 100
        let isDaylight = (number(current, "is_day") ?? 1) >= 0.5
        let code = Int(number(current, "weather_code") ?? 0)

        // Dew point is worked from the temperature and the humidity rather than
        // asked for: the current block does not carry it on every model, and
        // Magnus is exact enough that two ways of getting the same number would
        // only be a way to disagree with itself.
        let dewPoint = series("dew_point_2m", at: anchor)
            ?? dewPointC(temperatureC: temperature, humidity: humidity)

        let hours = (anchor..<times.count)
            .prefix(hourCount)
            .map { index -> Hour in
                let hourCode = Int(series("weather_code", at: index) ?? 0)
                let hourIsDay = (series("is_day", at: index) ?? 1) >= 0.5
                let hourTemperature = series("temperature_2m", at: index) ?? 0
                let hourHumidity = (series("relative_humidity_2m", at: index) ?? 0) / 100

                return Hour(
                    date: Date(timeIntervalSince1970: times[index]),
                    temperatureC: hourTemperature,
                    dewPointC: series("dew_point_2m", at: index)
                        ?? dewPointC(temperatureC: hourTemperature, humidity: hourHumidity),
                    symbolName: WeatherCode.symbol(hourCode, isDaylight: hourIsDay),
                    conditionLabel: WeatherCode.label(hourCode),
                    precipitationChance: (series("precipitation_probability", at: index) ?? 0) / 100,
                    precipitationAmountMM: series("precipitation", at: index) ?? 0,
                    // The service publishes snowfall in centimetres while every
                    // other depth in the answer is millimetres. Converted here
                    // rather than carried in its own unit, so nothing
                    // downstream has to remember that one field is different.
                    snowfallAmountMM: (series("snowfall", at: index) ?? 0) * 10,
                    windSpeedKnots: series("wind_speed_10m", at: index) ?? 0,
                    windGustKnots: series("wind_gusts_10m", at: index),
                    windDirectionDegrees: series("wind_direction_10m", at: index) ?? 0,
                    visibilityMetres: series("visibility", at: index),
                    cloudCover: (series("cloud_cover", at: index) ?? 0) / 100,
                    pressureMillibars: series("pressure_msl", at: index) ?? 0,
                    uvIndex: Int((series("uv_index", at: index) ?? 0).rounded()),
                    isDaylight: hourIsDay
                )
            }

        let pressure = number(current, "pressure_msl") ?? series("pressure_msl", at: anchor) ?? 0

        return Snapshot(
            conditionLabel: WeatherCode.label(code),
            symbolName: WeatherCode.symbol(code, isDaylight: isDaylight),
            temperatureC: temperature,
            apparentTemperatureC: number(current, "apparent_temperature") ?? temperature,
            dewPointC: dewPoint,
            humidity: humidity,
            pressureMillibars: pressure,
            pressureTrend: trend(pressure, threeHoursAgo: series("pressure_msl", at: anchor - 3)),
            uvIndex: Int((series("uv_index", at: anchor) ?? 0).rounded()),
            cloudCover: (number(current, "cloud_cover") ?? 0) / 100,
            visibilityMetres: series("visibility", at: anchor),
            windSpeedKnots: number(current, "wind_speed_10m") ?? 0,
            windDirectionDegrees: number(current, "wind_direction_10m") ?? 0,
            windGustKnots: number(current, "wind_gusts_10m"),
            isDaylight: isDaylight,
            nearTerm: nearTerm(root["minutely_15"] as? [String: Any], code: code, now: now),
            hours: Array(hours),
            days: days(root["daily"] as? [String: Any], at: coordinate, in: timeZone, now: now),
            alerts: alerts,
            timeZone: timeZone,
            fetched: Date()
        )
    }

    /// Magnus-Tetens, which is the formula a met office would use and is good to
    /// a tenth of a degree over every temperature an aerodrome sees.
    private static func dewPointC(temperatureC: Double, humidity: Double) -> Double {
        let relative = max(0.01, min(1, humidity))
        let a = 17.625
        let b = 243.04

        let gamma = log(relative) + a * temperatureC / (b + temperatureC)
        return b * gamma / (a - gamma)
    }

    /// Rising, falling, or neither.
    ///
    /// A millibar over three hours is the threshold a report's own tendency
    /// group is built on, and anything under it is the model's noise rather
    /// than the weather's.
    private static func trend(_ now: Double, threeHoursAgo before: Double?) -> PressureTrend {
        guard let before = before, before > 0, now > 0 else { return .steady }

        let change = now - before
        if change >= 1 { return .rising }
        if change <= -1 { return .falling }
        return .steady
    }

    // MARK: - The next two hours

    private static func nearTerm(
        _ minutely: [String: Any]?,
        code: Int,
        now: Date
    ) -> NearTerm? {
        guard let minutely = minutely,
              let times = minutely["time"] as? [Double],
              let amounts = minutely["precipitation"] as? [Any]
        else { return nil }

        let stamp = now.timeIntervalSince1970
        // Two hours, in quarters. The step before now is kept so the first bar
        // is the quarter hour being lived through rather than the next one.
        let window = stamp..<(stamp + 2 * 3600)

        let steps = zip(times, amounts).compactMap { time, amount -> NearTerm.Step? in
            guard window.contains(time) || (time <= stamp && time > stamp - 900) else { return nil }
            let value = (amount as? NSNumber)?.doubleValue ?? 0
            return NearTerm.Step(
                date: Date(timeIntervalSince1970: time),
                amountMM: value.isFinite ? max(0, value) : 0
            )
        }

        guard steps.count >= 4 else { return nil }

        let threshold = NearTerm.threshold
        let kind = WeatherCode.precipitation(code)
        let word = kind ?? "Rain"
        let isWetNow = steps.first.map { $0.amountMM >= threshold } ?? false

        let summary: String
        if isWetNow {
            if let dry = steps.first(where: { $0.amountMM < threshold }) {
                summary = "\(word) easing \(relative(dry.date))."
            } else {
                summary = "\(word) for the next two hours."
            }
        } else if let wet = steps.first(where: { $0.amountMM >= threshold }) {
            summary = "\(word) starting \(relative(wet.date))."
        } else {
            summary = "Nothing falling in the next two hours."
        }

        return NearTerm(steps: steps, kind: kind, summary: summary)
    }

    /// "in about 20 minutes", "shortly", "now" — the tail of the sentence above.
    ///
    /// Rounded to the quarter the series is written in, because a bar chart of
    /// fifteen-minute buckets that claims a start time to the minute is claiming
    /// a precision it does not have.
    private static func relative(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
        if minutes <= 5 { return "now" }
        if minutes <= 15 { return "shortly" }
        return "in about \(Int((Double(minutes) / 15).rounded()) * 15) minutes"
    }

    // MARK: - The next ten days

    private static func days(
        _ daily: [String: Any]?,
        at coordinate: CLLocationCoordinate2D,
        in timeZone: TimeZone,
        now: Date
    ) -> [Day] {
        guard let daily = daily, let times = daily["time"] as? [Double] else { return [] }

        func series(_ name: String, at index: Int) -> Double? {
            guard let values = daily[name] as? [Any], index < values.count,
                  let value = (values[index] as? NSNumber)?.doubleValue,
                  value.isFinite else { return nil }
            return value
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)

        return times.indices.compactMap { index -> Day? in
            let date = Date(timeIntervalSince1970: times[index])
            // A day already over is not an outlook. The request asks for none,
            // but a bucket boundary crossed between the answer and the reading
            // is exactly the sort of thing that puts yesterday under "Today".
            guard date >= today.addingTimeInterval(-3600) else { return nil }

            let code = Int(series("weather_code", at: index) ?? 0)
            let sun = SkyAlmanac.sun(at: coordinate, on: date, in: timeZone)
            let moon = SkyAlmanac.moon(at: coordinate, on: date, in: timeZone)

            return Day(
                date: date,
                // Daytime symbols throughout: a row of the outlook is a whole
                // day, and a day is not night.
                symbolName: WeatherCode.symbol(code, isDaylight: true),
                conditionLabel: WeatherCode.label(code),
                highC: series("temperature_2m_max", at: index) ?? 0,
                lowC: series("temperature_2m_min", at: index) ?? 0,
                precipitationChance: (series("precipitation_probability_max", at: index) ?? 0) / 100,
                precipitationAmountMM: series("precipitation_sum", at: index) ?? 0,
                windSpeedKnots: series("wind_speed_10m_max", at: index) ?? 0,
                windGustKnots: series("wind_gusts_10m_max", at: index),
                windDirectionDegrees: series("wind_direction_10m_dominant", at: index) ?? 0,
                uvIndex: Int((series("uv_index_max", at: index) ?? 0).rounded()),
                sunrise: sun.sunrise,
                sunset: sun.sunset,
                civilDawn: sun.civilDawn,
                civilDusk: sun.civilDusk,
                moonPhase: moon.phase,
                moonrise: moon.moonrise,
                moonset: moon.moonset
            )
        }
    }

    // MARK: - Warnings

    /// Severe-weather warnings for a point, from whoever issues them there.
    ///
    /// Which today is the United States and nowhere else. The National Weather
    /// Service publishes its active alerts openly — no key, no account, no
    /// quota — and no other agency covering a large area does anything
    /// comparable for free. A warning card that appears over Kansas and not over
    /// Bavaria is a smaller thing to explain than one that never appears at all,
    /// and where a second agency opens up it is this one function that changes.
    ///
    /// Every failure here is an empty list. A warnings service that is down must
    /// not take the forecast down with it.
    private static func alerts(near coordinate: CLLocationCoordinate2D) async -> [Alert] {
        guard isCoveredByNWS(coordinate) else { return [] }

        let point = String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
        var components = URLComponents(string: "https://api.weather.gov/alerts/active")
        components?.queryItems = [URLQueryItem(name: "point", value: point)]

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        // The service asks callers to identify themselves and refuses the ones
        // that do not. Their documented shape: something that names the app.
        request.setValue("Inflight/1.1 (flight tracker)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/geo+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 8

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]]
        else { return [] }

        return features.compactMap { feature -> Alert? in
            guard let properties = feature["properties"] as? [String: Any] else { return nil }

            // The headline is the sentence with the times in it — "Tornado
            // Warning issued January 3 at 4:12PM CST until..." — and the event
            // is the bare name. The headline where there is one, because "until
            // when" is most of what a warning is.
            guard let summary = (properties["headline"] as? String)
                    ?? (properties["event"] as? String), !summary.isEmpty
            else { return nil }

            return Alert(
                summary: summary,
                severity: severity(properties["severity"] as? String),
                source: properties["senderName"] as? String ?? "National Weather Service",
                region: properties["areaDesc"] as? String
            )
        }
    }

    private static func severity(_ name: String?) -> AlertSeverity {
        switch name?.lowercased() {
        case "extreme": return .extreme
        case "severe": return .severe
        case "moderate": return .moderate
        default: return .minor
        }
    }

    /// Roughly where the National Weather Service issues. Two boxes rather than
    /// a polygon: the point of asking is to not spend a request over the Atlantic,
    /// and a request that comes back empty costs the same as one never sent.
    private static func isCoveredByNWS(_ coordinate: CLLocationCoordinate2D) -> Bool {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude

        // The continental states, Alaska, and the Caribbean territories.
        let americas = (14.0...72.0).contains(latitude) && (-172.0...(-60.0)).contains(longitude)
        // Hawaii and the Pacific territories, which sit the other side of the
        // date line from the rest of it.
        let pacific = (13.0...29.0).contains(latitude) && (-179.0...(-154.0)).contains(longitude)

        return americas || pacific
    }
}
