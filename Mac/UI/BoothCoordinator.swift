import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import ImageIO
import SwiftData
import Observation
import AVFoundation

enum CameraSourceKind: String, CaseIterable, Identifiable {
    case avFoundation = "Built-in / USB / Continuity"
    case dslr         = "DSLR / Mirrorless (USB Tethered)"
    var id: String { rawValue }
}

// Which channel carries the live preview stream to the iPad.
// Control messages remain on the reliable BoothTransport control channel;
// USB is an optional preview-only path.
enum PreviewConnectionMode: String, CaseIterable, Identifiable {
    case wireless = "Wireless (Wi-Fi)"
    case cable    = "Cable (USB)"
    var id: String { rawValue }
}

enum PreviewFrameRate: Int, CaseIterable, Identifiable {
    case standard = 30
    case maximum = 60

    var id: Int { rawValue }
    var label: String { "\(rawValue) FPS" }
}

enum SelphyPaperSize: String, CaseIterable {
    case postcard   = "Postcard (4×6\")"
    case lSize      = "L-size (3.5×5\")"
    case creditCard = "Credit Card"

    var pointSize: NSSize {
        switch self {
        case .postcard:    return NSSize(width: 288, height: 432) // 4×6 in at 72 pt/in
        case .lSize:       return NSSize(width: 252, height: 360)
        case .creditCard:  return NSSize(width: 153, height: 244)
        }
    }
}

@MainActor
@Observable
final class BoothCoordinator {
    static let eventFolderPathKey = "eventFolderPath"

    nonisolated static func downloadURL(
        publicBaseURL: String?,
        localBaseURL: String,
        token: String,
        cloudUploadEnabled: Bool
    ) -> String {
        (try? SessionQRCodePayloadResolver.resolve(
            token: token,
            localBaseURL: localBaseURL,
            publicBaseURL: publicBaseURL,
            cloudUploadEnabled: cloudUploadEnabled
        )) ?? "\(localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))/s/\(token)/"
    }

    let multipeer: BoothTransport
    let capture: CaptureService
    let stateMachine: SessionStateMachine
    let server: LocalWebServer
    let operatorAuth: RemoteOperatorAuth
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
    let usbPreview = USBPreviewServer()
    let experienceStore: EventExperienceStore
    let filterPipeline: PhotoFilterPipeline
    let galleryStore: EventGalleryStore

    var activeEvent: BoothEvent? {
        didSet {
            capture.captureRotationDegrees = activeEvent?.cameraRotationDegrees ?? 0
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
    var serverURL: String = ""
    var cameraSourceKind: CameraSourceKind = .avFoundation {
        didSet {
            if cameraSourceKind == .avFoundation {
                capture.usesDSLR = false
            }
        }
    }
    var cameraPermissionGranted: Bool = false
    private(set) var isBoothPaused = false
    var previewConnectionMode: PreviewConnectionMode {
        get { PreviewConnectionMode(rawValue: UserDefaults.standard.string(forKey: "previewConnectionMode") ?? "") ?? .wireless }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "previewConnectionMode") }
    }
    var previewFrameRate: PreviewFrameRate {
        get { PreviewFrameRate(rawValue: UserDefaults.standard.integer(forKey: "previewFrameRate")) ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "previewFrameRate")
            capture.setPreviewFrameRate(newValue.rawValue)
        }
    }

    private var currentSession: BoothSession?
    private var currentManifest: SessionManifest?
    private var currentManifestID: String?
    private(set) var lastCompletedSessionID: String?
    private var retakeCounts: [Int: Int] = [:]
    private var gifFrames: [Int: [CGImage]] = [:]
    private var countdownTask: Task<Void, Never>?
    private var currentCaptureAttempt: CaptureAttempt?
    private var hasSeenDSLRConnection = false
    private var wasDSLRConnected = false
    private(set) var cameraReconnectCount = 0
    var currentStripPreview: CGImage?
    private(set) var currentFilteredReviewImages: [Int: CGImage] = [:]
    private(set) var currentSessionPresentation: SessionPresentation?
    private var lastSessionPresentation: SessionPresentation?
    var externalSelection = CustomerSessionSelectionDraft()

    // MARK: - External display viewer
    private(set) var externalScreens: [NSScreen] = []
    private var externalDisplayWindow: NSWindow?
    var isExternalViewerActive: Bool { externalDisplayWindow != nil }

    init() {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--legacy-multipeer") {
            multipeer = MultipeerService(role: .mac)
        } else {
            multipeer = NetworkBoothTransport(role: .mac)
        }
#else
        multipeer = NetworkBoothTransport(role: .mac)
#endif
        capture = CaptureService()
        stateMachine = SessionStateMachine()
        server = LocalWebServer(port: 8585)
        operatorAuth = RemoteOperatorAuth()
        store = DataStore.shared
        cloudSSHSetup = CloudSSHSetupService()
        let runtimeDirectory = Self.runtimeDirectoryURL()
        try? FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
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
            galleryStore: galleryStore
        )
        jobQueue = SessionJobQueue(store: jobStore, executor: executor)
        recoveryService = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: workspace,
            jobQueue: jobQueue
        )
        preflight = BoothPreflightService()
        jobQueue.onJobsChanged = { [weak self] in
            self?.reconcileCurrentSessionJobs()
            self?.reconcileRecoveredSessions()
            self?.cleanupCompletedWorkingFiles()
            Task { @MainActor [weak self] in await self?.refreshServerRoutes() }
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
            usbPreview.start()
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
            if let ip = LocalWebServer.lanIPAddress() {
                serverURL = "http://\(ip):8585"
            }
            await server.configureOperatorHandlers(OperatorWebHandlers(
                pairingURL: { [weak self] in self?.operatorPairingURL ?? "" },
                pair: { [weak self] token in self?.operatorAuth.pair(token) },
                authorize: { [weak self] token in self?.operatorAuth.isValidOperatorToken(token) ?? false },
                status: { [weak self] in await self?.healthSnapshot() ?? .empty },
                action: { [weak self] action in await self?.performRemoteOperatorAction(action) ?? false },
                events: { [weak self] in await self?.operationsEvents.jsonData() ?? Data("[]".utf8) }
            ))
            try? await server.start()
            _ = await server.waitUntilReady()
            jobQueue.start()
            activeEvent = store.fetchActiveEvent()
            await restoreDownloadTokens()
            await recoveryService.scanNow()
            await cleanupOldSessions(keepDays: 60)
            await runSafePreflight()
        }

        setupMultipeerHandlers()
        multipeer.start()

        refreshExternalScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExternalScreens() }
        }
    }

    var operatorPairingURL: String {
        let base = serverURL.isEmpty
            ? "http://\(LocalWebServer.lanIPAddress() ?? "localhost"):8585"
            : serverURL
        return "\(base)/operator/pair/\(operatorAuth.pairingTokenValue())"
    }

    var sharingStationURL: String? {
        guard let gallery = activeExperienceDocument?.gallery, gallery.mode != .disabled else { return nil }
        let base = serverURL.isEmpty
            ? "http://\(LocalWebServer.lanIPAddress() ?? "localhost"):8585"
            : serverURL
        return "\(base)/e/\(gallery.eventToken)/station"
    }

    func performRemoteOperatorAction(_ action: RemoteOperatorAction) async -> Bool {
        switch action {
        case .pause:
            pauseBooth(); return true
        case .resume:
            resumeBooth(); return true
        case .retryFailedJobs:
            jobQueue.retryAllFailed(); return true
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
            activeExperienceDocument = document
            experienceCatalog = CustomerExperienceCatalogBuilder().build(event: snapshot, document: document)
            if let event = activeEvent, event.id == snapshot.id {
                try LegacyEventMirrorService().updateLegacyEvent(event, using: document, modelContext: store.context)
            }
            sendExperienceCatalog()
            await runSafePreflight()
        } catch {
            activeExperienceDocument = nil
            experienceCatalog = nil
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

    func loadExperienceDocument(for event: BoothEvent) async throws -> EventExperienceDocument {
        let snapshot = makeEventSnapshot(event)
        return try await experienceStore.ensureDocument(for: snapshot)
    }

    func saveExperienceDocument(
        _ document: EventExperienceDocument,
        for event: BoothEvent
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
        try await experienceStore.save(normalized)
        try LegacyEventMirrorService().updateLegacyEvent(event, using: normalized, modelContext: store.context)
        if activeEvent?.id == event.id {
            activeExperienceDocument = normalized
            let snapshot = makeEventSnapshot(event)
            experienceCatalog = CustomerExperienceCatalogBuilder().build(event: snapshot, document: normalized)
            sendExperienceCatalog()
            await refreshServerRoutes()
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
            let previewData = try? await self.experienceStore.readTemplatePreviews(
                eventID: document.eventID,
                templates: templates
            )
            for template in templates {
                guard let data = previewData?[template.id] else {
                    self.errorMessage = "Template preview unavailable: \(template.id)"
                    continue
                }
                guard data.count <= 350_000 else {
                    self.errorMessage = "Template preview is too large: \(template.id)"
                    continue
                }
                self.multipeer.sendControl(.eventExperienceAsset(packet: ExperienceAssetPacket(
                    eventID: document.eventID,
                    revision: document.revision,
                    assetID: template.id,
                    kind: .templatePreview,
                    jpegData: data
                )))
            }
        }
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
        stateMachine.transition(to: .selectingExperience)
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
            experienceRevision: catalog.revision
        )
        stateMachine.transition(to: .readyToStart)
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

    private func makePresentation(
        sessionID: String,
        config: EventConfig,
        document: EventExperienceDocument
    ) async -> SessionPresentation {
        var prompts: [SessionPromptPresentation] = []
        for prompt in config.posePrompts {
            let imageData: Data?
            if let assetID = prompt.assetID,
               let data = try? await experienceStore.readPromptImage(eventID: document.eventID, fileName: assetID) {
                imageData = sessionPromptImageData(data)
            } else {
                imageData = nil
            }
            prompts.append(SessionPromptPresentation(
                promptID: prompt.id,
                photoIndex: prompt.photoIndex,
                title: prompt.title.value(for: config.customerLanguage),
                subtitle: localizedOptional(prompt.subtitle, language: config.customerLanguage),
                imageData: imageData
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

    var isCustomerDisplayReady: Bool {
        if isExternalViewerActive { return true }
        if case .connected = multipeer.connectionState { return true }
        return false
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
        countdownTask?.cancel()
        multipeer.disconnect()
        capture.stop()
        usbPreview.stop()
        jobQueue.stop()
        Task { await server.stop() }
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
            capture.setPreviewFrameRate(previewFrameRate.rawValue)
            try capture.start()
            capture.onPreviewJPEG = { [weak self] jpeg in
                guard let self else { return }
                switch previewConnectionMode {
                case .wireless: multipeer.sendPreviewFrame(jpeg)
                case .cable:    usbPreview.send(jpeg)
                }
            }
        } catch {
            errorMessage = "Camera error: \(error.localizedDescription)"
        }
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
            cameraSourceKind = .avFoundation
        }
    }

    func disconnectDSLR() {
        capture.stopDSLR()
        capture.usesDSLR = false
        cameraSourceKind = .avFoundation
    }

    func testCameraCapture() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await capture.captureDiagnosticStill()
                errorMessage = nil
            } catch {
                errorMessage = "Test capture failed: \(error.localizedDescription)"
            }
        }
    }

    func runSafePreflight() async {
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
                _ = try await self.capture.captureDiagnosticStill()
            },
            printerTest: { [weak self] in
                guard let self else { return }
                try await self.printer.printTestPage()
            }
        )
    }

    private func makePreflightContext() async -> BoothPreflightContext {
        let serverStatus = await server.statusSnapshot()
        let serverHealthy = await localServerHealthCheck(status: serverStatus)
        let ipadConnected: Bool = {
            if case .connected = multipeer.connectionState { return true }
            return false
        }()
        let output = picturesOutputDir()
        let capacity = output.flatMap { try? $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity }.map(Int64.init)
        let jobs = jobQueue.jobs
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
            case .available: return true
            case .unavailable: return false
            case .systemDefault:
                return NSPrinter.printerNames.contains(NSPrintInfo.shared.printer.name)
            }
        }()
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
            cameraConnected: capture.isRunning && (cameraSourceKind != .dslr || capture.dslr.isRunning),
            customerDisplayReady: isCustomerDisplayReady,
            ipadConnected: ipadConnected,
            usesCablePreview: previewConnectionMode == .cable,
            usbPreviewSupported: usbPreview.isSupported,
            usbPreviewClientConnected: usbPreview.isClientConnected,
            outputFolderURL: output,
            availableDiskBytes: capacity,
            localServerStatus: serverStatus,
            localServerHealthPassed: serverHealthy,
            localIPAddress: LocalWebServer.lanIPAddress(),
            runtimeDirectoryURL: Self.runtimeDirectoryURL(),
            runtimePersistenceAvailable: FileManager.default.fileExists(atPath: Self.runtimeDirectoryURL().path),
            queuePersistenceAvailable: jobQueue.lastQueueError == nil,
            unfinishedCaptureSession: recoveryService.recoverableCaptureSession != nil,
            requiredJobFailed: requiredFailed || jobs.contains(where: { !$0.kind.isOptional && $0.status == .cancelled }),
            optionalJobPendingOrFailed: optionalPendingOrFailed,
            cloudUploadEnabled: cloudUploadEnabled,
            cloudSetupComplete: cloudSetupComplete,
            cloudConnectivityPassed: cloudConnectivityPassed,
            automaticPrintingEnabled: UserDefaults.standard.bool(forKey: "selphyAutoPrintAfterSession"),
            printerConfigured: printerConfigured,
            printerTestResult: printer.lastTestResult
        )
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
        if cameraSourceKind == .dslr && !capture.dslr.isConnecting {
            cameraSourceKind = .avFoundation
        }
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

    func startSession(selection requestedSelection: CustomerSessionSelection? = nil) {
        guard !isBoothPaused else {
            errorMessage = "The booth is paused by the operator."
            return
        }
        guard currentSession == nil, let event = activeEvent else { return }
        reviewDecisionPending = false
        guard recoveryService.recoverableCaptureSession == nil else {
            errorMessage = "Resume or discard the unfinished session in Operations."
            return
        }
        guard let document = activeExperienceDocument else {
            errorMessage = "Event experience is still loading."
            if requestedSelection != nil { multipeer.sendControl(.sessionRequestRejected(reason: errorMessage!)) }
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
            if requestedSelection != nil {
                let reason = (error as? CustomerSelectionError)?.message(for: selection.language) ?? error.localizedDescription
                multipeer.sendControl(.sessionRequestRejected(reason: reason))
                if let selectionError = error as? CustomerSelectionError,
                   selectionError == .staleCatalog {
                    sendExperienceCatalog()
                }
            }
            errorMessage = (error as? CustomerSelectionError)?.message(for: .english) ?? error.localizedDescription
            return
        }
        guard isCustomerDisplayReady else {
            errorMessage = "Connect an iPad or activate the external viewer before starting a session."
            return
        }
        guard cameraPermissionGranted,
              capture.isRunning,
              (cameraSourceKind != .dslr || capture.dslr.isRunning) else {
            errorMessage = "The selected camera is not ready."
            return
        }
        guard config.photoCount > 0,
              !config.slots.isEmpty,
              config.slots.allSatisfy({ $0.photoIndex >= 0 && $0.photoIndex < config.photoCount }),
              config.canvasWidth > 0,
              config.canvasHeight > 0,
              let outputRoot = picturesOutputDir() else {
            errorMessage = "The active event layout is not valid."
            return
        }
        let session = store.startSession(for: event)
        session.photoCount = config.photoCount
        try? store.context.save()
        let frameURL = selectedTemplateFrameURL(validated.template, eventID: event.id)

        Task { @MainActor [weak self] in
            guard let self else { return }
            var createdDirectory: URL?
            do {
                let descriptor = try workspace.createWorkspace(
                    sessionID: session.id,
                    eventName: config.eventName,
                    outputRoot: outputRoot,
                    startedAt: session.startedAt,
                    frameSourceURL: frameURL
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
                    lastError: nil,
                    updatedAt: Date()
                )
                try await manifestStore.create(manifest)
                currentSession = session
                currentManifest = manifest
                currentManifestID = manifest.id
                retakeCounts = [:]
                gifFrames = [:]
                currentCaptureAttempt = nil
                currentFilteredReviewImages = [:]
                capture.resetStills()
                stateMachine.startSession(config: config, sessionID: session.id)
                let presentation = await makePresentation(
                    sessionID: session.id,
                    config: config,
                    document: document
                )
                try workspace.savePresentationSnapshot(
                    presentation: presentation,
                    prompts: config.posePrompts,
                    workspace: descriptor
                )
                currentSessionPresentation = presentation
                lastSessionPresentation = presentation
                recordOperation(.sessionStarted, sessionID: session.id)
                multipeer.sendControl(.sessionStart)
                multipeer.sendControl(.eventConfig(config: config))
                multipeer.sendControl(.sessionPrepared(config: config, presentation: presentation))
                beginCountdown(photoIndex: 0)
            } catch {
                if let createdDirectory { try? FileManager.default.removeItem(at: createdDirectory) }
                store.deleteSession(session)
                errorMessage = "Session start failed: \(error.localizedDescription)"
            }
        }
    }

    func beginCountdown(photoIndex: Int) {
        stateMachine.beginCountdown(photoIndex: photoIndex)
        multipeer.sendControl(.beginCountdown(photoIndex: photoIndex, seconds: stateMachine.config.countdownSeconds))
        runCountdown(photoIndex: photoIndex, seconds: stateMachine.config.countdownSeconds)
    }

    private func runCountdown(photoIndex: Int, seconds: Int) {
        countdownTask?.cancel()
        countdownTask = Task {
            for remaining in stride(from: seconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                stateMachine.transition(to: .countdown(photoIndex: photoIndex, secondsRemaining: remaining))
                try? await Task.sleep(for: .seconds(1))
            }
            if !Task.isCancelled { await captureShot(photoIndex: photoIndex) }
        }
    }

    private func captureShot(photoIndex: Int) async {
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
        do {
            gifFrames[photoIndex] = capture.drainBufferForGIF()
            let image = try await capture.captureStill(for: photoIndex)
            let filtered = try await filterPipeline.apply(stateMachine.config.selectedFilterID, to: image)
            currentFilteredReviewImages[photoIndex] = filtered
            guard let thumbData = capture.thumbnail(for: filtered) else {
                throw PhotoFilterError.failedToCreateOutput(stateMachine.config.selectedFilterID)
            }
            stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: thumbData)
            reviewDecisionPending = false
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .success,
                completedAt: Date(),
                reason: nil,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            recordOperation(.captureSucceeded, sessionID: currentManifest?.id, photoIndex: photoIndex, duration: Date().timeIntervalSince(attempt.startedAt))
            currentCaptureAttempt = nil
            multipeer.sendControl(.shotCaptured(index: photoIndex, thumbnailData: thumbData))
            updateStripPreview()
        } catch {
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
            await persistCaptureFailure(photoIndex: photoIndex, error: error)
            currentCaptureAttempt = nil
            stateMachine.enterCaptureRecovery(photoIndex: photoIndex, failure: summary)
            reviewDecisionPending = false
            multipeer.sendControl(.captureRecovery(photoIndex: photoIndex, failure: summary))
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
        guard var manifest = currentManifest,
              currentManifestID == manifest.id else { return }
        var records = manifest.captureAttempts ?? []
        let record = CaptureAttemptRecord(
            id: attempt.id.uuidString,
            photoIndex: photoIndex,
            startedAt: attempt.startedAt,
            completedAt: completedAt,
            result: result,
            reason: reason,
            receiveDuration: receiveDuration
        )
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        manifest.captureAttempts = records
        manifest.updatedAt = Date()
        try? await manifestStore.save(manifest)
        currentManifest = manifest
    }

    private func persistCaptureFailure(photoIndex: Int, error: Error) async {
        guard var manifest = currentManifest,
              currentManifestID == manifest.id else { return }
        manifest.lastError = error.localizedDescription
        manifest.nextPhotoIndex = photoIndex
        manifest.updatedAt = Date()
        try? await manifestStore.save(manifest)
        currentManifest = manifest
        errorMessage = error.localizedDescription
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
        let qrPayload = config.qrCodeElements.isEmpty ? nil : try? SessionQRCodePayloadResolver.resolve(
            token: manifest.downloadToken,
            localBaseURL: "http://\(LocalWebServer.lanIPAddress() ?? "localhost"):8585",
            publicBaseURL: UserDefaults.standard.string(forKey: "publicBaseURL"),
            cloudUploadEnabled: UserDefaults.standard.bool(forKey: "cloudUploadEnabled")
        )
        Task.detached(priority: .utility) { [compositor, images, qrPayload] in
            let img = try? compositor.render(images: images, qrPayload: qrPayload)
            await MainActor.run { [weak self] in self?.currentStripPreview = img }
        }
    }

    func handleReviewDecision(photoIndex: Int, action: ReviewAction) {
        let customerAction: CustomerDisplayAction = action == .keep
            ? .keep(photoIndex: photoIndex)
            : .retake(photoIndex: photoIndex)
        guard !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { return }
        reviewDecisionPending = true
        multipeer.sendControl(.reviewDecision(action: action))
        switch action {
        case .keep:
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.reviewDecisionPending = false }
                await self.acceptShot(photoIndex: photoIndex)
            }
        case .retake:
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.reviewDecisionPending = false }
                await self.requestRetake(photoIndex: photoIndex, source: .guest)
            }
        }
    }

    func handleCaptureRecoveryAction(_ action: CaptureRecoveryAction) {
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
        guard !reviewDecisionPending,
              CustomerDisplayWorkflow.canApply(customerAction, in: stateMachine.phase) else { return }
        reviewDecisionPending = true
        Task { @MainActor [weak self] in
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
        }
    }

    private func retryReceive(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex else { return }
        let attempt = CaptureAttempt()
        currentCaptureAttempt = attempt
        do {
            let image = try await capture.recoverLastCapture()
            let filtered = try await filterPipeline.apply(stateMachine.config.selectedFilterID, to: image)
            guard let thumbData = capture.thumbnail(for: filtered) else {
                throw PhotoFilterError.failedToCreateOutput(stateMachine.config.selectedFilterID)
            }
            capture.storeStill(image, for: photoIndex)
            currentFilteredReviewImages[photoIndex] = filtered
            stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: thumbData)
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .transferRecovered,
                completedAt: Date(),
                reason: nil,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            recordOperation(.captureRecovered, sessionID: currentManifest?.id, photoIndex: photoIndex, duration: Date().timeIntervalSince(attempt.startedAt))
            currentCaptureAttempt = nil
            multipeer.sendControl(.shotCaptured(index: photoIndex, thumbnailData: thumbData))
            updateStripPreview()
        } catch {
            let summary = captureFailureSummary(photoIndex: photoIndex, error: error)
            await recordCaptureAttempt(
                attempt,
                photoIndex: photoIndex,
                result: .failed,
                completedAt: Date(),
                reason: error.localizedDescription,
                receiveDuration: Date().timeIntervalSince(attempt.startedAt)
            )
            await persistCaptureFailure(photoIndex: photoIndex, error: error)
            stateMachine.enterCaptureRecovery(photoIndex: photoIndex, failure: summary)
            currentCaptureAttempt = nil
            multipeer.sendControl(.captureRecovery(photoIndex: photoIndex, failure: summary))
        }
    }

    private func retakeFailedCapture(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              var manifest = currentManifest else { return }
        let current = manifest.shots.first(where: { $0.photoIndex == photoIndex })
        let count = incrementRetakeCount(in: &retakeCounts, photoIndex: photoIndex)
        upsertManifestShot(
            &manifest,
            photoIndex: photoIndex,
            imageFileName: nil,
            gifFrameFileNames: [],
            retakeCount: count,
            acceptedAt: nil,
            previousImageFileName: current?.imageFileName ?? current?.previousImageFileName,
            previousGifFrameFileNames: current?.gifFrameFileNames.isEmpty == false
                ? current?.gifFrameFileNames
                : current?.previousGifFrameFileNames,
            previousAcceptedAt: current?.acceptedAt ?? current?.previousAcceptedAt
        )
        manifest.nextPhotoIndex = photoIndex
        manifest.status = .capturing
        manifest.lastError = nil
        do {
            try await manifestStore.save(manifest)
            currentManifest = manifest
            await recordCaptureAttempt(
                CaptureAttempt(),
                photoIndex: photoIndex,
                result: .retaken,
                completedAt: Date(),
                reason: "retaken",
                receiveDuration: nil
            )
            recordOperation(.captureRetried, sessionID: manifest.id, photoIndex: photoIndex)
            currentCaptureAttempt = nil
            stateMachine.retakeShot(photoIndex: photoIndex)
            beginCountdown(photoIndex: photoIndex)
        } catch {
            errorMessage = "Could not start retake: \(error.localizedDescription)"
        }
    }

    private func continueAfterCaptureFailure(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              var manifest = currentManifest else { return }
        let next = stateMachine.continueAfterCaptureFailure(photoIndex: photoIndex)
        guard let next else {
            errorMessage = "Cannot continue while a required photograph is missing."
            return
        }
        manifest.nextPhotoIndex = next
        manifest.status = .capturing
        manifest.updatedAt = Date()
        do {
            try await manifestStore.save(manifest)
            currentManifest = manifest
            await recordCaptureAttempt(
                CaptureAttempt(),
                photoIndex: photoIndex,
                result: .deferred,
                completedAt: Date(),
                reason: "deferred",
                receiveDuration: nil
            )
            recordOperation(.captureDeferred, sessionID: manifest.id, photoIndex: photoIndex)
            currentCaptureAttempt = nil
            beginCountdown(photoIndex: next)
        } catch {
            errorMessage = "Could not defer photograph: \(error.localizedDescription)"
        }
    }

    private func usePreviousCapture(photoIndex: Int) async {
        guard case .captureRecovery(let currentIndex, _) = stateMachine.phase,
              currentIndex == photoIndex,
              var manifest = currentManifest,
              let previous = manifest.shots.first(where: { $0.photoIndex == photoIndex }),
              let imageFileName = previous.previousImageFileName else { return }
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        guard let image = loadCGImage(from: directory.appendingPathComponent(imageFileName)) else {
            errorMessage = "The previous photograph is no longer available."
            return
        }
        do {
            let filtered = try await filterPipeline.apply(stateMachine.config.selectedFilterID, to: image)
            guard let thumbData = capture.thumbnail(for: filtered) else {
                throw PhotoFilterError.failedToCreateOutput(stateMachine.config.selectedFilterID)
            }
            let gifs = previous.previousGifFrameFileNames ?? []
            upsertManifestShot(
                &manifest,
                photoIndex: photoIndex,
                imageFileName: imageFileName,
                gifFrameFileNames: gifs,
                retakeCount: previous.retakeCount,
                acceptedAt: previous.previousAcceptedAt ?? Date()
            )
            manifest.nextPhotoIndex = (0..<manifest.eventConfig.photoCount)
                .first { index in
                    manifest.shots.first(where: { $0.photoIndex == index })?.imageFileName == nil
                } ?? manifest.eventConfig.photoCount
            manifest.status = manifest.nextPhotoIndex == manifest.eventConfig.photoCount ? .finalizing : .capturing
            manifest.lastError = nil
            try await manifestStore.save(manifest)
            currentManifest = manifest
            capture.storeStill(image, for: photoIndex)
            currentFilteredReviewImages[photoIndex] = filtered
            stateMachine.usePreviousCapture(photoIndex: photoIndex, thumbnailData: thumbData)
            await recordCaptureAttempt(
                CaptureAttempt(),
                photoIndex: photoIndex,
                result: .usedPrevious,
                completedAt: Date(),
                reason: "previous_photo_used",
                receiveDuration: nil
            )
            recordOperation(.previousPhotoUsed, sessionID: manifest.id, photoIndex: photoIndex)
            currentCaptureAttempt = nil
            if case .processing = stateMachine.phase {
                await finalizeSession()
            } else if case .countdown(let next, _) = stateMachine.phase {
                beginCountdown(photoIndex: next)
            }
        } catch {
            errorMessage = "Could not restore the previous photograph: \(error.localizedDescription)"
        }
    }

    func operatorOverride(_ action: OperatorAction) {
        multipeer.sendControl(.operatorOverride(action: action))
        switch action {
        case .forceStart:
            if stateMachine.phase == .idle || stateMachine.phase == .readyToStart { startSession() }
        case .forceRetake:
            if case .review(let idx) = stateMachine.phase,
               !reviewDecisionPending,
               CustomerDisplayWorkflow.canApply(.retake(photoIndex: idx), in: stateMachine.phase) {
                reviewDecisionPending = true
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { self.reviewDecisionPending = false }
                    await self.requestRetake(photoIndex: idx, source: .operatorSource)
                }
            }
        case .skip:
            if case .review(let idx) = stateMachine.phase { handleReviewDecision(photoIndex: idx, action: .keep) }
        case .cancelSession:
            Task { @MainActor [weak self] in
                await self?.cancelCurrentSession()
            }
        }
    }

    private enum RetakeSource {
        case guest
        case operatorSource
    }

    private func acceptShot(photoIndex: Int) async {
        guard case .review(let currentIndex) = stateMachine.phase,
              currentIndex == photoIndex,
              var manifest = currentManifest,
              currentManifestID == manifest.id,
              let image = capture.capturedStills[photoIndex] else {
            errorMessage = "Cannot keep this photograph because its review state is unavailable."
            return
        }

        do {
            let saved = try workspace.saveAcceptedCapture(
                image: image,
                gifFrames: gifFrames[photoIndex] ?? [],
                photoIndex: photoIndex,
                workspace: workspaceDescriptor(from: manifest)
            )
            upsertManifestShot(
                &manifest,
                photoIndex: photoIndex,
                imageFileName: saved.imageFileName,
                gifFrameFileNames: saved.gifFrameFileNames,
                retakeCount: retakeCounts[photoIndex] ?? 0,
                acceptedAt: Date()
            )
            manifest.nextPhotoIndex = (0..<manifest.eventConfig.photoCount)
                .first { index in
                    manifest.shots.first(where: { $0.photoIndex == index })?.imageFileName == nil
                } ?? manifest.eventConfig.photoCount
            let isComplete = manifest.nextPhotoIndex == manifest.eventConfig.photoCount
            manifest.status = isComplete ? .finalizing : .capturing
            manifest.lastError = nil
            try await manifestStore.save(manifest)
            currentManifest = manifest
            let session = currentSession ?? store.restoreSessionRecord(from: manifest)
            store.upsertShot(
                session: session,
                photoIndex: photoIndex,
                imagePath: saved.imageFileName,
                retakeCount: retakeCounts[photoIndex] ?? 0
            )

            stateMachine.keepShot(photoIndex: photoIndex)
            if case .processing = stateMachine.phase {
                await finalizeSession()
            } else if case .countdown(let next, _) = stateMachine.phase {
                beginCountdown(photoIndex: next)
            }
        } catch {
            errorMessage = "Could not save photograph \(photoIndex + 1): \(error.localizedDescription)"
        }
    }

    private func requestRetake(photoIndex: Int, source: RetakeSource) async {
        _ = source
        guard case .review(let currentIndex) = stateMachine.phase,
              currentIndex == photoIndex,
              var manifest = currentManifest else { return }

        let count = incrementRetakeCount(in: &retakeCounts, photoIndex: photoIndex)
        let previous = manifest.shots.first(where: { $0.photoIndex == photoIndex })
        upsertManifestShot(
            &manifest,
            photoIndex: photoIndex,
            imageFileName: nil,
            gifFrameFileNames: [],
            retakeCount: count,
            acceptedAt: nil,
            previousImageFileName: previous?.imageFileName ?? previous?.previousImageFileName,
            previousGifFrameFileNames: previous?.gifFrameFileNames.isEmpty == false
                ? previous?.gifFrameFileNames
                : previous?.previousGifFrameFileNames,
            previousAcceptedAt: previous?.acceptedAt ?? previous?.previousAcceptedAt
        )
        do {
            try await manifestStore.save(manifest)
            currentManifest = manifest
            if let session = currentSession {
                store.upsertShot(
                    session: session,
                    photoIndex: photoIndex,
                    imagePath: previous?.imageFileName,
                    retakeCount: count
                )
            }
            stateMachine.retakeShot(photoIndex: photoIndex)
            beginCountdown(photoIndex: photoIndex)
        } catch {
            retakeCounts[photoIndex] = max(0, count - 1)
            errorMessage = "Could not save retake count: \(error.localizedDescription)"
        }
    }

    private func cancelCurrentSession() async {
        countdownTask?.cancel()
        guard currentSession != nil, var manifest = currentManifest else {
            reviewDecisionPending = false
            stateMachine.reset()
            return
        }
        manifest.status = .cancelled
        manifest.cancelledAt = Date()
        recordOperation(.sessionCancelled, sessionID: manifest.id)
        try? await manifestStore.save(manifest)
        jobQueue.cancelJobs(sessionID: manifest.id)
        try? workspace.removeEntireSession(manifest: manifest)
        if let session = currentSession { store.deleteSession(session) }
        currentManifest = nil
        currentManifestID = nil
        currentSession = nil
        currentSessionPresentation = nil
        retakeCounts = [:]
        gifFrames = [:]
        currentCaptureAttempt = nil
        currentFilteredReviewImages = [:]
        capture.resetStills()
        reviewDecisionPending = false
        stateMachine.reset()
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
        currentSessionPresentation = (try? workspace.loadPresentationSnapshot(manifest: manifest))
            ?? presentation(for: manifest.eventConfig, sessionID: manifest.id)
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
        multipeer.sendControl(.sessionStart)
        multipeer.sendControl(.eventConfig(config: manifest.eventConfig))
        multipeer.sendControl(.sessionPrepared(
            config: manifest.eventConfig,
            presentation: currentSessionPresentation!
        ))
        beginCountdown(photoIndex: manifest.nextPhotoIndex)
    }

    private func finishDiscardingRecoveredSession(_ manifest: SessionManifest) {
        if let session = store.fetchSession(id: manifest.id) { store.deleteSession(session) }
        if currentManifestID == manifest.id {
            currentManifest = nil
            currentManifestID = nil
            currentSession = nil
            currentSessionPresentation = nil
            capture.resetStills()
            retakeCounts = [:]
            gifFrames = [:]
            stateMachine.reset()
        }
    }

    // MARK: - Finalize session

    private func finalizeSession() async {
        guard var manifest = currentManifest else { return }
        guard (0..<manifest.eventConfig.photoCount).allSatisfy({ index in
            manifest.shots.first(where: { $0.photoIndex == index })?.imageFileName != nil
        }) else {
            errorMessage = "Session cannot finish until every photograph is accepted."
            return
        }

        manifest.status = .finalizing
        manifest.lastError = nil
        do {
            try await manifestStore.save(manifest)
        } catch {
            errorMessage = "Could not start session processing: \(error.localizedDescription)"
            return
        }
        currentManifest = manifest
        jobQueue.enqueueFinalizationJobs(for: manifest)
        if UserDefaults.standard.bool(forKey: "cloudUploadEnabled") {
            jobQueue.enqueueCloudUpload(for: manifest)
        }
        if UserDefaults.standard.bool(forKey: "selphyAutoPrintAfterSession") &&
            UserDefaults.standard.bool(forKey: "selphySkipPrintDialog") {
            jobQueue.enqueueAutoPrint(for: manifest)
        }
    }

    private func reconcileCurrentSessionJobs() {
        guard let manifest = currentManifest,
              currentSession != nil,
              stateMachine.phase == .processing else { return }
        let jobs = jobQueue.jobs.filter { $0.sessionID == manifest.id }
        if let failed = jobs.first(where: {
            ($0.kind == .renderStrip || $0.kind == .registerDownload) && $0.status == .failed
        }) {
            Task { await markCurrentSessionFailed(message: failed.lastError ?? "Required job failed.") }
            return
        }
        guard jobs.first(where: { $0.kind == .renderStrip })?.status == .succeeded,
              jobs.first(where: { $0.kind == .registerDownload })?.status == .succeeded else {
            return
        }
        Task { await completeCurrentSessionIfReady() }
    }

    private func cleanupCompletedWorkingFiles() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            for result in await manifestStore.loadAll() {
                guard case .loaded(let manifest) = result, manifest.status == .completed else { continue }
                let jobs = jobQueue.jobs.filter { $0.sessionID == manifest.id }
                // Keep failed GIF inputs available for an operator retry; explicit cancellation permits cleanup.
                guard jobs.first(where: { $0.kind == .renderStrip })?.status == .succeeded,
                      jobs.filter({ $0.kind == .renderGIF }).allSatisfy({
                          $0.status == .succeeded || $0.status == .cancelled
                      }) else { continue }
                try? workspace.removeWorkingFiles(manifest: manifest)
            }
        }
    }

    private func reconcileRecoveredSessions() {
        guard currentSession == nil else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let results = await manifestStore.loadAll()
            for result in results {
                guard case .loaded(let manifest) = result, manifest.status == .finalizing else { continue }
                let jobs = jobQueue.jobs.filter { $0.sessionID == manifest.id }
                if let failed = jobs.first(where: {
                    ($0.kind == .renderStrip || $0.kind == .registerDownload) && $0.status == .failed
                }) {
                    var failedManifest = manifest
                    failedManifest.status = .failed
                    failedManifest.lastError = failed.lastError ?? "Required job failed."
                    failedManifest.updatedAt = Date()
                    try? await manifestStore.save(failedManifest)
                    continue
                }
                guard jobs.first(where: { $0.kind == .renderStrip })?.status == .succeeded,
                      jobs.first(where: { $0.kind == .registerDownload })?.status == .succeeded else {
                    continue
                }
                var completed = manifest
                completed.status = .completed
                completed.completedAt = Date()
                completed.lastError = nil
                try? await manifestStore.save(completed)
                _ = store.restoreSessionRecord(from: completed)
                store.finishSession(
                    sessionID: completed.id,
                    stripPath: completed.stripFileName.map { "\(completed.relativeDirectoryPath)/\($0)" },
                    gifPath: completed.gifFileName.map { "\(completed.relativeDirectoryPath)/\($0)" }
                )
                if jobs.filter({ $0.kind == .renderGIF }).allSatisfy({
                    $0.status == .succeeded || $0.status == .cancelled
                }) {
                    try? workspace.removeWorkingFiles(manifest: completed)
                }
            }
        }
    }

    private func markCurrentSessionFailed(message: String) async {
        guard let current = currentManifest, current.status != .failed else { return }
        var manifest = (try? await manifestStore.load(sessionID: current.id)) ?? current
        manifest.status = .failed
        manifest.lastError = message
        try? await manifestStore.save(manifest)
        currentManifest = manifest
    }

    private func completeCurrentSessionIfReady() async {
        guard let original = currentManifest,
              currentSession != nil,
              stateMachine.phase == .processing else { return }
        let jobs = jobQueue.jobs.filter { $0.sessionID == original.id }
        guard jobs.first(where: { $0.kind == .renderStrip })?.status == .succeeded,
              jobs.first(where: { $0.kind == .registerDownload })?.status == .succeeded else {
            return
        }
        let latest = (try? await manifestStore.load(sessionID: original.id)) ?? original
        var manifest = latest
        guard manifest.status != .completed else { return }
        manifest.status = .completed
        manifest.completedAt = Date()
        manifest.lastError = nil
        do {
            try await manifestStore.save(manifest)
        } catch {
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

        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        let token = manifest.downloadToken
        let publicBase = UserDefaults.standard.string(forKey: "publicBaseURL")?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let ip = LocalWebServer.lanIPAddress() ?? "localhost"
        let qr = Self.downloadURL(
            publicBaseURL: publicBase,
            localBaseURL: "http://\(ip):8585",
            token: token,
            cloudUploadEnabled: UserDefaults.standard.bool(forKey: "cloudUploadEnabled")
        )
        let stripThumb = loadCGImage(from: directory.appendingPathComponent("strip.png"))
            .flatMap { jpegData(from: $0, quality: 0.4) }
        currentStripPreview = loadCGImage(from: directory.appendingPathComponent("strip.png"))
        stateMachine.finishSession(qrPayload: qr)
        multipeer.sendControl(.sessionFinished(qrPayload: qr, stripThumbData: stripThumb, gifThumbData: nil))
        if jobs.filter({ $0.kind == .renderGIF }).allSatisfy({
            $0.status == .succeeded || $0.status == .cancelled
        }) {
            try? workspace.removeWorkingFiles(manifest: manifest)
        }
        currentSession = nil
        lastSessionPresentation = currentSessionPresentation
        currentSessionPresentation = nil
    }

    private func restoreDownloadTokens() async {
        await refreshServerRoutes()
    }

    func refreshServerRoutes() async {
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
                eventGalleryPath: galleryPath
            )
        }
        await server.replaceSessionRoutes(sessionMappings)
        await server.replaceGalleryRoutes(galleryMappings)
    }

    // MARK: - Session cleanup (M10)

    private func cleanupOldSessions(keepDays: Int) async {
        let cutoff = Calendar.current.date(byAdding: .day, value: -keepDays, to: Date())!
        for result in await manifestStore.loadAll() {
            guard case .loaded(let manifest) = result else { continue }
            if manifest.status == .completed,
               let completedAt = manifest.completedAt,
               completedAt < cutoff {
                try? workspace.removeEntireSession(manifest: manifest)
                try? await manifestStore.delete(sessionID: manifest.id)
                jobQueue.deleteJobs(sessionID: manifest.id)
                await server.unregisterToken(manifest.downloadToken)
                if let session = store.fetchSession(id: manifest.id) { store.deleteSession(session) }
            } else if manifest.status == .cancelled,
                      let cancelledAt = manifest.cancelledAt,
                      cancelledAt < Calendar.current.date(byAdding: .day, value: -7, to: Date())! {
                try? await manifestStore.delete(sessionID: manifest.id)
                jobQueue.deleteJobs(sessionID: manifest.id)
            }
        }
        jobQueue.purgeOldSucceededJobs(olderThan: Calendar.current.date(byAdding: .day, value: -7, to: Date())!)

        // Keep the pre-1.1 cleanup path for sessions that predate runtime manifests.
        for session in store.fetchSessions(finishedBefore: cutoff) {
            if let stripPath = session.stripPath {
                let strip = picturesOutputDir()?.appendingPathComponent(stripPath)
                try? strip.map { try FileManager.default.removeItem(at: $0.deletingLastPathComponent()) }
            }
            store.deleteSession(session)
        }
    }

    // MARK: - Print

    func printCurrentStrip() {
        guard let sessionID = lastCompletedSessionID else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  let manifest = try? await manifestStore.load(sessionID: sessionID) else { return }
            let skipDialog = UserDefaults.standard.bool(forKey: "selphySkipPrintDialog")
            if skipDialog {
                if let existing = jobQueue.jobs.first(where: { $0.sessionID == sessionID && $0.kind == .autoPrint }),
                   existing.status == .failed || existing.status == .cancelled {
                    jobQueue.retry(jobID: existing.id)
                } else {
                    jobQueue.enqueueAutoPrint(for: manifest)
                }
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
            guard let self,
                  let manifest = try? await manifestStore.load(sessionID: sessionID) else { return }
            let url = URL(fileURLWithPath: manifest.absoluteDirectoryPath)
                .appendingPathComponent(manifest.stripFileName ?? "strip.png")
            do {
                try await printer.printStrip(
                    at: url,
                    showPrintDialog: !UserDefaults.standard.bool(forKey: "selphySkipPrintDialog")
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
    }

    private func handleMessage(_ msg: Message) {
        switch msg {
        case .hello(let role) where role == .iPad:
            if let event = activeEvent {
                multipeer.sendControl(.eventConfig(config: event.toEventConfig()))
            }
            sendExperienceCatalog()
            resynciPad()
        case .setPreviewTransport(let transport):
            previewConnectionMode = transport == .usb ? .cable : .wireless
        case .sessionStart:
            if stateMachine.phase == .idle, activeEvent != nil {
                startSession()
            }
        case .customerSessionRequest(let selection):
            guard stateMachine.phase == .idle || stateMachine.phase == .selectingExperience || stateMachine.phase == .readyToStart else {
                multipeer.sendControl(.sessionRequestRejected(reason: LocalizedText(
                    english: "A session is already in progress.",
                    thai: "มีเซสชันกำลังดำเนินการอยู่แล้ว"
                ).value(for: selection.language)))
                return
            }
            startSession(selection: selection)
        case .reviewDecision(let action):
            if case .review(let idx) = stateMachine.phase {
                handleReviewDecision(photoIndex: idx, action: action)
            }
        case .captureRecoveryAction(let action):
            handleCaptureRecoveryAction(action)
        default: break
        }
    }

    // Push current Mac state to iPad after (re)connect so it's never stuck at idle mid-session.
    private func resynciPad() {
        let phase = stateMachine.phase
        let sessionID: String? = switch phase {
        case .idle, .selectingExperience, .readyToStart: nil
        default: currentSession?.id ?? lastCompletedSessionID
        }
        let reviewThumbnail: Data? = {
            guard case .review(let index) = phase else { return nil }
            return stateMachine.keptShots[index]
        }()
        let stripThumbnail: Data? = {
            guard case .finished = phase else { return nil }
            return currentStripPreview.flatMap { jpegData(from: $0, quality: 0.4) }
        }()
        multipeer.sendControl(.sessionSync(snapshot: SessionSyncSnapshot(
            config: stateMachine.config,
            sessionID: sessionID,
            phase: phase,
            presentation: currentSessionPresentation ?? lastSessionPresentation,
            reviewThumbnailData: reviewThumbnail,
            stripThumbnailData: stripThumbnail,
            isMirrored: capture.camera.isMirrored,
            isBoothPaused: isBoothPaused
        )))
        multipeer.sendControl(.setMirrored(isMirrored: capture.camera.isMirrored))
    }

    // MARK: - Directories

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
        let connected = capture.isRunning && (!dslr || capture.dslr.isRunning)
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
        let connectedPeer: String? = {
            guard case .connected = multipeer.connectionState else { return nil }
            return multipeer.peerName.isEmpty ? nil : multipeer.peerName
        }()
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
        let overall: BoothHealthStatus = camera.connected && serverHealth == .healthy && !hasRequiredFailure
            ? .healthy
            : camera.connected || serverHealth == .healthy ? .degraded : .unavailable
        let deliverySessionID = currentSession?.id ?? lastCompletedSessionID
        let deliveryJobs = deliverySessionID.map { sessionID in queue.filter { $0.sessionID == sessionID } } ?? []
        return BoothHealthSnapshot(
            updatedAt: Date(),
            status: overall,
            camera: camera,
            customerDisplayConnected: connectedPeer != nil || isExternalViewerActive,
            customerDisplayPeer: connectedPeer,
            controlConnection: connectionLabel(multipeer.connectionState),
            previewConnection: previewConnectionMode.rawValue,
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
            delivery: deliveryJobs.isEmpty ? nil : SessionDeliveryResolver.resolve(deliveryJobs)
        )
    }

    private var printerLabel: String {
        switch printer.configuredPrinterStatus() {
        case .systemDefault: return "System Default"
        case .available(let name), .unavailable(let name): return name
        }
    }

    private var printerStatusLabel: String {
        switch printer.configuredPrinterStatus() {
        case .systemDefault, .available: return "available"
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

    private func recordOperation(
        _ kind: OperationsEventKind,
        sessionID: String? = nil,
        photoIndex: Int? = nil,
        duration: Double? = nil,
        reason: String? = nil
    ) {
        Task { await operationsEvents.record(kind, sessionID: sessionID, photoIndex: photoIndex, duration: duration, reason: reason) }
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
        if let d { try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
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

    private func safeFolderName(_ s: String) -> String {
        SessionWorkspace.safeEventFolderName(s)
    }

    private func workspaceDescriptor(from manifest: SessionManifest) -> SessionWorkspaceDescriptor {
        SessionWorkspaceDescriptor(
            outputRootPath: manifest.outputRootPath,
            relativeDirectoryPath: manifest.relativeDirectoryPath,
            absoluteDirectoryPath: manifest.absoluteDirectoryPath,
            frameSnapshotFileName: manifest.frameSnapshotFileName
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
