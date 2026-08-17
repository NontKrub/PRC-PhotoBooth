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
    private(set) var recoveryErrors: [String] = []
    private var recordedErrors: [String] = []

    var onResume: ((SessionManifest, [Int: CGImage]) -> Void)?
    var onDiscard: ((SessionManifest) -> Void)?

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
                var manifest = try await manifestStore.load(sessionID: sessionID)
                manifest.status = .cancelled
                manifest.cancelledAt = Date()
                manifest.updatedAt = Date()
                try await manifestStore.save(manifest)
                jobQueue.cancelJobs(sessionID: sessionID)
                try workspace.removeEntireSession(manifest: manifest)
                if recoverableCaptureSession?.manifest.id == sessionID {
                    recoverableCaptureSession = nil
                }
                onDiscard?(manifest)
            } catch {
                recoveryErrors.append(error.localizedDescription)
            }
        }
    }

    private func scan() async {
        recoverableCaptureSession = nil
        automaticallyRecoveringSessions = []
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
                var failed = older
                failed.status = .failed
                failed.lastError = "A newer unfinished capture session exists."
                failed.updatedAt = Date()
                do {
                    try await manifestStore.save(failed)
                } catch {
                    recoveryErrors.append(error.localizedDescription)
                }
            }

            let issue = captureIssue(for: newest)
            recoverableCaptureSession = RecoverableSession(manifest: newest, issue: issue)
        }

        for manifest in manifests where manifest.status == .finalizing {
            removeAbandonedGIFTemporaries(for: manifest)
            automaticallyRecoveringSessions.append(manifest.id)
            jobQueue.enqueueFinalizationJobs(for: manifest)
            if defaults.bool(forKey: "cloudUploadEnabled") {
                jobQueue.enqueueCloudUpload(for: manifest)
            }
            if defaults.bool(forKey: "selphyAutoPrintAfterSession") {
                jobQueue.enqueueAutoPrint(for: manifest)
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

    private func removeAbandonedGIFTemporaries(for manifest: SessionManifest) {
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.lastPathComponent.hasPrefix(".booth-") && file.pathExtension == "gif" {
            try? FileManager.default.removeItem(at: file)
        }
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
