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

    /// How far the picture has to be turned to sit level, which AVFoundation
    /// works out from the device's own orientation.
    @Published private(set) var previewRotation: CGFloat = 90

    let session = AVCaptureSession()

    /// Configuring a session blocks for long enough to drop frames elsewhere,
    /// and `startRunning` blocks outright, so neither happens on the main
    /// thread.
    private let queue = DispatchQueue(label: "com.tracker.Inflight.sky.camera")

    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObserver: NSKeyValueObservation?
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
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.access = .unavailable }
            return
        }

        session.sessionPreset = .high
        session.addInput(input)
        isConfigured = true

        let field = Double(device.activeFormat.videoFieldOfView)
        DispatchQueue.main.async {
            self.fieldOfViewDegrees = field
            self.watchRotation(of: device)
        }
    }

    /// Keeps the preview level as the phone turns. The coordinator is given no
    /// layer of its own — the one figure wanted here is the angle, and the view
    /// hands it to whichever layer it has built by then.
    private func watchRotation(of device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotation = coordinator
        rotationObserver = coordinator.observe(
            \.videoRotationAngleForHorizonLevelPreview,
            options: [.initial, .new]
        ) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            DispatchQueue.main.async { self?.previewRotation = angle }
        }
    }
}

/// The picture itself, filling whatever it is given.
struct SkyCameraPreview: UIViewRepresentable {

    let session: AVCaptureSession
    let rotation: CGFloat

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
        guard let connection = view.previewLayer.connection,
              connection.isVideoRotationAngleSupported(rotation),
              connection.videoRotationAngle != rotation else { return }
        connection.videoRotationAngle = rotation
    }

    final class PreviewView: UIView {

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            // Guaranteed by `layerClass` above.
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
