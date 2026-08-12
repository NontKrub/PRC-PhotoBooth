import Foundation
import CoreGraphics
import AVFoundation

struct CaptureAttempt: Sendable, Equatable {
    let id: UUID
    let startedAt: Date

    init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id = id
        self.startedAt = startedAt
    }
}

struct CaptureAttemptGate {
    private(set) var activeAttemptID: UUID?

    mutating func begin(_ attempt: CaptureAttempt) {
        activeAttemptID = attempt.id
    }

    func isCurrent(_ attemptID: UUID) -> Bool {
        activeAttemptID == attemptID
    }

    mutating func finish(_ attemptID: UUID) {
        guard activeAttemptID == attemptID else { return }
        activeAttemptID = nil
    }
}

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
