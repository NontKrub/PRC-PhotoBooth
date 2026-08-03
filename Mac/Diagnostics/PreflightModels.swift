import Foundation

enum PreflightCheckStatus: String, Sendable {
    case passed
    case warning
    case failed
    case running
    case notRun
    case skipped
}

enum PreflightRequirement: Sendable {
    case required
    case recommended
}

enum PreflightCheckID: String, Sendable, CaseIterable, Identifiable {
    case activeEvent
    case eventLayout
    case cameraPermission
    case cameraConnection
    case cameraTestCapture
    case customerDisplay
    case previewTransport
    case outputFolder
    case diskSpace
    case localDownloadServer
    case localIPAddress
    case runtimePersistence
    case unfinishedSession
    case queueHealth
    case cloudUpload
    case printerConfiguration
    case printerTest

    var id: String { rawValue }
}

struct PreflightCheckResult: Identifiable, Sendable {
    var id: PreflightCheckID
    var title: String
    var detail: String
    var requirement: PreflightRequirement
    var status: PreflightCheckStatus
    var checkedAt: Date
}

enum BoothReadinessStatus: Sendable, Equatable {
    case ready
    case readyWithWarnings
    case notReady
    case checking
}

struct BoothPreflightContext: Sendable {
    var event: EventConfig?
    var cameraPermissionGranted: Bool
    var cameraConnected: Bool
    var customerDisplayReady: Bool
    var ipadConnected: Bool
    var usesCablePreview: Bool
    var usbPreviewSupported: Bool
    var usbPreviewClientConnected: Bool
    var outputFolderURL: URL?
    var availableDiskBytes: Int64?
    var localServerStatus: LocalWebServerStatus
    var localServerHealthPassed: Bool
    var localIPAddress: String?
    var runtimeDirectoryURL: URL
    var runtimePersistenceAvailable: Bool
    var queuePersistenceAvailable: Bool
    var unfinishedCaptureSession: Bool
    var requiredJobFailed: Bool
    var optionalJobPendingOrFailed: Bool
    var cloudUploadEnabled: Bool
    var cloudSetupComplete: Bool
    var cloudConnectivityPassed: Bool
    var automaticPrintingEnabled: Bool
    var printerConfigured: Bool
    var printerTestResult: PrinterTestResult?

    init(
        event: EventConfig? = nil,
        cameraPermissionGranted: Bool = false,
        cameraConnected: Bool = false,
        customerDisplayReady: Bool = false,
        ipadConnected: Bool = false,
        usesCablePreview: Bool = false,
        usbPreviewSupported: Bool = true,
        usbPreviewClientConnected: Bool = false,
        outputFolderURL: URL? = nil,
        availableDiskBytes: Int64? = nil,
        localServerStatus: LocalWebServerStatus = LocalWebServerStatus(state: .stopped, registeredTokenCount: 0),
        localServerHealthPassed: Bool = false,
        localIPAddress: String? = nil,
        runtimeDirectoryURL: URL = FileManager.default.temporaryDirectory,
        runtimePersistenceAvailable: Bool = true,
        queuePersistenceAvailable: Bool = true,
        unfinishedCaptureSession: Bool = false,
        requiredJobFailed: Bool = false,
        optionalJobPendingOrFailed: Bool = false,
        cloudUploadEnabled: Bool = false,
        cloudSetupComplete: Bool = false,
        cloudConnectivityPassed: Bool = false,
        automaticPrintingEnabled: Bool = false,
        printerConfigured: Bool = false,
        printerTestResult: PrinterTestResult? = nil
    ) {
        self.event = event
        self.cameraPermissionGranted = cameraPermissionGranted
        self.cameraConnected = cameraConnected
        self.customerDisplayReady = customerDisplayReady
        self.ipadConnected = ipadConnected
        self.usesCablePreview = usesCablePreview
        self.usbPreviewSupported = usbPreviewSupported
        self.usbPreviewClientConnected = usbPreviewClientConnected
        self.outputFolderURL = outputFolderURL
        self.availableDiskBytes = availableDiskBytes
        self.localServerStatus = localServerStatus
        self.localServerHealthPassed = localServerHealthPassed
        self.localIPAddress = localIPAddress
        self.runtimeDirectoryURL = runtimeDirectoryURL
        self.runtimePersistenceAvailable = runtimePersistenceAvailable
        self.queuePersistenceAvailable = queuePersistenceAvailable
        self.unfinishedCaptureSession = unfinishedCaptureSession
        self.requiredJobFailed = requiredJobFailed
        self.optionalJobPendingOrFailed = optionalJobPendingOrFailed
        self.cloudUploadEnabled = cloudUploadEnabled
        self.cloudSetupComplete = cloudSetupComplete
        self.cloudConnectivityPassed = cloudConnectivityPassed
        self.automaticPrintingEnabled = automaticPrintingEnabled
        self.printerConfigured = printerConfigured
        self.printerTestResult = printerTestResult
    }
}
