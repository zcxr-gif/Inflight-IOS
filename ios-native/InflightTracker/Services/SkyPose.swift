import CoreLocation
import CoreMotion
import Foundation
import simd

/// The attitude, and nothing else.
///
/// Its own object so that the thirty-a-second signal reaches only the thing
/// that needs it. See the note on `SkyPose.attitude`.
final class SkyAttitude: ObservableObject {

    @Published fileprivate(set) var rotation: simd_double3x3?
}

/// Which way the phone is pointing, and where it is.
///
/// Two sensors that only make sense together: the attitude says which way the
/// camera is aimed, and the fix says what "north" is worth — CoreMotion cannot
/// give a true-north reference frame without location services, because the
/// difference between the magnetic pole and the real one depends on where you
/// are standing.
///
/// Nothing here is published to a server, cached, or written down. It is read
/// while the sky view is open and stopped the moment it closes, which is also
/// the only honest way to run two sensors this expensive.
final class SkyPose: NSObject, ObservableObject {

    /// Why the sky view cannot draw anything yet, in the order the user should
    /// be told about it.
    enum Trouble: Equatable {
        /// A phone with no gyroscope, or a reference frame the hardware cannot
        /// produce. Nothing to be done about either.
        case noSensors
        /// Location refused. The vantage and true north both depend on it.
        case locationRefused
        /// Everything is running and has not answered yet.
        case waiting
        /// The magnetometer is confused — near a speaker, a car dashboard, a
        /// magnetic case. The figure-of-eight wave is the fix, and the system
        /// will not prompt for it on our behalf here.
        case uncalibrated
    }

    /// The device's attitude, on an object of its own.
    ///
    /// Thirty times a second is a great deal of invalidation, and an
    /// `ObservableObject` does not publish per property — anything that reads
    /// *any* part of this object is rebuilt every time the phone moves. With
    /// the attitude in here that meant the camera preview, the chrome, the
    /// notices and the whole geometry reader around them were all being
    /// re-diffed at sensor rate, and the markers drifted behind the camera and
    /// settled when you stopped moving. Which is what "elastic" looks like.
    ///
    /// Split out, only the layer that draws the aeroplanes watches this one.
    /// Everything else on the view watches the object below, which changes
    /// when a fix lands or a permission does — a handful of times, ever.
    let attitude = SkyAttitude()

    /// Whether the attitude has started arriving. Flips once, so the view can
    /// wait for it without watching every sample.
    @Published private(set) var hasAttitude = false

    /// The current attitude, for anything that wants a reading rather than a
    /// subscription.
    var rotation: simd_double3x3? { attitude.rotation }

    @Published private(set) var location: CLLocation?

    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// Degrees of slop the compass admits to. Negative means it has not
    /// produced a heading yet.
    @Published private(set) var headingAccuracyDegrees: Double = -1

    /// Thirty a second. Sixty is what the hardware will give and what a game
    /// would take; this is a label on an aeroplane forty miles away, and half
    /// the redraws is half the battery for a difference nobody can see.
    private static let updateInterval: TimeInterval = 1.0 / 30

    /// Past this the compass is far enough out to be worth saying so.
    private static let calibrationThreshold: Double = 25

    private let motion = CMMotionManager()
    private let locations = CLLocationManager()
    private var isRunning = false

    override init() {
        super.init()
        locations.delegate = self
        locations.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        authorization = locations.authorizationStatus
    }

    /// Whether the hardware can do this at all.
    var hasSensors: Bool {
        motion.isDeviceMotionAvailable
            && CMMotionManager.availableAttitudeReferenceFrames().contains(.xTrueNorthZVertical)
    }

    var trouble: Trouble? {
        guard hasSensors else { return .noSensors }
        if authorization == .denied || authorization == .restricted { return .locationRefused }
        guard hasAttitude else { return .waiting }
        // A negative accuracy is the compass saying it has not answered yet,
        // which is a moment at the start rather than a problem to report.
        if headingAccuracyDegrees > Self.calibrationThreshold { return .uncalibrated }
        return nil
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if authorization == .notDetermined {
            locations.requestWhenInUseAuthorization()
        }

        locations.startUpdatingLocation()
        // Not for the heading itself — the attitude carries that — but for what
        // the heading says about its own accuracy, which is the only way to
        // know the compass needs waving about.
        locations.startUpdatingHeading()

        guard hasSensors else { return }

        motion.deviceMotionUpdateInterval = Self.updateInterval
        motion.startDeviceMotionUpdates(
            using: .xTrueNorthZVertical,
            to: .main
        ) { [weak self] sample, _ in
            guard let self = self, let sample = sample?.attitude else { return }
            self.attitude.rotation = sample.rotationMatrix.matrix
            if !self.hasAttitude { self.hasAttitude = true }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false

        motion.stopDeviceMotionUpdates()
        locations.stopUpdatingLocation()
        locations.stopUpdatingHeading()

        // Cleared rather than left at the last reading: a stale attitude coming
        // back on screen half a second before the live one arrives is a view
        // that opens pointing the wrong way.
        attitude.rotation = nil
        hasAttitude = false
    }
}

extension SkyPose: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus

        // The first grant arrives after `start` has already asked, so this is
        // where the sensors actually get going for anybody seeing the prompt.
        guard isRunning, authorization == .authorizedWhenInUse || authorization == .authorizedAlways else { return }
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last else { return }
        location = fix
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        headingAccuracyDegrees = newHeading.headingAccuracy
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to do and nothing worth saying: a failed fix leaves the last
        // good one in place, and the view already knows how to wait for one.
    }
}

extension CMRotationMatrix {

    /// CoreMotion's own struct, in a form that can be multiplied.
    var matrix: simd_double3x3 {
        simd_double3x3(rows: [
            SIMD3(m11, m12, m13),
            SIMD3(m21, m22, m23),
            SIMD3(m31, m32, m33)
        ])
    }
}
