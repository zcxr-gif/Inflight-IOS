import Combine
import Foundation
import SwiftUI

/// What weather the map should be drawing right now, and — when the radar is
/// animating — which frame of it.
///
/// The service holds the frames; this holds the playhead. Kept apart because
/// they answer different questions: the service is asked "what is available",
/// once every few minutes, and this is asked "what do I draw", several times a
/// second while an animation runs.
final class MapWeatherModel: ObservableObject {

    /// The tiles the map should have on it, or nil for none.
    @Published private(set) var tiles: MapWeatherTiles?

    /// The frame being drawn, for the timestamp over the map.
    @Published private(set) var frameTime: Date?

    /// Where the playhead is in the frame list, 0...1, for the scrubber. Nil
    /// when there is nothing to scrub.
    @Published private(set) var progress: Double?

    /// Whether the layer is on but has nothing to draw, so the map's chrome can
    /// say why rather than showing a switch that appears to do nothing.
    @Published private(set) var unavailable: String?

    /// Frames a second.
    ///
    /// Slower than it was. Every frame is a whole screen of tiles from a free
    /// service, and three a second asks for them faster than they can arrive —
    /// which is a rate limiter tripped, tiles refused, and a layer that
    /// flickers rather than animates. Two a second still reads as movement, and
    /// the second time round the loop it comes from the cache and costs
    /// nothing.
    private static let framesPerSecond: Double = 2

    /// How much of the past the animation runs through.
    ///
    /// An hour rather than the two the index carries. The frames are ten
    /// minutes apart, so this halves the tiles a loop touches — and an hour is
    /// enough to see which way a front is moving, which is the whole question.
    /// The scrubber still reaches every frame the service published.
    private static let animatedFrames = 7

    /// How long the newest frame is held before the loop restarts, so the
    /// animation ends on *now* rather than flicking straight back to the start.
    private static let restingFrames = 4

    private let service = RainViewerService.shared
    private let preferences = WeatherPreferences.shared

    private var step = 0
    private var timer: AnyCancellable?
    private var watchers: Set<AnyCancellable> = []

    /// Which layer was last built, so a change of layer can start the playhead
    /// and the tile reports over.
    private var lastLayer: MapWeatherLayer = .off

    /// Whether the camera is being moved right now, as reported by the map.
    private var isCameraMoving = false

    /// Whether the map is the drawn planet, which cannot afford an animation.
    ///
    /// ## Why the loop is held there
    ///
    /// On the flat map a frame is a set of tile URLs and MapKit does the rest —
    /// the tiles are cached, the compositing is the GPU's, and two frames a
    /// second costs almost nothing. On the planet a frame is a *software
    /// raster*: every tile decoded to pixels and the whole visible face of the
    /// sphere unprojected pixel by pixel to read them. See `GlobeWeatherRaster`
    /// for why there is no other way to put a mercator tile on a globe.
    ///
    /// That is affordable once, when the planet settles. It is not affordable
    /// twice a second, and an animation that costs the device more than it
    /// costs to draw the planet underneath it is not an animation anybody
    /// wants. So the playhead is held on the newest frame while the planet is
    /// the map, and the scrubber still reaches every frame by hand.
    private var isPlanetDrawn = false

    /// Whether anything is holding the animation still.
    private var isHeld: Bool { isCameraMoving || isPlanetDrawn }

    /// The map, saying whether it is the drawn planet.
    func report(drawnPlanet: Bool) {
        guard isPlanetDrawn != drawnPlanet else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isPlanetDrawn != drawnPlanet else { return }
            self.isPlanetDrawn = drawnPlanet
            // Straight to the newest frame on the way in, so what the planet
            // shows is now rather than wherever the loop happened to be.
            if drawnPlanet {
                self.stop()
                let frames = MapWeatherSource.frames(for: self.preferences.mapLayer)
                self.step = max(frames.count - 1, 0)
                self.rebuild()
            } else {
                self.startIfNeeded()
            }
        }
    }

    /// The last thing the map *said*, as opposed to the last thing acted on.
    ///
    /// Kept separately because the acting is a runloop turn behind the saying.
    /// Comparing a new report against `isCameraMoving` would read a value the
    /// hop has not written yet, so a stop arriving hard on the heels of a start
    /// looks like no change at all and is dropped — which leaves the animation
    /// paused for good. This is written where it is read, so it cannot be
    /// behind.
    private var reportedCameraMoving = false

    /// The map, saying whether the camera is moving.
    ///
    /// The animation stops while it is. Every frame is a whole screen of
    /// tiles, and a zoom changes which tiles those are — so a radar loop
    /// running through a pinch asks for seven screenfuls the cache has never
    /// seen, all at once, at a zoom the finger has already left. That is a
    /// rate limiter tripped and a layer that flickers, which is precisely what
    /// the animation is meant to look like the opposite of.
    ///
    /// The playhead is not touched: it sits on whatever frame it had reached
    /// and carries on from there when the map settles.
    func report(cameraMoving moving: Bool) {
        guard reportedCameraMoving != moving else { return }
        reportedCameraMoving = moving

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isCameraMoving != moving else { return }
            self.isCameraMoving = moving
            if moving { self.stop() } else { self.startIfNeeded() }
        }
    }

    init() {
        // Anything that changes what should be on screen rebuilds it: the
        // frame index landing, the layer being switched, the animation being
        // turned off.
        //
        // `objectWillChange` fires *before* the value it is announcing is
        // stored, so both of these are deliberately hopped through the main
        // queue rather than handled inline — that defers the work by a runloop
        // turn, which is exactly long enough for the new value to be the one
        // read below. Handling it synchronously would rebuild from the setting
        // that is on its way out.
        service.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rebuild() }
            .store(in: &watchers)

        preferences.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
            .store(in: &watchers)
    }

    /// Called when the map appears and on every packet. Fetches the index if it
    /// is stale, and does nothing at all while the layer is off — a switch
    /// nobody has turned on should cost no network.
    func refresh() {
        if preferences.mapLayer != lastLayer {
            lastLayer = preferences.mapLayer
            // The two layers are different services with different frame
            // counts. Neither the playhead nor anything said about the last
            // one's tiles carries over.
            step = 0
            service.resetTileReports()
        }

        guard preferences.mapLayer != .off else {
            stop()
            if tiles != nil || frameTime != nil || unavailable != nil {
                tiles = nil
                frameTime = nil
                progress = nil
                unavailable = nil
            }
            return
        }

        // Only the radar has an index to fetch. The satellite's frames are days
        // of the calendar, which need asking nobody.
        if preferences.mapLayer == .radar { service.refresh() }

        rebuild()
        startIfNeeded()
    }

    /// Drag the playhead by hand. Stops nothing — the animation, if it is
    /// running, simply carries on from wherever it was left.
    func scrub(to fraction: Double) {
        let frames = MapWeatherSource.frames(for: preferences.mapLayer)
        guard frames.count > 1 else { return }
        let index = Int((fraction * Double(frames.count - 1)).rounded())
        step = min(max(index, 0), frames.count - 1)
        rebuild()
    }

    // MARK: - Internals

    private func rebuild() {
        let layer = preferences.mapLayer
        guard layer != .off else { return }

        let frames = MapWeatherSource.frames(for: layer)

        guard let host = MapWeatherSource.host(for: layer), !frames.isEmpty else {
            tiles = nil
            frameTime = nil
            progress = nil
            unavailable = Self.reason(for: service.state, layer: layer)
            return
        }

        // The index has frames, so the only remaining reason for an empty map
        // is the tiles themselves being refused, which the overlay reports.
        //
        // Zoom is no longer one of the reasons. The map used to take the
        // overlay off once the view was narrower than the tiles held detail
        // for, and this line said so — a switch that was on, drawing nothing,
        // with a sentence explaining it. The overlay now stays, at one
        // strength, however far in the map goes: see the note in
        // `MapWeatherSource`.
        unavailable = service.tileFailure

        // The playhead is clamped rather than wrapped: a shorter list arriving
        // — which is what a nowcast expiring looks like — should land on the
        // newest frame, not somewhere arbitrary in the middle of the old one.
        let index = min(step, frames.count - 1)
        let frame = frames[index]

        tiles = MapWeatherTiles(host: host, frame: frame, layer: layer)
        frameTime = frame.time.timeIntervalSince1970 > 0 ? frame.time : nil
        progress = frames.count > 1 ? Double(index) / Double(frames.count - 1) : nil
    }

    private func startIfNeeded() {
        // Held while the camera moves, and for as long as the map is the drawn
        // planet. Deliberately before everything below, so a hold leaves the
        // playhead exactly where it was rather than snapping it to the newest
        // frame the way switching the animation off does.
        guard !isHeld else {
            stop()
            return
        }

        let frames = MapWeatherSource.frames(for: preferences.mapLayer)
        // Only the radar runs. The satellite's frames are whole days, and three
        // days flicking past at two a second is a strobe rather than an
        // animation — they are there to be scrubbed through by hand.
        //
        // And nothing runs while the service is turning requests away: the
        // animation is what asks for thirteen screens of tiles instead of one,
        // so it is the thing that stops. The frame left on the map keeps asking
        // for its own tiles as you pan, and the first one that arrives says the
        // service is answering again.
        let wanted = preferences.animatesRadar
            && frames.count > 1
            && preferences.mapLayer == .radar
            && !service.isThrottled

        guard wanted else {
            stop()
            // Not animating means sitting on the newest frame, which is what
            // somebody who switched the animation off is asking to see.
            if step != max(frames.count - 1, 0) {
                step = max(frames.count - 1, 0)
                rebuild()
            }
            return
        }

        guard timer == nil else { return }

        timer = Timer.publish(every: 1 / Self.framesPerSecond, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.advance() }
    }

    private func advance() {
        let frames = MapWeatherSource.frames(for: preferences.mapLayer)
        guard frames.count > 1 else { return }

        // The pause on the newest frame is spent by running the counter past
        // the end of the list rather than by juggling a second timer.
        step += 1

        // Back to the start of the animated window rather than to the start of
        // the list: the older half of the two hours is still there to be
        // scrubbed to, it is simply not worth fetching on every loop. A
        // playhead dragged behind that window runs forward through everything
        // once and then settles into it.
        if step >= frames.count + Self.restingFrames {
            step = max(0, frames.count - Self.animatedFrames)
        }

        rebuild()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func reason(for state: RainViewerService.State, layer: MapWeatherLayer) -> String? {
        // The cloud layer has no index to be missing from: its frames are days
        // of the calendar. Reaching here at all means something else, and the
        // tiles report their own trouble.
        guard layer == .radar else { return nil }

        switch state {
        case .idle, .loading:
            return nil
        case .ready:
            return "No radar frames are being served just now."
        case .unavailable(let reason):
            return reason
        }
    }
}
