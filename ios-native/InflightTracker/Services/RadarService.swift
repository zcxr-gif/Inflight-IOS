import Combine
import Foundation

/// One frame of precipitation radar: the tiles for a single moment.
struct RadarFrame: Equatable {

    /// Fully formed `MKTileOverlay` template, with `{z}`, `{x}` and `{y}` left
    /// in for MapKit to fill.
    let urlTemplate: String

    /// When the radar sweep this frame came from was taken.
    let observed: Date

    /// `Radar · 11:40` — the age is the whole point of showing it. A radar
    /// picture with no time on it is a claim about now that might be two hours
    /// old.
    var label: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: observed)
    }
}

/// Precipitation radar tiles, from RainViewer — the same source the web build
/// used (`old/www/flight.js` -> `toggleWeatherLayer`, and the notes kept in
/// `old/www/rainviewer.txt`).
///
/// The service publishes an index of the last two hours of frames rather than
/// serving tiles itself; the newest one is what gets drawn. That index goes
/// stale in about ten minutes, which is how often a new sweep lands, so it is
/// re-read on that cadence for as long as the layer is switched on and never
/// while it is off.
final class RadarService: ObservableObject {

    static let shared = RadarService()

    /// The frame currently worth drawing. Nil before the first index lands, and
    /// after a failure — the map draws no radar rather than stale radar.
    @Published private(set) var frame: RadarFrame?

    /// Whether a fetch has come back at all yet, so a button can say "loading"
    /// rather than "no data" for the second before the first index arrives.
    @Published private(set) var hasAnswered = false

    private var timer: Timer?
    private var isRunning = false

    private init() {}

    /// Starts following the radar, and stops when nothing is drawing it.
    ///
    /// Driven by the layer being on rather than by the app being open: the
    /// index is a request every ten minutes, and making it for a layer nobody
    /// has switched on is a request per user per ten minutes for a picture that
    /// is never rendered.
    func setActive(_ active: Bool) {
        // The timer belongs to the main run loop, and this can be reached from
        // whichever thread first touches `MapAppearance` — a scheduled timer
        // attaches to the calling thread's run loop, which for a background
        // queue is one nothing ever runs.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.setActive(active) }
            return
        }

        guard active != isRunning else { return }
        isRunning = active

        timer?.invalidate()
        timer = nil

        guard active else { return }

        refresh()

        // Sweeps land every ten minutes. Asking on the same cadence means the
        // picture is never more than one sweep behind, which for weather at
        // cruise is close enough to live.
        //
        // Built unscheduled and added to `.common`, rather than
        // `scheduledTimer`, so it keeps firing while the map is being dragged —
        // a scheduled timer runs in the default mode only and stops for the
        // duration of every gesture.
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard let url = URL(string: "https://api.rainviewer.com/public/weather-maps.json") else { return }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        // The index is small and changes on a fixed cadence; a cached copy from
        // thirty seconds ago is the same answer.
        request.cachePolicy = .reloadRevalidatingCacheData

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            let resolved = data.flatMap { Self.decode($0) }

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.hasAnswered = true
                // A failed refresh keeps whatever is on screen: the frame it is
                // showing is ten minutes old rather than wrong, and blanking
                // the layer because one request timed out is worse.
                guard let resolved = resolved else { return }
                self.frame = resolved
            }
        }
        .resume()
    }

    // MARK: - Decoding

    private struct Index: Decodable {
        struct Frame: Decodable {
            let time: TimeInterval?
            let path: String?
        }

        struct Radar: Decodable {
            let past: [Frame]?
            let nowcast: [Frame]?
        }

        let host: String?
        let radar: Radar?
    }

    /// Builds the newest observed frame's tile template.
    ///
    /// Only `past` is read. The index also carries a half-hour nowcast, which
    /// is a forecast — drawing it beside live aircraft, in the same colours,
    /// with nothing saying which is which, would be presenting a prediction as
    /// an observation.
    ///
    /// The path segments after the tile coordinates are RainViewer's own:
    /// `512` is the retina tile size, `4` is their aviation colour scheme, and
    /// `1_1` asks for smoothing and for snow to be drawn separately. Same
    /// choices the web build made.
    private static func decode(_ data: Data) -> RadarFrame? {
        guard let index = try? JSONDecoder().decode(Index.self, from: data),
              let host = index.host,
              let latest = index.radar?.past?.last,
              let path = latest.path,
              let time = latest.time else { return nil }

        return RadarFrame(
            urlTemplate: "\(host)\(path)/512/{z}/{x}/{y}/4/1_1.png",
            observed: Date(timeIntervalSince1970: time)
        )
    }
}
