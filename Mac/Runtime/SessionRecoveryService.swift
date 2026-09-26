import Foundation
import CoreGraphics
import Observation

enum SessionJobReconciliationDecision: Sendable, Equatable {
    case none
    case restoreFinalizing
    case enqueueMissingRequiredJobs
    case fail(String)
    case complete

    static func evaluate(
        manifest: SessionManifest,
        jobs: [SessionJob]
    ) -> Self {
        guard let plan = FinalizationPlan.make(from: manifest) else {
            return .none
        }
        let transactionJobs = jobs.filter {
            $0.sessionID == manifest.id && $0.finalizationTransactionID == plan.transactionID
        }
        func latest(_ kind: SessionJobKind) -> SessionJob? {
            let matching = transactionJobs.filter { $0.kind == kind }
            let nonCancelled = matching.filter { $0.status != .cancelled }
            return (nonCancelled.isEmpty ? matching : nonCancelled).max {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
            }
        }
        let requiredJobs = FinalizationPlan.requiredJobKinds.compactMap(latest)

        switch manifest.status {
        case .failed:
            return requiredJobs.contains(where: { SessionJobDependencyPolicy.hasRunnableWork($0, in: jobs) })
                ? .restoreFinalizing
                : .none
        case .finalizing:
            if plan.jobKinds.contains(where: { latest($0) == nil }) {
                return .enqueueMissingRequiredJobs
            }
            if requiredJobs.count == FinalizationPlan.requiredJobKinds.count,
               requiredJobs.allSatisfy({ $0.status == .succeeded }) {
                return .complete
            }
            let unfinished = requiredJobs.filter { $0.status != .succeeded }
            let hasTerminalFailure = unfinished.contains { $0.status == .failed || $0.status == .cancelled }
            if hasTerminalFailure,
               !requiredJobs.contains(where: { SessionJobDependencyPolicy.hasRunnableWork($0, in: jobs) }) {
                return .fail(unfinished.compactMap(\.lastError).first ?? "Required finalization jobs failed.")
            }
            return requiredJobs.count < FinalizationPlan.requiredJobKinds.count ? .enqueueMissingRequiredJobs : .none
        case .capturing, .completed, .cancelled:
            return .none
        }
    }

}

struct RecoverableSession: Identifiable, Sendable {
    var manifest: SessionManifest
    var issue: String?

    var id: String { manifest.id }
}

@MainActor
@Observable
final class SessionRecoveryService {
    private let manifestStore: SessionManifestStore
    private let workspace: SessionWorkspace
    private let jobQueue: SessionJobQueue
    private var activeResumeID: String?
    private var scanInProgress = false
    private var locallyClaimedRecoverySessionIDs: Set<String> = []

    private(set) var recoverableCaptureSession: RecoverableSession?
    private(set) var automaticallyRecoveringSessions: [String] = []
    private(set) var cleanupPendingSessionIDs: Set<String> = []
    private(set) var recoveryErrors: [String] = []
    private var recordedErrors: [String] = []

    var onResume: ((SessionManifest, [Int: CGImage]) -> Void)?
    var onDiscard: ((SessionManifest) -> Void)?
    var quiesceSessionOperations: (@MainActor (String) async -> Bool)?
    var isSessionRecoveryInFlight: (@MainActor (String) -> Bool)?
    var claimSessionRecovery: (@MainActor (String) -> Bool)?
    var releaseSessionRecovery: (@MainActor (String) -> Void)?
    var onRecoveryScanFinished: (@MainActor () -> Void)?
#if DEBUG
    var beforeManifestReconciliationForTesting: (@MainActor (String) async -> Void)?
#endif

    init(
        manifestStore: SessionManifestStore,
        workspace: SessionWorkspace,
        jobQueue: SessionJobQueue
    ) {
        self.manifestStore = manifestStore
        self.workspace = workspace
        self.jobQueue = jobQueue
    }

    func recordError(_ message: String) {
        recordedErrors.append(message)
        recoveryErrors.append(message)
    }

    func markCleanupPending(sessionID: String) {
        cleanupPendingSessionIDs.insert(sessionID)
        recordError("Cancelled session cleanup is still pending: \(sessionID)")
    }

    func scanAtStartup() {
        Task { [weak self] in
            await self?.scanNow()
        }
    }

    func scanNow() async {
        await scan()
    }

    func resumeCaptureSession(sessionID: String) {
        guard activeResumeID == nil else { return }
        activeResumeID = sessionID
        Task { [weak self] in
            guard let self else { return }
            defer { activeResumeID = nil }
            do {
                let manifest = try await manifestStore.load(sessionID: sessionID)
                guard manifest.status == .capturing else {
                    throw RecoveryError.invalidCapture("Session is no longer waiting for capture recovery.")
                }
                let images = try loadAcceptedImages(for: manifest)
                recoverableCaptureSession = nil
                onResume?(manifest, images)
            } catch {
                let message = error.localizedDescription
                recoveryErrors.append(message)
                if let current = recoverableCaptureSession,
                   current.manifest.id == sessionID {
                    recoverableCaptureSession = RecoverableSession(
                        manifest: current.manifest,
                        issue: message
                    )
                }
            }
        }
    }

    func discardCaptureSession(sessionID: String) {
        Task { [weak self] in
            guard let self else { return }
            guard claimRecoverySession(sessionID) else {
                recoveryErrors.append("Session recovery is already running: \(sessionID)")
                return
            }
            defer { releaseRecoverySession(sessionID) }

            do {
                let manifest = try await manifestStore.transition(
                    sessionID: sessionID,
                    allowedFrom: [.capturing]
                ) { durable in
                    durable.status = .cancelled
                    durable.cancelledAt = Date()
                    durable.lastError = nil
                }
                if recoverableCaptureSession?.manifest.id == sessionID {
                    recoverableCaptureSession = nil
                }
                guard await quiesceSessionOperations?(sessionID) ?? true else {
                    markCleanupPending(sessionID: sessionID)
                    return
                }
                let quiescence = try await jobQueue.cancelAndQuiesceJobs(sessionID: sessionID)
                guard quiescence == .quiesced else {
                    markCleanupPending(sessionID: sessionID)
                    return
                }
                try workspace.removeEntireSession(manifest: manifest)
                onDiscard?(manifest)
            } catch {
                cleanupPendingSessionIDs.insert(sessionID)
                recoveryErrors.append(error.localizedDescription)
            }
        }
    }

    private func scan() async {
        guard !scanInProgress else { return }
        scanInProgress = true
        defer { scanInProgress = false }

        recoverableCaptureSession = nil
        automaticallyRecoveringSessions = []
        cleanupPendingSessionIDs = []
        recoveryErrors = recordedErrors
        await jobQueue.waitUntilReady()

        let results = await manifestStore.loadAll()
        var manifests: [SessionManifest] = []
        for result in results {
            switch result {
            case .loaded(let manifest):
                manifests.append(manifest)
            case .failed(let fileURL, let message):
                recoveryErrors.append("\(fileURL.lastPathComponent): \(message)")
            }
        }

        var claimedSessionIDs = Set<String>()
        for manifest in manifests where claimRecoverySession(manifest.id) {
            claimedSessionIDs.insert(manifest.id)
        }
        defer {
            for sessionID in claimedSessionIDs {
                releaseRecoverySession(sessionID)
            }
            if !claimedSessionIDs.isEmpty {
                onRecoveryScanFinished?()
            }
        }

        var reconciledManifests: [SessionManifest] = []
        for var manifest in manifests {
            guard claimedSessionIDs.contains(manifest.id) else {
                reconciledManifests.append(manifest)
                continue
            }
            let hasLegacyFinalizationWork = jobQueue.jobs.contains {
                $0.sessionID == manifest.id
                    && ($0.kind == .renderStrip || $0.kind == .registerDownload)
            }
            if manifest.status == .finalizing
                || (manifest.status == .failed && hasLegacyFinalizationWork && FinalizationPlan.make(from: manifest) == nil) {
                do {
                    manifest = try await prepareFinalizationPlanForRecovery(for: manifest)
                } catch {
                    recoveryErrors.append("Could not persist finalization plan for \(manifest.id): \(error.localizedDescription)")
                }
            }
            let sessionJobs = jobQueue.jobs.filter { $0.sessionID == manifest.id }
            let decision = SessionJobReconciliationDecision.evaluate(
                manifest: manifest,
                jobs: sessionJobs
            )
#if DEBUG
            if decision == .restoreFinalizing {
                await beforeManifestReconciliationForTesting?(manifest.id)
            } else if case .fail = decision {
                await beforeManifestReconciliationForTesting?(manifest.id)
            }
#endif
            switch decision {
            case .restoreFinalizing:
                do {
                    manifest = try await manifestStore.transition(
                        sessionID: manifest.id,
                        allowedFrom: [.failed]
                    ) { durable in
                        durable.status = .finalizing
                        durable.lastError = nil
                    }
                } catch {
                    recoveryErrors.append("Case A reconciliation failed for \(manifest.id): \(error.localizedDescription)")
                }
            case .fail(let reason):
                do {
                    manifest = try await manifestStore.transition(
                        sessionID: manifest.id,
                        allowedFrom: [.finalizing]
                    ) { durable in
                        durable.status = .failed
                        durable.lastError = reason
                    }
                } catch {
                    recoveryErrors.append("Case B reconciliation failed for \(manifest.id): \(error.localizedDescription)")
                }
            case .none, .enqueueMissingRequiredJobs, .complete:
                break
            }
            reconciledManifests.append(manifest)
        }
        manifests = reconciledManifests

        let capturing = manifests
            .filter { claimedSessionIDs.contains($0.id) && $0.status == .capturing }
            .sorted { $0.startedAt > $1.startedAt }
        if let newest = capturing.first {
            for older in capturing.dropFirst() {
                do {
                    _ = try await manifestStore.transition(
                        sessionID: older.id,
                        allowedFrom: [.capturing]
                    ) { failed in
                        failed.status = .failed
                        failed.lastError = "A newer unfinished capture session exists."
                    }
                } catch {
                    recoveryErrors.append(error.localizedDescription)
                }
            }

            let issue = captureIssue(for: newest)
            recoverableCaptureSession = RecoverableSession(manifest: newest, issue: issue)
        }

        for manifest in manifests where claimedSessionIDs.contains(manifest.id) && manifest.status == .finalizing {
            do {
                try workspace.removeAbandonedGIFTemporaries(manifest: manifest)
            } catch {
                recoveryErrors.append("Temporary GIF cleanup failed for \(manifest.id): \(error.localizedDescription)")
            }
            automaticallyRecoveringSessions.append(manifest.id)
            do {
                try await jobQueue.enqueueFinalizationJobs(for: manifest)
            } catch {
                recoveryErrors.append("Could not restore jobs for \(manifest.id): \(error.localizedDescription)")
            }
        }

        for manifest in manifests where claimedSessionIDs.contains(manifest.id) && manifest.status == .cancelled {
            do {
                let result = try await jobQueue.cancelAndQuiesceJobs(sessionID: manifest.id)
                guard result == .quiesced else {
                    cleanupPendingSessionIDs.insert(manifest.id)
                    recoveryErrors.append("Cancelled session cleanup is pending: \(manifest.id)")
                    continue
                }
                try workspace.removeEntireSession(manifest: manifest)
                try await manifestStore.delete(sessionID: manifest.id)
                try await jobQueue.deleteJobsAndForgetCancellationBarrier(sessionID: manifest.id)
            } catch {
                cleanupPendingSessionIDs.insert(manifest.id)
                recoveryErrors.append("Cancelled session cleanup failed for \(manifest.id): \(error.localizedDescription)")
            }
        }

        for manifest in manifests where manifest.status == .failed {
            if let error = manifest.lastError {
                recoveryErrors.append("\(manifest.eventName): \(error)")
            }
        }
    }

    func prepareFinalizationPlanForRecovery(for manifest: SessionManifest) async throws -> SessionManifest {
        guard manifest.status == .finalizing || manifest.status == .failed || manifest.status == .completed else {
            return manifest
        }
        let knownJobs = try await jobQueue.reloadJobsForRecovery()
        let existingIntent = manifest.deliveryIntent
        let transactionID = manifest.finalizationTransactionID.flatMap { $0.isEmpty ? nil : $0 }
            ?? "legacy-\(manifest.id)"
        let sessionJobs = knownJobs.filter { $0.sessionID == manifest.id }
        let hasHistoricalCloudEvidence = manifest.cloudDelivery != nil
            || sessionJobs.contains { $0.kind == .cloudUpload }
        let hasHistoricalPrintEvidence = sessionJobs.contains { $0.kind == .autoPrint }
        let cloudEnabled = existingIntent?.cloudUploadEnabled
            ?? hasHistoricalCloudEvidence
        let printEnabled = existingIntent?.automaticPrintEnabled
            ?? hasHistoricalPrintEvidence
        let deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: cloudEnabled,
            automaticPrintEnabled: printEnabled,
            updateGalleryEnabled: existingIntent?.updateGalleryEnabled
                ?? (manifest.eventConfig.eventGalleryPath != nil),
            renderGIFEnabled: existingIntent?.renderGIFEnabled
                ?? manifest.shots.contains { !$0.gifFrameFileNames.isEmpty }
        )
        let persistedCloudDelivery = manifest.cloudDelivery

        let needsPersistence = manifest.finalizationTransactionID != transactionID
            || manifest.deliveryIntent != deliveryIntent
            || manifest.cloudDelivery != persistedCloudDelivery
        var durableManifest = manifest
        if needsPersistence {
            durableManifest = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [manifest.status]
            ) { durable in
                durable.finalizationTransactionID = transactionID
                durable.deliveryIntent = deliveryIntent
                durable.cloudDelivery = persistedCloudDelivery
            }
        }

        try await jobQueue.migrateLegacyFinalizationJobs(for: durableManifest)
        if existingIntent == nil {
            var unknownEffects: [String] = []
            if !hasHistoricalPrintEvidence { unknownEffects.append("printing") }
            if !hasHistoricalCloudEvidence { unknownEffects.append("cloud upload") }
            if !unknownEffects.isEmpty {
                recordError(
                    "Legacy session \(manifest.id) had no historical evidence for \(unknownEffects.joined(separator: " or ")); recovery did not schedule those side effects."
                )
            }
        }
        return durableManifest
    }

    private func claimRecoverySession(_ sessionID: String) -> Bool {
        guard isSessionRecoveryInFlight?(sessionID) != true else { return false }
        if let claimSessionRecovery {
            return claimSessionRecovery(sessionID)
        }
        return locallyClaimedRecoverySessionIDs.insert(sessionID).inserted
    }

    private func releaseRecoverySession(_ sessionID: String) {
        if let releaseSessionRecovery {
            releaseSessionRecovery(sessionID)
        } else {
            locallyClaimedRecoverySessionIDs.remove(sessionID)
        }
    }

    private func captureIssue(for manifest: SessionManifest) -> String? {
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return "Output directory is missing: \(directory.path)"
        }
        do {
            _ = try workspace.loadAcceptedImages(manifest: manifest)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func loadAcceptedImages(for manifest: SessionManifest) throws -> [Int: CGImage] {
        if let issue = captureIssue(for: manifest) {
            throw RecoveryError.invalidCapture(issue)
        }
        return try workspace.loadAcceptedImages(manifest: manifest)
    }

}

@MainActor
final class SessionFlowOperationRegistry {
    enum Kind: Sendable {
        case capture
        case reviewDecision
        case captureRecovery
    }

    private struct Entry {
        let sessionID: String
        let task: Task<Void, Never>
    }

    private var entries: [UUID: Entry] = [:]
    private var waiters: [UUID: (sessionID: String, continuation: CheckedContinuation<Bool, Never>)] = [:]

    @discardableResult
    func start(
        sessionID: String,
        kind: Kind,
        operation: @escaping @MainActor () async -> Void
    ) -> UUID {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            await operation()
            self?.finish(id)
        }
        entries[id] = Entry(sessionID: sessionID, task: task)
        return id
    }

    func cancelAndQuiesce(sessionID: String, timeout: Duration) async -> Bool {
        for entry in entries.values where entry.sessionID == sessionID {
            entry.task.cancel()
        }
        guard entries.values.contains(where: { $0.sessionID == sessionID }) else { return true }
        return await waitForQuiescence(sessionID: sessionID, timeout: timeout)
    }

    private func finish(_ id: UUID) {
        entries.removeValue(forKey: id)
        let ready = waiters.filter { _, waiter in
            !entries.values.contains { $0.sessionID == waiter.sessionID }
        }
        for (waiterID, waiter) in ready {
            waiters.removeValue(forKey: waiterID)
            waiter.continuation.resume(returning: true)
        }
    }

    private func waitForQuiescence(sessionID: String, timeout: Duration) async -> Bool {
        guard entries.values.contains(where: { $0.sessionID == sessionID }) else { return true }
        let waiterID = UUID()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        return await withCheckedContinuation { continuation in
            waiters[waiterID] = (sessionID, continuation)
            Task { @MainActor [weak self] in
                do { try await clock.sleep(until: deadline) } catch { return }
                self?.timeout(waiterID)
            }
        }
    }

    private func timeout(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(returning: false)
    }
}

private enum RecoveryError: LocalizedError {
    case invalidCapture(String)

    var errorDescription: String? {
        switch self {
        case .invalidCapture(let message): return message
        }
    }
}
