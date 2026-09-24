import Testing
import Foundation
import CoreGraphics
@testable import PRC_PhotoBooth_Mac

@Suite("JobRecoveryTests")
struct JobRecoveryTests {

    @Test("Required render job fails and marks manifest as failed")
    @MainActor
    func requiredRenderJobFailureMarksManifestFailed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()
        executor.failKind = .renderStrip
        executor.failDisposition = .retryable("Strip render failed")

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let sessionID = "session-1"
        let manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        try await manifestStore.create(manifest)

        let enqueued = try await store.enqueueBatch(sessionID: sessionID, kinds: [.renderStrip, .registerDownload, .updateGallery])
        for var j in enqueued {
            j.attemptCount = 1
            try await store.update(j)
        }

        queue.start()

        try await waitUntil {
            let m = try? await manifestStore.load(sessionID: sessionID)
            return m?.status == .failed
        }

        let updated = try await manifestStore.load(sessionID: sessionID)
        #expect(updated.status == .failed)
        #expect(updated.lastError?.contains("Strip render failed") == true)
    }

    @Test("Individual Retry restores manifest to finalizing before execution and reaches completed")
    @MainActor
    func individualRetryRestoresManifestToFinalizingAndCompletes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()
        executor.failKind = .renderStrip
        executor.failDisposition = .retryable("Strip render failed")

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let sessionID = "session-2"
        let manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        try await manifestStore.create(manifest)

        let enqueued = try await store.enqueueBatch(sessionID: sessionID, kinds: [.renderStrip, .registerDownload, .updateGallery])
        for var j in enqueued {
            j.attemptCount = 1
            try await store.update(j)
        }

        queue.start()

        try await waitUntil {
            let m = try? await manifestStore.load(sessionID: sessionID)
            return m?.status == .failed
        }

        // Job is failed, manifest is failed.
        guard let failedJob = queue.jobs.first(where: { $0.sessionID == sessionID && $0.kind == .renderStrip }) else {
            Issue.record("Expected failed renderStrip job")
            return
        }

        // Now fix the executor so the retry will succeed!
        executor.failKind = nil

        // Call coordinator recovery
        try await coordinator.retryJob(jobID: failedJob.id)

        // Manifest must be restored to .finalizing immediately and ultimately .completed
        try await waitUntil {
            let m = try? await manifestStore.load(sessionID: sessionID)
            return m?.status == .completed
        }

        let finalManifest = try await manifestStore.load(sessionID: sessionID)
        #expect(finalManifest.status == .completed)
        #expect(finalManifest.lastError == nil)
    }

    @Test("Retry All Failed restores failed manifests and executes eligible jobs")
    @MainActor
    func retryAllFailedFollowsSamePath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()
        executor.failKind = .renderStrip
        executor.failDisposition = .retryable("Batch failure")

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let s1 = "session-batch-1"
        let s2 = "session-batch-2"
        try await manifestStore.create(makeManifest(id: s1, status: .finalizing, root: root))
        try await manifestStore.create(makeManifest(id: s2, status: .finalizing, root: root))

        for sid in [s1, s2] {
            let enqueued = try await store.enqueueBatch(sessionID: sid, kinds: [.renderStrip, .registerDownload, .updateGallery])
            for var j in enqueued {
                j.attemptCount = 1
                try await store.update(j)
            }
        }

        queue.start()

        try await waitUntil {
            let m1 = try? await manifestStore.load(sessionID: s1)
            let m2 = try? await manifestStore.load(sessionID: s2)
            return m1?.status == .failed && m2?.status == .failed
        }

        executor.failKind = nil
        let retried = try await coordinator.retryAllFailedJobs()
        #expect(retried.count >= 2)

        try await waitUntil {
            let m1 = try? await manifestStore.load(sessionID: s1)
            let m2 = try? await manifestStore.load(sessionID: s2)
            return m1?.status == .completed && m2?.status == .completed
        }

        let m1 = try await manifestStore.load(sessionID: s1)
        let m2 = try await manifestStore.load(sessionID: s2)
        #expect(m1.status == .completed)
        #expect(m2.status == .completed)
    }

    @Test("Remote Operator uses the exact same recovery path")
    @MainActor
    func remoteOperatorUsesSameAuthoritativePath() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()
        executor.failKind = .renderStrip
        executor.failDisposition = .retryable("Strip error")

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let sessionID = "session-remote-1"
        let manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        try await manifestStore.create(manifest)

        let enqueued = try await store.enqueueBatch(sessionID: sessionID, kinds: [.renderStrip, .registerDownload, .updateGallery])
        for var j in enqueued {
            j.attemptCount = 1
            try await store.update(j)
        }

        queue.start()

        try await waitUntil {
            let m = try? await manifestStore.load(sessionID: sessionID)
            return m?.status == .failed
        }

        executor.failKind = nil
        let success = await coordinator.performRemoteOperatorAction(.retryFailedJobs)
        #expect(success == true)

        try await waitUntil {
            let m = try? await manifestStore.load(sessionID: sessionID)
            return m?.status == .completed
        }

        let completed = try await manifestStore.load(sessionID: sessionID)
        #expect(completed.status == .completed)
    }

    @Test("Optional job retry does not rewrite completed manifest")
    @MainActor
    func optionalRetryDoesNotRewriteCompletedManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let sessionID = "session-completed-1"
        var manifest = makeManifest(id: sessionID, status: .completed, root: root)
        manifest.completedAt = Date()
        try await manifestStore.create(manifest)

        var job = try await store.enqueue(sessionID: sessionID, kind: .cloudUpload)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        job.lastError = "Network offline"
        try await store.update(job)

        queue.start()
        await queue.waitUntilReady()

        try await coordinator.retryJob(jobID: job.id)

        let loaded = try await manifestStore.load(sessionID: sessionID)
        #expect(loaded.status == .completed)
        #expect(loaded.completedAt != nil)
    }

    @Test("sideEffectUnknown printer outcome is not automatically retried")
    @MainActor
    func sideEffectUnknownPrinterNotAutomaticallyRetried() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let sessionID = "session-print-unknown"
        let manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        try await manifestStore.create(manifest)

        var job = try await store.enqueue(sessionID: sessionID, kind: .autoPrint)
        job.status = .failed
        job.lastFailureDisposition = .sideEffectUnknown
        job.lastError = "Paper jam unknown"
        try await store.update(job)

        queue.start()
        await queue.waitUntilReady()

        // Individual retry throws manualPrintResolutionRequired
        await #expect(throws: JobRecoveryError.manualPrintResolutionRequired(job.id)) {
            try await coordinator.retryJob(jobID: job.id)
        }

        // Retry all skips it
        let retried = try await coordinator.retryAllFailedJobs()
        #expect(!retried.contains { $0.id == job.id })
    }

    @Test("Cancelled session cannot be resurrected")
    @MainActor
    func cancelledSessionCannotBeResurrected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let executor = MockJobExecutor()

        let queue = SessionJobQueue(store: store, executor: executor)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        let sessionID = "session-cancelled-1"
        var manifest = makeManifest(id: sessionID, status: .cancelled, root: root)
        manifest.cancelledAt = Date()
        try await manifestStore.create(manifest)

        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        queue.start()
        await queue.waitUntilReady()

        await #expect(throws: JobRecoveryError.manifestCancelled(sessionID)) {
            try await coordinator.retryJob(jobID: job.id)
        }

        let retried = try await coordinator.retryAllFailedJobs()
        #expect(!retried.contains { $0.sessionID == sessionID })
    }

    @Test("Startup reconciliation Case A: failed manifest with runnable required job restores to finalizing")
    @MainActor
    func startupReconciliationCaseA() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)

        let sessionID = "session-reconcile-A"
        let manifest = makeManifest(id: sessionID, status: .failed, root: root)
        try await manifestStore.create(manifest)

        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .pending
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let recovery = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )

        queue.start()
        await recovery.scanNow()

        let restored = try await manifestStore.load(sessionID: sessionID)
        #expect(restored.status == .finalizing)
        #expect(restored.lastError == nil)
    }

    @Test("Startup reconciliation Case B: finalizing manifest with all terminal required jobs becomes failed")
    @MainActor
    func startupReconciliationCaseB() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)

        let sessionID = "session-reconcile-B"
        let manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        try await manifestStore.create(manifest)

        var job1 = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job1.status = .failed
        job1.lastError = "Fatal render error"
        try await store.update(job1)

        var job2 = try await store.enqueue(sessionID: sessionID, kind: .registerDownload)
        job2.status = .cancelled
        try await store.update(job2)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let recovery = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )

        queue.start()
        await recovery.scanNow()

        let corrected = try await manifestStore.load(sessionID: sessionID)
        #expect(corrected.status == .failed)
        #expect(corrected.lastError?.contains("Fatal render error") == true)
    }
}

@MainActor
private final class MockJobExecutor: SessionJobExecuting {
    var failKind: SessionJobKind?
    var failDisposition: JobExecutionError?

    func execute(_ job: SessionJob) async throws {
        if job.kind == failKind, let error = failDisposition {
            throw error
        }
    }
}

private func makeManifest(
    id: String,
    status: RuntimeSessionStatus,
    root: URL
) -> SessionManifest {
    let sessionDir = root.appendingPathComponent("Sessions").appendingPathComponent(id)
    try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
    let config = EventConfig(eventID: "event-1", eventName: "Event 1", photoCount: 1)
    return SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: id,
        eventID: config.eventID,
        eventName: config.eventName,
        eventConfig: config,
        startedAt: Date(),
        completedAt: nil,
        cancelledAt: nil,
        status: status,
        nextPhotoIndex: 1,
        outputRootPath: root.path,
        relativeDirectoryPath: "Sessions/\(id)",
        absoluteDirectoryPath: sessionDir.path,
        frameSnapshotFileName: nil,
        stripFileName: "strip.jpg",
        gifFileName: nil,
        downloadToken: "token-\(id)",
        shots: [],
        lastError: nil,
        updatedAt: Date()
    )
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-JobRecovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func waitUntil(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw TimeoutError()
}

private struct TimeoutError: Error {}
