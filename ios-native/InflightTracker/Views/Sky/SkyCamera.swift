import AVFoundation
import SwiftUI
import UIKit

/// The camera behind the sky view.
///
/// A capture session with an input and nothing else: no output, no photo, no
/// buffer ever handed to the app. The preview layer draws straight from the
/// hardware, which is the whole of what this feature needs a camera for — the
/// aircraft are drawn over the picture, never into it.
final class SkyCamera: NSObject, ObservableObject {

    enum Access: Equatable {
        case waiting
        case granted
        case refused
        /// A device with no back camera to open, or one that refused to
        /// configure. Rare, and not something an apology can fix.
        case unavailable
    }

    @Published private(set) var access: Access = .waiting

    /// The angle the picture spans across its long axis, which on a phone held
    /// upright is the vertical. Zero until the session has been configured, and
    /// the sky is not drawn until it is — placing aircraft against a guessed
    /// lens would put them in the wrong part of the sky.
    @Published private(set) var fieldOfViewDegrees: Double = 0

    /// The camera the session is running on, once there is one. The preview
    /// takes it to keep itself the right way up: which rotation the picture
    /// needs is a question about this device and the layer showing it, and the
    /// layer is the half that only the view has.
    @Published private(set) var device: AVCaptureDevice?

    let session = AVCaptureSession()

    /// Configuring a session blocks for long enough to drop frames elsewhere,
    /// and `startRunning` blocks outright, so neither happens on the main
    /// thread.
    private let queue = DispatchQueue(label: "com.tracker.Inflight.sky.camera")

    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            access = .granted
            run()

        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.access = granted ? .granted : .refused
                    if granted { self.run() }
                }
            }

        default:
            access = .refused
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func run() {
        queue.async { [weak self] in
            guard let self = self else { return }
            if !self.isConfigured { self.configure() }
            guard self.isConfigured, !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // The wide angle rather than whatever `.default(for:)` picks: the sky
        // view wants as much of the sky in frame as it can get, and the field
        // of view is what the whole projection is built on.
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.access = .unavailable }
            return
        }

        session.sessionPreset = .high
        session.addInput(input)
        isConfigured = true

        let field = Double(camera.activeFormat.videoFieldOfView)
        DispatchQueue.main.async {
            self.fieldOfViewDegrees = field
            self.device = camera
        }
    }
}

/// The picture itself, filling whatever it is given.
///
/// The right way up is the view's own business rather than something passed
/// down from SwiftUI state. A preview connection does not exist until the
/// session has an input, which is several async hops after the layer is built,
/// so an angle applied once on the way past lands on nothing and the picture
/// stays on its side. Here the view holds the rotation coordinator, applies
/// what it says the moment it says it, and applies it again on every layout —
/// by which time the connection is certainly there.
struct SkyCameraPreview: UIViewRepresentable {

    let session: AVCaptureSession

    /// The camera the session is running on. Nil until it has been opened.
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        // Filled rather than fitted, which is also the assumption the focal
        // length is worked out under: the long axis of the picture spans the
        // long side of the view, and the sides are cropped.
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        guard let device = device else { return }
        view.follow(device)
    }

    final class PreviewView: UIView {

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Guaranteed by `layerClass` above.
            layer as! AVCaptureVideoPreviewLayer
        }

        private var coordinator: AVCaptureDevice.RotationCoordinator?
        private var observation: NSKeyValueObservation?

        /// Starts keeping the picture level for this camera. Idempotent: the
        /// representable's update runs on every redraw and this is only ever
        /// set up once.
        func follow(_ device: AVCaptureDevice) {
            guard coordinator?.device !== device else { return }

            // Handed the layer, not nil: the angle the picture needs depends on
            // how the layer is sitting on screen as well as on how the phone is
            // being held, and a coordinator with no layer can only answer half
            // of that.
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            self.coordinator = coordinator

            observation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.apply(angle) }
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // The connection arrives with the session's input rather than with
            // the layer, so the angle the coordinator gave earlier may have had
            // nowhere to land. Laying out is the reliable moment it does.
            if let angle = coordinator?.videoRotationAngleForHorizonLevelPreview { apply(angle) }
        }

        private func apply(_ angle: CGFloat) {
            guard let connection = previewLayer.connection,
                  connection.isVideoRotationAngleSupported(angle),
                  connection.videoRotationAngle != angle else { return }
            connection.videoRotationAngle = angle
        }
    }
}
