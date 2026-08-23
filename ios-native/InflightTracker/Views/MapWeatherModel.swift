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

    /// Whether the map is somewhere the tiles still hold detail, as reported by
    /// the map itself.
    private var isLegible = true

    /// The map, saying whether the current layer is worth drawing at the zoom it
    /// is now at.
    ///
    /// Hopped through the main queue rather than acted on where it is called:
    /// this arrives from inside the map's own layout pass, and publishing from
    /// there is changing state in the middle of a SwiftUI update.
    func report(legible: Bool) {
        guard isLegible != legible else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isLegible != legible else { return }
            self.isLegible = legible
            self.rebuild()
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

        // Zoomed in past the imagery's own detail, the map takes the overlay
        // off — so the strip says why, rather than leaving a layer that is
        // switched on and drawing nothing.
        //
        // Otherwise the index has frames, and the only remaining reason for an
        // empty map is the tiles themselves being refused, which the overlay
        // reports.
        unavailable = isLegible
            ? service.tileFailure
            : "Too close in for \(layer.label.lowercased()). Zoom out."

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
