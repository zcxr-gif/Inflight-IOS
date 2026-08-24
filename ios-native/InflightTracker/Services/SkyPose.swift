import CoreLocation
import CoreMotion
import Foundation
import simd

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

    /// The device's attitude: a matrix that carries a vector in the phone's own
    /// frame out into the reference frame — X true north, Y west, Z up.
    @Published private(set) var rotation: simd_double3x3?

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
        guard rotation != nil else { return .waiting }
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
            guard let self = self, let attitude = sample?.attitude else { return }
            self.rotation = attitude.rotationMatrix.matrix
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
        rotation = nil
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
