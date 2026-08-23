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

    /// Frames a second. Slow enough to read a squall line moving, fast enough
    /// that two hours does not take a minute to watch.
    private static let framesPerSecond: Double = 3

    /// How long the newest frame is held before the loop restarts, so the
    /// animation ends on *now* rather than flicking straight back to two hours
    /// ago.
    private static let restingFrames = 4

    private let service = RainViewerService.shared
    private let preferences = WeatherPreferences.shared

    private var step = 0
    private var timer: AnyCancellable?
    private var watchers: Set<AnyCancellable> = []

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

        service.refresh()
        rebuild()
        startIfNeeded()
    }

    /// Drag the playhead by hand. Stops nothing — the animation, if it is
    /// running, simply carries on from wherever it was left.
    func scrub(to fraction: Double) {
        let frames = service.frames(for: preferences.mapLayer)
        guard frames.count > 1 else { return }
        let index = Int((fraction * Double(frames.count - 1)).rounded())
        step = min(max(index, 0), frames.count - 1)
        rebuild()
    }

    // MARK: - Internals

    private func rebuild() {
        let layer = preferences.mapLayer
        guard layer != .off else { return }

        let frames = service.frames(for: layer)

        guard let host = service.host, !frames.isEmpty else {
            tiles = nil
            frameTime = nil
            progress = nil
            unavailable = Self.reason(for: service.state, layer: layer)
            return
        }

        // The index has frames, so the only remaining reason for an empty map
        // is the tiles themselves being refused — which the overlay reports and
        // the strip is the place to say.
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
        let frames = service.frames(for: preferences.mapLayer)
        let wanted = preferences.animatesRadar && frames.count > 1

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
        let frames = service.frames(for: preferences.mapLayer)
        guard frames.count > 1 else { return }

        // The pause on the newest frame is spent by running the counter past
        // the end of the list rather than by juggling a second timer.
        step += 1
        if step >= frames.count + Self.restingFrames { step = 0 }
        rebuild()
    }

    private func stop() {
        timer?.cancel()
        timer = nil
    }

    private static func reason(for state: RainViewerService.State, layer: MapWeatherLayer) -> String? {
        switch state {
        case .idle, .loading:
            return nil
        case .ready:
            // The index arrived and this layer was not in it. RainViewer's
            // published schedule has the satellite maps ending on 1 January
            // 2026, so this is the expected answer for that one rather than a
            // fault.
            return layer == .satellite
                ? "Cloud tiles are no longer served. Radar still is."
                : "No radar frames are being served just now."
        case .unavailable(let reason):
            return reason
        }
    }
}
