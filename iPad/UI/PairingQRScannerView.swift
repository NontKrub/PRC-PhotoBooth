import AVFoundation
import SwiftUI
import UIKit

struct PairingQRScannerView: View {
    let onScanned: (String) -> Void
    let onEnterPIN: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            Group {
                switch authorizationStatus {
                case .authorized:
                    if AVCaptureDevice.default(for: .video) != nil {
                        PairingQRCameraView { value in
                            onScanned(value)
                            dismiss()
                        }
                        .ignoresSafeArea(edges: .bottom)
                    } else {
                        unavailableView(message: "Camera is unavailable on this iPad.")
                    }
                case .notDetermined:
                    ProgressView("Requesting camera access…")
                case .denied, .restricted:
                    unavailableView(message: "Camera access is required to scan pairing QR codes.")
                @unknown default:
                    unavailableView(message: "Camera access is unavailable.")
                }
            }
            .navigationTitle("Scan Pairing QR")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            guard authorizationStatus == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            authorizationStatus = granted ? .authorized : .denied
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func unavailableView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 52))
            Text(message)
                .multilineTextAlignment(.center)
            if authorizationStatus == .denied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Enter PIN Instead") {
                dismiss()
                onEnterPIN()
            }
            .buttonStyle(.bordered)
        }
        .padding(32)
    }
}

private struct PairingQRCameraView: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeUIViewController(context: Context) -> PairingQRCameraViewController {
        PairingQRCameraViewController(onScanned: onScanned)
    }

    func updateUIViewController(_ uiViewController: PairingQRCameraViewController, context: Context) {}
}

private final class PairingQRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let onScanned: (String) -> Void
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var didScan = false

    init(onScanned: @escaping (String) -> Void) {
        self.onScanned = onScanned
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("PairingQRCameraViewController does not support NSCoder.")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configureCapture() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didScan,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        didScan = true
        onScanned(value)
    }
}
