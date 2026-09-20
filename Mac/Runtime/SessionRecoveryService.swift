import Foundation
import CoreGraphics
import Observation

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
    private let defaults: UserDefaults
    private var activeResumeID: String?

    private(set) var recoverableCaptureSession: RecoverableSession?
    private(set) var automaticallyRecoveringSessions: [String] = []
    private(set) var cleanupPendingSessionIDs: Set<String> = []
    private(set) var recoveryErrors: [String] = []
    private var recordedErrors: [String] = []

    var onResume: ((SessionManifest, [Int: CGImage]) -> Void)?
    var onDiscard: ((SessionManifest) -> Void)?
    var quiesceSessionOperations: (@MainActor (String) async -> Bool)?

    init(
        manifestStore: SessionManifestStore,
        workspace: SessionWorkspace,
        jobQueue: SessionJobQueue,
        defaults: UserDefaults = .standard
    ) {
        self.manifestStore = manifestStore
        self.workspace = workspace
        self.jobQueue = jobQueue
        self.defaults = defaults
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
        recoverableCaptureSession = nil
        automaticallyRecoveringSessions = []
        cleanupPendingSessionIDs = []
        recoveryErrors = recordedErrors

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

        let capturing = manifests
            .filter { $0.status == .capturing }
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

        for manifest in manifests where manifest.status == .finalizing {
            do {
                try workspace.removeAbandonedGIFTemporaries(manifest: manifest)
            } catch {
                recoveryErrors.append("Temporary GIF cleanup failed for \(manifest.id): \(error.localizedDescription)")
            }
            automaticallyRecoveringSessions.append(manifest.id)
            do {
                try await jobQueue.enqueueFinalizationJobs(for: manifest)
                let cloudEnabled = manifest.deliveryIntent?.cloudUploadEnabled
                    ?? (manifest.cloudDelivery != nil
                        || defaults.bool(forKey: "cloudUploadEnabled"))
                if cloudEnabled {
                    try await jobQueue.enqueueCloudUpload(for: manifest)
                }
                let printEnabled = manifest.deliveryIntent?.automaticPrintEnabled
                    ?? defaults.bool(forKey: "selphyAutoPrintAfterSession")
                if printEnabled {
                    try await jobQueue.enqueueAutoPrint(for: manifest)
                }
            } catch {
                recoveryErrors.append("Could not restore jobs for \(manifest.id): \(error.localizedDescription)")
            }
        }

        for manifest in manifests where manifest.status == .cancelled {
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
