import CoreLocation
import Foundation
import WeatherKit

/// Forecast and alerts, from Apple.
///
/// The METAR beside this stays where it is and stays first: it is the
/// observation the field itself filed, in the units an aircraft is flown in,
/// and nothing here replaces it. What this adds is the half a METAR cannot —
/// what the weather is about to do, and whether anyone has issued a warning
/// about it.
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

    struct Hour: Identifiable {
        let date: Date
        let temperatureC: Double
        let symbolName: String
        /// 0...1.
        let precipitationChance: Double
        let windSpeedKph: Double
        let windDirectionDegrees: Double
        var id: Date { date }
    }

    struct Alert: Identifiable {
        let summary: String
        let severity: WeatherSeverity
        let detailsURL: URL?
        var id: String { summary }
    }

    struct Snapshot {
        let conditionLabel: String
        let symbolName: String
        let temperatureC: Double
        let apparentTemperatureC: Double
        let humidity: Double
        let pressureMillibars: Double
        let uvIndex: Int
        let hours: [Hour]
        let alerts: [Alert]
        let fetched: Date
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

    /// Apple's mark and legal link, fetched once. Nil until it arrives, and the
    /// data is not shown without it.
    @Published private(set) var attribution: WeatherAttribution?

    /// Hourly forecasts do not change faster than this, and a panel reopened
    /// twice in a minute should not spend two calls.
    private static let lifetime: TimeInterval = 15 * 60

    /// How far ahead the strip reads.
    private static let hourCount = 10

    private var inFlight: Set<String> = []

    private init() {}

    func state(for key: String) -> State { states[key] ?? .idle }

    func snapshot(for key: String) -> Snapshot? {
        if case .ready(let snapshot) = state(for: key),
           Date().timeIntervalSince(snapshot.fetched) < Self.lifetime {
            return snapshot
        }
        return nil
    }

    /// Loads a point's weather. Safe to call on every appearance: fresh, in
    /// flight, or already refused all do nothing.
    func load(key: String, coordinate: CLLocationCoordinate2D) {
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
            let mark = try? await WeatherKit.WeatherService.shared.attribution

            await MainActor.run {
                guard let self = self else { return }
                self.inFlight.remove(key)
                if let mark = mark { self.attribution = mark }
                self.states[key] = snapshot.map(State.ready) ?? .unavailable
            }
        }
    }

    private static func fetch(_ coordinate: CLLocationCoordinate2D) async -> Snapshot? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)

        do {
            let (current, hourly, alerts) = try await WeatherKit.WeatherService.shared.weather(
                for: location,
                including: .current, .hourly, .alerts
            )

            let now = Date()
            let hours = hourly
                .filter { $0.date >= now.addingTimeInterval(-1800) }
                .prefix(hourCount)
                .map { hour in
                    Hour(
                        date: hour.date,
                        temperatureC: hour.temperature.converted(to: .celsius).value,
                        symbolName: hour.symbolName,
                        precipitationChance: hour.precipitationChance,
                        windSpeedKph: hour.wind.speed.converted(to: .kilometersPerHour).value,
                        windDirectionDegrees: hour.wind.direction.converted(to: .degrees).value
                    )
                }

            return Snapshot(
                conditionLabel: current.condition.description,
                symbolName: current.symbolName,
                temperatureC: current.temperature.converted(to: .celsius).value,
                apparentTemperatureC: current.apparentTemperature.converted(to: .celsius).value,
                humidity: current.humidity,
                pressureMillibars: current.pressure.converted(to: .millibars).value,
                uvIndex: current.uvIndex.value,
                hours: Array(hours),
                alerts: (alerts ?? []).map {
                    Alert(summary: $0.summary, severity: $0.severity, detailsURL: $0.detailsURL)
                },
                fetched: Date()
            )
        } catch {
            return nil
        }
    }
}
