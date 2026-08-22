import Combine
import Foundation

/// The index of weather-tile frames RainViewer currently has.
///
/// One small JSON document lists every frame available — two hours of past
/// radar in ten-minute steps, whatever nowcast is still being served, and the
/// infrared satellite — as a host plus a path per frame. The tiles themselves
/// are then plain PNGs under those paths, which is what `RainViewerTileOverlay`
/// builds URLs against.
///
/// ## What is and is not still served
///
/// RainViewer has been withdrawing the free tier in stages, and the schedule
/// published in their own documentation (kept in `old/www/rainviewer.txt`) has
/// the satellite maps and the radar nowcast ending on 1 January 2026, with the
/// free zoom ceiling dropping to 7 at the same time. Rather than encode a
/// guess about which of that has actually happened, this reads what the index
/// says: a section the document does not carry is a layer this reports as
/// unavailable, and the panel then says so instead of offering a switch that
/// draws nothing.
final class RainViewerService: ObservableObject {

    static let shared = RainViewerService()

    /// One frame: when it is for, and where its tiles live.
    struct Frame: Equatable, Identifiable {
        let time: Date
        let path: String

        var id: String { path }
    }

    enum State: Equatable {
        case idle
        case loading
        case ready
        /// Asked, and got nothing usable. Carries what to tell the user.
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle

    /// Where the tiles are served from, e.g. `https://tilecache.rainviewer.com`.
    @Published private(set) var host: String?

    /// Past radar, oldest first, with any nowcast frames appended — so the
    /// animation runs forwards through time in one list.
    @Published private(set) var radarFrames: [Frame] = []

    @Published private(set) var satelliteFrames: [Frame] = []

    /// The index regenerates every ten minutes. Asking twice as often as that
    /// keeps the newest frame no more than a few minutes stale without asking
    /// for a document that has not changed.
    private static let refreshInterval: TimeInterval = 5 * 60

    private static let indexURL = URL(string: "https://api.rainviewer.com/public/weather-maps.json")

    private var lastFetch: Date?
    private var isFetching = false

    private init() {}

    /// Frames for one layer, or empty when that layer is not being served.
    func frames(for layer: MapWeatherLayer) -> [Frame] {
        switch layer {
        case .off: return []
        case .radar: return radarFrames
        case .satellite: return satelliteFrames
        }
    }

    /// Whether a layer has anything to draw. Radar and satellite are withdrawn
    /// on different schedules, so this is asked per layer rather than once.
    func isAvailable(_ layer: MapWeatherLayer) -> Bool {
        layer == .off || !frames(for: layer).isEmpty
    }

    /// Fetch the index if it is stale. Safe to call on every packet — it is a
    /// date comparison until the interval is up.
    func refresh(force: Bool = false) {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < Self.refreshInterval {
            return
        }
        guard !isFetching, let url = Self.indexURL else { return }

        isFetching = true
        if state == .idle { state = .loading }

        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }

            let parsed = Self.parse(data)

            DispatchQueue.main.async {
                self.isFetching = false
                self.lastFetch = Date()

                guard let parsed = parsed else {
                    // Whatever we already have stays on screen: a failed
                    // refresh is a reason to keep the last good frames, not to
                    // clear the map.
                    if self.radarFrames.isEmpty && self.satelliteFrames.isEmpty {
                        self.state = .unavailable(
                            error == nil
                                ? "The radar service answered with something this app could not read."
                                : "Could not reach the radar service."
                        )
                    }
                    return
                }

                self.host = parsed.host
                self.radarFrames = parsed.radar
                self.satelliteFrames = parsed.satellite
                self.state = parsed.radar.isEmpty && parsed.satellite.isEmpty
                    ? .unavailable("The radar service is no longer serving free tiles.")
                    : .ready
            }
        }.resume()
    }

    // MARK: - Parsing

    private struct Index {
        let host: String
        let radar: [Frame]
        let satellite: [Frame]
    }

    /// `{ host, radar: { past: [{time, path}], nowcast: [...] }, satellite: { infrared: [...] } }`
    ///
    /// Every section is optional, and that is the point — see the note on the
    /// type. A document with no `satellite` key is a satellite layer that has
    /// been withdrawn, not a parse failure.
    private static func parse(_ data: Data?) -> Index? {
        guard let data = data,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = root["host"] as? String,
              !host.isEmpty else {
            return nil
        }

        let radar = root["radar"] as? [String: Any]
        let satellite = root["satellite"] as? [String: Any]

        // Past then nowcast, so the list reads forwards through time.
        let radarFrames = frames(radar?["past"]) + frames(radar?["nowcast"])

        return Index(
            host: host.hasSuffix("/") ? String(host.dropLast()) : host,
            radar: radarFrames,
            satellite: frames(satellite?["infrared"])
        )
    }

    private static func frames(_ raw: Any?) -> [Frame] {
        guard let items = raw as? [[String: Any]] else { return [] }

        var out: [Frame] = []
        for item in items {
            guard let path = item["path"] as? String, !path.isEmpty else { continue }
            // Sent as a number, but the service has form for stringly numbers
            // elsewhere and a frame with an unreadable time is still a frame
            // worth drawing.
            let seconds = (item["time"] as? NSNumber)?.doubleValue
                ?? (item["time"] as? String).flatMap(Double.init)
            out.append(
                Frame(
                    time: Date(timeIntervalSince1970: seconds ?? 0),
                    path: path.hasPrefix("/") ? path : "/\(path)"
                )
            )
        }
        return out
    }
}
