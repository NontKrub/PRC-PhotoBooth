import Foundation
import Observation

@MainActor
@Observable
final class BoothPreflightService {
    private(set) var results: [PreflightCheckResult] = []
    private(set) var readiness: BoothReadinessStatus = .checking
    private(set) var lastRunAt: Date?
    private(set) var isRunning = false

    func runSafeChecks(using context: BoothPreflightContext) async {
        isRunning = true
        readiness = .checking
        let now = Date()
        var checked = [PreflightCheckResult]()

        checked.append(result(.activeEvent, "Active event", context.event == nil ? "No event is active." : "Active event: \(context.event!.eventName).", context.event == nil ? .failed : .passed, .required, now))
        checked.append(eventLayoutResult(context.event, now: now))
        checked.append(result(.eventExperience, "Event experience", context.eventExperienceDetail, context.eventExperienceStatus, .required, now))
        checked.append(result(.templateAssets, "Template assets", context.templateAssetsDetail, context.templateAssetsStatus, .recommended, now))
        checked.append(result(.filterPipeline, "Filter pipeline", context.filterPipelineDetail, context.filterPipelineStatus, .required, now))
        checked.append(result(.galleryStorage, "Gallery storage", context.galleryStorageDetail, context.galleryStorageStatus, .recommended, now))
        checked.append(capturePermissionResult(context, now: now))
        checked.append(result(
            .cameraConnection,
            context.cameraSourceKind == .dslr ? "DSLR capture" : "AVFoundation camera",
            context.cameraConnected ? "Selected capture source is ready." : "Selected capture source is unavailable.",
            context.cameraConnected ? .passed : .failed,
            .required,
            now
        ))
        checked.append(result(.cameraTestCapture, "Camera test capture", "Run Full Preflight to test the shutter.", .notRun, .recommended, now))
        checked.append(result(.customerDisplay, "Customer display", context.customerDisplayReady ? "A customer display is ready." : "Connect an iPad or activate the external viewer.", context.customerDisplayReady ? .passed : .failed, .required, now))
        checked.append(previewResult(context, now: now))

        let output = outputFolderResult(context.outputFolderURL, now: now)
        checked.append(output)
        checked.append(diskResult(context.availableDiskBytes, now: now))
        let serverDetail: String
        if context.localServerHealthPassed {
            serverDetail = "Health check returned HTTP 200."
        } else if case .failed(let message) = context.localServerStatus.state {
            serverDetail = "Local download server failed: \(message)"
        } else {
            serverDetail = "The local download server is not healthy."
        }
        checked.append(result(.localDownloadServer, "Local download server", serverDetail, context.localServerHealthPassed ? .passed : .failed, .required, now))
        checked.append(result(.localIPAddress, "Local IP address", context.localIPAddress == nil ? "No LAN address was found." : context.localIPAddress!, context.localIPAddress == nil ? .warning : .passed, .recommended, now))
        checked.append(runtimeResult(context, now: now))
        checked.append(startupResult(.recoveryStorage, component: .recoveryStore, title: "Recovery storage", context: context, now: now))
        checked.append(result(.unfinishedSession, "Unfinished session", context.unfinishedCaptureSession ? "An unfinished capture session awaits Resume or Discard." : "No unfinished capture session is waiting.", context.unfinishedCaptureSession ? .failed : .passed, .required, now))

        let queueUnavailable = context.startupComponents[.jobQueue]?.status == .unavailable
        let queueStatus: PreflightCheckStatus = queueUnavailable || !context.queuePersistenceAvailable || context.requiredJobFailed ? .failed : (context.optionalJobPendingOrFailed ? .warning : .passed)
        let queueDetail = queueUnavailable ? (context.startupComponents[.jobQueue]?.detail ?? "The persistent job queue is unavailable.") : !context.queuePersistenceAvailable ? "The persistent job queue is unavailable." : context.requiredJobFailed ? "A required queue job has permanently failed." : context.optionalJobPendingOrFailed ? "Optional cloud or print work is waiting or failed." : "Queue persistence and required jobs are healthy."
        checked.append(result(.queueHealth, "Queue health", queueDetail, queueStatus, .required, now))
        checked.append(cloudResult(context, now: now))
        checked.append(printerConfigurationResult(context, now: now))
        checked.append(printerTestResult(context, now: now))

        results = checked
        lastRunAt = now
        isRunning = false
        readiness = calculateReadiness(from: checked)
    }

    func runFullPreflight(
        using context: BoothPreflightContext,
        runPrinterTest: Bool,
        cameraTest: @escaping @MainActor () async throws -> Void,
        printerTest: @escaping @MainActor () async throws -> Void
    ) async {
        await runSafeChecks(using: context)
        if context.cameraConnected {
            update(.cameraTestCapture, status: .running, detail: "Running diagnostic camera capture…")
            do {
                try await cameraTest()
                update(.cameraTestCapture, status: .passed, detail: "Diagnostic capture succeeded.")
            } catch {
                update(.cameraTestCapture, status: .failed, detail: error.localizedDescription)
            }
        }
        if runPrinterTest {
            update(.printerTest, status: .running, detail: "Submitting printer test page…")
            do {
                try await printerTest()
                update(.printerTest, status: .passed, detail: "Test page submitted.")
            } catch {
                update(.printerTest, status: .failed, detail: error.localizedDescription)
            }
        }
        readiness = calculateReadiness(from: results)
        lastRunAt = Date()
    }

    func result(for id: PreflightCheckID) -> PreflightCheckResult? {
        results.first { $0.id == id }
    }

    private func update(_ id: PreflightCheckID, status: PreflightCheckStatus, detail: String) {
        guard let index = results.firstIndex(where: { $0.id == id }) else { return }
        results[index].status = status
        results[index].detail = detail
        results[index].checkedAt = Date()
    }

    private func result(_ id: PreflightCheckID, _ title: String, _ detail: String, _ status: PreflightCheckStatus, _ requirement: PreflightRequirement, _ date: Date) -> PreflightCheckResult {
        PreflightCheckResult(id: id, title: title, detail: detail, requirement: requirement, status: status, checkedAt: date)
    }

    private func eventLayoutResult(_ event: EventConfig?, now: Date) -> PreflightCheckResult {
        guard let event else { return result(.eventLayout, "Event layout", "No active event layout to validate.", .failed, .required, now) }
        if event.photoCount <= 0 || event.slots.isEmpty || event.canvasWidth <= 0 || event.canvasHeight <= 0 {
            return result(.eventLayout, "Event layout", "Photo count, canvas, and at least one slot are required.", .failed, .required, now)
        }
        if event.slots.contains(where: { $0.photoIndex < 0 || $0.photoIndex >= event.photoCount }) {
            return result(.eventLayout, "Event layout", "A slot references a photo index outside the event.", .failed, .required, now)
        }
        if event.slots.contains(where: { $0.normalizedRect.width <= 0 || $0.normalizedRect.height <= 0 }) {
            return result(.eventLayout, "Event layout", "A slot has zero or negative dimensions.", .warning, .recommended, now)
        }
        let indexes = Set(event.slots.map(\.photoIndex))
        if !(0..<event.photoCount).allSatisfy({ indexes.contains($0) }) {
            return result(.eventLayout, "Event layout", "One or more capture indexes have no corresponding slot.", .warning, .recommended, now)
        }
        return result(.eventLayout, "Event layout", "Photo slots and canvas are valid.", .passed, .required, now)
    }

    private func previewResult(_ context: BoothPreflightContext, now: Date) -> PreflightCheckResult {
        guard context.ipadConnected else {
            return result(.previewTransport, "Preview transport", "Skipped because no iPad is connected.", .skipped, .recommended, now)
        }
        if context.usesCablePreview {
            let ok = context.usbPreviewSupported && context.usbPreviewClientConnected
            return result(.previewTransport, "Preview transport", ok ? "USB preview client is connected." : "Cable mode requires a supported USB listener and connected client.", ok ? .passed : .failed, .required, now)
        }
        return result(.previewTransport, "Preview transport", "Wireless preview transport is active.", .passed, .required, now)
    }

    private func capturePermissionResult(_ context: BoothPreflightContext, now: Date) -> PreflightCheckResult {
        if context.cameraSourceKind == .avFoundation {
            return result(
                .cameraPermission,
                "AVFoundation camera permission",
                context.cameraPermissionGranted ? "macOS camera permission is granted." : "macOS camera permission is denied or restricted.",
                context.cameraPermissionGranted ? .passed : .failed,
                .required,
                now
            )
        }

        guard context.previewPermissionGranted else {
            return result(
                .cameraPermission,
                "AVFoundation preview",
                "AVFoundation preview permission is denied; DSLR capture remains available.",
                context.previewRequired ? .failed : .warning,
                context.previewRequired ? .required : .recommended,
                now
            )
        }
        guard context.previewConnected else {
            return result(
                .cameraPermission,
                "AVFoundation preview",
                "Optional AVFoundation preview is unavailable; DSLR capture remains available.",
                context.previewRequired ? .failed : .warning,
                context.previewRequired ? .required : .recommended,
                now
            )
        }
        return result(.cameraPermission, "AVFoundation preview", "Not required for DSLR still capture.", .skipped, .recommended, now)
    }

    private func outputFolderResult(_ url: URL?, now: Date) -> PreflightCheckResult {
        guard let url else { return result(.outputFolder, "Output folder", "No output folder is configured.", .failed, .required, now) }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let probe = url.appendingPathComponent(".preflight-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe, options: [.atomic])
            try FileManager.default.removeItem(at: probe)
            return result(.outputFolder, "Output folder", "Folder is writable.", .passed, .required, now)
        } catch {
            return result(.outputFolder, "Output folder", error.localizedDescription, .failed, .required, now)
        }
    }

    private func diskResult(_ bytes: Int64?, now: Date) -> PreflightCheckResult {
        let value = bytes ?? 0
        if value < 2_000_000_000 { return result(.diskSpace, "Disk space", "Less than 2 GB is available.", .failed, .required, now) }
        if value < 10_000_000_000 { return result(.diskSpace, "Disk space", "Between 2 GB and 10 GB is available.", .warning, .recommended, now) }
        return result(.diskSpace, "Disk space", "At least 10 GB is available.", .passed, .recommended, now)
    }

    private func runtimeResult(_ context: BoothPreflightContext, now: Date) -> PreflightCheckResult {
        if let health = context.startupComponents[.runtimeDirectory], health.status == .unavailable {
            return result(.runtimePersistence, "Runtime persistence", health.detail, .failed, .required, now)
        }
        if let health = context.startupComponents[.dataStore], health.status == .unavailable {
            return result(.runtimePersistence, "Runtime persistence", health.detail, .failed, .required, now)
        }
        guard context.runtimePersistenceAvailable else { return result(.runtimePersistence, "Runtime persistence", "Runtime persistence is unavailable.", .failed, .required, now) }
        do {
            try FileManager.default.createDirectory(at: context.runtimeDirectoryURL, withIntermediateDirectories: true)
            let probe = context.runtimeDirectoryURL.appendingPathComponent(".preflight-runtime-\(UUID().uuidString).json")
            try Data("{}".utf8).write(to: probe, options: [.atomic])
            try FileManager.default.removeItem(at: probe)
            return result(.runtimePersistence, "Runtime persistence", "Atomic runtime writes are available.", .passed, .required, now)
        } catch {
            return result(.runtimePersistence, "Runtime persistence", error.localizedDescription, .failed, .required, now)
        }
    }

    private func startupResult(
        _ id: PreflightCheckID,
        component: StartupComponent,
        title: String,
        context: BoothPreflightContext,
        now: Date
    ) -> PreflightCheckResult {
        guard let health = context.startupComponents[component] else {
            return result(id, title, "No startup error recorded.", .passed, .required, now)
        }
        let status: PreflightCheckStatus = switch health.status {
        case .ready: .passed
        case .degraded: .warning
        case .unavailable: .failed
        }
        return result(id, title, health.detail, status, .required, now)
    }

    private func cloudResult(_ context: BoothPreflightContext, now: Date) -> PreflightCheckResult {
        guard context.cloudUploadEnabled else { return result(.cloudUpload, "Cloud upload", "Disabled in Settings.", .skipped, .recommended, now) }
        guard context.cloudSetupComplete else { return result(.cloudUpload, "Cloud upload", "Cloud SSH setup is incomplete.", .failed, .required, now) }
        return result(.cloudUpload, "Cloud upload", context.cloudConnectivityPassed ? "SSH connectivity is ready." : "SSH connectivity failed.", context.cloudConnectivityPassed ? .passed : .failed, .required, now)
    }

    private func printerConfigurationResult(_ context: BoothPreflightContext, now: Date) -> PreflightCheckResult {
        if context.automaticPrintingEnabled {
            return result(.printerConfiguration, "Printer configuration", context.printerConfigured ? "Configured printer is available." : "Configured printer is unavailable.", context.printerConfigured ? .passed : .failed, .required, now)
        }
        return result(.printerConfiguration, "Printer configuration", context.printerConfigured ? "Printer is available." : "Automatic printing is disabled; configure a printer when needed.", context.printerConfigured ? .passed : .warning, .recommended, now)
    }

    private func printerTestResult(_ context: BoothPreflightContext, now: Date) -> PreflightCheckResult {
        guard let test = context.printerTestResult else { return result(.printerTest, "Printer test", "Not run during this application launch.", .notRun, .recommended, now) }
        return result(.printerTest, "Printer test", test.message, test.isSuccess ? .passed : .failed, .recommended, test.date)
    }

    private func calculateReadiness(from results: [PreflightCheckResult]) -> BoothReadinessStatus {
        if results.contains(where: { $0.requirement == .required && $0.status == .running }) { return .checking }
        if results.contains(where: { $0.requirement == .required && $0.status == .failed }) { return .notReady }
        if results.contains(where: { $0.status == .warning }) { return .readyWithWarnings }
        return .ready
    }
}
