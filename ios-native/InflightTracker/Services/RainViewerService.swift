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

    /// Shared with the satellite archive, which has frames of its own.
    typealias Frame = WeatherFrame

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

    /// The infrared satellite, while it lasted.
    ///
    /// RainViewer's published schedule withdrew it from the free tier, and the
    /// cloud layer is NASA's now — see `SatelliteImagery`. This is still parsed
    /// out of the index because the index still has a place for it, and a
    /// service that starts serving it again should not need a release to be
    /// noticed. Nothing draws from it today.
    @Published private(set) var satelliteFrames: [Frame] = []

    /// Why the tiles themselves are not drawing, when the index said they
    /// would.
    ///
    /// The index listing a frame is not the same as the images for it being
    /// served: a withdrawn tier answers the index perfectly well and then
    /// refuses every tile, which on the map is a layer that is switched on,
    /// costs requests, and draws nothing at all — with nothing anywhere saying
    /// why. The overlay reports what it actually got back, and this is what the
    /// strip over the map reads.
    @Published private(set) var tileFailure: String?

    /// Whether the tile service is currently turning requests away for coming
    /// too fast.
    ///
    /// Answered on the first 429 rather than after a run of them, because
    /// unlike a 404 there is nothing ambiguous about it — and because the
    /// correct response is to stop immediately. The animation is what generates
    /// the load, so the animation is what stops; a single frame stays on the
    /// map, and the first tile it draws successfully clears this.
    @Published private(set) var isThrottled = false

    /// How many refusals in a row, with no tile drawn between them, count as a
    /// layer that is not being served. More than one because a single 404 is a
    /// frame that expired mid-pan, which is ordinary.
    private static let tileFailuresBeforeReporting = 4

    private var tileFailures = 0

    // MARK: - How deep the tiles actually go

    /// The deepest zoom the radar is being served at.
    ///
    /// Starts at what RainViewer publishes and comes *down* when the tiles say
    /// otherwise. The published ceiling has moved twice under this app — see
    /// `MapWeatherSource.radarMaximumZoom` — and each time it moved, the app
    /// spent a release asking for a depth that was being refused, which is a
    /// blank layer past that depth rather than a soft one. Reading it off the
    /// tiles means the next move costs nobody anything.
    ///
    /// Only downwards, and only on a settled refusal. A 429 is being asked to
    /// slow down, not told the depth does not exist, and a 404 is a frame that
    /// expired mid-pan — neither says anything about the ceiling. The floor is
    /// four, below which the whole idea stops being a radar layer.
    ///
    /// Not `@Published`: it is read from whatever thread is building a tile, so
    /// it is behind its own lock, and the announcement is made by hand on the
    /// main queue.
    var servedRadarZoom: Int {
        zoomLock.lock()
        defer { zoomLock.unlock() }
        return servedZoom
    }

    /// Bumped whenever every tile on the map is worth asking for again.
    ///
    /// MapKit asks an overlay for a tile once and remembers the answer,
    /// including the answer "nothing". So a screen that came up empty while the
    /// app was holding back stays empty afterwards — there is no request to
    /// retry, because the retry is what was skipped. Nothing short of a new
    /// overlay makes it ask again, and a new overlay is what a changed key gets.
    ///
    /// So this is part of that key, and it moves on the two occasions where what
    /// is on the map is known to be worse than what the service would now give:
    /// a served depth that has come down, and a cooldown that has run out.
    var tilesToken: Int {
        zoomLock.lock()
        defer { zoomLock.unlock() }
        return token
    }

    private let zoomLock = NSLock()
    private var servedZoom = MapWeatherSource.radarMaximumZoom
    private var token = 0

    /// Say that whatever is drawn should be fetched again, and tell the map.
    /// On the main queue: the announcement is what rebuilds the overlays.
    private func askAgainForEveryTile() {
        zoomLock.lock()
        token &+= 1
        zoomLock.unlock()

        objectWillChange.send()
    }

    /// The lowest this will drop to before deciding the trouble is something
    /// other than the ceiling.
    private static let deepestUsableZoom = 4

    /// How many "you may not have this" refusals at the served depth, with no
    /// tile drawn at that depth between them, count as the ceiling having moved.
    private static let refusalsBeforeLoweringCeiling = 4

    private var ceilingRefusals = 0

    /// The index regenerates every ten minutes. Asking twice as often as that
    /// keeps the newest frame no more than a few minutes stale without asking
    /// for a document that has not changed.
    private static let refreshInterval: TimeInterval = 5 * 60

    private static let indexURL = URL(string: "https://api.rainviewer.com/public/weather-maps.json")

    private var lastFetch: Date?
    private var isFetching = false

    private init() {
        // The meter decides when the app is asking for too much; this is what
        // the rest of the app does about it. Wired here rather than at each call
        // site so there is one answer to "we are holding back" no matter which
        // of the two reasons tripped it.
        WeatherTileBudget.rainViewer.onPause = { [weak self] until in
            DispatchQueue.main.async { self?.holdRequests(until: until) }
        }
    }

    /// Frames for one layer, or empty when that layer is not being served.
    func frames(for layer: MapWeatherLayer) -> [Frame] {
        switch layer {
        case .off: return []
        case .radar: return radarFrames
        case .satellite: return satelliteFrames
        }
    }

    /// Whether this service has anything to draw for a layer.
    ///
    /// "Not known to be withdrawn" rather than "known to be there": until the
    /// index has actually been read, the layer is offered. Hiding radar because
    /// nobody has switched a layer on yet would be the same bug in the other
    /// direction.
    func isAvailable(_ layer: MapWeatherLayer) -> Bool {
        guard layer != .off else { return true }
        guard state == .ready else { return true }
        return !frames(for: layer).isEmpty
    }

    /// Forget what the tiles were doing.
    ///
    /// For a change of layer: the two are served by different people, and one's
    /// refusals say nothing about the other's. The request meter is cleared with
    /// them — a cooldown earned by one layer should not be served out by the
    /// other.
    func resetTileReports() {
        tileFailures = 0
        ceilingRefusals = 0
        WeatherTileBudget.rainViewer.reset()
        if tileFailure != nil { tileFailure = nil }
        if isThrottled { isThrottled = false }
    }

    /// What one tile request came back as, reported by the overlay.
    ///
    /// Called from a URL session's own thread, once per tile, so it hops to the
    /// main queue and does as little as possible: a counter, and a message only
    /// when enough have failed in a row to mean something.
    ///
    /// `zoom` is what the request was for, which is the difference between "the
    /// service is down" and "the service does not go that deep" — and `layer`
    /// says whose depth is being talked about. Both layers report here, because
    /// the strip over the map has one sentence for whichever is on; only
    /// RainViewer's own refusals are allowed to say anything about RainViewer's
    /// ceiling or its meter.
    func noteTile(status: Int, failed: Bool, zoom: Int, layer: MapWeatherLayer) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            guard failed else {
                // One tile drawn is the whole layer working. Anything said
                // about it before that was wrong, throttling included — the
                // service is answering again.
                self.tileFailures = 0
                if layer == .radar, zoom >= self.servedRadarZoom { self.ceilingRefusals = 0 }
                if self.tileFailure != nil { self.tileFailure = nil }
                // Not while the meter is still holding back. A request that was
                // already in the air when the hold began can land successfully
                // after it, and letting that restart the animation would be
                // seven frames' worth of tiles asked for and every one of them
                // skipped.
                if self.isThrottled, WeatherTileBudget.rainViewer.pausedUntil == nil {
                    self.isThrottled = false
                }
                return
            }

            // Nothing is done here about a 429 beyond saying so. Stopping is the
            // budget's job — it has already started the pause that `onPause`
            // turns into a hold, and it started one before the service had to
            // ask, which is the point of having it.
            if layer == .radar { self.noteCeilingRefusal(status: status, zoom: zoom) }

            self.tileFailures += 1
            guard self.tileFailures >= Self.tileFailuresBeforeReporting || status == 429 else { return }

            let message = Self.tileReason(status: status)
            if self.tileFailure != message { self.tileFailure = message }
        }
    }

    /// The budget has started holding requests back, until `until`.
    ///
    /// Two things follow, and they used to follow only from a 429 the service
    /// had actually sent — which was both too late and, worse, unrecoverable:
    /// the flag cleared only when a tile came back successfully, and no tile can
    /// come back successfully while the reason for the flag is that no tile is
    /// being fetched. A single 429 during a pinch could leave the radar frozen
    /// on one frame until the layer was switched off and on again.
    ///
    /// So: the animation stops, because it is what turns one screenful of tiles
    /// into seven; and when the hold runs out the whole screen is asked for
    /// again, because every tile skipped in the meantime is a hole MapKit now
    /// considers settled and will never re-request on its own.
    private func holdRequests(until: Date) {
        if !isThrottled { isThrottled = true }

        throttleHold += 1
        let hold = throttleHold

        // A second past what the budget is waiting for, so the first thing asked
        // on the other side is something it will actually permit.
        let wait = max(until.timeIntervalSinceNow + 1, 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self = self, self.throttleHold == hold else { return }
            self.tileFailures = 0
            if self.isThrottled { self.isThrottled = false }
            self.askAgainForEveryTile()
        }
    }

    private var throttleHold = 0

    /// A refusal at the depth this thinks is served, and what to make of it.
    private func noteCeilingRefusal(status: Int, zoom: Int) {
        // 401/402/403 is the service saying this is not yours to have. A 429 is
        // "not so fast" and a 404 is a frame that has aged out; neither is about
        // the zoom, and treating them as such would walk the ceiling down over
        // a bad minute and leave the radar coarse for the rest of the session.
        guard [401, 402, 403].contains(status) else { return }
        guard zoom >= servedRadarZoom, servedRadarZoom > Self.deepestUsableZoom else { return }

        ceilingRefusals += 1
        guard ceilingRefusals >= Self.refusalsBeforeLoweringCeiling else { return }

        ceilingRefusals = 0

        zoomLock.lock()
        servedZoom -= 1
        zoomLock.unlock()

        // Everything past the old depth was built from an ancestor that is not
        // being served. None of it is worth keeping.
        askAgainForEveryTile()
    }

    private static func tileReason(status: Int) -> String {
        switch status {
        case 401, 402, 403:
            return "The tile service is refusing these tiles — the free tier no longer covers them."
        case 404:
            return "The tile service has no images for this frame."
        case 429:
            return "The tile service is rate-limiting this app. Try again shortly."
        case 500...599:
            return "The tile service is having trouble (\(status))."
        case 0:
            return "Could not reach the tile service."
        default:
            return "The tile service refused these tiles (\(status))."
        }
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
                    if self.radarFrames.isEmpty {
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

                // A fresh index is a fresh chance for the tiles behind it.
                self.tileFailures = 0
                self.tileFailure = nil

                // Judged on the radar alone: the satellite section going away
                // is what was expected of it, and the cloud layer no longer
                // comes from here anyway.
                self.state = parsed.radar.isEmpty
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
