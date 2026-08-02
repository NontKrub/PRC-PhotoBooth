import Foundation
import CoreGraphics
import AVFoundation

// Protocol every camera backend must satisfy.
@MainActor
protocol CameraSource: AnyObject {
    var isRunning: Bool { get }
    var availableDevices: [CameraDeviceInfo] { get }
    var selectedDeviceID: String? { get set }

    // Callbacks set by CaptureService
    var onPreviewFrame: ((CVPixelBuffer) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    func start() throws
    func stop()
    func captureStill() async throws -> CGImage
}

struct CameraDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String          // unique device identifier
    let name: String
    let kind: Kind

    enum Kind: Sendable { case builtIn, usb, dslr, continuityCamera }
}
