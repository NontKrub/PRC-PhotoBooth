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

enum StartupComponent: String, CaseIterable, Sendable {
    case runtimeDirectory
    case dataStore
    case jobQueue
    case recoveryStore
    case localServer
    case eventExperienceStore
    case galleryStore
}

enum StartupComponentStatus: String, Sendable, Equatable {
    case ready
    case unavailable
    case degraded
}

struct StartupComponentHealth: Sendable, Equatable {
    var status: StartupComponentStatus
    var detail: String

    static let ready = StartupComponentHealth(status: .ready, detail: "Ready.")
}

enum PreflightCheckID: String, Sendable, CaseIterable, Identifiable {
    case activeEvent
    case eventLayout
    case eventExperience
    case templateAssets
    case filterPipeline
    case galleryStorage
    case cameraPermission
    case cameraConnection
    case cameraTestCapture
    case customerDisplay
    case wifiPath
    case lanPath
    case ipadTransport
    case authentication
    case controlChannel
    case previewChannel
    case secureTransport
    case assetChannel
    case networkRoute
    case networkFreshness
    case reconnectState
    case outputFolder
    case diskSpace
    case localDownloadServer
    case localIPAddress
    case runtimePersistence
    case recoveryStorage
    case unfinishedSession
    case queueHealth
    case cloudUpload
    case guestDeliverySecurity
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
    var eventExperienceStatus: PreflightCheckStatus
    var eventExperienceDetail: String
    var templateAssetsStatus: PreflightCheckStatus
    var templateAssetsDetail: String
    var filterPipelineStatus: PreflightCheckStatus
    var filterPipelineDetail: String
    var galleryStorageStatus: PreflightCheckStatus
    var galleryStorageDetail: String
    var cameraPermissionGranted: Bool
    var cameraConnected: Bool
    var cameraSourceKind: CameraSourceKind
    var previewPermissionGranted: Bool
    var previewConnected: Bool
    var previewRequired: Bool
    var customerDisplayReady: Bool
    var ipadConnected: Bool
    var controlChannelConnected: Bool
    var ipadPreviewChannelConnected: Bool
    var secureTransportReady: Bool
    var assetChannelConnected: Bool
    var assetChannelVerified: Bool
    var lastControlActivityAt: Date?
    var reconnectInProgress: Bool
    var reconnectAttempt: Int
    var requestedNetwork: BoothNetworkPreference
    var effectiveNetwork: BoothEffectiveNetworkTransport
    var wifiPathAvailable: Bool
    var lanPathAvailable: Bool
    var networkFallbackActive: Bool
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
    var queuePendingCount: Int
    var queueRunningCount: Int
    var queueRetryingCount: Int
    var queueFailedCount: Int
    var oldestCriticalJobAge: TimeInterval?
    var cloudUploadEnabled: Bool
    var allowTrustedLocalHTTP: Bool
    var publicBaseURL: String?
    var cloudSetupComplete: Bool
    var cloudConnectivityPassed: Bool
    var automaticPrintingEnabled: Bool
    var printerConfigured: Bool
    var printerTestResult: PrinterTestResult?
    var startupComponents: [StartupComponent: StartupComponentHealth]

    init(
        event: EventConfig? = nil,
        eventExperienceStatus: PreflightCheckStatus = .skipped,
        eventExperienceDetail: String = "Skipped for legacy events.",
        templateAssetsStatus: PreflightCheckStatus = .skipped,
        templateAssetsDetail: String = "Skipped until an experience document is available.",
        filterPipelineStatus: PreflightCheckStatus = .skipped,
        filterPipelineDetail: String = "Skipped until filter settings are available.",
        galleryStorageStatus: PreflightCheckStatus = .skipped,
        galleryStorageDetail: String = "Gallery is disabled.",
        cameraPermissionGranted: Bool = false,
        cameraConnected: Bool = false,
        cameraSourceKind: CameraSourceKind = .avFoundation,
        previewPermissionGranted: Bool = true,
        previewConnected: Bool = true,
        previewRequired: Bool = false,
        customerDisplayReady: Bool = false,
        ipadConnected: Bool = false,
        controlChannelConnected: Bool = false,
        ipadPreviewChannelConnected: Bool = false,
        secureTransportReady: Bool = false,
        assetChannelConnected: Bool = false,
        assetChannelVerified: Bool = false,
        lastControlActivityAt: Date? = nil,
        reconnectInProgress: Bool = false,
        reconnectAttempt: Int = 0,
        requestedNetwork: BoothNetworkPreference = .wifi,
        effectiveNetwork: BoothEffectiveNetworkTransport = .unavailable,
        wifiPathAvailable: Bool = false,
        lanPathAvailable: Bool = false,
        networkFallbackActive: Bool = false,
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
        queuePendingCount: Int = 0,
        queueRunningCount: Int = 0,
        queueRetryingCount: Int = 0,
        queueFailedCount: Int = 0,
        oldestCriticalJobAge: TimeInterval? = nil,
        cloudUploadEnabled: Bool = false,
        allowTrustedLocalHTTP: Bool = false,
        publicBaseURL: String? = nil,
        cloudSetupComplete: Bool = false,
        cloudConnectivityPassed: Bool = false,
        automaticPrintingEnabled: Bool = false,
        printerConfigured: Bool = false,
        printerTestResult: PrinterTestResult? = nil,
        startupComponents: [StartupComponent: StartupComponentHealth] = [:]
    ) {
        self.event = event
        self.eventExperienceStatus = eventExperienceStatus
        self.eventExperienceDetail = eventExperienceDetail
        self.templateAssetsStatus = templateAssetsStatus
        self.templateAssetsDetail = templateAssetsDetail
        self.filterPipelineStatus = filterPipelineStatus
        self.filterPipelineDetail = filterPipelineDetail
        self.galleryStorageStatus = galleryStorageStatus
        self.galleryStorageDetail = galleryStorageDetail
        self.cameraPermissionGranted = cameraPermissionGranted
        self.cameraConnected = cameraConnected
        self.cameraSourceKind = cameraSourceKind
        self.previewPermissionGranted = previewPermissionGranted
        self.previewConnected = previewConnected
        self.previewRequired = previewRequired
        self.customerDisplayReady = customerDisplayReady
        self.ipadConnected = ipadConnected
        self.controlChannelConnected = controlChannelConnected
        self.ipadPreviewChannelConnected = ipadPreviewChannelConnected
        self.secureTransportReady = secureTransportReady
        self.assetChannelConnected = assetChannelConnected
        self.assetChannelVerified = assetChannelVerified
        self.lastControlActivityAt = lastControlActivityAt
        self.reconnectInProgress = reconnectInProgress
        self.reconnectAttempt = reconnectAttempt
        self.requestedNetwork = requestedNetwork
        self.effectiveNetwork = effectiveNetwork
        self.wifiPathAvailable = wifiPathAvailable
        self.lanPathAvailable = lanPathAvailable
        self.networkFallbackActive = networkFallbackActive
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
        self.queuePendingCount = queuePendingCount
        self.queueRunningCount = queueRunningCount
        self.queueRetryingCount = queueRetryingCount
        self.queueFailedCount = queueFailedCount
        self.oldestCriticalJobAge = oldestCriticalJobAge
        self.cloudUploadEnabled = cloudUploadEnabled
        self.allowTrustedLocalHTTP = allowTrustedLocalHTTP
        self.publicBaseURL = publicBaseURL
        self.cloudSetupComplete = cloudSetupComplete
        self.cloudConnectivityPassed = cloudConnectivityPassed
        self.automaticPrintingEnabled = automaticPrintingEnabled
        self.printerConfigured = printerConfigured
        self.printerTestResult = printerTestResult
        self.startupComponents = startupComponents
    }
}
