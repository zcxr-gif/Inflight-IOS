import Foundation
import QuartzCore
import os

/// The app's own heavy work, named and timed.
///
/// Every section is an `os_signpost` interval, so a Time Profiler or Points of
/// Interest trace in Instruments shows each packet, settle and traffic frame as
/// a labelled bar over the frame it landed in. That costs next to nothing when
/// nothing is recording. While the frame-rate meter is on, each section is also
/// timed here, and the meter names the slowest — so a stutter seen on a phone,
/// in a TestFlight build, with no Mac to hand, still says what it was.
enum Perf {

    private static let signposter = OSSignposter(subsystem: "com.tracker.Inflight", category: .pointsOfInterest)

    /// Runs `work` as a named section.
    @inline(__always) @discardableResult
    static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        guard FrameMeter.isRunning else {
            defer { signposter.endInterval(name, state) }
            return try work()
        }
        let start = CACurrentMediaTime()
        defer {
            signposter.endInterval(name, state)
            FrameMeter.shared.note(name, seconds: CACurrentMediaTime() - start)
        }
        return try work()
    }
}

/// How smoothly the app is drawing, measured on the phone itself.
///
/// A display link at the screen's full rate, on the main thread. Its callbacks
/// arrive on time only when the main thread is free to take them, and the main
/// thread is where SwiftUI lays out and where Mapbox draws the map — so a late
/// callback is exactly a frame the screen did not get. Off unless switched on
/// under Settings › About, and costs nothing then: no link, no timing.
final class FrameMeter: NSObject {

    static let shared = FrameMeter()

    /// The setting that shows the meter.
    static let settingKey = "diagnostics.frameMeter"

    /// Read from wherever a section is timed, which is not always the main
    /// thread; a stale answer for one section is harmless.
    private(set) static var isRunning = false

    /// What the meter shows.
    struct Reading {
        /// Frames drawn over the last second.
        var framesPerSecond = 0
        /// The rate the screen was asked for.
        var targetRate = 0
        /// Milliseconds of hitch per second over the last five — Apple's own
        /// measure: under 5 is smooth, over 10 is a stutter people notice.
        var hitchMillisecondsPerSecond = 0.0
        /// Frames that arrived late over the last five seconds.
        var hitches = 0
        /// The longest frame over the last five seconds, in milliseconds.
        var worstFrameMilliseconds = 0.0
        /// The slowest named section over the last five seconds.
        var slowest: (name: String, milliseconds: Double)?
    }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// Main thread only: the display link's own record.
    private var frameTimes: [CFTimeInterval] = []
    private var lateFrames: [(at: CFTimeInterval, frame: Double, late: Double)] = []
    private var targetRate = 0

    /// Written from any thread a section runs on.
    private let lock = NSLock()
    private var sections: [(at: CFTimeInterval, name: StaticString, seconds: Double)] = []

    /// How far back the meter looks.
    private static let window: CFTimeInterval = 5

    /// Sections shorter than this are not worth naming.
    private static let notable: Double = 0.002

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // The highest rate the screen offers, so the meter measures against
        // the strictest frame budget rather than whatever the map asked for.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
        Self.isRunning = true
    }

    func stop() {
        link?.invalidate()
        link = nil
        Self.isRunning = false
        frameTimes.removeAll()
        lateFrames.removeAll()
        lock.lock()
        sections.removeAll()
        lock.unlock()
    }

    func note(_ name: StaticString, seconds: Double) {
        guard seconds >= Self.notable else { return }
        let now = CACurrentMediaTime()
        lock.lock()
        sections.append((now, name, seconds))
        if sections.count > 256 { sections.removeFirst(sections.count - 256) }
        lock.unlock()
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let budget = link.targetTimestamp - link.timestamp
        if budget > 0 { targetRate = Int((1 / budget).rounded()) }

        defer { lastTimestamp = now }
        frameTimes.append(now)
        guard lastTimestamp > 0, budget > 0 else { return }

        let frame = now - lastTimestamp
        // Coming back from the background is not a hitch.
        guard frame < 1 else { return }
        if frame > budget * 1.5 {
            lateFrames.append((now, frame, frame - budget))
        }
    }

    /// The last few seconds, summed up.
    func reading() -> Reading {
        let now = CACurrentMediaTime()
        frameTimes.removeAll { now - $0 > 1 }
        lateFrames.removeAll { now - $0.at > Self.window }

        var reading = Reading()
        reading.framesPerSecond = frameTimes.count
        reading.targetRate = targetRate
        reading.hitches = lateFrames.count
        reading.hitchMillisecondsPerSecond = lateFrames.reduce(0) { $0 + $1.late } * 1000 / Self.window
        reading.worstFrameMilliseconds = (lateFrames.map { $0.frame }.max() ?? 0) * 1000

        lock.lock()
        sections.removeAll { now - $0.at > Self.window }
        if let slowest = sections.max(by: { $0.seconds < $1.seconds }) {
            reading.slowest = ("\(slowest.name)", slowest.seconds * 1000)
        }
        lock.unlock()

        return reading
    }
}
