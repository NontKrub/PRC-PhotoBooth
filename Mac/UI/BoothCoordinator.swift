import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CoreGraphics
import ImageIO
import SwiftData
import Observation
import AVFoundation
import Network
import CryptoKit

enum CameraSourceKind: String, CaseIterable, Identifiable {
    case avFoundation = "Built-in / USB / Continuity"
    case dslr         = "DSLR / Mirrorless (USB Tethered)"
    var id: String { rawValue }
}

// Preview frames use the reliable BoothTransport preview channel.
// Control messages remain on the separate BoothTransport control channel.
enum PreviewFrameRate: Int, CaseIterable, Identifiable {
    case standard = 30
    case maximum = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

func shouldScheduleAutomaticCloudRetry(previous: Bool?, isSatisfied: Bool) -> Bool {
    isSatisfied && previous != true
}

enum JobRecoveryError: LocalizedError, Sendable, Equatable {
    case jobNotFound(String)
    case sessionCancelled(String)
    case manualPrintResolutionRequired(String)
    case manifestNotFound(String)
    case manifestCancelled(String)
    case manifestNotRetryable(String, RuntimeSessionStatus)
    case retryAlreadyInProgress(String)
    case obsoleteTransaction(String)

    var errorDescription: String? {
        switch self {
        case .jobNotFound(let id):
            return "Job \(id) was not found."
        case .sessionCancelled(let id):
            return "Session \(id) has been cancelled and cannot be retried."
        case .manualPrintResolutionRequired:
            return "Print outcome is unknown. Please verify the printer before retrying."
        case .manifestNotFound(let id):
            return "Manifest for session \(id) was not found."
        case .manifestCancelled(let id):
            return "Session \(id) is cancelled and cannot be retried."
        case .manifestNotRetryable(let id, let status):
            return "Required job for session \(id) cannot be retried while the manifest is \(status.rawValue)."
        case .retryAlreadyInProgress(let id):
            return "A recovery operation is already running for session \(id)."
        case .obsoleteTransaction(let id):
            return "Job \(id) belongs to an obsolete finalization transaction and cannot be retried."
        }
    }
}

@MainActor
@Observable
final class BoothCoordinator {
    static let eventFolderPathKey = "eventFolderPath"
    static let networkPreferenceKey = "boothNetworkPreference"

    nonisolated static func downloadURL(
        publicBaseURL: String?,
        localBaseURL: String,
        token: String,
        cloudUploadEnabled: Bool,
        allowTrustedLocalHTTP: Bool = false
    ) -> String {
        (try? SessionQRCodePayloadResolver.resolve(
            token: token,
            localBaseURL: localBaseURL,
            publicBaseURL: publicBaseURL,
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )) ?? ""
    }

    let multipeer: BoothTransport
    let connectionStatus: BoothConnectionStatus
    let capture: CaptureService
    let stateMachine: SessionStateMachine
    let server: LocalWebServer
    let operatorAuth: RemoteOperatorAuth
    private(set) var isRemoteOperatorEnabled = false
    private var eventActivity: NSObjectProtocol?
    let store: DataStore
    let cloudSSHSetup: CloudSSHSetupService
    let manifestStore: SessionManifestStore
    let workspace: SessionWorkspace
    let jobQueue: SessionJobQueue
    let recoveryService: SessionRecoveryService
    let preflight: BoothPreflightService
    let operationsEvents: OperationsEventStore
    let printer: PrinterService
    let cloudUpload: CloudUploadService
    let experienceStore: EventExperienceStore
    let filterPipeline: PhotoFilterPipeline
    let galleryStore: EventGalleryStore

    var activeEvent: BoothEvent? {
        didSet {
            updateEventActivity()
            capture.captureRotationDegrees = activeEvent?.cameraRotationDegrees ?? 0
            if activeEvent == nil {
                activeExperienceDocument = nil
                experienceCatalog = nil
            }
            let snapshot = activeEvent.map { makeEventSnapshot($0) }
            Task { @MainActor [weak self] in
                guard let self, let snapshot else { return }
                await self.loadExperience(for: snapshot)
            }
        }
    }
    private(set) var activeExperienceDocument: EventExperienceDocument?
    private(set) var experienceCatalog: CustomerExperienceCatalog?
    var errorMessage: String?
    private(set) var reviewDecisionPending = false
    private(set) var startupComponents: [StartupComponent: StartupComponentHealth] = [:]
    var serverURL: String = ""
    private(set) var isLocalServerReady = false

    private var guestDeliveryInterfaceSelection: GuestDeliveryInterfaceSelection {
        .forBoothNetwork(
            requested: connectionStatus.requestedNetwork,
            effective: connectionStatus.effectiveNetwork
        )
    }
    var cameraSourceKind: CameraSourceKind = .avFoundation {
        didSet {
            if cameraSourceKind == .avFoundation {
                capture.usesDSLR = false
            }
        }
    }
    var cameraPermissionGranted: Bool = false
    private(set) var isBoothPaused = false
    var requestedNetworkPreference: BoothNetworkPreference {
        get { multipeer.requestedNetworkPreference }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.networkPreferenceKey)
            multipeer.requestedNetworkPreference = newValue
        }
    }
    private(set) var ethernetTestInProgress = false
    private(set) var ethernetProbeResult: EthernetProbeResult?

    var isCaptureSessionActive: Bool {
        switch stateMachine.phase {
        case .idle, .selectingExperience, .readyToStart, .finished:
            return false
        default:
            return true
        }
    }

    var operationsSessionStatus: String? {
        switch sessionLifecycleOperation {
        case .cancelling:
            return "Cancelling"
        case .finalizing, .completing:
            return "Finalizing"
        case .idle:
            guard currentSession != nil else { return nil }
            switch stateMachine.phase {
            case .processing: return "Finalizing"
            case .captureRecovery: return "Capture recovery"
            case .finished: return "Finished"
            case .idle, .selectingExperience, .readyToStart: return "Ready"
            case .countdown, .captured, .review: return "Capturing"
            }
        }
    }
    var previewFrameRate: PreviewFrameRate {
        get { PreviewFrameRate(rawValue: UserDefaults.standard.integer(forKey: "previewFrameRate")) ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "previewFrameRate")
            capture.setPreviewFrameRate(newValue.rawValue)
        }
    }

    var previewQualityPreset: PreviewQualityPreset {
        get { PreviewQualityPreset(rawValue: UserDefaults.standard.string(forKey: "previewQuality") ?? "auto") ?? .auto }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "previewQuality")
            previewQualityPolicy.setPreset(newValue)
            applyPreviewQuality()
        }
    }

    private var currentSession: BoothSession?
    private var currentManifest: SessionManifest?
    private var currentManifestID: String?
    private var activeSoakRunID: String?
    private var soakCloudUploadOverride: Bool?
    private var soakAutomaticPrintOverride: Bool?
    @ObservationIgnored private var recoveryInFlightSessionIDs: Set<String> = []
    @ObservationIgnored private var jobReconciliationDirty = false
    @ObservationIgnored private var jobReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var serverRouteRefreshGeneration: UInt64 = 0
    @ObservationIgnored private var guestDeliveryConfigurationDirty = false
    @ObservationIgnored private var guestDeliveryConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var deferredAutomaticCloudRetrySessionIDs: Set<String> = []
#if DEBUG
    @ObservationIgnored var beforeManualRetryQueueMutationForTesting: (@MainActor () async -> Void)?
    @ObservationIgnored var beforeCloudRetryQueueMutationForTesting: (@MainActor (String) async -> Void)?
    @ObservationIgnored var beforeCancellationQueueBarrierForTesting: (@MainActor (String) async -> Void)?
    @ObservationIgnored private var stopCancellationAfterJobBarrierForTesting = false
#endif
    private(set) var lastCompletedSessionID: String?
    private var retakeCounts: [Int: Int] = [:]
    private var gifFrames: [Int: [CGImage]] = [:]
    private var countdownTask: Task<Void, Never>?
    private let sessionFlowOperations = SessionFlowOperationRegistry()
    private var currentCountdown: CountdownDescriptor?
    private var sessionMessageSequence: UInt64 = 0
    private let authorityEpoch = UUID()
    private var sessionLifecycleGeneration: UInt64 = 0
    private struct ActiveSessionStart {
        let requestID: UUID
        let generation: UInt64
        var sessionID: String?
    }
    private var activeSessionStart: ActiveSessionStart?
    private var lastSessionStartRequestID: UUID?
    private var lastSessionStartSessionID: String?
    private enum SessionLifecycleOperation: Equatable {
        case idle
        case cancelling(sessionID: String, token: UUID)
        case finalizing(sessionID: String, token: UUID)
        case completing(sessionID: String, token: UUID)

        var token: UUID? {
            switch self {
            case .idle: return nil
            case .cancelling(_, let token), .finalizing(_, let token), .completing(_, let token):
                return token
            }
        }

        var allowsCancellation: Bool {
            switch self {
            case .idle, .finalizing:
                return true
            case .cancelling, .completing:
                return false
            }
        }
    }
    private var sessionLifecycleOperation: SessionLifecycleOperation = .idle
    private var currentReviewStateToken: ReviewStateToken?
    private var currentCaptureRecoveryStateToken: CaptureRecoveryStateToken?
    private struct ReviewRequestRecord {
        let state: ReviewStateToken
        let action: ReviewAction
        let result: ReviewDecisionResult
    }
    private var recentReviewRequests: [UUID: ReviewRequestRecord] = [:]
    private var recentReviewRequestOrder: [UUID] = []
    private struct CaptureRecoveryRequestRecord {
        let state: CaptureRecoveryStateToken
        let action: CaptureRecoveryAction
        let result: CaptureRecoveryActionResult
    }
    private var recentCaptureRecoveryRequests: [UUID: CaptureRecoveryRequestRecord] = [:]
    private var recentCaptureRecoveryRequestOrder: [UUID] = []
    private var activeReviewRequestID: UUID?
    private var currentCaptureAttempt: CaptureAttempt?
    private var hasSeenDSLRConnection = false
    private let networkMonitor = NWPathMonitor()
    private var lastNetworkSatisfied: Bool?
    private var automaticCloudRetryTask: Task<Void, Never>?
    private var ethernetTestTask: Task<Void, Never>?
    private var previewQualityTask: Task<Void, Never>?
    private var previewQualityPolicy = PreviewQualityPolicy()
    private var lastAutomaticCloudRetryAt: Date?
    private var wasDSLRConnected = false
    private(set) var cameraReconnectCount = 0
    var currentStripPreview: CGImage?
    private(set) var currentFilteredReviewImages: [Int: CGImage] = [:]
    private(set) var currentSessionPresentation: SessionPresentation?
    private var lastSessionPresentation: SessionPresentation?
    private var finishedAwaitingCustomerAckSessionID: String?
    private var completionInFlightSessionID: String?
    private var customerFinishedInFlightSessionID: String?
    private var sessionAssetReferences: [Int: BoothAssetReference] = [:]
    private var stripAssetReference: BoothAssetReference?
    private var pendingPromptAssets: [String: (reference: BoothAssetReference, data: Data)] = [:]
    private var assetSources: [BoothAssetReference: Data] = [:]
    private var assetAssembler = BoothAssetAssembler()
    var externalSelection = CustomerSessionSelectionDraft()

    // MARK: - External display viewer
    private(set) var externalScreens: [NSScreen] = []
    private var externalDisplayWindow: NSWindow?
    var isExternalViewerActive: Bool { externalDisplayWindow != nil }

    init() {
        let networkPreference = Self.loadNetworkPreference()
        let status = BoothConnectionStatus(requestedNetwork: networkPreference)
        multipeer = NetworkBoothTransport(role: .mac, networkPreference: networkPreference, connectionStatus: status)
        connectionStatus = status
        capture = CaptureService()
        stateMachine = SessionStateMachine()
        server = LocalWebServer(port: 8585)
        operatorAuth = RemoteOperatorAuth()
        store = DataStore.shared
        cloudSSHSetup = CloudSSHSetupService()
        let runtimeDirectory = Self.runtimeDirectoryURL()
        var initialStartupComponents: [StartupComponent: StartupComponentHealth] = [:]
        do {
            try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
            initialStartupComponents[.runtimeDirectory] = .ready
        } catch {
            initialStartupComponents[.runtimeDirectory] = StartupComponentHealth(
                status: .unavailable,
                detail: "Runtime storage could not be created: \(error.localizedDescription)"
            )
        }
        experienceStore = EventExperienceStore(baseDirectory: Self.appSupportRootURL())
        filterPipeline = PhotoFilterPipeline()
        galleryStore = EventGalleryStore(baseDirectory: Self.appSupportRootURL())
#if DEBUG
        let demoModeEnabled = ProcessInfo.processInfo.arguments.contains("--demo-mode")
        capture.demoMode = demoModeEnabled
        if demoModeEnabled { cameraPermissionGranted = true }
#endif
        manifestStore = SessionManifestStore(baseDirectory: runtimeDirectory)
        workspace = SessionWorkspace()
        operationsEvents = OperationsEventStore(fileURL: runtimeDirectory.appendingPathComponent("operations-events.json"))
        printer = PrinterService()
        cloudUpload = CloudUploadService()
        let jobStore = JobQueueStore(fileURL: runtimeDirectory.appendingPathComponent("jobs.json"))
        let executor = SessionJobExecutor(
            manifestStore: manifestStore,
            workspace: workspace,
            store: store,
            server: server,
            cloudUpload: cloudUpload,
            printer: printer,
            galleryStore: galleryStore,
            guestDeliverySelection: {
                .forBoothNetwork(requested: status.requestedNetwork, effective: status.effectiveNetwork)
            }
        )
        jobQueue = SessionJobQueue(store: jobStore, executor: executor)
        recoveryService = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: workspace,
            jobQueue: jobQueue
        )
        preflight = BoothPreflightService()
        recoveryService.quiesceSessionOperations = { [weak self] sessionID in
            guard let self else { return true }
            return await self.sessionFlowOperations.cancelAndQuiesce(
                sessionID: sessionID,
                timeout: .seconds(10)
            )
        }
        initialStartupComponents[.dataStore] = store.lastPersistenceError.map {
            StartupComponentHealth(
                status: store.databaseWasRecreated ? .degraded : .unavailable,
                detail: store.databaseWasRecreated
                    ? "Database was recreated after corruption. Previous event data moved to backup (Finding 19)."
                    : "Persistent event data is unavailable: \($0)"
            )
        } ?? StartupComponentHealth(
            status: .ready,
            detail: "SwiftData store is available."
        )
        self.startupComponents = initialStartupComponents
        recoveryService.isSessionRecoveryInFlight = { [weak self] sessionID in
            self?.recoveryInFlightSessionIDs.contains(sessionID) ?? false
        }
        recoveryService.claimSessionRecovery = { [weak self] sessionID in
            self?.claimSessionRecovery(sessionID) ?? false
        }
        recoveryService.releaseSessionRecovery = { [weak self] sessionID in
            self?.releaseSessionRecovery(sessionID)
        }
        recoveryService.onRecoveryScanFinished = { [weak self] in
            self?.scheduleJobReconciliation()
        }
        jobQueue.onJobsChanged = { [weak self] in
            self?.scheduleJobReconciliation()
            self?.cleanupCompletedWorkingFiles()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.refreshServerRoutes()
                if self.jobQueue.lastQueueError != nil {
                    await self.runSafePreflight()
                }
            }
        }
        recoveryService.onResume = { [weak self] manifest, images in
            self?.resumeRecoveredSession(manifest: manifest, images: images)
        }
        recoveryService.onDiscard = { [weak self] manifest in
            self?.finishDiscardingRecoveredSession(manifest)
        }
        capture.dslr.onError = { [weak self] err in
            Task { @MainActor [weak self] in self?.errorMessage = "DSLR: \(err.localizedDescription)" }
        }
        capture.dslr.onConnectionStateChanged = { [weak self] in
            Task { @MainActor [weak self] in self?.handleDSLRConnectionStateChanged() }
        }

        Task { @MainActor [self] in
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--demo-mode") {
                do {
                    let demoEvent = try await DemoDataSeeder().seed(
                        store: store,
                        experienceStore: experienceStore,
                        reset: ProcessInfo.processInfo.arguments.contains("--reset-demo-data")
                    )
                    activeEvent = demoEvent
                } catch {
                    errorMessage = "Demo data could not load: \(error.localizedDescription)"
                }
            }
#endif
            await checkCameraPermission()
            if cameraPermissionGranted { startCamera() }
            serverURL = LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection)
                .endpoint?.baseURL ?? ""
            await server.configureOperatorHandlers(OperatorWebHandlers(
                isEnabled: { [weak self] in self?.operatorAuth.isEnabled ?? false },
                pair: { [weak self] token in self?.operatorAuth.pair(token) },
                authorize: { [weak self] token in self?.operatorAuth.isValidOperatorToken(token) ?? false },
                status: { [weak self] in await self?.healthSnapshot() ?? .empty },
                action: { [weak self] action in await self?.performRemoteOperatorAction(action) ?? false },
                events: { [weak self] in await self?.operationsEvents.jsonData() ?? Data("[]".utf8) }
            ))
            do {
                try await server.start()
            } catch {
                startupComponents[.localServer] = StartupComponentHealth(
                    status: .unavailable,
                    detail: "Local download server could not start: \(error.localizedDescription)"
                )
                errorMessage = startupComponents[.localServer]?.detail
            }
            let serverStatus = await server.waitUntilReady()
            if case .failed(let message) = serverStatus.state {
                isLocalServerReady = false
                startupComponents[.localServer] = StartupComponentHealth(
                    status: .unavailable,
                    detail: "Local download server failed: \(message)"
                )
                errorMessage = startupComponents[.localServer]?.detail
            } else if case .ready = serverStatus.state {
                isLocalServerReady = !serverURL.isEmpty
                startupComponents[.localServer] = .ready
            }

            let runtimeReady = startupComponents[.runtimeDirectory]?.status == .ready
            if runtimeReady {
                jobQueue.pauseWorkersForRecovery()
                jobQueue.start()
                startupComponents[.jobQueue] = .ready
            } else {
                startupComponents[.jobQueue] = StartupComponentHealth(
                    status: .unavailable,
                    detail: "Job queue disabled because runtime storage is unavailable."
                )
                startupComponents[.recoveryStore] = StartupComponentHealth(
                    status: .unavailable,
                    detail: "Recovery scanning disabled because runtime storage is unavailable."
                )
            }
            activeEvent = store.fetchActiveEvent()
            if runtimeReady {
                await restoreDownloadTokens()
                await recoveryService.scanNow()
                jobQueue.resumeWorkersAfterRecovery()
                startupComponents[.recoveryStore] = StartupComponentHealth(
                    status: recoveryService.recoveryErrors.isEmpty ? .ready : .degraded,
                    detail: recoveryService.recoveryErrors.first ?? "Recovery storage scanned."
                )
                await cleanupOldSessions(keepDays: 60)
            }
            await runSafePreflight()
        }

        setupMultipeerHandlers()
        if let networkTransport = multipeer as? NetworkBoothTransport {
            networkTransport.canAttemptPreferredLANRecovery = { [weak self] in
                guard let self else { return false }
                return !self.isCaptureSessionActive
            }
            networkTransport.canAcceptIncomingPairing = { [weak self] in
                guard let self else { return false }
                return !self.isCaptureSessionActive
            }
        }
        multipeer.start()
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleNetworkPathChange(isSatisfied: path.status == .satisfied)
            }
        }
        networkMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.NetworkMonitor"))

        refreshExternalScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExternalScreens() }
        }
    }

#if DEBUG
    init(
        testingManifestStore: SessionManifestStore,
        testingJobQueue: SessionJobQueue,
        runtimeDirectory: URL,
        testingRecoveryService: SessionRecoveryService? = nil,
        testingWorkspace: SessionWorkspace? = nil
    ) {
        let networkPreference = Self.loadNetworkPreference()
        let status = BoothConnectionStatus(requestedNetwork: networkPreference)
        multipeer = NetworkBoothTransport(role: .mac, networkPreference: networkPreference, connectionStatus: status)
        connectionStatus = status
        capture = CaptureService()
        stateMachine = SessionStateMachine()
        server = LocalWebServer(port: 8585)
        operatorAuth = RemoteOperatorAuth()
        store = DataStore.shared
        cloudSSHSetup = CloudSSHSetupService()
        experienceStore = EventExperienceStore(baseDirectory: runtimeDirectory)
        filterPipeline = PhotoFilterPipeline()
        galleryStore = EventGalleryStore(baseDirectory: runtimeDirectory)
        self.manifestStore = testingManifestStore
        let ws = testingWorkspace ?? SessionWorkspace()
        self.workspace = ws
        operationsEvents = OperationsEventStore(fileURL: runtimeDirectory.appendingPathComponent("operations-events.json"))
        printer = PrinterService()
        cloudUpload = CloudUploadService()
        self.jobQueue = testingJobQueue
        self.recoveryService = testingRecoveryService ?? SessionRecoveryService(
            manifestStore: testingManifestStore,
            workspace: ws,
            jobQueue: testingJobQueue
        )
        preflight = BoothPreflightService()
        startupComponents = [:]
        recoveryService.isSessionRecoveryInFlight = { [weak self] sessionID in
            self?.recoveryInFlightSessionIDs.contains(sessionID) ?? false
        }
        recoveryService.claimSessionRecovery = { [weak self] sessionID in
            self?.claimSessionRecovery(sessionID) ?? false
        }
        recoveryService.releaseSessionRecovery = { [weak self] sessionID in
            self?.releaseSessionRecovery(sessionID)
        }
        jobQueue.onJobsChanged = { [weak self] in
            self?.scheduleJobReconciliation()
            self?.cleanupCompletedWorkingFiles()
        }
    }
#endif

    var operatorPairingURL: String? {
        guard operatorAuth.isEnabled,
              isLocalServerReady,
              !serverURL.isEmpty else { return nil }
        return "\(serverURL)/operator/pair/\(operatorAuth.pairingTokenValue())"
    }

    func enableRemoteOperator() {
        guard RemoteOperatorAuth.isAvailableInCurrentBuild,
              isLocalServerReady,
              !serverURL.isEmpty else { return }
        operatorAuth.enable()
        isRemoteOperatorEnabled = true
    }

    func disableRemoteOperator() {
        operatorAuth.disable()
        isRemoteOperatorEnabled = false
    }

    var sharingStationURL: String? {
        let defaults = UserDefaults.standard
        let allowTrustedLocalHTTP = defaults.bool(forKey: "allowTrustedLocalHTTP")
        let localBaseURL = LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection)
            .endpoint?.baseURL
        let policy = SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: defaults.string(forKey: "publicBaseURL"),
            cloudUploadEnabled: defaults.bool(forKey: "cloudUploadEnabled"),
            allowTrustedLocalHTTP: allowTrustedLocalHTTP,
            localBaseURL: localBaseURL
        )
        guard policy.permitsLocalGuestHTTP(allowTrustedLocalHTTP: allowTrustedLocalHTTP),
              let gallery = activeExperienceDocument?.gallery,
              gallery.mode != .disabled else { return nil }
        let base: String
        if !serverURL.isEmpty && SessionQRCodePayloadResolver.isRoutableLocalBase(serverURL) {
            base = serverURL
        } else if let localBaseURL {
            base = localBaseURL
        } else {
            return nil
        }
        return "\(base)/e/\(gallery.eventToken)/station"
    }

    func guestDeliveryConfigurationDidChange() {
        serverRouteRefreshGeneration &+= 1
        serverURL = LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection)
            .endpoint?.baseURL ?? ""
        guestDeliveryConfigurationDirty = true
        guard guestDeliveryConfigurationTask == nil else { return }
        guestDeliveryConfigurationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { guestDeliveryConfigurationTask = nil }
            while guestDeliveryConfigurationDirty {
                guestDeliveryConfigurationDirty = false
                await refreshServerRoutes()
                await runSafePreflight()
            }
        }
    }

    func performRemoteOperatorAction(_ action: RemoteOperatorAction) async -> Bool {
        switch action {
        case .pause:
            pauseBooth(); return true
        case .resume:
            resumeBooth(); return true
        case .retryFailedJobs:
            do {
                _ = try await retryAllFailedJobs()
                return true
            } catch {
                recoveryService.recordError("Remote operator retry failed: \(error.localizedDescription)")
                return false
            }
        case .safeChecks:
            await runSafePreflight(); return true
        case .reconnectCamera:
            guard currentCaptureAttempt == nil else { return false }
            if cameraSourceKind == .dslr {
                disconnectDSLR()
                connectDSLR()
            } else {
                capture.stop()
                startCamera()
            }
            return true
        case .cancelSession:
            guard currentSession != nil else { return false }
            await cancelCurrentSession(); return true
        case .retryReceive, .retake, .continueSession, .usePrevious:
            guard case .captureRecovery(let index, _) = stateMachine.phase else { return false }
            let recoveryAction: CaptureRecoveryAction
            switch action {
            case .retryReceive: recoveryAction = .retryReceive(photoIndex: index)
            case .retake: recoveryAction = .retake(photoIndex: index)
            case .continueSession: recoveryAction = .continueSession(photoIndex: index)
            case .usePrevious: recoveryAction = .usePrevious(photoIndex: index)
            default: return false
            }
            let customerAction: CustomerDisplayAction = switch recoveryAction {
            case .retryReceive(let photoIndex): .retryReceive(photoIndex: photoIndex)
            case .retake(let photoIndex): .retakeFailedCapture(photoIndex: photoIndex)
            case .continueSession(let photoIndex): .continueAfterCaptureFailure(photoIndex: photoIndex)
            case .usePrevious(let photoIndex): .usePreviousCapture(photoIndex: photoIndex)
            }
            guard CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { return false }
            handleCaptureRecoveryAction(recoveryAction)
            return true
        }
    }

    private func loadExperience(for snapshot: BoothEventSnapshot) async {
        do {
            let document = try await experienceStore.ensureDocument(for: snapshot)
            guard activeEvent?.id == snapshot.id else { return }
            activeExperienceDocument = document
            experienceCatalog = CustomerExperienceCatalogBuilder().build(event: snapshot, document: document)
            if let event = activeEvent, event.id == snapshot.id {
                try LegacyEventMirrorService().updateLegacyEvent(event, using: document, modelContext: store.context)
            }
            startupComponents[.eventExperienceStore] = .ready
            sendExperienceCatalog()
            await runSafePreflight()
        } catch {
            activeExperienceDocument = nil
            experienceCatalog = nil
            startupComponents[.eventExperienceStore] = StartupComponentHealth(
                status: .unavailable,
                detail: "Event experience storage is unavailable: \(error.localizedDescription)"
            )
            errorMessage = "Event experience could not load: \(error.localizedDescription)"
        }
    }

    func refreshActiveExperience() {
        guard let event = activeEvent else { return }
        let snapshot = makeEventSnapshot(event)
        Task { @MainActor [weak self] in
            await self?.loadExperience(for: snapshot)
        }
    }

    @discardableResult
    func setActiveEvent(_ event: BoothEvent?) -> Bool {
        if activeSoakRunID != nil,
           event?.id != activeEvent?.id {
            errorMessage = "The active event cannot change during a production soak run."
            return false
        }
        guard store.setActiveEvent(event) else {
            let detail = store.lastPersistenceError ?? "unknown error"
            errorMessage = "Event changes could not be saved: \(detail)"
            return false
        }
        activeEvent = event
        return true
    }

    func loadExperienceDocument(for event: BoothEvent) async throws -> EventExperienceDocument {
        let snapshot = makeEventSnapshot(event)
        return try await experienceStore.ensureDocument(for: snapshot)
    }

    func saveExperienceDocument(
        _ document: EventExperienceDocument,
        for event: BoothEvent,
        editingSession: EventExperienceEditingSession? = nil
    ) async throws {
        var normalized = document
        normalized.templates.sort {
            if $0.sortOrder == $1.sortOrder { return $0.id < $1.id }
            return $0.sortOrder < $1.sortOrder
        }
        for index in normalized.templates.indices {
            normalized.templates[index].sortOrder = index
        }
        normalized.revision = UUID().uuidString
        normalized.updatedAt = Date()
        if let editingSession {
            try await experienceStore.commitEditing(editingSession, document: normalized)
        } else {
            try await experienceStore.save(normalized)
        }
        var previewErrorMessage: String?
        do {
            let result = try await experienceStore.rebuildPreviews(eventID: normalized.eventID)
            normalized = result.document
            if !result.failures.isEmpty {
                previewErrorMessage = "Event saved. Template previews need rebuilding: \(result.failures.joined(separator: "; "))"
            }
        } catch {
            previewErrorMessage = "Event saved, but template previews could not be rebuilt: \(error.localizedDescription)"
        }
        do {
            try LegacyEventMirrorService().updateLegacyEvent(event, using: normalized, modelContext: store.context)
        } catch {
            errorMessage = "Event saved, but compatibility fields could not be updated: \(error.localizedDescription)"
        }
        if activeEvent?.id == event.id {
            activeExperienceDocument = normalized
            let snapshot = makeEventSnapshot(event)
            experienceCatalog = CustomerExperienceCatalogBuilder().build(event: snapshot, document: normalized)
            sendExperienceCatalog()
            await refreshServerRoutes()
        }
        if let previewErrorMessage { errorMessage = previewErrorMessage }
    }

    func retryCloudUpload(sessionID: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard claimSessionRecovery(sessionID) else {
                errorMessage = JobRecoveryError.retryAlreadyInProgress(sessionID).localizedDescription
                return
            }
            defer { releaseSessionRecovery(sessionID, scheduleReconciliation: true) }

            var manifest: SessionManifest
            do {
                manifest = try await manifestStore.load(sessionID: sessionID)
            } catch {
                errorMessage = "Cloud upload could not load the session: \(error.localizedDescription)"
                return
            }
            guard manifest.status != .cancelled else {
                errorMessage = "This session is cancelled and cannot be requeued."
                return
            }
            if FinalizationPlan.make(from: manifest) == nil {
                do {
                    manifest = try await recoveryService.prepareFinalizationPlanForRecovery(for: manifest)
                } catch {
                    errorMessage = "Cloud upload recovery plan could not be migrated: \(error.localizedDescription)"
                    return
                }
            }
            guard let plan = FinalizationPlan.make(from: manifest),
                  plan.jobKinds.contains(.cloudUpload),
                  jobQueue.jobs.contains(where: {
                      $0.sessionID == sessionID
                          && $0.kind == .cloudUpload
                          && $0.finalizationTransactionID == plan.transactionID
                  }) else {
                errorMessage = "No cloud upload job exists for the active finalization transaction."
                return
            }
            let snapshot = manifest.cloudDelivery
            let cloudEnabled = manifest.deliveryIntent?.cloudUploadEnabled
                ?? (snapshot != nil || UserDefaults.standard.bool(forKey: "cloudUploadEnabled"))
            if !cloudEnabled {
                errorMessage = "Cloud upload is disabled."
                return
            }

            let sshHost = (snapshot?.sshHost ?? UserDefaults.standard.string(forKey: "cloudSSHHost") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sshHost.isEmpty else {
                errorMessage = "Cloud upload is not configured: SSH host is missing."
                return
            }
            let publicBase = (snapshot?.publicBaseURL ?? UserDefaults.standard.string(forKey: "publicBaseURL") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard ValidatedPublicGuestBaseURL(string: publicBase) != nil else {
                errorMessage = "Cloud upload is not configured: public URL is missing or invalid."
                return
            }

#if DEBUG
            await beforeCloudRetryQueueMutationForTesting?(sessionID)
#endif
            do {
                let result = try await jobQueue.forceRequeueCloudUpload(
                    sessionID: sessionID,
                    finalizationTransactionID: plan.transactionID
                )
                errorMessage = switch result {
                case .queued: "Web upload queued."
                case .alreadyQueued: "Web upload is already waiting."
                case .alreadyRunning: "Web upload is already running."
                case .notFound: "No web upload job exists for this session."
                case .sessionCancelled: "This session is cancelled and cannot be requeued."
                }
            } catch {
                errorMessage = "Cloud upload could not be requeued: \(error.localizedDescription)"
            }
        }
    }

    func resolveUnknownPrint(jobID: String, printed: Bool) {
        let resolution: UnknownPrintResolution = printed ? .printed : .notPrinted
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await jobQueue.resolveUnknownPrint(jobID: jobID, resolution: resolution)
            } catch {
                errorMessage = "Printer outcome could not be recorded: \(error.localizedDescription)"
            }
        }
    }

    func retryJob(jobID: String) async throws {
        guard let job = jobQueue.jobs.first(where: { $0.id == jobID }) else {
            throw JobRecoveryError.jobNotFound(jobID)
        }
        let eligibility = try await jobQueue.manualRetryEligibility(jobID: jobID)
        if eligibility == .sideEffectUnknown {
            throw JobRecoveryError.manualPrintResolutionRequired(jobID)
        }
        guard eligibility == .eligible else {
            if eligibility == .sessionCancelled {
                throw JobRecoveryError.sessionCancelled(job.sessionID)
            }
            throw JobQueueStoreError.manualRetryRejected(jobID, eligibility)
        }
        guard claimSessionRecovery(job.sessionID) else {
            throw JobRecoveryError.retryAlreadyInProgress(job.sessionID)
        }
        defer {
            releaseSessionRecovery(job.sessionID, scheduleReconciliation: true)
        }

        var manifest: SessionManifest
        do {
            manifest = try await manifestStore.load(sessionID: job.sessionID)
        } catch {
            throw JobRecoveryError.manifestNotFound(job.sessionID)
        }

        if manifest.status == .cancelled {
            _ = try? await jobQueue.cancelAndQuiesceJobs(sessionID: job.sessionID)
            throw JobRecoveryError.manifestCancelled(job.sessionID)
        }
        if FinalizationPlan.make(from: manifest) == nil {
            manifest = try await recoveryService.prepareFinalizationPlanForRecovery(for: manifest)
            if currentManifestID == job.sessionID {
                currentManifest = manifest
            }
        }
        let currentJob = jobQueue.jobs.first(where: { $0.id == jobID }) ?? job
        guard let plan = FinalizationPlan.make(from: manifest),
              plan.authorizes(currentJob, for: manifest) else {
            throw JobRecoveryError.obsoleteTransaction(job.id)
        }

        var restoredManifest: SessionManifest?
        let isRequired = !job.kind.isOptional
        if isRequired {
            switch manifest.status {
            case .failed:
                let restored = try await manifestStore.transition(
                    sessionID: job.sessionID,
                    allowedFrom: [.failed]
                ) { durable in
                    durable.status = .finalizing
                    durable.lastError = nil
                }
                restoredManifest = restored
                if currentManifestID == job.sessionID {
                    currentManifest = restored
                }
            case .finalizing:
                break
            case .capturing, .completed, .cancelled:
                throw JobRecoveryError.manifestNotRetryable(job.sessionID, manifest.status)
            }
        }

        do {
#if DEBUG
            await beforeManualRetryQueueMutationForTesting?()
#endif
            try await jobQueue.retry(jobID: jobID)
        } catch {
            if restoredManifest != nil {
                do {
                    let rolledBack = try await manifestStore.transition(
                        sessionID: job.sessionID,
                        allowedFrom: [.finalizing]
                    ) { durable in
                        durable.status = .failed
                        durable.lastError = "Queue retry failed: \(error.localizedDescription)"
                    }
                    if currentManifestID == job.sessionID {
                        currentManifest = rolledBack
                    }
                } catch {
                    recoveryService.recordError("HIGH SEVERITY: Manifest rollback failed for \(job.sessionID): \(error.localizedDescription)")
                }
            }
            throw error
        }
    }

    @discardableResult
    func retryAllFailedJobs() async throws -> [SessionJob] {
        let requestedIDs = Set(jobQueue.jobs.filter {
            ManualJobRetryEligibility.evaluate($0) == .eligible
        }.map(\.id))
        guard !requestedIDs.isEmpty else { return [] }

        let eligibleCandidates = try await jobQueue.eligibleManualRetryJobs(jobIDs: requestedIDs)
        guard !eligibleCandidates.isEmpty else { return [] }

        let candidateSessionIDs = Set(eligibleCandidates.map(\.sessionID))
        let sessionsToClaim = Set(candidateSessionIDs.filter(claimSessionRecovery))
        guard !sessionsToClaim.isEmpty else { return [] }
        defer {
            for sessionID in sessionsToClaim {
                releaseSessionRecovery(sessionID, scheduleReconciliation: true)
            }
        }

        var retryJobIDs = Set<String>()
        var restoredSessionIDs = Set<String>()
        for sessionID in sessionsToClaim.sorted() {
            let sessionCandidates = eligibleCandidates.filter { $0.sessionID == sessionID }
            do {
                var manifest = try await manifestStore.load(sessionID: sessionID)
                if manifest.status == .cancelled {
                    _ = try? await jobQueue.cancelAndQuiesceJobs(sessionID: sessionID)
                    continue
                }
                if FinalizationPlan.make(from: manifest) == nil {
                    manifest = try await recoveryService.prepareFinalizationPlanForRecovery(for: manifest)
                    if currentManifestID == sessionID {
                        currentManifest = manifest
                    }
                }
                guard let plan = FinalizationPlan.make(from: manifest) else {
                    recoveryService.recordError("Retry skipped for \(sessionID): finalization transaction is missing.")
                    continue
                }
                let currentSessionCandidates = jobQueue.jobs.filter {
                    $0.sessionID == sessionID
                        && ManualJobRetryEligibility.evaluate($0) == .eligible
                }
                let activeCandidates = currentSessionCandidates.filter { plan.authorizes($0, for: manifest) }
                let obsoleteIDs = Set(sessionCandidates.map(\.id)).subtracting(activeCandidates.map(\.id))
                if !obsoleteIDs.isEmpty {
                    recoveryService.recordError("Retry skipped obsolete finalization jobs for \(sessionID): \(obsoleteIDs.sorted().joined(separator: ", ")).")
                }
                guard !activeCandidates.isEmpty else { continue }
                let hasRequiredCandidate = activeCandidates.contains { !$0.kind.isOptional }
                if hasRequiredCandidate {
                    switch manifest.status {
                    case .failed:
                        let restored = try await manifestStore.transition(
                            sessionID: sessionID,
                            allowedFrom: [.failed]
                        ) { durable in
                            durable.status = .finalizing
                            durable.lastError = nil
                        }
                        restoredSessionIDs.insert(sessionID)
                        if currentManifestID == sessionID {
                            currentManifest = restored
                        }
                    case .finalizing:
                        break
                    case .capturing, .completed, .cancelled:
                        recoveryService.recordError("Required retry skipped for session \(sessionID): manifest is \(manifest.status.rawValue).")
                        continue
                    }
                }
                retryJobIDs.formUnion(activeCandidates.map(\.id))
            } catch {
                recoveryService.recordError("Could not inspect/restore manifest \(sessionID): \(error.localizedDescription)")
            }
        }
        guard !retryJobIDs.isEmpty else { return [] }

        let result: ManualRetryBatchResult
        do {
            #if DEBUG
            await beforeManualRetryQueueMutationForTesting?()
            #endif
            result = try await jobQueue.retryAllFailed(jobIDs: retryJobIDs)
        } catch {
            for sessionID in restoredSessionIDs {
                await rollbackRetryManifest(sessionID: sessionID, message: error.localizedDescription)
            }
            throw error
        }

        for sessionID in restoredSessionIDs where !result.retried.contains(where: {
            $0.sessionID == sessionID && !$0.kind.isOptional
        }) {
            await rollbackRetryManifest(sessionID: sessionID, message: "No required queue job was durably requeued.")
        }
        for skipped in result.skipped {
            recoveryService.recordError("Manual retry skipped \(skipped.jobID): \(skipped.reason).")
        }
        return result.retried
    }

    private func rollbackRetryManifest(sessionID: String, message: String) async {
        do {
            let rolledBack = try await manifestStore.transition(
                sessionID: sessionID,
                allowedFrom: [.finalizing]
            ) { durable in
                durable.status = .failed
                durable.lastError = "Queue retry failed: \(message)"
            }
            if currentManifestID == sessionID {
                currentManifest = rolledBack
            }
        } catch {
            recoveryService.recordError("HIGH SEVERITY: Retry manifest rollback failed for \(sessionID): \(error.localizedDescription)")
        }
    }

    private func currentCloudDeliverySnapshot(enabledOverride: Bool? = nil) -> SessionCloudDeliverySnapshot? {
        guard enabledOverride ?? UserDefaults.standard.bool(forKey: "cloudUploadEnabled") else { return nil }
        return SessionCloudDeliverySnapshot(
            publicBaseURL: UserDefaults.standard.string(forKey: "publicBaseURL") ?? "",
            remoteBasePath: UserDefaults.standard.string(forKey: "cloudRemotePath")
                ?? CloudUploadConfiguration.defaultRemoteBasePath,
            sshHost: UserDefaults.standard.string(forKey: "cloudSSHHost") ?? ""
        )
    }

    private func currentDeliveryIntentSnapshot(
        updateGalleryEnabled: Bool? = nil,
        renderGIFEnabled: Bool? = nil,
        cloudUploadEnabled: Bool? = nil,
        automaticPrintEnabled: Bool? = nil
    ) -> SessionDeliveryIntentSnapshot {
        SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: cloudUploadEnabled
                ?? soakCloudUploadOverride
                ?? UserDefaults.standard.bool(forKey: "cloudUploadEnabled"),
            automaticPrintEnabled: automaticPrintEnabled
                ?? soakAutomaticPrintOverride
                ?? UserDefaults.standard.bool(forKey: "selphyAutoPrintAfterSession"),
            updateGalleryEnabled: updateGalleryEnabled,
            renderGIFEnabled: renderGIFEnabled
        )
    }

    private func handleNetworkPathChange(isSatisfied: Bool) {
        let previous = lastNetworkSatisfied
        lastNetworkSatisfied = isSatisfied
        if !isSatisfied {
            automaticCloudRetryTask?.cancel()
            return
        }
        guard shouldScheduleAutomaticCloudRetry(previous: previous, isSatisfied: isSatisfied) else { return }

        let now = Date()
        guard lastAutomaticCloudRetryAt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        automaticCloudRetryTask?.cancel()
        automaticCloudRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, self.lastNetworkSatisfied == true else { return }
            self.lastAutomaticCloudRetryAt = Date()
            self.automaticCloudRetryTask = nil
            await self.retryFailedCloudUploadsSafely()
        }
    }

    private func retryFailedCloudUploadsSafely(sessionIDs requestedSessionIDs: Set<String>? = nil) async {
        let sessionIDs = requestedSessionIDs ?? Set(jobQueue.jobs.compactMap { job in
            job.kind == .cloudUpload
                && job.status == .failed
                && job.lastFailureDisposition == .retryable
                ? job.sessionID
                : nil
        })

        for sessionID in sessionIDs.sorted() {
            guard claimSessionRecovery(sessionID) else {
                deferredAutomaticCloudRetrySessionIDs.insert(sessionID)
                continue
            }
            do {
                defer { releaseSessionRecovery(sessionID, scheduleReconciliation: true) }
                var manifest = try await manifestStore.load(sessionID: sessionID)
                guard manifest.status != .cancelled else { continue }
                if FinalizationPlan.make(from: manifest) == nil {
                    manifest = try await recoveryService.prepareFinalizationPlanForRecovery(for: manifest)
                }
                guard let plan = FinalizationPlan.make(from: manifest),
                      plan.jobKinds.contains(.cloudUpload) else { continue }
                _ = try await jobQueue.retryFailedCloudUploads(
                    sessionIDs: [sessionID],
                    finalizationTransactionIDs: [sessionID: plan.transactionID]
                )
            } catch {
                recoveryService.recordError("Automatic cloud retry was skipped for \(sessionID): \(error.localizedDescription)")
            }
        }
    }

    private func sendExperienceCatalog() {
        guard let catalog = experienceCatalog, let document = activeExperienceDocument else { return }
        multipeer.sendControl(.eventExperienceCatalog(catalog: catalog))
        let templates = document.templates
            .filter(\.isEnabled)
            .sorted { $0.sortOrder < $1.sortOrder }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let previewData: [String: Data]
            do {
                previewData = try await self.experienceStore.readTemplatePreviews(
                    eventID: document.eventID,
                    templates: templates
                )
            } catch {
                self.startupComponents[.eventExperienceStore] = StartupComponentHealth(
                    status: .degraded,
                    detail: "Template previews are unavailable: \(error.localizedDescription)"
                )
                self.errorMessage = "Template previews could not load: \(error.localizedDescription)"
                return
            }
            for template in templates {
                guard let data = previewData[template.id] else {
                    self.errorMessage = "Template preview unavailable: \(template.id)"
                    continue
                }
                guard data.count <= BoothAssetTransfer.maximumAssetBytes else {
                    self.errorMessage = "Template preview is too large: \(template.id)"
                    continue
                }
                let reference = self.makeAssetReference(
                    data: data,
                    assetID: template.id,
                    sessionID: nil,
                    revision: document.revision,
                    kind: .templatePreview
                )
                _ = self.sendAsset(data: data, reference: reference)
            }
        }
    }

    private func makeAssetReference(
        data: Data,
        assetID: String,
        sessionID: String?,
        revision: String,
        kind: BoothAssetKind
    ) -> BoothAssetReference {
        BoothAssetReference(
            assetID: assetID,
            sessionID: sessionID,
            revision: revision,
            kind: kind,
            byteCount: data.count,
            sha256: Data(SHA256.hash(data: data))
        )
    }

    @discardableResult
    private func sendAsset(data: Data, reference: BoothAssetReference) -> Bool {
        assetSources[reference] = data
        guard connectionStatus.isAssetChannelReady else { return false }
        guard data.count <= BoothAssetTransfer.maximumAssetBytes else {
            errorMessage = "Asset could not be prepared for transfer: \(reference.assetID)"
            return false
        }
        let transport = multipeer
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await transport.sendAsset(data: data, reference: reference) else {
                self.errorMessage = "Asset transfer is unavailable: \(reference.assetID)"
                return
            }
        }
        return true
    }

    private func sendReviewAsset(
        context: SessionMessageContext,
        photoIndex: Int,
        data: Data
    ) {
        let reference = makeAssetReference(
            data: data,
            assetID: "review-\(context.sessionID)-\(photoIndex)-\(context.sequence)",
            sessionID: context.sessionID,
            revision: "review-v1",
            kind: .reviewImage
        )
        sessionAssetReferences[photoIndex] = reference
        assetSources[reference] = data
        multipeer.sendControl(.shotCapturedAsset(context: context, index: photoIndex, asset: reference))
        _ = sendAsset(data: data, reference: reference)
    }

    private func makeEventSnapshot(_ event: BoothEvent) -> BoothEventSnapshot {
        BoothEventSnapshot(
            id: event.id,
            name: event.name,
            photoCount: event.photoCount,
            countdownSeconds: event.countdownSeconds,
            canvasWidth: event.canvasWidth,
            canvasHeight: event.canvasHeight,
            framePNGURL: event.framePNGPath.flatMap { appSupportDir()?.appendingPathComponent($0) },
            slots: event.slots.sorted { $0.zOrder < $1.zOrder }.map {
                SharedPhotoSlot(
                    id: $0.id,
                    normalizedRect: CGRect(x: $0.normX, y: $0.normY, width: $0.normW, height: $0.normH),
                    rotation: $0.rotation,
                    zOrder: $0.zOrder,
                    photoIndex: $0.photoIndex
                )
            }
        )
    }

    private func defaultSelection(for document: EventExperienceDocument) -> CustomerSessionSelection {
        CustomerSessionSelection(
            eventID: document.eventID,
            experienceRevision: document.revision,
            templateID: document.defaultTemplateID,
            filterID: document.defaultFilterID,
            language: document.defaultCustomerLanguage
        )
    }

    var externalSelectionRequired: Bool {
        guard let catalog = experienceCatalog else { return false }
        return (catalog.templates.count > 1 && catalog.guestTemplateSelectionEnabled)
            || (catalog.allowedFilterIDs.count > 1 && catalog.guestFilterSelectionEnabled)
            || catalog.guestLanguageSelectionEnabled
    }

    func beginExternalExperienceSelection() {
        guard CustomerDisplayWorkflow.canApply(.begin, in: stateMachine.phase)
                || CustomerDisplayWorkflow.canApply(.back, in: stateMachine.phase) else { return }
        guard let document = activeExperienceDocument else { return }
        let selection = defaultSelection(for: document)
        externalSelection = CustomerSessionSelectionDraft(
            eventID: selection.eventID,
            experienceRevision: selection.experienceRevision,
            templateID: selection.templateID,
            filterID: selection.filterID,
            language: selection.language
        )
        stateMachine.beginSelectingExperience()
    }

    func confirmExternalExperienceSelection() {
        guard CustomerDisplayWorkflow.canApply(.confirmSelection, in: stateMachine.phase) else { return }
        guard let catalog = experienceCatalog,
              let template = catalog.templates.first(where: { $0.id == externalSelection.templateID }) else { return }
        stateMachine.config = EventConfig(
            eventID: catalog.eventID,
            eventName: catalog.eventName,
            photoCount: template.photoCount,
            countdownSeconds: activeEvent?.countdownSeconds ?? 5,
            templateID: template.id,
            templateName: template.name,
            selectedFilterID: externalSelection.filterID,
            customerLanguage: externalSelection.language,
            experienceRevision: catalog.revision,
            gifQualityPreset: activeExperienceDocument?.gifQualityPreset ?? .balanced
        )
        stateMachine.setReadyToStart()
    }

    private func selectedTemplateFrameURL(_ template: EventTemplateDefinition, eventID: String) -> URL? {
        guard let fileName = template.frameFileName else { return nil }
        return appSupportDir()?
            .appendingPathComponent("EventExperiences", isDirectory: true)
            .appendingPathComponent(eventID, isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(template.id, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private func selectedTemplateForegroundOverlayURL(_ template: EventTemplateDefinition, eventID: String) -> URL? {
        guard let fileName = template.foregroundOverlayFileName else { return nil }
        return appSupportDir()?
            .appendingPathComponent("EventExperiences", isDirectory: true)
            .appendingPathComponent(eventID, isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(template.id, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private func makePresentation(
        sessionID: String,
        config: EventConfig,
        document: EventExperienceDocument
    ) async -> SessionPresentation {
        pendingPromptAssets = [:]
        var prompts: [SessionPromptPresentation] = []
        for prompt in config.posePrompts {
            let imageData: Data?
            var imageAsset: BoothAssetReference?
            if let assetID = prompt.assetID,
               let data = try? await experienceStore.readPromptImage(eventID: document.eventID, fileName: assetID) {
                imageData = sessionPromptImageData(data)
                if let imageData {
                    let reference = makeAssetReference(
                        data: imageData,
                        assetID: "prompt-\(sessionID)-\(prompt.id)",
                        sessionID: sessionID,
                        revision: document.revision,
                        kind: .promptImage
                    )
                    imageAsset = reference
                    pendingPromptAssets[reference.assetID] = (reference, imageData)
                }
            } else {
                imageData = nil
            }
            prompts.append(SessionPromptPresentation(
                promptID: prompt.id,
                photoIndex: prompt.photoIndex,
                title: prompt.title.value(for: config.customerLanguage),
                subtitle: localizedOptional(prompt.subtitle, language: config.customerLanguage),
                imageData: imageData,
                imageAsset: imageAsset
            ))
        }
        return SessionPresentation(
            sessionID: sessionID,
            language: config.customerLanguage,
            templateDisplayName: config.templateName.value(for: config.customerLanguage),
            filterID: config.selectedFilterID,
            prompts: prompts
        )
    }

    private func sessionPromptImageData(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 768,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let jpeg = jpegData(from: image, quality: 0.82),
              jpeg.count <= 250_000 else { return nil }
        return jpeg
    }

    private func presentation(for config: EventConfig, sessionID: String) -> SessionPresentation {
        SessionPresentation(
            sessionID: sessionID,
            language: config.customerLanguage,
            templateDisplayName: config.templateName.value(for: config.customerLanguage),
            filterID: config.selectedFilterID,
            prompts: config.posePrompts.map {
                SessionPromptPresentation(
                    promptID: $0.id,
                    photoIndex: $0.photoIndex,
                    title: $0.title.value(for: config.customerLanguage),
                    subtitle: localizedOptional($0.subtitle, language: config.customerLanguage),
                    imageData: nil
                )
            }
        )
    }

    // MARK: - External display viewer

    var customerDisplayAuthority: CustomerDisplayAuthority {
        CustomerDisplayAuthority.evaluate(
            isAuthenticatedIPadConnected: isAuthenticatedIPadConnected && connectionStatus.isPreviewChannelConnected,
            isExternalViewerActive: isExternalViewerActive
        )
    }

    var isCustomerDisplayReady: Bool {
        customerDisplayAuthority.isCustomerDisplayReady
    }

    private var isAuthenticatedIPadConnected: Bool {
        guard case .connected = connectionStatus.state else { return false }
        guard multipeer is NetworkBoothTransport else { return true }
        return connectionStatus.isPeerAuthenticated
            && connectionStatus.peerID == connectionStatus.preferredPeerID
    }

    func refreshExternalScreens() {
        externalScreens = NSScreen.screens.filter { $0 != NSScreen.main }
        if let window = externalDisplayWindow,
           let screen = window.screen,
           !NSScreen.screens.contains(screen) {
            hideExternalViewer()
        }
    }

    func showExternalViewer(on screen: NSScreen) {
        hideExternalViewer()
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary, .stationary, .ignoresCycle]
        window.contentView = NSHostingView(rootView: ExternalDisplayView()
            .environment(self)
            .environment(stateMachine))
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        externalDisplayWindow = window
    }

    func hideExternalViewer() {
        externalDisplayWindow?.close()
        externalDisplayWindow = nil
    }

    func shutdown() {
        cancelCountdown()
        multipeer.disconnect()
        capture.stop()
        jobQueue.stop()
        endEventActivity()
        Task { await server.stop() }
    }

    private func updateEventActivity() {
        guard activeEvent != nil else {
            endEventActivity()
            return
        }
        guard eventActivity == nil else { return }
        eventActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "PRC PhotoBooth active event"
        )
    }

    private func endEventActivity() {
        guard let eventActivity else { return }
        ProcessInfo.processInfo.endActivity(eventActivity)
        self.eventActivity = nil
    }

    func pauseBooth() {
        isBoothPaused = true
        multipeer.sendControl(.boothPaused(isPaused: true))
    }

    func resumeBooth() {
        isBoothPaused = false
        multipeer.sendControl(.boothPaused(isPaused: false))
    }

    // MARK: - Camera permission (M10)

    func checkCameraPermission() async {
#if DEBUG
        if capture.demoMode {
            cameraPermissionGranted = true
            if !capture.isRunning { startCamera() }
            return
        }
#endif
        if cameraSourceKind == .dslr {
            // ImageCaptureCore owns DSLR access. Do not gate tethered still
            // capture on AVFoundation's unrelated camera permission.
            cameraPermissionGranted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraPermissionGranted = true
        case .notDetermined:
            cameraPermissionGranted = await AVCaptureDevice.requestAccess(for: .video)
            if cameraPermissionGranted { startCamera() }
        default:
            cameraPermissionGranted = false
        }
    }

    func startCamera() {
        do {
            previewQualityPolicy.setPreset(previewQualityPreset)
            applyPreviewQuality()
            try capture.start()
            startPreviewQualityMonitor()
            capture.onPreviewJPEG = { [weak self] jpeg in
                guard let self else { return }
                multipeer.sendPreviewFrame(jpeg)
            }
        } catch {
            errorMessage = "Camera error: \(error.localizedDescription)"
        }
    }

    private func applyPreviewQuality() {
        let profile = previewQualityPolicy.update(
            effectiveNetwork: connectionStatus.effectiveNetwork
        )
        capture.setPreviewQuality(profile)
        let requestedRate = previewFrameRate.rawValue
        capture.setPreviewFrameRate(profile.allows60FPS ? requestedRate : min(requestedRate, 30))
    }

    private func startPreviewQualityMonitor() {
        previewQualityTask?.cancel()
        previewQualityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.applyPreviewQuality()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func testEthernetConnection() {
        guard !isCaptureSessionActive, !ethernetTestInProgress else { return }
        ethernetTestInProgress = true
        ethernetProbeResult = nil
        ethernetTestTask?.cancel()
        ethernetTestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.ethernetTestInProgress = false
                self.ethernetTestTask = nil
            }
            if let networkTransport = self.multipeer as? NetworkBoothTransport {
                self.ethernetProbeResult = await networkTransport.probeEthernet()
            } else {
                self.ethernetProbeResult = EthernetProbeResult(
                    interfaceAvailable: false,
                    peerDiscovered: false,
                    controlConnected: false,
                    handshakeSucceeded: false,
                    previewConnected: false,
                    duration: 0,
                    error: "Production Ethernet transport is unavailable."
                )
            }
        }
    }

    func reconnectIPad() {
        guard !isCaptureSessionActive else { return }
        multipeer.restart()
    }

    func retryLANNow() {
        guard !isCaptureSessionActive else { return }
        _ = (multipeer as? NetworkBoothTransport)?.retryPreferredLANNow()
    }

    func copyDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.diagnosticsReport()
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    func exportDiagnostics() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await self.diagnosticsReport()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "PRC-PhotoBooth-diagnostics.txt"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Could not export diagnostics: \(error.localizedDescription)"
            }
        }
    }

    private func diagnosticsReport() async -> String {
        let printerDefaultStatus: String = switch printer.configuredPrinterStatus() {
            case .systemDefault: "System Default"
            case .unavailable(let name): "Unavailable: \(name)"
        }
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        let architecture = "unknown"
#endif
        let jobs = jobQueue.jobs
        let allEvents = await operationsEvents.load()
        let criticalJobs = jobs.filter {
            !$0.kind.isOptional && ($0.status == .pending || $0.status == .running || $0.status == .waitingRetry)
        }
        let discoveryDiagnostics = (multipeer as? NetworkBoothTransport)?.discoveryDiagnostics
        let snapshot = BoothDiagnosticsReport.Snapshot(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown",
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architecture,
            generatedAt: Date(),
            requestedNetwork: connectionStatus.requestedNetwork,
            effectiveNetwork: connectionStatus.effectiveNetwork,
            connectionState: connectionStatus.state,
            fallbackReason: connectionStatus.isFallbackActive
                ? connectionStatus.fallbackReason ?? "Active"
                : nil,
            peerName: connectionStatus.peerDisplayName,
            ethernetPath: connectionStatus.lanPathObservation,
            wifiPath: connectionStatus.wifiPathObservation,
            lanHandshake: connectionStatus.lanHandshake,
            controlConnected: {
                if case .connected = connectionStatus.state { return true }
                return false
            }(),
            previewConnected: connectionStatus.isPreviewChannelConnected,
            lastNetworkError: connectionStatus.lastNetworkError,
            previewDiagnostics: connectionStatus.previewDiagnostics,
            printerDefaultStatus: printerDefaultStatus,
            printerName: printerLabel,
            lastPrinterTest: printer.lastTestResult,
            printRequestCount: printer.printRequestCount,
            printSuccessCount: printer.printSuccessCount,
            printFailureCount: printer.printFailureCount,
            lastPrintError: printer.lastPrintError,
            preflightReadiness: preflight.readiness,
            preflightResults: preflight.results,
            authenticated: connectionStatus.isPeerAuthenticated,
            reconnectCount: allEvents.filter { $0.kind == .transportReconnectSucceeded }.count,
            heartbeatTimeoutCount: allEvents.filter { $0.kind == .heartbeatTimedOut }.count,
            controlSendFailureCount: allEvents.filter { $0.kind == .controlSendFailed || $0.kind == .controlPayloadRejected }.count,
            queuePendingCount: jobs.filter { $0.status == .pending }.count,
            queueRunningCount: jobs.filter { $0.status == .running }.count,
            queueRetryingCount: jobs.filter { $0.status == .waitingRetry }.count,
            queueFailedCount: jobs.filter { $0.status == .failed }.count,
            oldestCriticalJobAge: criticalJobs.map { Date().timeIntervalSince($0.createdAt) }.max(),
            recentEvents: Array(allEvents.suffix(50)),
            discoveryDiagnostics: discoveryDiagnostics
        )
        return BoothDiagnosticsReport.make(snapshot)
    }

    private func attemptPendingLANRecoveryIfIdle() {
        (multipeer as? NetworkBoothTransport)?.attemptPendingLANRecoveryIfIdle()
    }

    func setMirrored(_ isMirrored: Bool) {
        capture.camera.isMirrored = isMirrored
        multipeer.sendControl(.setMirrored(isMirrored: isMirrored))
    }

    func connectDSLR() {
        cameraSourceKind = .dslr
        capture.usesDSLR = false
        choosePreviewDeviceForDSLR()
        Task { @MainActor [weak self] in
            // External camera enumeration can lag behind USB session open; retry briefly.
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(500))
                self?.choosePreviewDeviceForDSLR()
                if let self,
                   self.capture.camera.availableDevices.contains(where: {
                       $0.id == self.capture.camera.selectedDeviceID && $0.kind != .builtIn
                   }) {
                    break
                }
            }
        }
        do {
            try capture.startDSLR()
        } catch {
            errorMessage = "DSLR connect failed: \(error.localizedDescription)"
            capture.usesDSLR = false
        }
    }

    func disconnectDSLR() {
        capture.stopDSLR()
        capture.usesDSLR = false
    }

    func testCameraCapture() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard stateMachine.phase == .idle || stateMachine.phase == .readyToStart else {
                errorMessage = "Camera test is unavailable during an active session."
                return
            }
            do {
                _ = try await capture.captureDiagnosticStill()
                errorMessage = nil
            } catch {
                errorMessage = "Test capture failed: \(error.localizedDescription)"
            }
        }
    }

    func runSafePreflight() async {
        printer.refreshPrinters()
        attemptPendingLANRecoveryIfIdle()
        let context = await makePreflightContext()
        await preflight.runSafeChecks(using: context)
    }

    func runFullPreflight(runPrinterTest: Bool) async {
        let context = await makePreflightContext()
        await preflight.runFullPreflight(
            using: context,
            runPrinterTest: runPrinterTest,
            cameraTest: { [weak self] in
                guard let self else { return }
                guard self.stateMachine.phase == .idle || self.stateMachine.phase == .readyToStart else {
                    throw CameraError.captureInProgress
                }
                _ = try await self.capture.captureDiagnosticStill()
            },
            printerTest: { [weak self] in
                guard let self else { throw CancellationError() }
                return try await self.printer.printTestPage()
            }
        )
    }

    private func makePreflightContext() async -> BoothPreflightContext {
        let serverStatus = await server.statusSnapshot()
        let serverHealthy = await localServerHealthCheck(status: serverStatus)
        let ipadConnected = isAuthenticatedIPadConnected
        let output = picturesOutputDir()
        let capacity = output.flatMap { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity }.map(Int64.init)
        let jobs = jobQueue.jobs
        let controlChannelConnected: Bool = {
            guard case .connected = connectionStatus.state else { return false }
            return multipeer is NetworkBoothTransport ? connectionStatus.isPeerAuthenticated : true
        }()
        let criticalJobs = jobs.filter {
            !$0.kind.isOptional && ($0.status == .pending || $0.status == .running || $0.status == .waitingRetry)
        }
        let requiredFailed = jobs.contains {
            !$0.kind.isOptional && $0.status == .failed
        }
        let optionalPendingOrFailed = jobs.contains {
            $0.kind.isOptional && ($0.status == .waitingRetry || $0.status == .failed)
        }
        let cloudUploadEnabled = UserDefaults.standard.bool(forKey: "cloudUploadEnabled")
        let cloudSetupComplete = cloudSSHSetup.state == .complete
        let cloudConnectivityPassed = cloudUploadEnabled && cloudSetupComplete
            ? await cloudSSHSetup.checkConnection()
            : false
        let experienceStatus: PreflightCheckStatus = activeEvent == nil
            ? .skipped
            : activeExperienceDocument == nil ? .failed : .passed
        let experienceDetail = activeEvent == nil
            ? "Skipped because no event is active."
            : activeExperienceDocument == nil ? "The event experience document is unavailable." : "Experience document is loaded and validated."
        let templateStatus: (PreflightCheckStatus, String) = {
            guard let document = activeExperienceDocument else {
                return (.skipped, "Skipped until an experience document is available.")
            }
            let valid = document.templates.allSatisfy { template in
                !template.slots.isEmpty
                    && (0..<template.photoCount).allSatisfy { index in
                        template.slots.contains(where: { $0.photoIndex == index })
                    }
            }
            return valid
                ? (.passed, "Enabled template slots are valid.")
                : (.failed, "An enabled template has invalid capture slots.")
        }()
        let filterValid: Bool
        if let document = activeExperienceDocument {
            var valid = await filterPipeline.validate(document.defaultFilterID)
            for filter in document.allowedFilterIDs {
                let filterIsValid = await filterPipeline.validate(filter)
                valid = valid && filterIsValid
            }
            filterValid = valid
        } else {
            filterValid = true
        }
        let filterStatus: (PreflightCheckStatus, String) = activeExperienceDocument == nil
            ? (.skipped, "Skipped until filter settings are available.")
            : filterValid
                ? (.passed, "Configured filters passed synthetic-image validation.")
                : (.failed, "A configured filter failed synthetic-image validation.")
        let galleryStatus: (PreflightCheckStatus, String) = {
            guard let document = activeExperienceDocument, document.gallery.mode != .disabled else {
                return (.skipped, "Gallery is disabled.")
            }
            do {
                let directory = Self.appSupportRootURL().appendingPathComponent("Gallery/Events", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return (.passed, "Gallery storage is writable.")
            } catch {
                return (.warning, "Gallery storage warning: \(error.localizedDescription)")
            }
        }()
        let printerConfigured: Bool = {
            switch printer.configuredPrinterStatus() {
            case .systemDefault: return true
            case .unavailable: return false
            }
        }()
        var startupHealth = startupComponents
        if let persistenceError = store.lastPersistenceError {
            startupHealth[.dataStore] = StartupComponentHealth(
                status: .unavailable,
                detail: "Persistent event data is unavailable: \(persistenceError)"
            )
        }
        if let queueError = jobQueue.lastQueueError {
            startupHealth[.jobQueue] = StartupComponentHealth(
                status: .unavailable,
                detail: "Persistent job queue is unavailable: \(queueError)"
            )
        }
        return BoothPreflightContext(
            event: activeEvent?.toEventConfig(),
            eventExperienceStatus: experienceStatus,
            eventExperienceDetail: experienceDetail,
            templateAssetsStatus: templateStatus.0,
            templateAssetsDetail: templateStatus.1,
            filterPipelineStatus: filterStatus.0,
            filterPipelineDetail: filterStatus.1,
            galleryStorageStatus: galleryStatus.0,
            galleryStorageDetail: galleryStatus.1,
            cameraPermissionGranted: cameraPermissionGranted,
            cameraConnected: selectedCaptureSourceReady,
            cameraSourceKind: cameraSourceKind,
            previewPermissionGranted: cameraPermissionGranted,
            previewConnected: capture.isRunning,
            previewRequired: false,
            customerDisplayReady: isAuthenticatedIPadConnected && connectionStatus.isPreviewChannelConnected,
            ipadConnected: ipadConnected,
            controlChannelConnected: controlChannelConnected,
            ipadPreviewChannelConnected: connectionStatus.isPreviewChannelConnected,
            secureTransportReady: connectionStatus.isSecureChannelEstablished,
            assetChannelConnected: connectionStatus.isAssetChannelConnected,
            assetChannelVerified: connectionStatus.isAssetChannelVerified,
            lastControlActivityAt: connectionStatus.lastControlActivityAt,
            reconnectInProgress: connectionStatus.isReconnectInProgress,
            reconnectAttempt: connectionStatus.reconnectAttempt,
            requestedNetwork: connectionStatus.requestedNetwork,
            effectiveNetwork: connectionStatus.effectiveNetwork,
            wifiPathAvailable: connectionStatus.isWiFiPathAvailable,
            lanPathAvailable: connectionStatus.isLANPathAvailable,
            networkFallbackActive: connectionStatus.isFallbackActive,
            outputFolderURL: output,
            availableDiskBytes: capacity,
            localServerStatus: serverStatus,
            localServerHealthPassed: serverHealthy,
            localIPAddress: LocalWebServer.lanIPAddress(selection: guestDeliveryInterfaceSelection),
            guestDeliveryResolution: LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection),
            runtimeDirectoryURL: Self.runtimeDirectoryURL(),
            runtimePersistenceAvailable: startupComponents[.runtimeDirectory]?.status == .ready,
            queuePersistenceAvailable: jobQueue.lastQueueError == nil,
            unfinishedCaptureSession: recoveryService.recoverableCaptureSession != nil,
            requiredJobFailed: requiredFailed || jobs.contains(where: { !$0.kind.isOptional && $0.status == .cancelled }),
            optionalJobPendingOrFailed: optionalPendingOrFailed,
            queuePendingCount: jobs.filter { $0.status == .pending }.count,
            queueRunningCount: jobs.filter { $0.status == .running }.count,
            queueRetryingCount: jobs.filter { $0.status == .waitingRetry }.count,
            queueFailedCount: jobs.filter { $0.status == .failed }.count,
            oldestCriticalJobAge: criticalJobs.map { max(0, Date().timeIntervalSince($0.createdAt)) }.max(),
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP"),
            publicBaseURL: UserDefaults.standard.string(forKey: "publicBaseURL"),
            cloudSetupComplete: cloudSetupComplete,
            cloudConnectivityPassed: cloudConnectivityPassed,
            automaticPrintingEnabled: UserDefaults.standard.bool(forKey: "selphyAutoPrintAfterSession"),
            printerConfigured: printerConfigured,
            printerTestResult: printer.lastTestResult,
            startupComponents: startupHealth
        )
    }

    var selectedCaptureSourceReady: Bool {
        switch cameraSourceKind {
        case .avFoundation:
            return cameraPermissionGranted && capture.isRunning
        case .dslr:
            return capture.dslr.isRunning && capture.dslr.isPTPHealthy
        }
    }

    private func localServerHealthCheck(status: LocalWebServerStatus) async -> Bool {
        guard case .ready(let port) = status.state else { return false }
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func handleDSLRConnectionStateChanged() {
        if capture.dslr.isRunning, !wasDSLRConnected {
            recordOperation(hasSeenDSLRConnection ? .cameraReconnected : .cameraConnected)
        } else if !capture.dslr.isRunning, wasDSLRConnected {
            recordOperation(.cameraDisconnected)
        }
        if capture.dslr.isRunning, hasSeenDSLRConnection, !wasDSLRConnected {
            cameraReconnectCount += 1
        }
        if capture.dslr.isRunning { hasSeenDSLRConnection = true }
        wasDSLRConnected = capture.dslr.isRunning
        if capture.dslr.isRunning {
            if cameraSourceKind == .dslr { capture.usesDSLR = true }
            choosePreviewDeviceForDSLR()
            return
        }
        capture.usesDSLR = false
    }

    private func choosePreviewDeviceForDSLR() {
        let preferredName = capture.dslr.selectedDeviceName?.lowercased()
        let candidates = capture.camera.availableDevices.filter { $0.kind != .builtIn }
        guard !candidates.isEmpty else { return }

        if let preferredName,
           let exact = candidates.first(where: { $0.name.lowercased().contains(preferredName) }) {
            capture.camera.selectedDeviceID = exact.id
            return
        }

        if let sony = candidates.first(where: { $0.name.lowercased().contains("sony") }) {
            capture.camera.selectedDeviceID = sony.id
            return
        }

        if capture.camera.selectedDeviceID == nil || !candidates.contains(where: { $0.id == capture.camera.selectedDeviceID }) {
            capture.camera.selectedDeviceID = candidates[0].id
        }
    }

    // MARK: - Session control

    private func sendSessionStartResult(
        requestID: UUID?,
        result: CustomerSessionStartResult
    ) {
        guard let requestID else { return }
        multipeer.sendControl(.customerSessionStartResult(requestID: requestID, result: result))
    }

    private func releaseSessionStart(_ requestID: UUID) {
        guard activeSessionStart?.requestID == requestID else { return }
        activeSessionStart = nil
    }

    func startSession(
        selection requestedSelection: CustomerSessionSelection? = nil,
        requestID requestedRequestID: UUID? = nil,
        origin: SessionOrigin = .normal,
        soakRunID: String? = nil,
        soakCycleIndex: Int? = nil
    ) {
        let startRequestID = requestedRequestID ?? UUID()
        let respondsToRequest = requestedRequestID != nil
        let customerLanguage = requestedSelection?.language ?? .english
        func startMessage(english: String, thai: String) -> String {
            LocalizedText(english: english, thai: thai).value(for: customerLanguage)
        }
        guard activeSessionStart == nil else {
            if respondsToRequest { sendSessionStartResult(requestID: requestedRequestID, result: .inProgress) }
            return
        }
        guard activeSoakRunID == nil
                || (origin == .soakTest && soakRunID == activeSoakRunID) else {
            let reason = "A production soak run currently owns the booth."
            errorMessage = reason
            sendSessionStartResult(requestID: requestedRequestID, result: .rejected(reason: reason))
            return
        }
        guard !isBoothPaused else {
            errorMessage = startMessage(
                english: "The booth is paused by the operator.",
                thai: "บูธถูกหยุดชั่วคราวโดยผู้ดูแล"
            )
            sendSessionStartResult(requestID: requestedRequestID, result: .rejected(reason: errorMessage!))
            return
        }
        guard currentSession == nil, finishedAwaitingCustomerAckSessionID == nil else {
            let reason = startMessage(
                english: "A session is already in progress.",
                thai: "มีเซสชันกำลังดำเนินการอยู่แล้ว"
            )
            errorMessage = reason
            sendSessionStartResult(requestID: requestedRequestID, result: .rejected(reason: reason))
            return
        }
        guard let event = activeEvent else {
            let reason = startMessage(
                english: "No active event is available.",
                thai: "ไม่มีอีเวนต์ที่กำลังใช้งาน"
            )
            errorMessage = reason
            sendSessionStartResult(requestID: requestedRequestID, result: .rejected(reason: reason))
            return
        }
        sessionLifecycleGeneration &+= 1
        let lifecycleGeneration = sessionLifecycleGeneration
        activeSessionStart = ActiveSessionStart(
            requestID: startRequestID,
            generation: lifecycleGeneration,
            sessionID: nil
        )
        func failBeforeTransaction(_ message: String, result: CustomerSessionStartResult = .rejected(reason: "")) {
            self.releaseSessionStart(startRequestID)
            self.errorMessage = message
            switch result {
            case .rejected:
                self.sendSessionStartResult(
                    requestID: requestedRequestID,
                    result: .rejected(reason: message)
                )
            default:
                self.sendSessionStartResult(requestID: requestedRequestID, result: result)
            }
        }
        reviewDecisionPending = false
        currentReviewStateToken = nil
        recentReviewRequests.removeAll(keepingCapacity: true)
        recentReviewRequestOrder.removeAll(keepingCapacity: true)
        activeReviewRequestID = nil
        sessionAssetReferences = [:]
        stripAssetReference = nil
        assetSources = [:]
        assetAssembler = BoothAssetAssembler()
        guard recoveryService.recoverableCaptureSession == nil else {
            failBeforeTransaction(startMessage(
                english: "Resume or discard the unfinished session in Operations.",
                thai: "ดำเนินการต่อหรือละทิ้งเซสชันที่ค้างอยู่ใน Operations"
            ))
            return
        }
        guard let document = activeExperienceDocument else {
            failBeforeTransaction(startMessage(
                english: "Event experience is still loading.",
                thai: "กำลังโหลดประสบการณ์ของอีเวนต์"
            ))
            return
        }
        let snapshot = makeEventSnapshot(event)
        let selection = requestedSelection ?? defaultSelection(for: document)
        let validated: ValidatedCustomerSelection
        let config: EventConfig
        do {
            validated = try CustomerSelectionValidator().validate(selection, against: document)
            config = try EventConfigBuilder().build(
                event: snapshot,
                document: document,
                selection: validated,
                galleryPath: document.gallery.mode == .disabled
                    ? nil
                    : "/e/\(document.gallery.eventToken)/"
            )
        } catch {
            // Always release the start latch so subsequent starts are not blocked (Finding 17).
            releaseSessionStart(startRequestID)
            if respondsToRequest {
                let reason = (error as? CustomerSelectionError)?.message(for: selection.language) ?? error.localizedDescription
                sendSessionStartResult(requestID: requestedRequestID, result: .rejected(reason: reason))
                if let selectionError = error as? CustomerSelectionError,
                   selectionError == .staleCatalog {
                    sendExperienceCatalog()
                }
            }
            errorMessage = (error as? CustomerSelectionError)?.message(for: .english) ?? error.localizedDescription
            return
        }
        guard isCustomerDisplayReady else {
            failBeforeTransaction(startMessage(
                english: "Connect an iPad or activate the external viewer before starting a session.",
                thai: "เชื่อมต่อ iPad หรือเปิดหน้าจอภายนอกก่อนเริ่มเซสชัน"
            ))
            return
        }
        if let health = startupComponents[.localServer], health.status == .unavailable {
            failBeforeTransaction(health.detail)
            return
        }
        guard startupComponents[.runtimeDirectory]?.status == .ready,
              startupComponents[.dataStore]?.status == .ready,
              jobQueue.lastQueueError == nil else {
            failBeforeTransaction(startMessage(
                english: "Required runtime persistence is unavailable. Resolve Preflight errors before starting.",
                thai: "พื้นที่จัดเก็บที่จำเป็นไม่พร้อมใช้งาน แก้ไขข้อผิดพลาด Preflight ก่อนเริ่ม"
            ))
            return
        }
        guard selectedCaptureSourceReady else {
            failBeforeTransaction(startMessage(
                english: "The selected camera is not ready.",
                thai: "กล้องที่เลือกยังไม่พร้อมใช้งาน"
            ))
            return
        }
        guard config.photoCount > 0,
              !config.slots.isEmpty,
              config.slots.allSatisfy({ $0.photoIndex >= 0 && $0.photoIndex < config.photoCount }),
              config.canvasWidth > 0,
              config.canvasHeight > 0,
              let outputRoot = picturesOutputDir() else {
            failBeforeTransaction(startMessage(
                english: "The active event layout is not valid.",
                thai: "เลย์เอาต์อีเวนต์ที่ใช้งานไม่ถูกต้อง"
            ))
            return
        }
        let session = store.startSession(for: event)
        if var activeSessionStart {
            activeSessionStart.sessionID = session.id
            self.activeSessionStart = activeSessionStart
        }
        session.photoCount = config.photoCount
        guard store.saveChanges() else {
            store.deleteSession(session)
            let detail = store.lastPersistenceError ?? "unknown error"
            failBeforeTransaction("Session persistence is unavailable: \(detail)", result: .persistenceFailed)
            return
        }
        let frameURL = selectedTemplateFrameURL(validated.template, eventID: event.id)
        let foregroundURL = selectedTemplateForegroundOverlayURL(validated.template, eventID: event.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.sessionLifecycleGeneration == lifecycleGeneration,
                  self.activeSessionStart?.requestID == startRequestID else {
                self.store.deleteSession(session)
                self.releaseSessionStart(startRequestID)
                return
            }
            var createdDirectory: URL?
            do {
                let descriptor = try workspace.createWorkspace(
                    sessionID: session.id,
                    eventName: config.eventName,
                    outputRoot: outputRoot,
                    startedAt: session.startedAt,
                    frameSourceURL: frameURL,
                    foregroundOverlaySourceURL: foregroundURL
                )
                createdDirectory = URL(fileURLWithPath: descriptor.absoluteDirectoryPath, isDirectory: true)
                let manifest = SessionManifest(
                    schemaVersion: SessionManifest.currentSchemaVersion,
                    id: session.id,
                    eventID: config.eventID,
                    eventName: config.eventName,
                    eventConfig: config,
                    startedAt: session.startedAt,
                    completedAt: nil,
                    cancelledAt: nil,
                    status: .capturing,
                    nextPhotoIndex: 0,
                    outputRootPath: descriptor.outputRootPath,
                    relativeDirectoryPath: descriptor.relativeDirectoryPath,
                    absoluteDirectoryPath: descriptor.absoluteDirectoryPath,
                    frameSnapshotFileName: descriptor.frameSnapshotFileName,
                    foregroundOverlaySnapshotFileName: descriptor.foregroundOverlaySnapshotFileName,
                    stripFileName: nil,
                    gifFileName: nil,
                    downloadToken: session.downloadToken,
                    shots: (0..<config.photoCount).map {
                        RuntimeShotRecord(
                            photoIndex: $0,
                            imageFileName: nil,
                            gifFrameFileNames: [],
                            retakeCount: 0,
                            acceptedAt: nil
                        )
                    },
                    cloudDelivery: currentCloudDeliverySnapshot(enabledOverride: soakCloudUploadOverride),
                    deliveryIntent: currentDeliveryIntentSnapshot(),
                    origin: origin,
                    soakRunID: soakRunID,
                    soakCycleIndex: soakCycleIndex,
                    lastError: nil,
                    updatedAt: Date()
                )
                try await manifestStore.create(manifest)
                guard self.sessionLifecycleGeneration == lifecycleGeneration,
                      self.activeSessionStart?.requestID == startRequestID else {
                    try? await manifestStore.delete(sessionID: manifest.id)
                    try? workspace.removeEntireSession(manifest: manifest)
                    store.deleteSession(session)
                    self.releaseSessionStart(startRequestID)
                    return
                }
                currentSession = session
                currentManifest = manifest
                currentManifestID = manifest.id
                retakeCounts = [:]
                gifFrames = [:]
                currentCaptureAttempt = nil
                currentFilteredReviewImages = [:]
                capture.resetStills()
                let presentation = await makePresentation(
                    sessionID: session.id,
                    config: config,
                    document: document
                )
                guard self.sessionLifecycleGeneration == lifecycleGeneration,
                      self.activeSessionStart?.requestID == startRequestID else {
                    throw CancellationError()
                }
                try workspace.savePresentationSnapshot(
                    presentation: presentation,
                    prompts: config.posePrompts,
                    workspace: descriptor
                )
                stateMachine.startSession(config: config, sessionID: session.id)
                currentSessionPresentation = presentation
                lastSessionPresentation = presentation
                recordOperation(.sessionStarted, sessionID: session.id)
                guard let startContext = nextSessionMessageContext(),
                      let preparedContext = nextSessionMessageContext() else {
                    throw NSError(domain: "PRCPhotoBooth.Session", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session identity could not be issued."])
                }
                let sessionID = session.id
                let authority = customerDisplayAuthority
                for asset in pendingPromptAssets.values {
                    assetSources[asset.reference] = asset.data
                }
                if authority.requiresIPadSetupSend {
                    multipeer.sendControl(.sessionStart(context: startContext))
                    multipeer.sendControl(.eventConfig(config: config))
                    multipeer.sendControl(.sessionPrepared(
                        config: config,
                        presentation: presentation,
                        context: preparedContext
                    )) { [weak self] outcome in
                        guard let self else { return }
                        guard outcome == .sent,
                              self.currentSession?.id == sessionID,
                              self.stateMachine.currentSessionID == sessionID else {
                            // Only show error if an iPad was expected (Finding 6).
                            if self.isAuthenticatedIPadConnected {
                                self.errorMessage = "The iPad did not receive session setup. Reconnect before retrying."
                            }
                            return
                        }
                        self.beginCountdown(photoIndex: 0)
                    }
                }
                // External-display-only: no iPad to acknowledge, begin countdown directly (Finding 6).
                if authority.shouldStartCountdownImmediatelyLocally {
                    beginCountdown(photoIndex: 0)
                }
                self.lastSessionStartRequestID = startRequestID
                self.lastSessionStartSessionID = sessionID
                self.releaseSessionStart(startRequestID)
                self.sendSessionStartResult(
                    requestID: requestedRequestID,
                    result: .accepted(sessionID: sessionID)
                )
            } catch {
                if let createdDirectory { try? FileManager.default.removeItem(at: createdDirectory) }
                if let persisted = try? await manifestStore.load(sessionID: session.id),
                   persisted.status == .capturing {
                    try? await manifestStore.delete(sessionID: session.id)
                }
                store.deleteSession(session)
                if currentSession?.id == session.id {
                    cancelCountdown()
                    currentSession = nil
                    currentManifest = nil
                    currentManifestID = nil
                    currentSessionPresentation = nil
                    lastSessionPresentation = nil
                    sessionAssetReferences = [:]
                    stripAssetReference = nil
                    assetSources = [:]
                    pendingPromptAssets = [:]
                    currentFilteredReviewImages = [:]
                    currentCaptureRecoveryStateToken = nil
                    currentReviewStateToken = nil
                    stateMachine.reset()
                }
                self.releaseSessionStart(startRequestID)
                if !(error is CancellationError) {
                    errorMessage = "Session start failed: \(error.localizedDescription)"
                    self.sendSessionStartResult(
                        requestID: requestedRequestID,
                        result: .persistenceFailed
                    )
                }
            }
        }
    }

    func productionSoakReadinessIssues(config: BoothSoakTestConfig) -> [String] {
        var issues: [String] = []
        if activeEvent == nil { issues.append("An active event is required.") }
        if !selectedCaptureSourceReady { issues.append("The selected physical camera is not ready.") }
        if !isCustomerDisplayReady { issues.append("Connect the paired iPad or activate the external customer display.") }
        if currentSession != nil || currentManifest != nil || activeSessionStart != nil
                || finishedAwaitingCustomerAckSessionID != nil {
            issues.append("Finish or cancel the active customer session before starting a production soak.")
        }
        if recoveryService.recoverableCaptureSession != nil {
            issues.append("Resolve the unfinished capture session before starting a production soak.")
        }
        if jobQueue.lastQueueError != nil { issues.append("The persistent job queue is unavailable.") }
        if jobQueue.jobs.contains(where: { $0.status == .pending || $0.status == .running || $0.status == .waitingRetry }) {
            issues.append("Wait for existing production jobs to settle before starting a soak.")
        }
        if jobQueue.jobs.contains(where: {
            $0.kind == .autoPrint && $0.lastFailureDisposition == .sideEffectUnknown
        }) {
            issues.append("Resolve the uncertain print outcome in Operations before starting a production soak.")
        }
        if startupComponents[.runtimeDirectory]?.status != .ready
                || startupComponents[.dataStore]?.status != .ready {
            issues.append("Runtime and session persistence must be healthy.")
        }
        guard let outputRoot = picturesOutputDir() else {
            issues.append("The production session output volume is unavailable.")
            return issues
        }
        do {
            try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
            let probe = outputRoot.appendingPathComponent(".soak-preflight-\(UUID().uuidString)")
            try Data([0x53]).write(to: probe, options: [.atomic])
            try FileManager.default.removeItem(at: probe)
        } catch {
            issues.append("The production session output volume is not writable: \(error.localizedDescription)")
        }
        if !isLocalServerReady {
            issues.append("The local download server is unavailable.")
        }

        let localAllowed = UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP")
        let localEndpoint = LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection).endpoint
        let publicBase = UserDefaults.standard.string(forKey: "publicBaseURL")
        let publicConfigured = ValidatedPublicGuestBaseURL(string: publicBase ?? "") != nil
        if localAllowed && localEndpoint == nil && !(config.testCloudUpload && publicConfigured) {
            issues.append("Trusted local HTTP is enabled, but the selected guest network is unavailable or ambiguous.")
        } else if !localAllowed && !(config.testCloudUpload && publicConfigured) {
            issues.append("Enable trusted local HTTP on one selected interface or enable cloud testing with a valid public HTTPS URL.")
        }
        if config.testCloudUpload {
            if !UserDefaults.standard.bool(forKey: "cloudUploadEnabled") {
                issues.append("Cloud testing uses the current production configuration; cloud upload is disabled in Settings.")
            }
            if !publicConfigured
                    || (UserDefaults.standard.string(forKey: "cloudSSHHost") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append("Cloud testing requires a valid public HTTPS URL and configured SSH host.")
            }
        }
        if config.enablePhysicalPrint {
            if case .unavailable = printer.configuredPrinterStatus() {
                issues.append("Physical print verification requires a configured printer.")
            }
            if !printer.isIdle {
                issues.append("Wait for the configured printer to become idle before enabling physical soak printing.")
            }
        }
        return issues
    }

    func beginAutomatedSoakRun(runID: String, config: BoothSoakTestConfig) throws {
        guard activeSoakRunID == nil else {
            throw BoothSoakTestError.productionRunUnavailable("another soak run already owns the booth")
        }
        let issues = productionSoakReadinessIssues(config: config)
        guard issues.isEmpty else {
            throw BoothSoakTestError.productionRunUnavailable(issues.joined(separator: " "))
        }
        activeSoakRunID = runID
    }

    func runAutomatedSoakCycle(
        runID: String,
        cycleIndex: Int,
        config: BoothSoakTestConfig,
        printEnabled: Bool
    ) async throws -> BoothAutomatedSoakCycleResult {
        guard activeSoakRunID == runID else {
            throw BoothSoakTestError.productionRunUnavailable("the soak run no longer owns the booth")
        }
        guard currentSession == nil, currentManifest == nil, finishedAwaitingCustomerAckSessionID == nil else {
            throw BoothSoakTestError.productionRunUnavailable("a previous session has not reached its safe boundary")
        }

        soakCloudUploadOverride = config.testCloudUpload
        soakAutomaticPrintOverride = printEnabled
        errorMessage = nil
        startSession(origin: .soakTest, soakRunID: runID, soakCycleIndex: cycleIndex)

        let sessionDeadline = Date().addingTimeInterval(45)
        var manifest: SessionManifest?
        while Date() < sessionDeadline {
            try Task.checkCancellation()
            if let currentManifest,
               currentManifest.origin == .soakTest,
               currentManifest.soakRunID == runID,
               currentManifest.soakCycleIndex == cycleIndex {
                manifest = currentManifest
                break
            }
            if let errorMessage, !errorMessage.isEmpty {
                throw BoothSoakTestError.productionRunUnavailable(errorMessage)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let startedManifest = manifest else {
            throw BoothSoakTestError.stageTimeout("session creation")
        }

        let completionDeadline = Date().addingTimeInterval(180)
        var finalizingAt: Date?
        var completedManifest: SessionManifest?
        var finalJobs: [SessionJob] = []
        while Date() < completionDeadline {
            try Task.checkCancellation()
            let latest = (try? await manifestStore.load(sessionID: startedManifest.id)) ?? currentManifest
            if let latest {
                if latest.status == .failed || latest.status == .cancelled {
                    if latest.status == .cancelled {
                        throw CancellationError()
                    }
                    throw BoothSoakTestError.productionRunUnavailable(
                        latest.lastError ?? "session entered \(latest.status.rawValue)"
                    )
                }
                if latest.status == .finalizing, finalizingAt == nil { finalizingAt = Date() }

                if case .review(let photoIndex) = stateMachine.phase,
                   currentManifest?.id == latest.id,
                   !reviewDecisionPending {
                    handleReviewDecision(photoIndex: photoIndex, action: .keep)
                }
                if case .captureRecovery = stateMachine.phase {
                    throw BoothSoakTestError.productionRunUnavailable(
                        currentManifest?.lastError ?? "camera capture entered recovery"
                    )
                }

                if latest.status == .completed,
                   let plan = FinalizationPlan.make(from: latest) {
                    let matching = jobQueue.jobs.filter { plan.authorizes($0, for: latest) }
                    let isTerminal = matching.count == plan.jobKinds.count && matching.allSatisfy {
                        $0.status == .succeeded || $0.status == .failed || $0.status == .cancelled
                    }
                    if isTerminal {
                        guard matching.allSatisfy({ $0.status == .succeeded }) else {
                            let failures = matching.filter { $0.status != .succeeded }
                                .map { "\($0.kind.rawValue): \($0.lastError ?? $0.status.rawValue)" }
                            throw BoothSoakTestError.productionRunUnavailable(failures.joined(separator: "; "))
                        }
                        completedManifest = latest
                        finalJobs = matching
                        break
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        guard let completedManifest else {
            throw BoothSoakTestError.stageTimeout("production finalization and queue drain")
        }
        if config.testCloudUpload,
           !finalJobs.contains(where: { $0.kind == .cloudUpload && $0.status == .succeeded }) {
            throw BoothSoakTestError.productionRunUnavailable("the configured cloud upload job did not succeed")
        }
        if printEnabled,
           !finalJobs.contains(where: { $0.kind == .autoPrint && $0.status == .succeeded }) {
            throw BoothSoakTestError.productionRunUnavailable("the scheduled physical print job did not succeed")
        }

        if !completedManifest.eventConfig.qrCodeElements.isEmpty {
            let localEndpoint = LocalWebServer.guestDeliveryEndpoint(
                selection: guestDeliveryInterfaceSelection,
                port: server.port
            ).endpoint
            let localBase = localEndpoint?.baseURL ?? ""
            _ = try SessionQRCodePayloadResolver.resolve(
                token: completedManifest.downloadToken,
                localBaseURL: localBase,
                publicBaseURL: completedManifest.cloudDelivery?.publicBaseURL,
                cloudUploadEnabled: completedManifest.deliveryIntent?.cloudUploadEnabled ?? false,
                allowTrustedLocalHTTP: UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP")
            )
        }

        var localDeliveryVerified = false
        if UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP"),
           let endpoint = LocalWebServer.guestDeliveryEndpoint(
                selection: guestDeliveryInterfaceSelection,
                port: server.port
            ).endpoint {
            guard let stripName = completedManifest.stripFileName else {
                throw BoothSoakTestError.productionRunUnavailable("the real strip output is missing")
            }
            let stripURL = URL(fileURLWithPath: completedManifest.absoluteDirectoryPath)
                .appendingPathComponent(stripName)
            let expectedBytes = try Data(contentsOf: stripURL)
            guard let guestURL = URL(string: "\(endpoint.baseURL)/s/\(completedManifest.downloadToken)/\(stripName)") else {
                throw BoothSoakTestError.productionRunUnavailable("the local guest URL is invalid")
            }
            let (downloadedBytes, response) = try await URLSession.shared.data(from: guestURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  downloadedBytes == expectedBytes else {
                throw BoothSoakTestError.productionRunUnavailable("local guest download did not match the rendered strip")
            }
            localDeliveryVerified = true
        } else if UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP"),
                  !finalJobs.contains(where: { $0.kind == .cloudUpload && $0.status == .succeeded }) {
            throw BoothSoakTestError.productionRunUnavailable("local guest delivery became ambiguous and no cloud delivery completed")
        }

        let captureLatencies = (completedManifest.captureAttempts ?? []).compactMap { attempt -> Double? in
            guard attempt.result == .success, let completedAt = attempt.completedAt else { return nil }
            return completedAt.timeIntervalSince(attempt.startedAt)
        }
        let renderLatency = finalJobs.first(where: { $0.kind == .renderStrip }).map {
            max(0, $0.updatedAt.timeIntervalSince($0.lastAttemptAt ?? $0.createdAt))
        }
        let queueDrain = finalizingAt.map { max(0, Date().timeIntervalSince($0)) }

        if config.autoCleanupWorkingFiles {
            try await cleanupCompletedSoakSession(completedManifest)
        } else if stateMachine.phase.isFinished {
            resetToIdleAfterCompletion()
        }
        soakCloudUploadOverride = nil
        soakAutomaticPrintOverride = nil
        return BoothAutomatedSoakCycleResult(
            captureLatencies: captureLatencies,
            renderLatency: renderLatency,
            queueDrainSeconds: queueDrain,
            localDeliveryVerified: localDeliveryVerified,
            cloudUploadVerified: finalJobs.contains { $0.kind == .cloudUpload && $0.status == .succeeded },
            physicalPrintVerified: finalJobs.contains { $0.kind == .autoPrint && $0.status == .succeeded },
            galleryUpdateVerified: finalJobs.contains { $0.kind == .updateGallery && $0.status == .succeeded }
        )
    }

    func endAutomatedSoakRun(runID: String) async {
        guard activeSoakRunID == runID else { return }
        if let manifest = currentManifest,
           manifest.origin == .soakTest,
           manifest.soakRunID == runID,
           (manifest.status == .capturing || manifest.status == .finalizing || manifest.status == .failed) {
            await cancelCurrentSession()
        }
        activeSoakRunID = nil
        soakCloudUploadOverride = nil
        soakAutomaticPrintOverride = nil
        if stateMachine.phase.isFinished { resetToIdleAfterCompletion() }
    }

    func cancelAutomatedSoakCycle(runID: String) async {
        guard activeSoakRunID == runID else { return }
        if activeSessionStart != nil {
            await cancelCurrentSession()
            return
        }
        guard let manifest = currentManifest,
              manifest.origin == .soakTest,
              manifest.soakRunID == runID,
              manifest.status == .capturing || manifest.status == .finalizing else { return }
        await cancelCurrentSession()
    }

    private func cleanupCompletedSoakSession(_ manifest: SessionManifest) async throws {
        guard manifest.origin == .soakTest,
              let runID = manifest.soakRunID,
              activeSoakRunID == runID,
              manifest.status == .completed else {
            throw BoothSoakTestError.productionRunUnavailable("refusing cleanup for a non-soak or incomplete session")
        }
        if manifest.deliveryIntent?.updateGalleryEnabled == true {
            try await galleryStore.removeSession(eventID: manifest.eventID, sessionID: manifest.id)
        }
        await server.unregisterToken(manifest.downloadToken)
        try workspace.removeEntireSession(manifest: manifest)
        try await jobQueue.removeCompletedSoakJobs(sessionID: manifest.id)
        try await manifestStore.delete(sessionID: manifest.id)
        if let session = store.fetchSession(id: manifest.id) { store.deleteSession(session) }
        await refreshServerRoutes()
        if stateMachine.phase.isFinished { resetToIdleAfterCompletion() }
    }

    func beginCountdown(photoIndex: Int) {
        let descriptor = CountdownDescriptor(
            photoIndex: photoIndex,
            captureAt: Date().addingTimeInterval(TimeInterval(stateMachine.config.countdownSeconds))
        )
        stateMachine.beginCountdown(photoIndex: photoIndex, captureAt: descriptor.captureAt)
        guard case .countdown(let index, _) = stateMachine.phase, index == photoIndex else { return }
        currentReviewStateToken = nil
        currentCaptureRecoveryStateToken = nil
        currentCountdown = descriptor
        if let context = nextSessionMessageContext() {
            multipeer.sendControl(.beginCountdown(context: context, descriptor: descriptor))
        }
        runCountdown(descriptor)
    }

    private func runCountdown(_ descriptor: CountdownDescriptor) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                stateMachine.updateCountdown(at: Date())
                guard descriptor.captureAt > Date() else {
                    currentCountdown = nil
                    countdownTask = nil
                    guard let sessionID = currentManifest?.id else { return }
                    sessionFlowOperations.start(
                        sessionID: sessionID,
                        kind: .capture
                    ) { [weak self] in
                        await self?.captureShot(photoIndex: descriptor.photoIndex)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        currentCountdown = nil
    }

    private func captureShot(photoIndex: Int) async {
        guard !Task.isCancelled,
              case .countdown(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              let sessionID = currentManifest?.id else { return }
        let lifecycleGeneration = sessionLifecycleGeneration
        let attempt = CaptureAttempt()
        currentCaptureAttempt = attempt
        recordOperation(.captureStarted, sessionID: currentManifest?.id, photoIndex: photoIndex)
        await recordCaptureAttempt(
            attempt,
            photoIndex: photoIndex,
            result: .failed,
            completedAt: nil,
            reason: "in_progress",
            receiveDuration: nil
        )
        guard sessionLifecycleGeneration == lifecycleGeneration,
              currentManifest?.id == sessionID else {
            currentCaptureAttempt = nil
            return
        }
        do {
            gifFrames[photoIndex] = capture.drainBufferForGIF()
            let image = try await capture.captureStill(for: photoIndex)
            let filtered = try await filterPipeline.apply(stateMachine.config.selectedFilterID, to: image)
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else {
                currentCaptureAttempt = nil
                return
            }
            currentFilteredReviewImages[photoIndex] = filtered
            guard let thumbData = capture.thumbnail(for: filtered) else {
                throw PhotoFilterError.failedToCreateOutput(stateMachine.config.selectedFilterID)
            }
            let context = nextSessionMessageContext()
            let reviewData: Data
            if let context {
                reviewData = try ReviewImageEncoder.encode(image: filtered, context: context, index: photoIndex)
            } else {
                reviewData = thumbData
            }
            stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: thumbData, reviewImageData: reviewData)
            if let context {
                currentReviewStateToken = ReviewStateToken(
                    sessionID: context.sessionID,
                    photoIndex: photoIndex,
                    revision: context.sequence,
                    authorityEpoch: context.authorityEpoch
                )
            }
            reviewDecisionPending = false
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .success,
                completedAt: Date(),
                reason: nil,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID,
                  stateMachine.phase == .review(photoIndex: photoIndex) else {
                currentCaptureAttempt = nil
                return
            }
            recordOperation(.captureSucceeded, sessionID: currentManifest?.id, photoIndex: photoIndex, duration: Date().timeIntervalSince(attempt.startedAt))
            currentCaptureAttempt = nil
            if let context { sendReviewAsset(context: context, photoIndex: photoIndex, data: reviewData) }
            updateStripPreview()
        } catch {
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else {
                currentCaptureAttempt = nil
                return
            }
            let summary = captureFailureSummary(photoIndex: photoIndex, error: error)
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .failed,
                completedAt: Date(),
                reason: error.localizedDescription,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            recordOperation(.captureFailed, sessionID: currentManifest?.id, photoIndex: photoIndex, duration: Date().timeIntervalSince(attempt.startedAt), reason: summary.reason.rawValue)
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else {
                currentCaptureAttempt = nil
                return
            }
            let persistSucceeded = await persistCaptureFailure(photoIndex: photoIndex, error: error)
            // Enter recovery regardless — the operator needs a way out (Finding 20).
            currentCaptureAttempt = nil
            stateMachine.enterCaptureRecovery(photoIndex: photoIndex, failure: summary)
            if !persistSucceeded {
                recoveryService.recordError(
                    "Capture failure for photo \(photoIndex) could not be persisted. "
                    + "Recovery UI is shown but the failure is not durable."
                )
            }
            currentReviewStateToken = nil
            reviewDecisionPending = false
            if let context = nextSessionMessageContext() {
                currentCaptureRecoveryStateToken = CaptureRecoveryStateToken(
                    sessionID: context.sessionID,
                    photoIndex: photoIndex,
                    revision: context.sequence,
                    authorityEpoch: context.authorityEpoch
                )
                multipeer.sendControl(.captureRecovery(context: context, photoIndex: photoIndex, failure: summary))
            }
        }
    }

    private func recordCaptureAttempt(
        _ attempt: CaptureAttempt,
        photoIndex: Int,
        result: CaptureAttemptResult,
        completedAt: Date?,
        reason: String?,
        receiveDuration: Double?
    ) async {
        guard let manifest = currentManifest,
              currentManifestID == manifest.id else { return }
        let lifecycleGeneration = sessionLifecycleGeneration
        let sessionID = manifest.id
        let record = CaptureAttemptRecord(
            id: attempt.id.uuidString,
            photoIndex: photoIndex,
            startedAt: attempt.startedAt,
            completedAt: completedAt,
            result: result,
            reason: reason,
            receiveDuration: receiveDuration
        )
        do {
            let saved = try await manifestStore.update(
                sessionID: sessionID,
                allowedStatuses: [.capturing]
            ) { durable in
                var records = durable.captureAttempts ?? []
                if let index = records.firstIndex(where: { $0.id == record.id }) {
                    records[index] = record
                } else {
                    records.append(record)
                }
                durable.captureAttempts = records
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else { return }
            currentManifest = saved
        } catch {
            recoveryService.recordError("Capture attempt could not be persisted: \(error.localizedDescription)")
            errorMessage = "Capture diagnostics could not be persisted: \(error.localizedDescription)"
        }
    }

    private func persistCaptureFailure(photoIndex: Int, error: Error) async -> Bool {
        guard let manifest = currentManifest,
              currentManifestID == manifest.id else { return false }
        let lifecycleGeneration = sessionLifecycleGeneration
        let sessionID = manifest.id
        let persistedErrorMessage = error.localizedDescription
        do {
            let saved = try await manifestStore.update(
                sessionID: sessionID,
                allowedStatuses: [.capturing]
            ) { durable in
                durable.lastError = persistedErrorMessage
                durable.nextPhotoIndex = photoIndex
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else { return false }
            currentManifest = saved
        } catch {
            recoveryService.recordError("Capture failure could not be persisted: \(error.localizedDescription)")
            return false
        }
        errorMessage = error.localizedDescription
        return true
    }

    private func captureFailureSummary(photoIndex: Int, error: Error) -> CaptureFailureSummary {
        let reason: CaptureFailureReason
#if DEBUG
        if let demoFailure = error as? DemoCaptureFailure {
            reason = demoFailure.reason
        } else {
            reason = captureFailureReason(for: error)
        }
#else
        reason = captureFailureReason(for: error)
#endif
        let previous = currentManifest?.shots.first(where: { $0.photoIndex == photoIndex })
        let hasOtherMissingPhoto = currentManifest?.shots.contains {
            $0.photoIndex != photoIndex && $0.imageFileName == nil
        } ?? false
        let canReceive = (capture.usesDSLR || capture.demoMode)
            && reason != .cameraDisconnected
        let message: String
        switch reason {
        case .cameraDisconnected:
            message = "The camera disconnected before the image arrived."
        case .cameraBusy:
            message = "The camera is busy. Please try the photo again."
        default:
            message = "The camera may have taken the photo, but the image did not reach the booth."
        }
        return CaptureFailureSummary(
            photoIndex: photoIndex,
            reason: reason,
            message: message,
            shutterLikelyFired: reason != .cameraBusy,
            canRetryReceive: canReceive,
            canUsePreviousPhoto: previous?.previousImageFileName != nil,
            canContinueSession: hasOtherMissingPhoto
        )
    }

    private func captureFailureReason(for error: Error) -> CaptureFailureReason {
        if let dslrError = error as? DSLRError,
           case .cameraDisconnected = dslrError {
            return .cameraDisconnected
        }
        let text = error.localizedDescription.lowercased()
        if text.contains("busy") { return .cameraBusy }
        if text.contains("timed out") || text.contains("timeout") { return .transferTimeout }
        if text.contains("decode") { return .decodeFailed }
        if text.contains("download") || text.contains("image received") { return .downloadFailed }
        if text.contains("ptp") { return .ptpFailure }
        return .unknown
    }

    private func updateStripPreview() {
        guard let manifest = currentManifest else { return }
        let config = manifest.eventConfig
        let framePNG = manifest.frameSnapshotFileName.flatMap {
            loadCGImage(from: URL(fileURLWithPath: manifest.absoluteDirectoryPath).appendingPathComponent($0))
        }
        let images = currentFilteredReviewImages
        let compositor = Compositor(config: config, framePNG: framePNG)
        let cloudUploadEnabled = manifest.deliveryIntent?.cloudUploadEnabled
            ?? (manifest.cloudDelivery != nil || UserDefaults.standard.bool(forKey: "cloudUploadEnabled"))
        let allowTrustedLocalHTTP = UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP")
        let localBaseURL = LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection)
            .endpoint?.baseURL ?? ""
        let qrPayload = config.qrCodeElements.isEmpty ? nil : try? SessionQRCodePayloadResolver.resolve(
            token: manifest.downloadToken,
            localBaseURL: localBaseURL,
            publicBaseURL: manifest.cloudDelivery?.publicBaseURL
                ?? UserDefaults.standard.string(forKey: "publicBaseURL"),
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )
        let expectedSessionID = manifest.id
        let expectedGeneration = sessionLifecycleGeneration
        Task.detached(priority: .utility) { [compositor, images, qrPayload] in
            let img = try? compositor.render(images: images, qrPayload: qrPayload)
            await MainActor.run { [weak self] in
                guard let self,
                      self.currentManifest?.id == expectedSessionID,
                      self.sessionLifecycleGeneration == expectedGeneration else {
                    return  // session changed — discard stale render (Finding 21)
                }
                self.currentStripPreview = img
            }
        }
    }

    func handleReviewDecision(photoIndex: Int, action: ReviewAction) {
        let customerAction: CustomerDisplayAction = action == .keep
            ? .keep(photoIndex: photoIndex)
            : .retake(photoIndex: photoIndex)
        guard !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { return }
        reviewDecisionPending = true
        switch action {
        case .keep:
            guard let sessionID = currentManifest?.id else {
                reviewDecisionPending = false
                return
            }
            sessionFlowOperations.start(sessionID: sessionID, kind: .reviewDecision) { [weak self] in
                guard let self else { return }
                defer { self.reviewDecisionPending = false }
                let result = await self.acceptShot(photoIndex: photoIndex)
                if result == .accepted { self.sendAuthoritativeReviewDecision() }
            }
        case .retake:
            guard let sessionID = currentManifest?.id else {
                reviewDecisionPending = false
                return
            }
            sessionFlowOperations.start(sessionID: sessionID, kind: .reviewDecision) { [weak self] in
                guard let self else { return }
                defer { self.reviewDecisionPending = false }
                let result = await self.requestRetake(photoIndex: photoIndex, source: .guest)
                if result == .accepted { self.sendAuthoritativeReviewDecision() }
            }
        }
    }

    func handleCaptureRecoveryAction(_ action: CaptureRecoveryAction) {
        guard let state = currentCaptureRecoveryStateToken else { return }
        handleCaptureRecoveryAction(state: state, requestID: UUID(), action: action)
    }

    private func handleCaptureRecoveryAction(
        state: CaptureRecoveryStateToken,
        requestID: UUID,
        action: CaptureRecoveryAction
    ) {
        if activeSoakRunID != nil {
            rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .stale)
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .stale))
            return
        }
        if let record = recentCaptureRecoveryRequests[requestID] {
            guard record.state == state, record.action == action else {
                multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .stale))
                return
            }
            let result = record.result == .accepted ? .duplicate : record.result
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: result))
            if record.result == .accepted { resynciPad() }
            return
        }

        guard let current = currentCaptureRecoveryStateToken else {
            rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .stale)
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .stale))
            return
        }
        guard current.sessionID == state.sessionID else {
            rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .sessionChanged)
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .sessionChanged))
            return
        }
        let requestedPhotoIndex: Int = switch action {
        case .retryReceive(let index), .retake(let index), .continueSession(let index), .usePrevious(let index): index
        }
        guard current.photoIndex == state.photoIndex,
              requestedPhotoIndex == state.photoIndex else {
            rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .wrongPhoto)
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .wrongPhoto))
            return
        }
        guard current == state else {
            rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .stale)
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .stale))
            return
        }

        let customerAction: CustomerDisplayAction
        switch action {
        case .retryReceive(let photoIndex):
            customerAction = .retryReceive(photoIndex: photoIndex)
        case .retake(let photoIndex):
            customerAction = .retakeFailedCapture(photoIndex: photoIndex)
        case .continueSession(let photoIndex):
            customerAction = .continueAfterCaptureFailure(photoIndex: photoIndex)
        case .usePrevious(let photoIndex):
            customerAction = .usePreviousCapture(photoIndex: photoIndex)
        }
        guard case .idle = sessionLifecycleOperation,
              !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else {
            rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .stale)
            multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .stale))
            return
        }
        if case .continueSession(let photoIndex) = action {
            // The iPad decides which buttons to show; the Mac decides what is
            // legal. Without this the client can request a deferral that has
            // nowhere to go.
            let hasOtherMissing = currentManifest?.shots.contains {
                $0.photoIndex != photoIndex && $0.imageFileName == nil
            } ?? false
            guard hasOtherMissing else {
                rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: .wrongPhoto)
                multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: .wrongPhoto))
                return
            }
        }
        reviewDecisionPending = true
        sessionFlowOperations.start(
            sessionID: state.sessionID,
            kind: .captureRecovery
        ) { [weak self] in
            guard let self else { return }
            defer { self.reviewDecisionPending = false }
            switch action {
            case .retryReceive(let photoIndex):
                await self.retryReceive(photoIndex: photoIndex)
            case .retake(let photoIndex):
                await self.retakeFailedCapture(photoIndex: photoIndex)
            case .continueSession(let photoIndex):
                await self.continueAfterCaptureFailure(photoIndex: photoIndex)
            case .usePrevious(let photoIndex):
                await self.usePreviousCapture(photoIndex: photoIndex)
            }
            let result: CaptureRecoveryActionResult = self.currentCaptureRecoveryStateToken == state
                ? .persistenceFailed
                : .accepted
            self.rememberCaptureRecoveryRequest(requestID, state: state, action: action, result: result)
            self.multipeer.sendControl(.captureRecoveryActionResult(requestID: requestID, result: result))
            if result == .accepted { self.resynciPad() }
        }
    }

    private func rememberCaptureRecoveryRequest(
        _ requestID: UUID,
        state: CaptureRecoveryStateToken,
        action: CaptureRecoveryAction,
        result: CaptureRecoveryActionResult
    ) {
        guard result != .persistenceFailed else { return }
        recentCaptureRecoveryRequests[requestID] = CaptureRecoveryRequestRecord(
            state: state,
            action: action,
            result: result
        )
        recentCaptureRecoveryRequestOrder.removeAll { $0 == requestID }
        recentCaptureRecoveryRequestOrder.append(requestID)
        if recentCaptureRecoveryRequestOrder.count > 32 {
            let expired = recentCaptureRecoveryRequestOrder.removeFirst()
            recentCaptureRecoveryRequests.removeValue(forKey: expired)
        }
    }

    private func retryReceive(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              let sessionID = currentManifest?.id else { return }
        let lifecycleGeneration = sessionLifecycleGeneration
        let attempt = CaptureAttempt()
        currentCaptureAttempt = attempt
        do {
            let image = try await capture.recoverLastCapture()
            let filtered = try await filterPipeline.apply(stateMachine.config.selectedFilterID, to: image)
            guard let thumbData = capture.thumbnail(for: filtered) else {
                throw PhotoFilterError.failedToCreateOutput(stateMachine.config.selectedFilterID)
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else { return }
            let context = nextSessionMessageContext()
            let reviewData: Data
            if let context {
                reviewData = try ReviewImageEncoder.encode(image: filtered, context: context, index: photoIndex)
            } else {
                reviewData = thumbData
            }
            capture.storeStill(image, for: photoIndex)
            currentFilteredReviewImages[photoIndex] = filtered
            stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: thumbData, reviewImageData: reviewData)
            currentCaptureRecoveryStateToken = nil
            if let context {
                currentReviewStateToken = ReviewStateToken(
                    sessionID: context.sessionID,
                    photoIndex: photoIndex,
                    revision: context.sequence,
                    authorityEpoch: context.authorityEpoch
                )
            }
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .transferRecovered,
                completedAt: Date(),
                reason: nil,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID,
                  stateMachine.phase == .review(photoIndex: photoIndex) else {
                currentCaptureAttempt = nil
                return
            }
            recordOperation(.captureRecovered, sessionID: currentManifest?.id, photoIndex: photoIndex, duration: Date().timeIntervalSince(attempt.startedAt))
            currentCaptureAttempt = nil
            if let context { sendReviewAsset(context: context, photoIndex: photoIndex, data: reviewData) }
            updateStripPreview()
        } catch {
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID else { return }
            let summary = captureFailureSummary(photoIndex: photoIndex, error: error)
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .failed,
                completedAt: Date(),
                reason: error.localizedDescription,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == sessionID,
                  await persistCaptureFailure(photoIndex: photoIndex, error: error) else {
                currentCaptureAttempt = nil
                return
            }
            stateMachine.enterCaptureRecovery(photoIndex: photoIndex, failure: summary)
            currentCaptureAttempt = nil
            if let context = nextSessionMessageContext() {
                currentCaptureRecoveryStateToken = CaptureRecoveryStateToken(
                    sessionID: context.sessionID,
                    photoIndex: photoIndex,
                    revision: context.sequence,
                    authorityEpoch: context.authorityEpoch
                )
                multipeer.sendControl(.captureRecovery(context: context, photoIndex: photoIndex, failure: summary))
            }
        }
    }

    private func retakeFailedCapture(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              let manifest = currentManifest else { return }
        capture.invalidateCaptureRecovery()
        let lifecycleGeneration = sessionLifecycleGeneration
        let count = retakeCounts[photoIndex, default: 0] + 1
        do {
            let committedManifest = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing]
            ) { durable in
                let current = durable.shots.first(where: { $0.photoIndex == photoIndex })
                upsertRuntimeShot(
                    in: &durable.shots,
                    photoIndex: photoIndex,
                    imageFileName: nil,
                    gifFrameFileNames: [],
                    retakeCount: max(count, (current?.retakeCount ?? 0) + 1),
                    acceptedAt: nil,
                    previousImageFileName: current?.imageFileName ?? current?.previousImageFileName,
                    previousGifFrameFileNames: current?.gifFrameFileNames.isEmpty == false
                        ? current?.gifFrameFileNames
                        : current?.previousGifFrameFileNames,
                    previousAcceptedAt: current?.acceptedAt ?? current?.previousAcceptedAt
                )
                durable.nextPhotoIndex = photoIndex
                durable.lastError = nil
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return }
            currentManifest = committedManifest
            retakeCounts[photoIndex] = count
            await recordCaptureAttempt(
                CaptureAttempt(),
                photoIndex: photoIndex,
                result: .retaken,
                completedAt: Date(),
                reason: "retaken",
                receiveDuration: nil
            )
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return }
            recordOperation(.captureRetried, sessionID: committedManifest.id, photoIndex: photoIndex)
            currentCaptureAttempt = nil
            stateMachine.retakeFailedCapture(photoIndex: photoIndex)
            beginCountdown(photoIndex: photoIndex)
        } catch {
            errorMessage = "Could not start retake: \(error.localizedDescription)"
        }
    }

    private func continueAfterCaptureFailure(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              let manifest = currentManifest else { return }
        let lifecycleGeneration = sessionLifecycleGeneration
        let next = stateMachine.nextPhotoAfterCaptureFailure(photoIndex: photoIndex)
        guard let next else {
            errorMessage = "Cannot continue while a required photograph is missing."
            return
        }
        capture.invalidateCaptureRecovery()
        do {
            let committedManifest = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing]
            ) { durable in
                durable.nextPhotoIndex = next
            }
            guard case .captureRecovery(let current, _) = stateMachine.phase,
                  current == photoIndex,
                  sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return }
            guard stateMachine.continueAfterCaptureFailure(photoIndex: photoIndex) == next else { return }
            currentManifest = committedManifest
            await recordCaptureAttempt(
                CaptureAttempt(),
                photoIndex: photoIndex,
                result: .deferred,
                completedAt: Date(),
                reason: "deferred",
                receiveDuration: nil
            )
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return }
            recordOperation(.captureDeferred, sessionID: committedManifest.id, photoIndex: photoIndex)
            currentCaptureAttempt = nil
            beginCountdown(photoIndex: next)
        } catch {
            errorMessage = "Could not defer photograph: \(error.localizedDescription)"
        }
    }

    private func usePreviousCapture(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              let manifest = currentManifest,
              let previous = manifest.shots.first(where: { $0.photoIndex == photoIndex }),
              let imageFileName = previous.previousImageFileName else { return }
        let lifecycleGeneration = sessionLifecycleGeneration
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        guard let image = loadCGImage(from: directory.appendingPathComponent(imageFileName)) else {
            errorMessage = "The previous photograph is no longer available."
            return
        }
        capture.invalidateCaptureRecovery()
        do {
            let filtered = try await filterPipeline.apply(stateMachine.config.selectedFilterID, to: image)
            guard let thumbData = capture.thumbnail(for: filtered) else {
                throw PhotoFilterError.failedToCreateOutput(stateMachine.config.selectedFilterID)
            }
            let reviewData = try? ReviewImageEncoder.encode(
                image: filtered,
                context: SessionMessageContext(
                    sessionID: stateMachine.currentSessionID,
                    sequence: 0,
                    authorityEpoch: authorityEpoch
                ),
                index: photoIndex
            )
            let gifs = previous.previousGifFrameFileNames ?? []
            let committedManifest = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing]
            ) { durable in
                upsertRuntimeShot(
                    in: &durable.shots,
                    photoIndex: photoIndex,
                    imageFileName: imageFileName,
                    gifFrameFileNames: gifs,
                    retakeCount: previous.retakeCount,
                    acceptedAt: previous.previousAcceptedAt ?? Date()
                )
                durable.nextPhotoIndex = (0..<durable.eventConfig.photoCount)
                    .first { index in
                        durable.shots.first(where: { $0.photoIndex == index })?.imageFileName == nil
                    } ?? durable.eventConfig.photoCount
                durable.lastError = nil
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return }
            currentManifest = committedManifest
            capture.storeStill(image, for: photoIndex)
            currentFilteredReviewImages[photoIndex] = filtered
            currentCaptureRecoveryStateToken = nil
            let completesSession = committedManifest.nextPhotoIndex >= committedManifest.eventConfig.photoCount
            await recordCaptureAttempt(
                CaptureAttempt(),
                photoIndex: photoIndex,
                result: .usedPrevious,
                completedAt: Date(),
                reason: "previous_photo_used",
                receiveDuration: nil
            )
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return }
            recordOperation(.previousPhotoUsed, sessionID: committedManifest.id, photoIndex: photoIndex)
            currentCaptureAttempt = nil
            if completesSession {
                guard await finalizeSession(),
                      sessionLifecycleGeneration == lifecycleGeneration,
                      currentManifest?.id == committedManifest.id else { return }
            }
            stateMachine.usePreviousCapture(photoIndex: photoIndex, thumbnailData: thumbData, reviewImageData: reviewData)
            if case .countdown(let next, _) = stateMachine.phase { beginCountdown(photoIndex: next) }
        } catch {
            errorMessage = "Could not restore the previous photograph: \(error.localizedDescription)"
        }
    }

    func operatorOverride(_ action: OperatorAction) {
        switch action {
        case .forceStart:
            guard stateMachine.phase == .idle || stateMachine.phase == .readyToStart else { return }
            startSession()
        case .forceRetake:
            guard case .review(let idx) = stateMachine.phase,
                  !reviewDecisionPending,
                  CustomerDisplayWorkflow.canApply(.retake(photoIndex: idx), in: stateMachine.phase) else { return }
            reviewDecisionPending = true
            guard let sessionID = currentManifest?.id else {
                reviewDecisionPending = false
                return
            }
            sessionFlowOperations.start(sessionID: sessionID, kind: .reviewDecision) { [weak self] in
                guard let self else { return }
                defer { self.reviewDecisionPending = false }
                let result = await self.requestRetake(photoIndex: idx, source: .operatorSource)
                if result == .accepted { self.sendAuthoritativeReviewDecision() }
            }
        case .skip:
            guard case .review(let idx) = stateMachine.phase,
                  !reviewDecisionPending,
                  CustomerDisplayWorkflow.canApply(.keep(photoIndex: idx), in: stateMachine.phase) else { return }
            handleReviewDecision(photoIndex: idx, action: .keep)
        case .cancelSession:
            if currentSession != nil {
                Task { @MainActor [weak self] in
                    await self?.cancelCurrentSession()
                }
            } else if finishedAwaitingCustomerAckSessionID != nil
                      || stateMachine.phase.isFinished {
                // Post-completion reset — session already cleared (Finding 7).
                resetToIdleAfterCompletion()
            }
        }
    }

    /// Resets the booth to idle from a post-completion state where `currentSession` has
    /// already been cleared but `finishedAwaitingCustomerAckSessionID` or `.finished` phase
    /// are still active (Finding 7).
    private func resetToIdleAfterCompletion() {
        customerFinishedInFlightSessionID = nil
        finishedAwaitingCustomerAckSessionID = nil
        completionInFlightSessionID = nil
        sessionLifecycleGeneration &+= 1
        currentManifest = nil
        currentManifestID = nil
        currentSession = nil
        currentSessionPresentation = nil
        currentStripPreview = nil
        currentFilteredReviewImages = [:]
        sessionAssetReferences = [:]
        stripAssetReference = nil
        assetSources = [:]
        pendingPromptAssets = [:]
        assetAssembler = BoothAssetAssembler()
        capture.resetStills()
        retakeCounts = [:]
        gifFrames = [:]
        currentCaptureAttempt = nil
        currentCountdown = nil
        reviewDecisionPending = false
        currentReviewStateToken = nil
        activeReviewRequestID = nil
        recentReviewRequests.removeAll(keepingCapacity: true)
        recentReviewRequestOrder.removeAll(keepingCapacity: true)
        stateMachine.reset()
        resynciPad()
        attemptPendingLANRecoveryIfIdle()
    }

    private enum RetakeSource {
        case guest
        case operatorSource
    }

    private func acceptShot(photoIndex: Int) async -> ReviewDecisionResult {
        guard case .review(let currentIndex) = stateMachine.phase,
              currentIndex == photoIndex,
              case .idle = sessionLifecycleOperation,
              let manifest = currentManifest,
              currentManifestID == manifest.id,
              let image = capture.capturedStills[photoIndex] else {
            errorMessage = "Cannot keep this photograph because its review state is unavailable."
            return .wrongPhoto
        }
        let lifecycleGeneration = sessionLifecycleGeneration
        let retakeCount = retakeCounts[photoIndex] ?? 0

        do {
            let saved = try workspace.saveAcceptedCapture(
                image: image,
                gifFrames: gifFrames[photoIndex] ?? [],
                photoIndex: photoIndex,
                workspace: workspaceDescriptor(from: manifest)
            )
            let committedManifest = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing]
            ) { durable in
                upsertRuntimeShot(
                    in: &durable.shots,
                    photoIndex: photoIndex,
                    imageFileName: saved.imageFileName,
                    gifFrameFileNames: saved.gifFrameFileNames,
                    retakeCount: retakeCount,
                    acceptedAt: Date()
                )
                durable.nextPhotoIndex = (0..<durable.eventConfig.photoCount)
                    .first { index in
                        durable.shots.first(where: { $0.photoIndex == index })?.imageFileName == nil
                    } ?? durable.eventConfig.photoCount
                durable.lastError = nil
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return .stale }
            currentManifest = committedManifest
            try? workspace.pruneUnreferencedCaptureFiles(manifest: committedManifest)
            let session = currentSession ?? store.restoreSessionRecord(from: committedManifest)
            store.upsertShot(
                session: session,
                photoIndex: photoIndex,
                imagePath: saved.imageFileName,
                retakeCount: retakeCount
            )

            let completesSession = committedManifest.nextPhotoIndex >= committedManifest.eventConfig.photoCount
            if completesSession {
                guard await finalizeSession(),
                      sessionLifecycleGeneration == lifecycleGeneration,
                      currentManifest?.id == committedManifest.id else { return .stale }
                stateMachine.keepShot(photoIndex: photoIndex)
            } else {
                stateMachine.keepShot(photoIndex: photoIndex)
                if case .countdown(let next, _) = stateMachine.phase {
                    beginCountdown(photoIndex: next)
                }
            }
            currentReviewStateToken = nil
            return .accepted
        } catch {
            if let currentManifest {
                try? workspace.pruneUnreferencedCaptureFiles(manifest: currentManifest)
            }
            errorMessage = "Could not save photograph \(photoIndex + 1): \(error.localizedDescription)"
            return .persistenceFailed
        }
    }

    private func sendAuthoritativeReviewDecision() {
        resynciPad()
    }

    private func rememberReviewRequest(
        _ requestID: UUID,
        state: ReviewStateToken,
        action: ReviewAction,
        result: ReviewDecisionResult
    ) {
        // Don't cache transient failures — allow retries to re-attempt the save (Finding 9).
        guard result != .persistenceFailed else { return }
        recentReviewRequests[requestID] = ReviewRequestRecord(state: state, action: action, result: result)
        recentReviewRequestOrder.removeAll { $0 == requestID }
        recentReviewRequestOrder.append(requestID)
        if recentReviewRequestOrder.count > 32 {
            let expired = recentReviewRequestOrder.removeFirst()
            recentReviewRequests.removeValue(forKey: expired)
        }
    }

    private func sendReviewDecisionResult(_ requestID: UUID, _ result: ReviewDecisionResult) {
        multipeer.sendControl(.reviewDecisionResult(requestID: requestID, result: result))
    }

    private func handleClientReviewDecision(
        state: ReviewStateToken,
        requestID: UUID,
        action: ReviewAction
    ) {
        if activeSoakRunID != nil {
            rememberReviewRequest(requestID, state: state, action: action, result: .stale)
            sendReviewDecisionResult(requestID, .stale)
            return
        }
        if let record = recentReviewRequests[requestID] {
            guard record.state == state, record.action == action else {
                sendReviewDecisionResult(requestID, .stale)
                return
            }
            sendReviewDecisionResult(
                requestID,
                record.result == .accepted ? .duplicate : record.result
            )
            if record.result == .accepted { sendAuthoritativeReviewDecision() }
            return
        }

        let phasePhotoIndex: Int? = if case .review(let photoIndex) = stateMachine.phase {
            photoIndex
        } else {
            nil
        }
        let validation = ReviewDecisionGate.validate(
            current: currentReviewStateToken,
            phasePhotoIndex: phasePhotoIndex,
            requested: state
        )
        guard validation == .accepted else {
            rememberReviewRequest(requestID, state: state, action: action, result: validation)
            sendReviewDecisionResult(requestID, validation)
            return
        }
        if reviewDecisionPending {
            guard activeReviewRequestID != requestID else { return }
            rememberReviewRequest(requestID, state: state, action: action, result: .stale)
            sendReviewDecisionResult(requestID, .stale)
            return
        }

        reviewDecisionPending = true
        activeReviewRequestID = requestID
        let lifecycleGeneration = sessionLifecycleGeneration
        sessionFlowOperations.start(
            sessionID: state.sessionID,
            kind: .reviewDecision
        ) { [weak self] in
            guard let self,
                  !Task.isCancelled,
                  self.sessionLifecycleGeneration == lifecycleGeneration,
                  self.currentManifest?.id == state.sessionID else { return }
            let result: ReviewDecisionResult = switch action {
            case .keep: await self.acceptShot(photoIndex: state.photoIndex)
            case .retake: await self.requestRetake(photoIndex: state.photoIndex, source: .guest)
            }
            guard !Task.isCancelled,
                  self.sessionLifecycleGeneration == lifecycleGeneration,
                  self.currentManifest?.id == state.sessionID else { return }
            self.reviewDecisionPending = false
            self.activeReviewRequestID = nil
            self.rememberReviewRequest(requestID, state: state, action: action, result: result)
            self.sendReviewDecisionResult(requestID, result)
            if result == .accepted { self.sendAuthoritativeReviewDecision() }
        }
    }

    private func requestRetake(photoIndex: Int, source: RetakeSource) async -> ReviewDecisionResult {
        _ = source
        guard case .review(let currentIndex) = stateMachine.phase,
              currentIndex == photoIndex,
              case .idle = sessionLifecycleOperation,
              let manifest = currentManifest else { return .wrongPhoto }
        let lifecycleGeneration = sessionLifecycleGeneration

        let count = retakeCounts[photoIndex, default: 0] + 1
        let previousImagePath = manifest.shots.first(where: { $0.photoIndex == photoIndex })?.imageFileName
        do {
            let committedManifest = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing]
            ) { durable in
                let previous = durable.shots.first(where: { $0.photoIndex == photoIndex })
                upsertRuntimeShot(
                    in: &durable.shots,
                    photoIndex: photoIndex,
                    imageFileName: nil,
                    gifFrameFileNames: [],
                    retakeCount: max(count, (previous?.retakeCount ?? 0) + 1),
                    acceptedAt: nil,
                    previousImageFileName: previous?.imageFileName ?? previous?.previousImageFileName,
                    previousGifFrameFileNames: previous?.gifFrameFileNames.isEmpty == false
                        ? previous?.gifFrameFileNames
                        : previous?.previousGifFrameFileNames,
                    previousAcceptedAt: previous?.acceptedAt ?? previous?.previousAcceptedAt
                )
                durable.nextPhotoIndex = photoIndex
                durable.lastError = nil
            }
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  currentManifest?.id == committedManifest.id else { return .stale }
            currentManifest = committedManifest
            retakeCounts[photoIndex] = committedManifest.shots.first(where: { $0.photoIndex == photoIndex })?.retakeCount ?? count
            sessionAssetReferences.removeValue(forKey: photoIndex)
            currentFilteredReviewImages.removeValue(forKey: photoIndex)
            if let session = currentSession {
                store.upsertShot(
                    session: session,
                    photoIndex: photoIndex,
                    imagePath: previousImagePath,
                    retakeCount: count
                )
            }
            stateMachine.retakeShot(photoIndex: photoIndex)
            beginCountdown(photoIndex: photoIndex)
            currentReviewStateToken = nil
            return .accepted
        } catch {
            errorMessage = "Could not save retake count: \(error.localizedDescription)"
            return .persistenceFailed
        }
    }

    private func cancelCurrentSession() async {
        guard sessionLifecycleOperation.allowsCancellation else { return }
        capture.invalidateCaptureRecovery()
        guard let session = currentSession, let manifest = currentManifest else {
            if activeSessionStart != nil {
                sessionLifecycleGeneration &+= 1
                activeSessionStart = nil
            }
            reviewDecisionPending = false
            currentReviewStateToken = nil
            currentCaptureRecoveryStateToken = nil
            activeReviewRequestID = nil
            recentReviewRequests.removeAll(keepingCapacity: true)
            recentReviewRequestOrder.removeAll(keepingCapacity: true)
            recentCaptureRecoveryRequests.removeAll(keepingCapacity: true)
            recentCaptureRecoveryRequestOrder.removeAll(keepingCapacity: true)
            sessionAssetReferences = [:]
            stripAssetReference = nil
            assetSources = [:]
            pendingPromptAssets = [:]
            currentStripPreview = nil
            currentFilteredReviewImages = [:]
            currentSessionPresentation = nil
            lastSessionPresentation = nil
            stateMachine.reset()
            attemptPendingLANRecoveryIfIdle()
            resynciPad()
            return
        }
        guard claimSessionRecovery(manifest.id) else {
            errorMessage = JobRecoveryError.retryAlreadyInProgress(manifest.id).localizedDescription
            return
        }
        defer { releaseSessionRecovery(manifest.id, scheduleReconciliation: true) }

        let lifecycleToken = UUID()
        sessionLifecycleOperation = .cancelling(sessionID: manifest.id, token: lifecycleToken)
        let cancelledManifest: SessionManifest
        do {
            cancelledManifest = try await manifestStore.transition(
                sessionID: manifest.id,
                allowedFrom: [.capturing, .finalizing, .failed]
            ) { durable in
                durable.status = .cancelled
                durable.cancelledAt = Date()
                durable.lastError = nil
            }
        } catch {
            sessionLifecycleOperation = .idle
            recoveryService.recordError("Cancelled session could not be persisted: \(error.localizedDescription)")
            errorMessage = "Session cancellation could not be persisted: \(error.localizedDescription)"
            return
        }

        sessionLifecycleGeneration &+= 1
        let lifecycleGeneration = sessionLifecycleGeneration
        guard sessionLifecycleGeneration == lifecycleGeneration,
              sessionLifecycleOperation == .cancelling(sessionID: manifest.id, token: lifecycleToken) else { return }
        currentManifest = cancelledManifest
        cancelCountdown()
        reviewDecisionPending = false
        let flowQuiesced = await sessionFlowOperations.cancelAndQuiesce(
            sessionID: manifest.id,
            timeout: .seconds(10)
        )
#if DEBUG
        await beforeCancellationQueueBarrierForTesting?(manifest.id)
#endif
        do {
            let result = try await jobQueue.cancelAndQuiesceJobs(sessionID: manifest.id)
            guard sessionLifecycleGeneration == lifecycleGeneration,
                  sessionLifecycleOperation == .cancelling(sessionID: manifest.id, token: lifecycleToken) else { return }
            if !flowQuiesced || result == .cleanupPending {
                recoveryService.markCleanupPending(sessionID: manifest.id)
                errorMessage = "Session cancellation was saved; its files were retained while background work stops."
            } else {
                recordOperation(.sessionCancelled, sessionID: manifest.id)
                do {
                    try workspace.removeEntireSession(manifest: cancelledManifest)
                } catch {
                    recoveryService.recordError("Cancelled session files could not be removed: \(error.localizedDescription)")
                }
            }
        } catch {
            recoveryService.markCleanupPending(sessionID: manifest.id)
            recoveryService.recordError("Cancelled session jobs could not be quiesced: \(error.localizedDescription)")
            errorMessage = "Session cancellation was saved; files were retained because background work could not be stopped."
        }

#if DEBUG
        if stopCancellationAfterJobBarrierForTesting { return }
#endif

        // Keep the durable cancelled manifest when cleanup is pending so a
        // later startup can retry the retained workspace without making the
        // session recoverable to the customer.
        store.deleteSession(session)
        currentManifest = nil
        currentManifestID = nil
        currentSession = nil
        currentSessionPresentation = nil
        retakeCounts = [:]
        gifFrames = [:]
        currentCaptureAttempt = nil
        currentFilteredReviewImages = [:]
        sessionAssetReferences = [:]
        stripAssetReference = nil
        assetSources = [:]
        pendingPromptAssets = [:]
        assetAssembler = BoothAssetAssembler()
        currentStripPreview = nil
        capture.resetStills()
        reviewDecisionPending = false
        currentReviewStateToken = nil
        currentCaptureRecoveryStateToken = nil
        activeReviewRequestID = nil
        recentReviewRequests.removeAll(keepingCapacity: true)
        recentReviewRequestOrder.removeAll(keepingCapacity: true)
        recentCaptureRecoveryRequests.removeAll(keepingCapacity: true)
        recentCaptureRecoveryRequestOrder.removeAll(keepingCapacity: true)
        stateMachine.reset()
        sessionLifecycleOperation = .idle
        attemptPendingLANRecoveryIfIdle()
        resynciPad()
    }

    private func resumeRecoveredSession(manifest: SessionManifest, images: [Int: CGImage]) {
        guard currentSession == nil else {
            errorMessage = "Finish or cancel the current session before resuming recovery."
            return
        }
        guard manifest.nextPhotoIndex >= 0,
              manifest.nextPhotoIndex < manifest.eventConfig.photoCount else {
            errorMessage = "Recovered session has no remaining photograph index."
            return
        }
        currentManifest = manifest
        currentManifestID = manifest.id
        currentSession = store.restoreSessionRecord(from: manifest)
        var recoveredPresentation = (try? workspace.loadPresentationSnapshot(manifest: manifest))
            ?? presentation(for: manifest.eventConfig, sessionID: manifest.id)
        assetSources = [:]
        pendingPromptAssets = [:]
        recoveredPresentation.prompts = recoveredPresentation.prompts.map { prompt in
            guard let data = prompt.imageData, !data.isEmpty else { return prompt }
            let reference = makeAssetReference(
                data: data,
                assetID: "prompt-\(manifest.id)-\(prompt.promptID)",
                sessionID: manifest.id,
                revision: manifest.eventConfig.experienceRevision,
                kind: .promptImage
            )
            pendingPromptAssets[reference.assetID] = (reference, data)
            var prompt = prompt
            prompt.imageAsset = reference
            return prompt
        }
        currentSessionPresentation = recoveredPresentation
        lastSessionPresentation = currentSessionPresentation
        retakeCounts = manifest.shots.reduce(into: [:]) { result, shot in
            result[shot.photoIndex] = shot.retakeCount
        }
        gifFrames = [:]
        currentCaptureAttempt = nil
        capture.restoreStills(images)
        let thumbnails = images.reduce(into: [Int: Data]()) { result, item in
            if let data = capture.thumbnail(for: item.value) { result[item.key] = data }
        }
        stateMachine.restoreSession(
            sessionID: manifest.id,
            config: manifest.eventConfig,
            keptShots: thumbnails,
            nextPhotoIndex: manifest.nextPhotoIndex
        )
        guard let presentation = currentSessionPresentation,
              let startContext = nextSessionMessageContext(),
              let preparedContext = nextSessionMessageContext() else {
            errorMessage = "Recovered session identity could not be synchronized."
            return
        }
        let recoveredSessionID = manifest.id
        let recoveredPhotoIndex = manifest.nextPhotoIndex
        let authority = customerDisplayAuthority
        for asset in pendingPromptAssets.values {
            assetSources[asset.reference] = asset.data
        }
        if authority.requiresIPadSetupSend {
            multipeer.sendControl(.sessionStart(context: startContext))
            multipeer.sendControl(.eventConfig(config: manifest.eventConfig))
            multipeer.sendControl(.sessionPrepared(
                config: manifest.eventConfig,
                presentation: presentation,
                context: preparedContext
            )) { [weak self] outcome in
                guard let self else { return }
                guard outcome == .sent,
                      self.currentSession?.id == recoveredSessionID,
                      self.stateMachine.currentSessionID == recoveredSessionID else {
                    if self.isAuthenticatedIPadConnected {
                        self.errorMessage = "The iPad did not receive recovered session setup. Reconnect before retrying."
                    }
                    return
                }
                self.beginCountdown(photoIndex: recoveredPhotoIndex)
            }
        }
        if authority.shouldStartCountdownImmediatelyLocally {
            beginCountdown(photoIndex: recoveredPhotoIndex)
        }
    }

    private func finishDiscardingRecoveredSession(_ manifest: SessionManifest) {
        if let session = store.fetchSession(id: manifest.id) { store.deleteSession(session) }
        if currentManifestID == manifest.id {
            currentManifest = nil
            currentManifestID = nil
            currentSession = nil
            currentSessionPresentation = nil
            assetSources = [:]
            pendingPromptAssets = [:]
            assetAssembler = BoothAssetAssembler()
            capture.resetStills()
            retakeCounts = [:]
            gifFrames = [:]
            stateMachine.reset()
        }
    }

    // MARK: - Finalize session

    private func finalizeSession() async -> Bool {
        guard case .idle = sessionLifecycleOperation,
              let current = currentManifest else { return false }
        let sessionID = current.id
        let lifecycleToken = UUID()
        sessionLifecycleOperation = .finalizing(sessionID: sessionID, token: lifecycleToken)
        let lifecycleGeneration = sessionLifecycleGeneration
        defer {
            if sessionLifecycleOperation == .finalizing(sessionID: sessionID, token: lifecycleToken) {
                sessionLifecycleOperation = .idle
            }
        }

        let transactionID = UUID().uuidString
        let galleryEnabled = activeExperienceDocument.map { $0.gallery.mode != .disabled }
            ?? (current.eventConfig.eventGalleryPath != nil)
        let finalGalleryPath: String? = if galleryEnabled {
            activeExperienceDocument.map { "/e/\($0.gallery.eventToken)/" }
                ?? current.eventConfig.eventGalleryPath
        } else {
            nil
        }
        let hasGIFFrames = current.shots.contains { !$0.gifFrameFileNames.isEmpty }
        let finalizationIntent = currentDeliveryIntentSnapshot(
            updateGalleryEnabled: galleryEnabled,
            renderGIFEnabled: hasGIFFrames,
            cloudUploadEnabled: soakCloudUploadOverride,
            automaticPrintEnabled: soakAutomaticPrintOverride
        )
        let cloudDelivery = currentCloudDeliverySnapshot(enabledOverride: soakCloudUploadOverride)
        let manifest: SessionManifest
        do {
            manifest = try await manifestStore.transition(
                sessionID: sessionID,
                allowedFrom: [.capturing]
            ) { durable in
                guard (0..<durable.eventConfig.photoCount).allSatisfy({ index in
                    durable.shots.first(where: { $0.photoIndex == index })?.imageFileName != nil
                }) else {
                    throw SessionManifestError.invalidTransition(
                        sessionID: durable.id,
                        from: durable.status,
                        to: .finalizing
                    )
                }
                durable.status = .finalizing
                durable.finalizationTransactionID = transactionID
                durable.deliveryIntent = finalizationIntent
                durable.cloudDelivery = cloudDelivery
                durable.eventConfig.eventGalleryPath = finalGalleryPath
                durable.lastError = nil
            }
        } catch {
            errorMessage = "Could not start session processing: \(error.localizedDescription)"
            return false
        }
        guard sessionLifecycleGeneration == lifecycleGeneration,
              currentManifest?.id == sessionID,
              sessionLifecycleOperation == .finalizing(sessionID: sessionID, token: lifecycleToken) else { return false }
        currentManifest = manifest
        stateMachine.applyAuthoritativePhase(.processing)
        do {
            try await jobQueue.enqueueFinalizationJobs(for: manifest)
        } catch {
            // Error logged and displayed.
            // Do not roll back manifest to .capturing. Reconciliation repairs
            // the full bundle from the durable finalization plan.
            recoveryService.recordError(
                "Job enqueue failed for finalizing session \(sessionID): \(error.localizedDescription)"
            )
            errorMessage = "Processing recovery required. The session is safe and job initialization will retry: \(error.localizedDescription)"
            scheduleJobReconciliation()
            return true
        }
        return true
    }

    private func scheduleJobReconciliation() {
        jobReconciliationDirty = true
        guard jobReconciliationTask == nil else { return }
        jobReconciliationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { jobReconciliationTask = nil }
            while jobReconciliationDirty {
                jobReconciliationDirty = false
                await reconcileJobState()
            }
        }
    }

    private func claimSessionRecovery(_ sessionID: String) -> Bool {
        recoveryInFlightSessionIDs.insert(sessionID).inserted
    }

    private func releaseSessionRecovery(_ sessionID: String, scheduleReconciliation: Bool = false) {
        guard recoveryInFlightSessionIDs.remove(sessionID) != nil else { return }
        if deferredAutomaticCloudRetrySessionIDs.remove(sessionID) != nil {
            Task { @MainActor [weak self] in
                await self?.retryFailedCloudUploadsSafely(sessionIDs: [sessionID])
            }
        }
        if scheduleReconciliation {
            scheduleJobReconciliation()
        }
    }

    private func reconcileJobState() async {
        await reconcileCurrentSessionJobs()
        await reconcileRecoveredSessions()
    }

#if DEBUG
    func reconcileJobsNowForTesting() async {
        await reconcileJobState()
    }

    func cancelSessionForTesting(manifest: SessionManifest) async {
        let session = BoothSession(eventID: manifest.eventID, photoCount: manifest.eventConfig.photoCount)
        session.id = manifest.id
        currentSession = session
        currentManifest = manifest
        currentManifestID = manifest.id
        stopCancellationAfterJobBarrierForTesting = true
        await cancelCurrentSession()
    }

    func retryFailedCloudUploadsNowForTesting() async {
        await retryFailedCloudUploadsSafely()
    }
#endif

    private func reconcileCurrentSessionJobs() async {
        guard var manifest = currentManifest,
              currentSession != nil,
              stateMachine.phase == .processing,
              !recoveryInFlightSessionIDs.contains(manifest.id) else { return }
        if manifest.status == .finalizing, FinalizationPlan.make(from: manifest) == nil {
            do {
                manifest = try await recoveryService.prepareFinalizationPlanForRecovery(for: manifest)
                currentManifest = manifest
            } catch {
                recoveryService.recordError("Could not migrate current finalization plan: \(error.localizedDescription)")
                return
            }
        }
        let jobs = jobQueue.jobs.filter {
            $0.sessionID == manifest.id
                && $0.finalizationTransactionID == manifest.finalizationTransactionID
        }
        let decision = SessionJobReconciliationDecision.evaluate(
            manifest: manifest,
            jobs: jobs
        )
        switch decision {
        case .none:
            return
        case .enqueueMissingRequiredJobs:
            do {
                guard claimSessionRecovery(manifest.id) else { return }
                defer { releaseSessionRecovery(manifest.id) }
                do {
                    try await jobQueue.enqueueFinalizationJobs(for: manifest)
                } catch {
                    recoveryService.recordError("Required finalization jobs could not be repaired: \(error.localizedDescription)")
                }
            }
        case .restoreFinalizing:
            do {
                guard claimSessionRecovery(manifest.id) else { return }
                defer { releaseSessionRecovery(manifest.id) }
                let restored = try await manifestStore.transition(
                    sessionID: manifest.id,
                    allowedFrom: [.failed]
                ) { durable in
                    durable.status = .finalizing
                    durable.lastError = nil
                }
                currentManifest = restored
                scheduleJobReconciliation()
            } catch {
                recoveryService.recordError("Runtime recovery could not restore \(manifest.id): \(error.localizedDescription)")
            }
        case .fail(let message):
            await markCurrentSessionFailed(message: message)
        case .complete:
            await completeCurrentSessionIfReady()
        }
    }

    private func cleanupCompletedWorkingFiles() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for result in await manifestStore.loadAll() {
                guard case .loaded(let manifest) = result, manifest.status == .completed else { continue }
                let jobs = jobQueue.jobs.filter {
                    $0.sessionID == manifest.id
                        && $0.finalizationTransactionID == manifest.finalizationTransactionID
                }
                // Keep failed GIF inputs available for an operator retry; explicit cancellation permits cleanup.
                guard jobs.first(where: { $0.kind == .renderStrip })?.status == .succeeded,
                      jobs.filter({ $0.kind == .renderGIF }).allSatisfy({
                          $0.status == .succeeded || $0.status == .cancelled
                      }) else { continue }
                do {
                    try workspace.removeWorkingFiles(manifest: manifest)
                } catch {
                    recoveryService.recordError("Completed working files could not be removed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func reconcileRecoveredSessions() async {
        guard currentSession == nil else { return }
        let results = await manifestStore.loadAll()
        for result in results {
            guard case .loaded(var manifest) = result,
                  !recoveryInFlightSessionIDs.contains(manifest.id) else { continue }
            if (manifest.status == .finalizing || manifest.status == .failed),
               FinalizationPlan.make(from: manifest) == nil {
                do {
                    manifest = try await recoveryService.prepareFinalizationPlanForRecovery(for: manifest)
                } catch {
                    recoveryService.recordError("Could not migrate recovered finalization plan for \(manifest.id): \(error.localizedDescription)")
                    continue
                }
            }
            let jobs = jobQueue.jobs.filter {
                $0.sessionID == manifest.id
                    && $0.finalizationTransactionID == manifest.finalizationTransactionID
            }
            let decision = SessionJobReconciliationDecision.evaluate(
                manifest: manifest,
                jobs: jobs
            )
            switch decision {
            case .none:
                continue
            case .restoreFinalizing:
                guard claimSessionRecovery(manifest.id) else { continue }
                do {
                    defer { releaseSessionRecovery(manifest.id) }
                    _ = try await manifestStore.transition(
                        sessionID: manifest.id,
                        allowedFrom: [.failed]
                    ) { durable in
                        durable.status = .finalizing
                        durable.lastError = nil
                    }
                    scheduleJobReconciliation()
                } catch {
                    recoveryService.recordError("Runtime Case A reconciliation failed for \(manifest.id): \(error.localizedDescription)")
                }
            case .enqueueMissingRequiredJobs:
                guard claimSessionRecovery(manifest.id) else { continue }
                do {
                    defer { releaseSessionRecovery(manifest.id) }
                    try await jobQueue.enqueueFinalizationJobs(for: manifest)
                } catch {
                    recoveryService.recordError("Required finalization jobs could not be repaired for \(manifest.id): \(error.localizedDescription)")
                }
            case .fail(let message):
                guard claimSessionRecovery(manifest.id) else { continue }
                do {
                    defer { releaseSessionRecovery(manifest.id) }
                    _ = try await manifestStore.transition(
                        sessionID: manifest.id,
                        allowedFrom: [.finalizing]
                    ) { durable in
                        durable.status = .failed
                        durable.lastError = message
                    }
                } catch {
                    recoveryService.recordError("Runtime Case B reconciliation failed for \(manifest.id): \(error.localizedDescription)")
                }
            case .complete:
                guard claimSessionRecovery(manifest.id) else { continue }
                do {
                    defer { releaseSessionRecovery(manifest.id) }
                    let completed = try await manifestStore.transition(
                        sessionID: manifest.id,
                        allowedFrom: [.finalizing]
                    ) { durable in
                        durable.status = .completed
                        durable.completedAt = Date()
                        durable.lastError = nil
                    }
                    _ = store.restoreSessionRecord(from: completed)
                    store.finishSession(
                        sessionID: completed.id,
                        stripPath: completed.stripFileName.map { "\(completed.relativeDirectoryPath)/\($0)" },
                        gifPath: completed.gifFileName.map { "\(completed.relativeDirectoryPath)/\($0)" }
                    )
                    if jobs.filter({ $0.kind == .renderGIF }).allSatisfy({
                        $0.status == .succeeded || $0.status == .cancelled
                    }) {
                        do {
                            try workspace.removeWorkingFiles(manifest: completed)
                        } catch {
                            recoveryService.recordError("Recovered working files could not be removed: \(error.localizedDescription)")
                        }
                    }
                } catch {
                    recoveryService.recordError("Failed recovered-session completion update: \(error.localizedDescription)")
                }
            }
        }
    }

    private func markCurrentSessionFailed(message: String) async {
        guard let current = currentManifest,
              current.status != .failed,
              claimSessionRecovery(current.id) else { return }
        defer { releaseSessionRecovery(current.id) }
        do {
            let updated = try await manifestStore.transition(
                sessionID: current.id,
                allowedFrom: [.finalizing]
            ) { durable in
                durable.status = .failed
                durable.lastError = message
            }
            currentManifest = updated
        } catch {
            recoveryService.recordError("Failed to reload session after queue failure: \(error.localizedDescription)")
            errorMessage = "Session failure could not be persisted: \(error.localizedDescription)"
        }
    }

    private func completeCurrentSessionIfReady() async {
        guard let original = currentManifest,
              currentSession != nil,
              stateMachine.phase == .processing,
              case .idle = sessionLifecycleOperation,
              !recoveryInFlightSessionIDs.contains(original.id),
              completionInFlightSessionID != original.id,
              finishedAwaitingCustomerAckSessionID != original.id,
              claimSessionRecovery(original.id) else { return }
        let lifecycleGeneration = sessionLifecycleGeneration
        let lifecycleToken = UUID()
        // Claimed synchronously, before the first suspension point, so a
        // second job-change task cannot overtake this one mid-await.
        completionInFlightSessionID = original.id
        sessionLifecycleOperation = .completing(sessionID: original.id, token: lifecycleToken)
        defer {
            releaseSessionRecovery(original.id)
            completionInFlightSessionID = nil
            if sessionLifecycleOperation == .completing(sessionID: original.id, token: lifecycleToken) {
                sessionLifecycleOperation = .idle
            }
        }
        guard let plan = FinalizationPlan.make(from: original) else { return }
        let jobs = jobQueue.jobs.filter {
            $0.sessionID == original.id
                && $0.finalizationTransactionID == plan.transactionID
        }
        guard jobs.first(where: { $0.kind == .renderStrip })?.status == .succeeded,
              jobs.first(where: { $0.kind == .registerDownload })?.status == .succeeded else {
            return
        }
        let serverStatus = await server.statusSnapshot()
        guard sessionLifecycleGeneration == lifecycleGeneration,
              currentManifest?.id == original.id,
              sessionLifecycleOperation == .completing(sessionID: original.id, token: lifecycleToken) else { return }
        guard case .ready = serverStatus.state else {
            errorMessage = "Session finished, but the local download server is unavailable. QR/download links were not published."
            return
        }
        let manifest: SessionManifest
        do {
            manifest = try await manifestStore.transition(
                sessionID: original.id,
                allowedFrom: [.finalizing]
            ) { durable in
                durable.status = .completed
                durable.completedAt = Date()
                durable.lastError = nil
            }
        } catch {
            recoveryService.recordError("Completed session could not be persisted: \(error.localizedDescription)")
            errorMessage = "Completed session could not be persisted: \(error.localizedDescription)"
            return
        }
        guard sessionLifecycleGeneration == lifecycleGeneration,
              currentManifest?.id == original.id,
              sessionLifecycleOperation == .completing(sessionID: original.id, token: lifecycleToken) else { return }
        guard manifest.status == .completed else {
            return
        }
        currentManifest = manifest
        lastCompletedSessionID = manifest.id
        recordOperation(.sessionCompleted, sessionID: manifest.id, duration: Date().timeIntervalSince(manifest.startedAt))
        store.finishSession(
            sessionID: manifest.id,
            stripPath: manifest.stripFileName.map { "\(manifest.relativeDirectoryPath)/\($0)" },
            gifPath: manifest.gifFileName.map { "\(manifest.relativeDirectoryPath)/\($0)" }
        )
        if let persistenceError = store.lastPersistenceError {
            recoveryService.recordError("Completed event record could not be persisted: \(persistenceError)")
            errorMessage = "Completed event record could not be persisted: \(persistenceError)"
        }

        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        let token = manifest.downloadToken
        let publicBase = (manifest.cloudDelivery?.publicBaseURL
            ?? UserDefaults.standard.string(forKey: "publicBaseURL"))?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let cloudUploadEnabled = manifest.deliveryIntent?.cloudUploadEnabled
            ?? (manifest.cloudDelivery != nil || UserDefaults.standard.bool(forKey: "cloudUploadEnabled"))
        let localBaseURL = LocalWebServer.guestDeliveryEndpoint(selection: guestDeliveryInterfaceSelection)
            .endpoint?.baseURL ?? ""
        let allowTrustedLocalHTTP = UserDefaults.standard.bool(forKey: "allowTrustedLocalHTTP")
        let qr = Self.downloadURL(
            publicBaseURL: publicBase,
            localBaseURL: localBaseURL,
            token: token,
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )
        let stripThumb = loadCGImage(from: directory.appendingPathComponent("strip.png"))
            .flatMap { jpegData(from: $0, quality: 0.4) }
        currentStripPreview = loadCGImage(from: directory.appendingPathComponent("strip.png"))
        stripAssetReference = stripThumb.map {
            makeAssetReference(
                data: $0,
                assetID: "strip-\(manifest.id)",
                sessionID: manifest.id,
                revision: "output-v1",
                kind: .stripThumbnail
            )
        }
        finishedAwaitingCustomerAckSessionID = manifest.id
        stateMachine.finishSession(qrPayload: qr)
        if let context = nextSessionMessageContext() {
            if let stripThumb, let stripAssetReference {
                assetSources[stripAssetReference] = stripThumb
            }
            multipeer.sendControl(.sessionFinishedAssets(
                context: context,
                qrPayload: qr,
                stripAsset: stripAssetReference,
                gifAsset: nil
            ))
            if let stripThumb, let stripAssetReference {
                _ = sendAsset(data: stripThumb, reference: stripAssetReference)
            }
        }
        if jobs.filter({ $0.kind == .renderGIF }).allSatisfy({
            $0.status == .succeeded || $0.status == .cancelled
        }) {
            do {
                try workspace.removeWorkingFiles(manifest: manifest)
            } catch {
                recoveryService.recordError("Working files could not be removed: \(error.localizedDescription)")
            }
        }
        currentSession = nil
        lastSessionPresentation = currentSessionPresentation
        currentSessionPresentation = nil
        sessionLifecycleOperation = .idle
        attemptPendingLANRecoveryIfIdle()
    }

    private func restoreDownloadTokens() async {
        await refreshServerRoutes()
    }

    func refreshServerRoutes() async {
        serverRouteRefreshGeneration &+= 1
        let generation = serverRouteRefreshGeneration
        let defaults = UserDefaults.standard
        let allowTrustedLocalHTTP = defaults.bool(forKey: "allowTrustedLocalHTTP")
        let policy = SessionQRCodePayloadResolver.evaluatePolicy(
            publicBaseURL: defaults.string(forKey: "publicBaseURL"),
            cloudUploadEnabled: defaults.bool(forKey: "cloudUploadEnabled"),
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )
        let exposure: LocalGuestRouteExposure = policy.permitsLocalGuestHTTP(
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        ) ? .trustedLocalHTTP : .disabled
        await server.setGuestRouteExposure(exposure)

        var galleryMappings: [String: EventGalleryRouteRegistration] = [:]
        for result in await galleryStore.loadAll() {
            guard case .loaded(let index) = result else { continue }
            if let document = try? await experienceStore.load(eventID: index.eventID),
               document.gallery.mode == .disabled {
                continue
            }
            let approved = index.sessions
                .filter { $0.approvalStatus == .approved }
                .map { entry in
                    GalleryRouteSession(
                        sessionID: entry.sessionID,
                        downloadToken: entry.downloadToken,
                        startedAt: entry.startedAt,
                        thumbnailURL: URL(fileURLWithPath: entry.absoluteSessionDirectoryPath)
                            .appendingPathComponent(entry.thumbnailFileName),
                        gifAvailable: entry.gifFileName != nil,
                        templateName: entry.templateName.value(for: index.language),
                        filterID: entry.filterID
                    )
                }
            galleryMappings[index.eventToken] = EventGalleryRouteRegistration(
                eventID: index.eventID,
                eventToken: index.eventToken,
                title: index.title.value(for: index.language),
                language: index.language,
                showGIFLinks: index.showGIFLinks,
                approvedSessions: approved
            )
        }

        var sessionMappings: [String: SessionRouteRegistration] = [:]
        for result in await manifestStore.loadAll() {
            guard case .loaded(let manifest) = result,
                  manifest.status == .completed || manifest.status == .finalizing else { continue }
            let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
            let strip = directory.appendingPathComponent(manifest.stripFileName ?? "strip.png")
            guard FileManager.default.fileExists(atPath: directory.path),
                  FileManager.default.fileExists(atPath: strip.path) else {
                recoveryService.recordError("Cannot restore download token for \(manifest.eventName): session output is missing.")
                continue
            }
            let galleryPath = manifest.eventConfig.eventGalleryPath.flatMap { path in
                galleryMappings.values.contains(where: { "/e/\($0.eventToken)/" == path }) ? path : nil
            }
            sessionMappings[manifest.downloadToken] = SessionRouteRegistration(
                sessionDirectory: directory,
                language: manifest.eventConfig.customerLanguage,
                eventGalleryPath: galleryPath,
                gifState: gifAvailability(for: manifest, directory: directory)
            )
        }
        guard generation == serverRouteRefreshGeneration else { return }
        await server.replaceSessionRoutes(sessionMappings)
        await server.replaceGalleryRoutes(galleryMappings)
    }

    private func gifAvailability(
        for manifest: SessionManifest,
        directory: URL
    ) -> GIFAvailabilityState {
        guard manifest.shots.contains(where: { !$0.gifFrameFileNames.isEmpty }) else { return .none }
        let gifURL = directory.appendingPathComponent("booth.gif")
        let fileExists = FileManager.default.fileExists(atPath: gifURL.path)
        guard let plan = FinalizationPlan.make(from: manifest),
              plan.jobKinds.contains(.renderGIF),
              let job = jobQueue.jobs.first(where: {
            $0.sessionID == manifest.id
                && $0.finalizationTransactionID == plan.transactionID
                && $0.kind == .renderGIF
        }) else {
            return manifest.gifFileName != nil && fileExists ? .ready : .preparing
        }
        switch job.status {
        case .succeeded:
            return fileExists ? .ready : .failed
        case .failed, .cancelled:
            return .failed
        case .pending, .running, .waitingRetry:
            return .preparing
        }
    }

    // MARK: - Session cleanup (M10)

    private func cleanupOldSessions(keepDays: Int) async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())!
        for result in await manifestStore.loadAll() {
            guard case .loaded(let manifest) = result else { continue }
            if manifest.status == .completed,
               let completedAt = manifest.completedAt,
               completedAt < cutoff {
                do {
                    let flowQuiesced = await sessionFlowOperations.cancelAndQuiesce(
                        sessionID: manifest.id,
                        timeout: .seconds(10)
                    )
                    let jobQuiescence = try await jobQueue.cancelAndQuiesceJobs(sessionID: manifest.id)
                    guard flowQuiesced, jobQuiescence == .quiesced else {
                        recoveryService.markCleanupPending(sessionID: manifest.id)
                        continue
                    }
                    try workspace.removeEntireSession(manifest: manifest)
                } catch {
                    recoveryService.recordError("Old session files could not be removed: \(error.localizedDescription)")
                    continue
                }
                do {
                    try await manifestStore.delete(sessionID: manifest.id)
                    try await jobQueue.deleteJobsAndForgetCancellationBarrier(sessionID: manifest.id)
                } catch {
                    recoveryService.recordError("Old session manifest could not be removed: \(error.localizedDescription)")
                    continue
                }
                await server.unregisterToken(manifest.downloadToken)
                if let session = store.fetchSession(id: manifest.id) { store.deleteSession(session) }
            } else if manifest.status == .cancelled,
                      let cancelledAt = manifest.cancelledAt,
                      cancelledAt < Calendar.current.date(byAdding: .day, value: -7, to: Date())! {
                do {
                    let result = try await jobQueue.cancelAndQuiesceJobs(sessionID: manifest.id)
                    guard result == .quiesced else {
                        recoveryService.markCleanupPending(sessionID: manifest.id)
                        continue
                    }
                    try workspace.removeEntireSession(manifest: manifest)
                    try await manifestStore.delete(sessionID: manifest.id)
                    try await jobQueue.deleteJobsAndForgetCancellationBarrier(sessionID: manifest.id)
                } catch {
                    recoveryService.markCleanupPending(sessionID: manifest.id)
                    recoveryService.recordError("Cancelled session cleanup could not finish: \(error.localizedDescription)")
                }
            }
        }
        jobQueue.purgeOldSucceededJobs(olderThan: Calendar.current.date(byAdding: .day, value: -7, to: Date())!)

        // Keep the pre-1.1 cleanup path for sessions that predate runtime manifests.
        for session in store.fetchSessions(finishedBefore: cutoff) {
            // Skip sessions managed by the manifest system (Finding 14).
            if let _ = try? await manifestStore.load(sessionID: session.id) {
                continue
            }
            if let stripPath = session.stripPath {
                let strip = picturesOutputDir()?.appendingPathComponent(stripPath)
                if let strip {
                    do {
                        try FileManager.default.removeItem(at: strip.deletingLastPathComponent())
                    } catch {
                        recoveryService.recordError("Legacy session files could not be removed: \(error.localizedDescription)")
                    }
                }
            }
            store.deleteSession(session)
        }
    }

    // MARK: - Print

    func printCurrentStrip() {
        guard let sessionID = lastCompletedSessionID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            printer.refreshPrinters()
            let manifest: SessionManifest
            do {
                manifest = try await manifestStore.load(sessionID: sessionID)
            } catch {
                errorMessage = "Print could not load the completed session: \(error.localizedDescription)"
                return
            }
            let url = URL(fileURLWithPath: manifest.absoluteDirectoryPath).appendingPathComponent(manifest.stripFileName ?? "strip.png")
            do {
                try await printer.printStrip(at: url, showPrintDialog: true)
            } catch {
                errorMessage = "Print failed: \(error.localizedDescription)"
            }
        }
    }

    func printAgainCurrentStrip() {
        guard let sessionID = lastCompletedSessionID else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            printer.refreshPrinters()
            let manifest: SessionManifest
            do {
                manifest = try await manifestStore.load(sessionID: sessionID)
            } catch {
                errorMessage = "Print could not load the completed session: \(error.localizedDescription)"
                return
            }
            let url = URL(fileURLWithPath: manifest.absoluteDirectoryPath)
                .appendingPathComponent(manifest.stripFileName ?? "strip.png")
            do {
                try await printer.printStrip(
                    at: url,
                    showPrintDialog: true
                )
            } catch {
                errorMessage = "Print failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Multipeer handlers

    private func setupMultipeerHandlers() {
        multipeer.onControlMessage = { [weak self] msg in
            self?.handleMessage(msg)
        }
        multipeer.onTransportReady = { [weak self] peer in
            guard peer.role == .iPad else { return }
            self?.handleTransportReady()
        }
        multipeer.onAssetChunk = { [weak self] chunk in
            self?.handleAssetChunk(chunk)
        }
        multipeer.onTransportEvent = { [weak self] event in
            self?.recordTransportEvent(event)
        }
    }

    private func recordTransportEvent(_ event: BoothTransportDiagnosticEvent) {
        guard let kind = OperationsEventKind(rawValue: event.kind.rawValue) else { return }
        recordOperation(
            kind,
            duration: event.duration,
            reason: event.reason,
            channel: event.channel,
            route: event.route,
            attempt: event.attempt,
            byteCount: event.byteCount,
            targetPeerID: event.targetPeerID,
            routeGeneration: event.routeGeneration,
            networkPreference: event.networkPreference,
            candidateSource: event.candidateSource
        )
    }

    private func handleTransportReady() {
        if let event = activeEvent {
            multipeer.sendControl(.eventConfig(config: event.toEventConfig()))
        }
        sendExperienceCatalog()
        resynciPad()
    }

    private func handleMessage(_ msg: Message) {
        switch msg {
        case .customerSessionStartRequest(let request):
            if let active = activeSessionStart {
                if active.requestID == request.requestID {
                    sendSessionStartResult(requestID: request.requestID, result: .inProgress)
                } else {
                    sendSessionStartResult(
                        requestID: request.requestID,
                        result: .rejected(reason: LocalizedText(
                            english: "A session is already starting.",
                            thai: "มีการเริ่มเซสชันอยู่แล้ว"
                        ).value(for: request.selection?.language ?? .english))
                    )
                }
                break
            }
            if request.requestID == lastSessionStartRequestID,
               let sessionID = lastSessionStartSessionID {
                sendSessionStartResult(
                    requestID: request.requestID,
                    result: .accepted(sessionID: sessionID)
                )
                resynciPad()
                break
            }
            guard currentSession == nil, finishedAwaitingCustomerAckSessionID == nil else {
                sendSessionStartResult(
                    requestID: request.requestID,
                    result: .rejected(reason: LocalizedText(
                        english: "A session is already in progress.",
                        thai: "มีเซสชันกำลังดำเนินการอยู่แล้ว"
                    ).value(for: request.selection?.language ?? .english))
                )
                break
            }
            startSession(selection: request.selection, requestID: request.requestID)
        case .sessionStart:
            break
        case .assetRequest(let references):
            handleAssetRequest(references)
        case .customerSessionRequest(let selection):
            guard stateMachine.phase == .idle || stateMachine.phase == .selectingExperience || stateMachine.phase == .readyToStart else {
                multipeer.sendControl(.sessionRequestRejected(reason: LocalizedText(
                    english: "A session is already in progress.",
                    thai: "มีเซสชันกำลังดำเนินการอยู่แล้ว"
                ).value(for: selection.language)))
                return
            }
            startSession(selection: selection)
        case .reviewDecision(let state, let requestID, let action):
            handleClientReviewDecision(state: state, requestID: requestID, action: action)
        case .captureRecoveryAction(let state, let requestID, let action):
            handleCaptureRecoveryAction(state: state, requestID: requestID, action: action)
        case .customerFinished(let context):
            handleCustomerFinished(context)
        default: break
        }
    }

    private func handleAssetChunk(_ chunk: BoothAssetChunk) {
        // The transport authenticates the peer; the session binding below keeps a
        // delayed asset from a prior session out of the current display.
        guard chunk.metadata.sessionID == nil
                || chunk.metadata.sessionID == currentSession?.id
                || chunk.metadata.sessionID == stateMachine.currentSessionID else { return }
        do {
            _ = try assetAssembler.append(chunk)
        } catch {
            errorMessage = "Received asset data was rejected."
        }
    }

    private func handleAssetRequest(_ references: [BoothAssetReference]) {
        guard !references.isEmpty, references.count <= 16 else {
            errorMessage = "Asset recovery request was rejected."
            return
        }
        var seen = Set<BoothAssetReference>()
        for reference in references where seen.insert(reference).inserted {
            let isKnownSession = reference.sessionID == nil
                || reference.sessionID == currentSession?.id
                || reference.sessionID == stateMachine.currentSessionID
                || reference.sessionID == lastCompletedSessionID
            guard isKnownSession else {
                multipeer.sendControl(.assetUnavailable(
                    reference: reference,
                    reason: "The requested asset is no longer available."
                ))
                continue
            }
            guard let data = assetSources[reference],
                  data.count == reference.byteCount,
                  Data(SHA256.hash(data: data)) == reference.sha256 else {
                multipeer.sendControl(.assetUnavailable(
                    reference: reference,
                    reason: "The requested asset is no longer available."
                ))
                continue
            }
            // A valid source can still be temporarily unable to queue on the
            // asset channel. Keep it retryable; only missing/invalid sources
            // are permanently unavailable.
            _ = sendAsset(data: data, reference: reference)
        }
    }

    private func handleCustomerFinished(_ context: SessionMessageContext) {
        guard activeSoakRunID == nil,
              let sessionID = finishedAwaitingCustomerAckSessionID,
              context.sessionID == sessionID,
              context.sequence <= sessionMessageSequence,
              acceptsClientSessionMessage(context),
              case .finished = stateMachine.phase,
              customerFinishedInFlightSessionID == nil else { return }
        customerFinishedInFlightSessionID = sessionID
        sessionMessageSequence &+= 1
        let idle = SessionSyncSnapshot(
            config: stateMachine.config,
            sessionID: nil,
            phase: .idle,
            presentation: nil,
            isMirrored: capture.camera.isMirrored,
            sequence: sessionMessageSequence,
            authorityEpoch: authorityEpoch
        )
        multipeer.sendControl(.sessionSync(snapshot: idle)) { [weak self] outcome in
            guard let self else { return }
            guard self.customerFinishedInFlightSessionID == sessionID else { return }
            guard outcome == .sent,
                  self.finishedAwaitingCustomerAckSessionID == sessionID else {
                self.customerFinishedInFlightSessionID = nil
                self.errorMessage = "The next session acknowledgement could not be delivered."
                return
            }
            self.customerFinishedInFlightSessionID = nil
            self.finishedAwaitingCustomerAckSessionID = nil
            self.sessionLifecycleGeneration &+= 1
            self.currentManifest = nil
            self.currentManifestID = nil
            self.retakeCounts = [:]
            self.gifFrames = [:]
            self.currentCaptureAttempt = nil
            self.currentCountdown = nil
            self.currentStripPreview = nil
            self.currentFilteredReviewImages = [:]
            self.currentSessionPresentation = nil
            self.lastSessionPresentation = nil
            self.sessionAssetReferences = [:]
            self.stripAssetReference = nil
            self.assetSources = [:]
            self.pendingPromptAssets = [:]
            self.assetAssembler = BoothAssetAssembler()
            self.capture.resetStills()
            self.reviewDecisionPending = false
            self.currentReviewStateToken = nil
            self.activeReviewRequestID = nil
            self.recentReviewRequests.removeAll(keepingCapacity: true)
            self.recentReviewRequestOrder.removeAll(keepingCapacity: true)
            self.stateMachine.reset()
            self.attemptPendingLANRecoveryIfIdle()
        }
    }

    private func nextSessionMessageContext() -> SessionMessageContext? {
        let sessionID = currentSession?.id ?? (stateMachine.currentSessionID.isEmpty ? nil : stateMachine.currentSessionID)
        guard let sessionID else { return nil }
        sessionMessageSequence &+= 1
        return SessionMessageContext(
            sessionID: sessionID,
            sequence: sessionMessageSequence,
            authorityEpoch: authorityEpoch
        )
    }

    private func acceptsClientSessionMessage(_ context: SessionMessageContext) -> Bool {
        let current = currentSession?.id ?? stateMachine.currentSessionID
        guard !current.isEmpty, context.sessionID == current else {
            #if DEBUG
            NSLog("[Session] Ignored client message for session %@; current is %@.", context.sessionID, current.isEmpty ? "none" : current)
            #endif
            return false
        }
        return context.authorityEpoch == authorityEpoch
    }

    // Push current Mac state to iPad after (re)connect so it's never stuck at idle mid-session.
    private func resynciPad() {
        let phase = stateMachine.phase
        let sessionID: String? = switch phase {
        case .idle, .selectingExperience: nil
        case .readyToStart: currentSession?.id
        default: currentSession?.id ?? lastCompletedSessionID
        }
        let context = sessionID == nil ? nil : nextSessionMessageContext()
        let sequence: UInt64
        if let context {
            sequence = context.sequence
        } else {
            sessionMessageSequence &+= 1
            sequence = sessionMessageSequence
        }
        if case .review(let index) = phase, let context {
            currentReviewStateToken = ReviewStateToken(
                sessionID: context.sessionID,
                photoIndex: index,
                revision: context.sequence,
                authorityEpoch: context.authorityEpoch
            )
        } else if case .captureRecovery = phase {
            // Keep the original recovery occurrence across reconnects. A new
            // sync sequence must not make an old action valid again.
        } else {
            currentReviewStateToken = nil
            currentCaptureRecoveryStateToken = nil
        }
        multipeer.sendControl(.sessionSync(snapshot: SessionSyncSnapshot(
            config: stateMachine.config,
            sessionID: sessionID,
            phase: phase,
            presentation: currentSessionPresentation ?? lastSessionPresentation,
            isMirrored: capture.camera.isMirrored,
            isBoothPaused: isBoothPaused,
            sequence: sequence,
            countdown: currentCountdown,
            reviewAsset: {
                guard case .review(let index) = phase else { return nil }
                return sessionAssetReferences[index]
            }(),
            stripAsset: {
                guard case .finished = phase else { return nil }
                return stripAssetReference
            }(),
            keptShotAssets: sessionAssetReferences,
            acceptedPhotoIndices: stateMachine.acceptedPhotoIndices.sorted(),
            deferredPhotoIndices: stateMachine.deferredPhotoIndices.sorted(),
            nextPhotoIndex: stateMachine.nextPhotoIndex,
            captureRecoveryState: currentCaptureRecoveryStateToken,
            authorityEpoch: authorityEpoch
        )))
        multipeer.sendControl(.setMirrored(isMirrored: capture.camera.isMirrored))
    }

    // MARK: - Directories

    private static func loadNetworkPreference() -> BoothNetworkPreference {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: networkPreferenceKey),
           let preference = BoothNetworkPreference(rawValue: raw) {
            return preference
        }

        // The removed preview setting maps to Wi-Fi during migration.
        defaults.set(BoothNetworkPreference.wifi.rawValue, forKey: networkPreferenceKey)
        defaults.removeObject(forKey: "previewConnectionMode")
        return .wifi
    }

    static func appSupportRootURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("PRC-PhotoBooth", isDirectory: true)
    }

    static func runtimeDirectoryURL() -> URL {
        Self.appSupportRootURL().appendingPathComponent("Runtime", isDirectory: true)
    }

    nonisolated static func eventFolderURL(storedPath: String?, fallback: URL) -> URL {
        guard let storedPath, !storedPath.isEmpty else { return fallback }
        return URL(fileURLWithPath: storedPath, isDirectory: true)
    }

    var eventFolderPath: String { picturesOutputDir()?.path ?? "Unavailable" }

    var cameraHealthSnapshot: CameraHealthSnapshot {
        let dslr = cameraSourceKind == .dslr
        let connected = selectedCaptureSourceReady
        let selectedName = dslr
            ? capture.dslr.selectedDeviceName
            : capture.camera.availableDevices.first(where: { $0.id == capture.camera.selectedDeviceID })?.name
        return CameraHealthSnapshot(
            connected: connected,
            connecting: dslr && capture.dslr.isConnecting,
            cameraName: selectedName,
            cameraKind: cameraSourceKind.rawValue,
            livePreviewActive: dslr ? capture.dslr.isLivePreviewActive : capture.isRunning,
            previewFPS: dslr ? capture.dslr.measuredPreviewFPS : nil,
            ptpHealthy: dslr ? capture.dslr.isPTPHealthy : nil,
            captureInProgress: currentCaptureAttempt != nil,
            lastCaptureAt: capture.lastCaptureAt,
            lastCaptureDuration: capture.lastCaptureDuration,
            lastCaptureError: capture.lastCaptureError,
            captureSuccessCount: capture.captureSuccessCount,
            captureFailureCount: capture.captureFailureCount,
            recoveredTransferCount: capture.recoveredTransferCount,
            reconnectCount: cameraReconnectCount,
            batteryLevel: nil
        )
    }

    func healthSnapshot() async -> BoothHealthSnapshot {
        let serverStatus = await server.statusSnapshot()
        let queue = jobQueue.jobs
        let displayReady = isCustomerDisplayReady
        let connectedPeer: String? = displayReady ? connectionStatus.peerDisplayName : nil
        let serverHealth: BoothHealthStatus = switch serverStatus.state {
        case .ready: .healthy
        case .starting: .unknown
        case .failed: .unavailable
        case .stopped: .unavailable
        }
        let disk = picturesOutputDir().flatMap {
            try? $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        }.map(Int64.init)
        let camera = cameraHealthSnapshot
        let hasRequiredFailure = queue.contains { !$0.kind.isOptional && $0.status == .failed }
        let connectionHealthy = displayReady
        let overall: BoothHealthStatus = camera.connected
            && serverHealth == .healthy
            && connectionHealthy
            && !hasRequiredFailure
            ? .healthy
            : camera.connected || serverHealth == .healthy || connectionHealthy ? .degraded : .unavailable
        let deliverySessionID = currentSession?.id ?? lastCompletedSessionID
        let deliveryJobs = deliverySessionID.map { sessionID in queue.filter { $0.sessionID == sessionID } } ?? []
        return BoothHealthSnapshot(
            updatedAt: Date(),
            status: overall,
            camera: camera,
            customerDisplayConnected: displayReady,
            customerDisplayPeer: connectedPeer,
            controlConnection: connectionLabel(connectionStatus.state),
            previewConnection: effectiveNetworkLabel,
            localServer: serverHealth,
            diskAvailableBytes: disk,
            queuePending: queue.filter { $0.status == .pending }.count,
            queueRunning: queue.filter { $0.status == .running }.count,
            queueRetrying: queue.filter { $0.status == .waitingRetry }.count,
            queueFailed: queue.filter { $0.status == .failed }.count,
            printerName: printerLabel,
            printerStatus: printerStatusLabel,
            printSuccessCount: printer.printSuccessCount,
            printFailureCount: printer.printFailureCount,
            cloudPendingCount: queue.filter { $0.kind == .cloudUpload && ($0.status == .pending || $0.status == .running || $0.status == .waitingRetry) }.count,
            cloudFailedCount: queue.filter { $0.kind == .cloudUpload && $0.status == .failed }.count,
            currentSessionID: currentSession?.id,
            currentPhase: stateMachine.phase.displayName,
            isBoothPaused: isBoothPaused,
            delivery: deliveryJobs.isEmpty ? nil : SessionDeliveryResolver.resolve(
                deliveryJobs,
                transactionID: currentManifest?.finalizationTransactionID
            )
        )
    }

    private var printerLabel: String {
        switch printer.configuredPrinterStatus() {
        case .systemDefault: return NSPrintInfo.shared.printer.name
        case .unavailable(let name): return name
        }
    }

    private var printerStatusLabel: String {
        switch printer.configuredPrinterStatus() {
        case .systemDefault: return "available"
        case .unavailable: return "unavailable"
        }
    }

    private func connectionLabel(_ state: BoothConnectionState) -> String {
        switch state {
        case .connected(let peer): return "connected: \(peer)"
        case .connecting: return "connecting"
        case .disconnected: return "disconnected"
        }
    }

    private var effectiveNetworkLabel: String {
        switch connectionStatus.effectiveNetwork {
        case .wifi:
            return connectionStatus.isFallbackActive ? "Wi-Fi fallback" : "Wi-Fi"
        case .lan: return "LAN (Ethernet)"
        case .unavailable: return "unavailable"
        }
    }

    private func recordOperation(
        _ kind: OperationsEventKind,
        sessionID: String? = nil,
        photoIndex: Int? = nil,
        duration: Double? = nil,
        reason: String? = nil,
        channel: String? = nil,
        route: String? = nil,
        attempt: Int? = nil,
        byteCount: Int? = nil,
        targetPeerID: String? = nil,
        routeGeneration: Int? = nil,
        networkPreference: BoothNetworkPreference? = nil,
        candidateSource: String? = nil
    ) {
        Task {
            await operationsEvents.record(
                kind,
                sessionID: sessionID,
                photoIndex: photoIndex,
                duration: duration,
                reason: reason,
                channel: channel,
                route: route,
                attempt: attempt,
                byteCount: byteCount,
                targetPeerID: targetPeerID,
                routeGeneration: routeGeneration,
                networkPreference: networkPreference,
                candidateSource: candidateSource
            )
        }
    }

    func setEventFolder(_ url: URL) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            errorMessage = "Cannot use this event folder: \(error.localizedDescription)"
            return
        }
        UserDefaults.standard.set(url.path, forKey: Self.eventFolderPathKey)
    }

    func appSupportDir() -> URL? {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PRC-PhotoBooth")
        guard let d else { return nil }
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        } catch {
            startupComponents[.runtimeDirectory] = StartupComponentHealth(
                status: .unavailable,
                detail: "Application Support storage is unavailable: \(error.localizedDescription)"
            )
            errorMessage = startupComponents[.runtimeDirectory]?.detail
            return nil
        }
        return d
    }

    func picturesOutputDir() -> URL? {
        guard let fallback = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("PRC-PhotoBooth") else { return nil }
        let d = Self.eventFolderURL(
            storedPath: UserDefaults.standard.string(forKey: Self.eventFolderPathKey),
            fallback: fallback
        )
        do {
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            return d
        } catch {
            errorMessage = "Cannot use the event folder: \(error.localizedDescription)"
            return nil
        }
    }

    var productionSoakOutputDirectory: URL? { picturesOutputDir() }

    private func safeFolderName(_ s: String) -> String {
        SessionWorkspace.safeEventFolderName(s)
    }

    private func workspaceDescriptor(from manifest: SessionManifest) -> SessionWorkspaceDescriptor {
        SessionWorkspaceDescriptor(
            outputRootPath: manifest.outputRootPath,
            relativeDirectoryPath: manifest.relativeDirectoryPath,
            absoluteDirectoryPath: manifest.absoluteDirectoryPath,
            frameSnapshotFileName: manifest.frameSnapshotFileName,
            foregroundOverlaySnapshotFileName: manifest.foregroundOverlaySnapshotFileName
        )
    }

    private func upsertManifestShot(
        _ manifest: inout SessionManifest,
        photoIndex: Int,
        imageFileName: String?,
        gifFrameFileNames: [String],
        retakeCount: Int,
        acceptedAt: Date?,
        previousImageFileName: String? = nil,
        previousGifFrameFileNames: [String]? = nil,
        previousAcceptedAt: Date? = nil
    ) {
        upsertRuntimeShot(
            in: &manifest.shots,
            photoIndex: photoIndex,
            imageFileName: imageFileName,
            gifFrameFileNames: gifFrameFileNames,
            retakeCount: retakeCount,
            acceptedAt: acceptedAt,
            previousImageFileName: previousImageFileName,
            previousGifFrameFileNames: previousGifFrameFileNames,
            previousAcceptedAt: previousAcceptedAt
        )
    }
}

private func localizedOptional(_ text: LocalizedText, language: CustomerLanguage) -> String {
    let requested = language == .english ? text.english : text.thai
    let other = language == .english ? text.thai : text.english
    return [requested, other]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty }) ?? ""
}

func incrementRetakeCount(in counts: inout [Int: Int], photoIndex: Int) -> Int {
    counts[photoIndex, default: 0] += 1
    return counts[photoIndex] ?? 1
}

func upsertRuntimeShot(
    in shots: inout [RuntimeShotRecord],
    photoIndex: Int,
    imageFileName: String?,
    gifFrameFileNames: [String],
    retakeCount: Int,
    acceptedAt: Date?,
    previousImageFileName: String? = nil,
    previousGifFrameFileNames: [String]? = nil,
    previousAcceptedAt: Date? = nil
) {
    let shot = RuntimeShotRecord(
        photoIndex: photoIndex,
        imageFileName: imageFileName,
        gifFrameFileNames: gifFrameFileNames,
        retakeCount: max(0, retakeCount),
        acceptedAt: acceptedAt,
        previousImageFileName: previousImageFileName,
        previousGifFrameFileNames: previousGifFrameFileNames,
        previousAcceptedAt: previousAcceptedAt
    )
    if let index = shots.firstIndex(where: { $0.photoIndex == photoIndex }) {
        shots[index] = shot
    } else {
        shots.append(shot)
    }
    shots.sort { $0.photoIndex < $1.photoIndex }
}
