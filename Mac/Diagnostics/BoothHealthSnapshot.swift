import Foundation

enum BoothHealthStatus: String, Codable, Sendable {
    case healthy
    case degraded
    case unavailable
    case unknown
}

struct CameraHealthSnapshot: Codable, Sendable, Equatable {
    var connected: Bool
    var connecting: Bool
    var cameraName: String?
    var cameraKind: String
    var livePreviewActive: Bool
    var previewFPS: Double?
    var ptpHealthy: Bool?
    var captureInProgress: Bool
    var lastCaptureAt: Date?
    var lastCaptureDuration: Double?
    var lastCaptureError: String?
    var captureSuccessCount: Int
    var captureFailureCount: Int
    var recoveredTransferCount: Int
    var reconnectCount: Int
    var batteryLevel: Int?
}

struct BoothHealthSnapshot: Codable, Sendable, Equatable {
    var updatedAt: Date
    var status: BoothHealthStatus
    var camera: CameraHealthSnapshot
    var customerDisplayConnected: Bool
    var customerDisplayPeer: String?
    var controlConnection: String
    var previewConnection: String
    var localServer: BoothHealthStatus
    var diskAvailableBytes: Int64?
    var queuePending: Int
    var queueRunning: Int
    var queueRetrying: Int
    var queueFailed: Int
    var printerName: String
    var printerStatus: String
    var printSuccessCount: Int
    var printFailureCount: Int
    var cloudPendingCount: Int
    var cloudFailedCount: Int
    var currentSessionID: String?
    var currentPhase: String
    var isBoothPaused: Bool
    var delivery: SessionDeliveryStatus?

    static let empty = BoothHealthSnapshot(
        updatedAt: .distantPast,
        status: .unknown,
        camera: CameraHealthSnapshot(
            connected: false, connecting: false, cameraName: nil, cameraKind: "unknown",
            livePreviewActive: false, previewFPS: nil, ptpHealthy: nil, captureInProgress: false,
            lastCaptureAt: nil, lastCaptureDuration: nil, lastCaptureError: nil,
            captureSuccessCount: 0, captureFailureCount: 0, recoveredTransferCount: 0,
            reconnectCount: 0, batteryLevel: nil
        ),
        customerDisplayConnected: false, customerDisplayPeer: nil,
        controlConnection: "disconnected", previewConnection: "unknown", localServer: .unknown,
        diskAvailableBytes: nil, queuePending: 0, queueRunning: 0, queueRetrying: 0, queueFailed: 0,
        printerName: "System Default", printerStatus: "unknown", printSuccessCount: 0,
        printFailureCount: 0, cloudPendingCount: 0, cloudFailedCount: 0,
        currentSessionID: nil, currentPhase: "Idle", isBoothPaused: false, delivery: nil
    )
}

enum RemoteOperatorAction: String, Codable, Sendable, CaseIterable {
    case pause
    case resume
    case retryReceive
    case retake
    case continueSession
    case usePrevious
    case cancelSession
    case reconnectCamera
    case retryFailedJobs
    case safeChecks
}

struct RemoteOperatorActionRequest: Codable, Sendable, Equatable {
    var action: RemoteOperatorAction
}
