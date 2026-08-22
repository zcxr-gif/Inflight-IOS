import Foundation

/// Smooths one aircraft's telemetry into something worth watching.
///
/// The feed delivers a packet every few seconds. Drawn straight, an artificial
/// horizon fed from it does not fly — it teleports, four times a minute, and
/// the whole point of an attitude display is the continuity. This walks the
/// drawn values towards the reported ones on the display's own clock, so
/// between packets the instruments settle rather than sit.
///
/// Deliberately *lagging* rather than extrapolating. Running the altitude
/// forward at the last vertical speed would look better and would be a
/// statement about where the aeroplane is that nothing has actually reported;
/// an instrument that is a second behind the truth is honest, and one that is
/// half a second ahead of it is not.
final class InstrumentAnimator {

    /// Seconds for a value to cover about two thirds of the gap. Attitude is
    /// quickest because it is the thing being watched; the tapes are slower
    /// because a number sliding for a moment reads better than one that snaps.
    private enum TimeConstant {
        static let attitude: Double = 0.55
        static let heading: Double = 0.7
        static let tape: Double = 0.8
        static let verticalSpeed: Double = 1.0
    }

    private var lastTick: Date?
    private var flightId: String?

    private var pitch: Double = 0
    private var bank: Double = 0
    /// Continuous, so a turn through north sweeps rather than spins the tape
    /// the long way round.
    private var unwrappedHeading: Double?
    private var unwrappedTrack: Double?
    private var speed: Double = 0
    private var altitude: Double = 0
    private var verticalSpeed: Double = 0

    /// The reading to draw at `date`, given what the feed last reported.
    ///
    /// Called once per animation frame from inside a `TimelineView`, which can
    /// evaluate a body more than once for the same instant — harmless here,
    /// because a repeat lands with no elapsed time and moves nothing.
    func reading(at date: Date, target: InstrumentReading, flightId: String) -> InstrumentReading {
        // Another aircraft is another aeroplane: it should open at its own
        // attitude rather than flying in from the last one's.
        if self.flightId != flightId {
            self.flightId = flightId
            lastTick = nil
        }

        guard let previous = lastTick else {
            lastTick = date
            adopt(target)
            return target
        }

        let elapsed = date.timeIntervalSince(previous)
        lastTick = date

        // A view coming back from the background can hand us a minute of
        // elapsed time; anything past a second is a jump rather than a frame.
        guard elapsed > 0 else { return current(from: target) }
        guard elapsed < 1 else {
            adopt(target)
            return target
        }

        pitch = approach(pitch, target.pitchDegrees, elapsed, TimeConstant.attitude)
        bank = approach(bank, target.bankDegrees, elapsed, TimeConstant.attitude)
        speed = approach(speed, target.speedKnots, elapsed, TimeConstant.tape)
        altitude = approach(altitude, target.altitudeFeet, elapsed, TimeConstant.tape)
        verticalSpeed = approach(
            verticalSpeed,
            target.verticalSpeedFPM,
            elapsed,
            TimeConstant.verticalSpeed
        )

        // Both bearings are stepped on the continuous line the drawn value is
        // already on, so a turn through north takes the short way round.
        let headingTarget = unwrap(unwrappedHeading, towards: target.headingDegrees)
        unwrappedHeading = approach(
            unwrappedHeading ?? headingTarget,
            headingTarget,
            elapsed,
            TimeConstant.heading
        )

        let trackTarget = unwrap(unwrappedTrack, towards: target.trackDegrees)
        unwrappedTrack = approach(
            unwrappedTrack ?? trackTarget,
            trackTarget,
            elapsed,
            TimeConstant.heading
        )

        return current(from: target)
    }

    // MARK: - Internals

    private func current(from target: InstrumentReading) -> InstrumentReading {
        var shown = target
        shown.pitchDegrees = pitch
        shown.bankDegrees = bank
        shown.speedKnots = speed
        shown.altitudeFeet = altitude
        shown.verticalSpeedFPM = verticalSpeed
        shown.headingDegrees = InstrumentReading.normalisedDegrees(
            unwrappedHeading ?? target.headingDegrees
        )
        shown.trackDegrees = InstrumentReading.normalisedDegrees(
            unwrappedTrack ?? target.trackDegrees
        )
        return shown
    }

    private func adopt(_ target: InstrumentReading) {
        pitch = target.pitchDegrees
        bank = target.bankDegrees
        speed = target.speedKnots
        altitude = target.altitudeFeet
        verticalSpeed = target.verticalSpeedFPM
        unwrappedHeading = target.headingDegrees
        unwrappedTrack = target.trackDegrees
    }

    /// The reported bearing expressed on the same continuous line the drawn one
    /// is on, so the shorter way round is the way it goes.
    private func unwrap(_ continuous: Double?, towards reported: Double) -> Double {
        guard let continuous = continuous else { return reported }
        var delta = reported - continuous.truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return continuous + delta
    }

    /// Exponential approach: the same fraction of whatever gap is left, every
    /// second, independent of the frame rate.
    private func approach(
        _ value: Double,
        _ target: Double,
        _ elapsed: Double,
        _ timeConstant: Double
    ) -> Double {
        guard value.isFinite, target.isFinite else { return target.isFinite ? target : 0 }
        guard elapsed > 0, timeConstant > 0 else { return value }
        let fraction = 1 - exp(-elapsed / timeConstant)
        return value + (target - value) * fraction
    }
}
