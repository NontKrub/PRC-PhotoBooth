import Foundation
import AppKit
import SwiftUI
import CoreGraphics
import SwiftData
import Observation
import AVFoundation

enum CameraSourceKind: String, CaseIterable, Identifiable {
    case avFoundation = "Built-in / USB / Continuity"
    case dslr         = "DSLR / Mirrorless (USB Tethered)"
    var id: String { rawValue }
}

// Which channel carries the live preview stream to the iPad.
// Control messages (session state, countdown, etc.) always go over MultipeerConnectivity —
// only the high-bandwidth preview frames move between Wi-Fi (MPC) and USB cable.
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
        cloudUploadSucceeded: Bool
    ) -> String {
        let publicBase = publicBaseURL?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) ?? ""
        let localBase = localBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let base = cloudUploadSucceeded && !publicBase.isEmpty ? publicBase : localBase
        return "\(base)/s/\(token)/"
    }

    let multipeer: MultipeerService
    let capture: CaptureService
    let stateMachine: SessionStateMachine
    let server: LocalWebServer
    let store: DataStore
    let cloudSSHSetup: CloudSSHSetupService
    let manifestStore: SessionManifestStore
    let workspace: SessionWorkspace
    let jobQueue: SessionJobQueue
    let recoveryService: SessionRecoveryService
    let preflight: BoothPreflightService
    let printer: PrinterService
    let cloudUpload: CloudUploadService
    let usbPreview = USBPreviewServer()

    var activeEvent: BoothEvent? {
        didSet { capture.captureRotationDegrees = activeEvent?.cameraRotationDegrees ?? 0 }
    }
    var errorMessage: String?
    var serverURL: String = ""
    var cameraSourceKind: CameraSourceKind = .avFoundation {
        didSet {
            if cameraSourceKind == .avFoundation {
                capture.usesDSLR = false
            }
        }
    }
    var cameraPermissionGranted: Bool = false
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
    var currentStripPreview: CGImage?

    // MARK: - External display viewer
    private(set) var externalScreens: [NSScreen] = []
    private var externalDisplayWindow: NSWindow?
    var isExternalViewerActive: Bool { externalDisplayWindow != nil }

    init() {
        multipeer = MultipeerService(role: .mac)
        capture = CaptureService()
        stateMachine = SessionStateMachine()
        server = LocalWebServer(port: 8585)
        store = DataStore.shared
        cloudSSHSetup = CloudSSHSetupService()
        let runtimeDirectory = Self.runtimeDirectoryURL()
        try? FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)
        manifestStore = SessionManifestStore(baseDirectory: runtimeDirectory)
        workspace = SessionWorkspace()
        printer = PrinterService()
        cloudUpload = CloudUploadService()
        let jobStore = JobQueueStore(fileURL: runtimeDirectory.appendingPathComponent("jobs.json"))
        let executor = SessionJobExecutor(
            manifestStore: manifestStore,
            workspace: workspace,
            store: store,
            server: server,
            cloudUpload: cloudUpload,
            printer: printer
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
            await checkCameraPermission()
            if cameraPermissionGranted { startCamera() }
            if let ip = LocalWebServer.lanIPAddress() {
                serverURL = "http://\(ip):8585"
            }
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

        refreshExternalScreens()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshExternalScreens() }
        }
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
        capture.stop()
        usbPreview.stop()
        jobQueue.stop()
        Task { await server.stop() }
    }

    // MARK: - Camera permission (M10)

    func checkCameraPermission() async {
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

    func startSession() {
        guard currentSession == nil, let event = activeEvent else { return }
        guard recoveryService.recoverableCaptureSession == nil else {
            errorMessage = "Resume or discard the unfinished session in Operations."
            return
        }
        let config = event.toEventConfig()
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
        let frameURL = event.framePNGPath.flatMap { appSupportDir()?.appendingPathComponent($0) }

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
                capture.resetStills()
                stateMachine.startSession(config: config, sessionID: session.id)
                multipeer.sendControl(.sessionStart)
                multipeer.sendControl(.eventConfig(config: config))
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
        do {
            gifFrames[photoIndex] = capture.drainBufferForGIF()
            let image = try await capture.captureStill(for: photoIndex)
            let thumbData = capture.thumbnail(for: image) ?? Data()
            stateMachine.enterReview(photoIndex: photoIndex, thumbnailData: thumbData)
            multipeer.sendControl(.shotCaptured(index: photoIndex, thumbnailData: thumbData))
            updateStripPreview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateStripPreview() {
        guard let manifest = currentManifest else { return }
        let config = manifest.eventConfig
        let framePNG = manifest.frameSnapshotFileName.flatMap {
            loadCGImage(from: URL(fileURLWithPath: manifest.absoluteDirectoryPath).appendingPathComponent($0))
        }
        let images = capture.capturedStills
        let compositor = Compositor(config: config, framePNG: framePNG)
        Task.detached(priority: .utility) { [compositor, images] in
            let img = try? compositor.render(images: images)
            await MainActor.run { [weak self] in self?.currentStripPreview = img }
        }
    }

    func handleReviewDecision(photoIndex: Int, action: ReviewAction) {
        multipeer.sendControl(.reviewDecision(action: action))
        switch action {
        case .keep:
            Task { @MainActor [weak self] in
                await self?.acceptShot(photoIndex: photoIndex)
            }
        case .retake:
            Task { @MainActor [weak self] in
                await self?.requestRetake(photoIndex: photoIndex, source: .guest)
            }
        }
    }

    func operatorOverride(_ action: OperatorAction) {
        multipeer.sendControl(.operatorOverride(action: action))
        switch action {
        case .forceStart:
            if stateMachine.phase == .idle || stateMachine.phase == .readyToStart { startSession() }
        case .forceRetake:
            if case .review(let idx) = stateMachine.phase {
                Task { @MainActor [weak self] in
                    await self?.requestRetake(photoIndex: idx, source: .operatorSource)
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
            imageFileName: previous?.imageFileName,
            gifFrameFileNames: previous?.gifFrameFileNames ?? [],
            retakeCount: count,
            acceptedAt: previous?.acceptedAt
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
            stateMachine.reset()
            return
        }
        manifest.status = .cancelled
        manifest.cancelledAt = Date()
        try? await manifestStore.save(manifest)
        jobQueue.cancelJobs(sessionID: manifest.id)
        try? workspace.removeEntireSession(manifest: manifest)
        if let session = currentSession { store.deleteSession(session) }
        currentManifest = nil
        currentManifestID = nil
        currentSession = nil
        retakeCounts = [:]
        gifFrames = [:]
        capture.resetStills()
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
        retakeCounts = manifest.shots.reduce(into: [:]) { result, shot in
            result[shot.photoIndex] = shot.retakeCount
        }
        gifFrames = [:]
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
        beginCountdown(photoIndex: manifest.nextPhotoIndex)
    }

    private func finishDiscardingRecoveredSession(_ manifest: SessionManifest) {
        if let session = store.fetchSession(id: manifest.id) { store.deleteSession(session) }
        if currentManifestID == manifest.id {
            currentManifest = nil
            currentManifestID = nil
            currentSession = nil
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
            cloudUploadSucceeded: jobs.first(where: { $0.kind == .cloudUpload })?.status == .succeeded
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
    }

    private func restoreDownloadTokens() async {
        var mappings: [String: URL] = [:]
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
            mappings[manifest.downloadToken] = directory
        }
        await server.replaceTokenMap(mappings)
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
            resynciPad()
        case .setPreviewTransport(let transport):
            previewConnectionMode = transport == .usb ? .cable : .wireless
        case .sessionStart:
            if stateMachine.phase == .idle, activeEvent != nil {
                startSession()
            }
        case .reviewDecision(let action):
            if case .review(let idx) = stateMachine.phase {
                handleReviewDecision(photoIndex: idx, action: action)
            }
        default: break
        }
    }

    // Push current Mac state to iPad after (re)connect so it's never stuck at idle mid-session.
    private func resynciPad() {
        multipeer.sendControl(.setMirrored(isMirrored: capture.camera.isMirrored))
        switch stateMachine.phase {
        case .idle, .readyToStart:
            break
        case .countdown(let idx, let secs):
            multipeer.sendControl(.sessionStart)
            multipeer.sendControl(.eventConfig(config: stateMachine.config))
            multipeer.sendControl(.beginCountdown(photoIndex: idx, seconds: secs))
        case .captured(let idx), .review(let idx):
            if let thumb = stateMachine.keptShots[idx] {
                multipeer.sendControl(.sessionStart)
                multipeer.sendControl(.eventConfig(config: stateMachine.config))
                multipeer.sendControl(.shotCaptured(index: idx, thumbnailData: thumb))
            }
        case .processing:
            multipeer.sendControl(.sessionStart)
            multipeer.sendControl(.eventConfig(config: stateMachine.config))
        case .finished(let qr):
            multipeer.sendControl(.sessionFinished(qrPayload: qr, stripThumbData: nil, gifThumbData: nil))
        }
    }

    // MARK: - Directories

    static func runtimeDirectoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return appSupport.appendingPathComponent("PRC-PhotoBooth/Runtime", isDirectory: true)
    }

    nonisolated static func eventFolderURL(storedPath: String?, fallback: URL) -> URL {
        guard let storedPath, !storedPath.isEmpty else { return fallback }
        return URL(fileURLWithPath: storedPath, isDirectory: true)
    }

    var eventFolderPath: String { picturesOutputDir()?.path ?? "Unavailable" }

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
        acceptedAt: Date?
    ) {
        upsertRuntimeShot(
            in: &manifest.shots,
            photoIndex: photoIndex,
            imageFileName: imageFileName,
            gifFrameFileNames: gifFrameFileNames,
            retakeCount: retakeCount,
            acceptedAt: acceptedAt
        )
    }
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
    acceptedAt: Date?
) {
    let shot = RuntimeShotRecord(
        photoIndex: photoIndex,
        imageFileName: imageFileName,
        gifFrameFileNames: gifFrameFileNames,
        retakeCount: max(0, retakeCount),
        acceptedAt: acceptedAt
    )
    if let index = shots.firstIndex(where: { $0.photoIndex == photoIndex }) {
        shots[index] = shot
    } else {
        shots.append(shot)
    }
    shots.sort { $0.photoIndex < $1.photoIndex }
}
