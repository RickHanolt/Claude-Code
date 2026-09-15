import SwiftUI
import AVFoundation
import AudioToolbox

/// Camera view that reports the first QR code it sees.
///
/// Deliberately single-shot: it stops the session on the first result rather
/// than firing repeatedly while the code stays in frame. Redeeming an invite
/// is single-use, so a second delivery would try to spend a code that's
/// already gone and show a failure to someone who did nothing wrong.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFound: onFound)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.coordinator = context.coordinator
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onFound: (String) -> Void
        private var hasFired = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !hasFired,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue
            else { return }

            hasFired = true
            AudioServicesPlaySystemSound(1108)
            onFound(value)
        }
    }

    final class ScannerViewController: UIViewController {
        var coordinator: Coordinator?
        var onFailure: ((String) -> Void)?

        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black

            // Asked explicitly rather than left to the session to trigger.
            // Starting a session without permission doesn't fail — it delivers
            // black frames forever, which looks exactly like a camera pointed
            // at nothing, and leaves someone holding a dark rectangle with no
            // idea they were ever asked anything.
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                configure()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    Task { @MainActor in
                        guard let self else { return }
                        if granted {
                            self.configure()
                        } else {
                            self.fail("SchoolSync doesn't have camera access.")
                        }
                    }
                }
            default:
                fail("Camera access is turned off for SchoolSync in iOS Settings.")
            }
        }

        private func configure() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                // A simulator, or a device with no usable camera — recoverable
                // either way by typing the code instead.
                fail("No camera available on this device.")
                return
            }

            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                fail("This device can't scan codes.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            layer.frame = view.layer.bounds
            view.layer.addSublayer(layer)
            preview = layer

            // Off the main thread: starting a capture session blocks for long
            // enough to stutter the presentation animation.
            Task.detached { [session] in session.startRunning() }
        }

        /// Deferred by a turn of the runloop. The caller dismisses the sheet
        /// this controller lives in, and doing that from inside the
        /// presentation it's still finishing leaves the sheet half-shown.
        private func fail(_ message: String) {
            DispatchQueue.main.async { [weak self] in
                self?.onFailure?(message)
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.layer.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                Task.detached { [session] in session.stopRunning() }
            }
        }
    }
}
