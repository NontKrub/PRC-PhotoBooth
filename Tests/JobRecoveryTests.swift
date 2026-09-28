import Testing
import Foundation
import CoreGraphics
@testable import PRC_PhotoBooth_Mac

@Suite("JobRecoveryTests", .serialized)
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
        #expect(coordinator.recoveryService.isSessionRecoveryInFlight?(sessionID) == false)
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

    @Test("obsolete finalization transactions are rejected before manual retry")
    @MainActor
    func obsoleteTransactionCannotBeManuallyRetried() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        var manifest = makeManifest(id: "session-obsolete-tx", status: .finalizing, root: root)
        manifest.finalizationTransactionID = "tx-current"
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: false,
            automaticPrintEnabled: false,
            updateGalleryEnabled: false,
            renderGIFEnabled: false
        )
        try await manifestStore.create(manifest)

        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var oldJob = try await store.enqueue(
            sessionID: manifest.id,
            kind: .renderStrip,
            finalizationTransactionID: "tx-old"
        )
        oldJob.status = .failed
        oldJob.lastFailureDisposition = .retryable
        try await store.update(oldJob)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        queue.pauseWorkersForRecovery()
        queue.start()
        await queue.waitUntilReady()
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )

        await #expect(throws: JobRecoveryError.obsoleteTransaction(oldJob.id)) {
            try await coordinator.retryJob(jobID: oldJob.id)
        }
        #expect(await store.snapshot().first { $0.id == oldJob.id }?.status == .failed)
        queue.stop()
    }

    @Test("Retry All requeues only the exact failed retryable candidates")
    @MainActor
    func retryAllUsesExactEligibleIDs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-exact-retry"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))

        var retryable = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        retryable.status = .failed
        retryable.lastFailureDisposition = .retryable
        try await store.update(retryable)

        var permanent = try await store.enqueue(sessionID: sessionID, kind: .registerDownload)
        permanent.status = .failed
        permanent.lastFailureDisposition = .permanent
        try await store.update(permanent)

        var waiting = try await store.enqueue(sessionID: sessionID, kind: .cloudUpload)
        waiting.status = .waitingRetry
        waiting.nextAttemptAt = Date().addingTimeInterval(3_600)
        waiting.lastFailureDisposition = .retryable
        try await store.update(waiting)

        var unknown = try await store.enqueue(sessionID: sessionID, kind: .autoPrint)
        unknown.status = .failed
        unknown.lastFailureDisposition = .sideEffectUnknown
        try await store.update(unknown)

        var cancelled = try await store.enqueue(sessionID: sessionID, kind: .renderGIF)
        cancelled.status = .cancelled
        cancelled.lastFailureDisposition = .retryable
        try await store.update(cancelled)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.count == 5 }

        let retried = try await coordinator.retryAllFailedJobs()
        #expect(retried.map(\.id) == [retryable.id])

        let durableJobs = try await store.load()
        #expect(durableJobs.first { $0.id == retryable.id }?.status == .pending)
        #expect(durableJobs.first { $0.id == permanent.id }?.status == .failed)
        #expect(durableJobs.first { $0.id == waiting.id }?.status == .waitingRetry)
        #expect(durableJobs.first { $0.id == unknown.id }?.status == .failed)
        #expect(durableJobs.first { $0.id == cancelled.id }?.status == .cancelled)
    }

    @Test("Retry All excludes jobs whose manifest cannot be loaded")
    @MainActor
    func retryAllSkipsUnrestorableManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var job = try await store.enqueue(sessionID: "missing-manifest", kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        let retried = try await coordinator.retryAllFailedJobs()
        #expect(retried.isEmpty)
        #expect(try await store.load().first { $0.id == job.id }?.status == .failed)
    }

    @Test("Permanent individual retry does not restore a failed manifest")
    @MainActor
    func permanentIndividualRetryDoesNotRestoreManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-permanent-retry"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .permanent
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        do {
            try await coordinator.retryJob(jobID: job.id)
            Issue.record("Permanent job was accepted for generic retry")
        } catch { }

        #expect(try await manifestStore.load(sessionID: sessionID).status == .failed)
        #expect(try await store.load().first { $0.id == job.id }?.status == .failed)
    }

    @Test("Cancelled individual retry does not restore a failed manifest")
    @MainActor
    func cancelledIndividualRetryDoesNotRestoreManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-cancelled-job-retry"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .cancelled
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        do {
            try await coordinator.retryJob(jobID: job.id)
            Issue.record("Cancelled job was accepted for generic retry")
        } catch { }

        #expect(try await manifestStore.load(sessionID: sessionID).status == .failed)
        #expect(try await store.load().first { $0.id == job.id }?.status == .cancelled)
    }

    @Test("Runtime reconciliation restores failed manifest when required job is runnable")
    @MainActor
    func runtimeReconciliationRestoresFailedManifestForRunnableJob() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-runtime-case-a"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        let job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }
        try await waitUntil(timeout: .seconds(1)) {
            (try? await manifestStore.load(sessionID: sessionID).status) == .finalizing
        }
        try await waitUntil(timeout: .seconds(1)) {
            queue.jobs.contains { $0.sessionID == sessionID && $0.kind == .registerDownload }
        }

        #expect(try await manifestStore.load(sessionID: sessionID).status == .finalizing)
        #expect(coordinator.recoveryService.isSessionRecoveryInFlight?(sessionID) == false)
    }

    @Test("Retry reconciliation cannot roll back a manifest between restore and queue retry")
    @MainActor
    func retryReconciliationIsGatedBetweenStores() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-retry-reconciliation-gate"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }
        coordinator.beforeManualRetryQueueMutationForTesting = {
            await coordinator.reconcileJobsNowForTesting()
        }

        try await coordinator.retryJob(jobID: job.id)

        #expect(await store.snapshot().first { $0.id == job.id }?.status == .pending)
        #expect(try await manifestStore.load(sessionID: sessionID).status == .finalizing)
    }

    @Test("Queue persistence failure rolls back retry and failed manifest")
    @MainActor
    func individualRetryRollsBackAfterQueuePersistenceFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        let sessionID = "session-retry-persistence-rollback"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }
        await store.failNextPersistenceForTesting()

        do {
            try await coordinator.retryJob(jobID: job.id)
            Issue.record("Retry unexpectedly succeeded after queue persistence failure")
        } catch { }

        #expect(await store.snapshot().first { $0.id == job.id }?.status == .failed)
        #expect(queue.jobs.first { $0.id == job.id }?.status == .failed)
        #expect(try await manifestStore.load(sessionID: sessionID).status == .failed)
        let durable = try await JobQueueStore(fileURL: jobsURL).load()
        #expect(durable.first { $0.id == job.id }?.status == .failed)
    }

    @Test("Duplicate individual retry is rejected while recovery is in flight")
    @MainActor
    func duplicateIndividualRetryIsRejected() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-duplicate-individual-retry"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }
        var duplicateWasRejected = false
        coordinator.beforeManualRetryQueueMutationForTesting = {
            do {
                try await coordinator.retryJob(jobID: job.id)
            } catch {
                duplicateWasRejected = true
            }
        }

        try await coordinator.retryJob(jobID: job.id)

        #expect(duplicateWasRejected)
        #expect(await store.snapshot().filter { $0.id == job.id && $0.status == .pending }.count == 1)
    }

    @Test("Explicit cloud retry cannot overtake the cancellation queue barrier")
    @MainActor
    func explicitCloudRetryCannotOvertakeCancellationBarrier() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-cloud-cancel-explicit"
        var manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example.com",
            remoteBasePath: "/photos",
            sshHost: "photos.example.com"
        )
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: false
        )
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(manifest)

        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var job = try await store.enqueue(sessionID: sessionID, kind: .cloudUpload)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)
        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        var cancellationPaused = false
        var resumeCancellation: CheckedContinuation<Void, Never>?
        coordinator.beforeCancellationQueueBarrierForTesting = { _ in
            cancellationPaused = true
            await withCheckedContinuation { resumeCancellation = $0 }
        }
        let cancellationTask = Task { await coordinator.cancelSessionForTesting(manifest: manifest) }
        try await waitUntil { cancellationPaused }

        coordinator.retryCloudUpload(sessionID: sessionID)
        try await waitUntil {
            let status = await store.snapshot().first { $0.id == job.id }?.status
            return coordinator.errorMessage != nil || status == .pending
        }
        #expect(await store.snapshot().first { $0.id == job.id }?.status == .failed)

        resumeCancellation?.resume()
        resumeCancellation = nil
        await cancellationTask.value
        #expect(await store.snapshot().first { $0.id == job.id }?.status == .cancelled)
    }

    @Test("Automatic cloud retry cannot overtake the cancellation queue barrier")
    @MainActor
    func automaticCloudRetryCannotOvertakeCancellationBarrier() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-cloud-cancel-automatic"
        var manifest = makeManifest(id: sessionID, status: .finalizing, root: root)
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example.com",
            remoteBasePath: "/photos",
            sshHost: "photos.example.com"
        )
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: false
        )
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(manifest)

        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var job = try await store.enqueue(sessionID: sessionID, kind: .cloudUpload)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)
        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        var cancellationPaused = false
        var resumeCancellation: CheckedContinuation<Void, Never>?
        coordinator.beforeCancellationQueueBarrierForTesting = { _ in
            cancellationPaused = true
            await withCheckedContinuation { resumeCancellation = $0 }
        }
        let cancellationTask = Task { await coordinator.cancelSessionForTesting(manifest: manifest) }
        try await waitUntil { cancellationPaused }

        await coordinator.retryFailedCloudUploadsNowForTesting()
        #expect(await store.snapshot().first { $0.id == job.id }?.status == .failed)

        resumeCancellation?.resume()
        resumeCancellation = nil
        await cancellationTask.value
        #expect(await store.snapshot().first { $0.id == job.id }?.status == .cancelled)
    }

    @Test("capturing sessions reject cloud retry without a finalization transaction")
    @MainActor
    func captureDiscardCannotRaceInFlightCloudRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-discard-cloud-retry-race"
        var manifest = makeManifest(id: sessionID, status: .capturing, root: root)
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example.com",
            remoteBasePath: "/photos",
            sshHost: "photos.example.com"
        )
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: false
        )
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(manifest)

        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var job = try await store.enqueue(sessionID: sessionID, kind: .cloudUpload)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)
        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        let recovery = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root,
            testingRecoveryService: recovery
        )
        var retryPaused = false
        var resumeRetry: CheckedContinuation<Void, Never>?
        coordinator.beforeCloudRetryQueueMutationForTesting = { _ in
            retryPaused = true
            await withCheckedContinuation { resumeRetry = $0 }
        }
        coordinator.retryCloudUpload(sessionID: sessionID)
        try await waitUntil { coordinator.errorMessage?.contains("active finalization transaction") == true }
        #expect(!retryPaused)
        #expect(try await manifestStore.load(sessionID: sessionID).status == .capturing)
        #expect(await store.snapshot().first { $0.id == job.id }?.status == .failed)
        #expect(recovery.isSessionRecoveryInFlight?(sessionID) == false)
    }

    @Test("Session cancellation cannot overtake an in-flight manual retry")
    @MainActor
    func sessionCancellationCannotOvertakeManualRetry() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-retry-cancel-race"
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        let jobsURL = root.appendingPathComponent("jobs.json")
        let store = JobQueueStore(fileURL: jobsURL)
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }

        var retryPaused = false
        var resumeRetry: CheckedContinuation<Void, Never>?
        coordinator.beforeManualRetryQueueMutationForTesting = {
            retryPaused = true
            await withCheckedContinuation { resumeRetry = $0 }
        }
        let retryTask = Task { try await coordinator.retryJob(jobID: job.id) }
        try await waitUntil(timeout: .seconds(2)) { retryPaused }

        let retryingManifest = try await manifestStore.load(sessionID: sessionID)
        await coordinator.cancelSessionForTesting(manifest: retryingManifest)
        #expect(try await manifestStore.load(sessionID: sessionID).status == .finalizing)

        resumeRetry?.resume()
        do {
            try await retryTask.value
        } catch {
            Issue.record("Manual retry failed after cancellation was deferred: \(error.localizedDescription)")
        }

        #expect(try await manifestStore.load(sessionID: sessionID).status == .finalizing)
        #expect(await store.snapshot().first { $0.id == job.id }?.status == .pending)
        let durable = try await JobQueueStore(fileURL: jobsURL).load()
        #expect(durable.first { $0.id == job.id }?.status == .pending)
    }

    @Test("Duplicate Retry All does not enqueue the same job twice")
    @MainActor
    func duplicateRetryAllDoesNotRequeueTwice() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let sessionID = "session-duplicate-batch-retry"
        try await manifestStore.create(makeManifest(id: sessionID, status: .failed, root: root))
        var job = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        job.status = .failed
        job.lastFailureDisposition = .retryable
        try await store.update(job)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: root
        )
        queue.refresh()
        try await waitUntil { queue.jobs.contains { $0.id == job.id } }
        var duplicateResult: [SessionJob]?
        coordinator.beforeManualRetryQueueMutationForTesting = {
            do {
                duplicateResult = try await coordinator.retryAllFailedJobs()
            } catch {
                duplicateResult = nil
            }
        }

        let retried = try await coordinator.retryAllFailedJobs()

        #expect(retried.map(\.id) == [job.id])
        #expect(duplicateResult?.isEmpty == true)
        #expect(await store.snapshot().filter { $0.id == job.id && $0.status == .pending }.count == 1)
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

        let executor = MockJobExecutor()
        executor.isPaused = true
        let queue = SessionJobQueue(store: store, executor: executor)
        let recovery = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )

        queue.start()
        await recovery.scanNow()
        executor.isPaused = false

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

    @Test("Startup reconciliation reserves a session before persisting its failure")
    @MainActor
    func startupReconciliationClaimsSessionBeforeTransition() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sessionID = "session-reconcile-retry-race"
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(makeManifest(id: sessionID, status: .finalizing, root: root))

        let store = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var render = try await store.enqueue(sessionID: sessionID, kind: .renderStrip)
        render.status = .failed
        render.lastFailureDisposition = .retryable
        render.lastError = "Previous render attempt failed."
        try await store.update(render)
        var registration = try await store.enqueue(sessionID: sessionID, kind: .registerDownload)
        registration.status = .cancelled
        try await store.update(registration)

        let queue = SessionJobQueue(store: store, executor: MockJobExecutor())
        queue.start()
        await queue.waitUntilReady()

        let recovery = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )
        var claimedSessionIDs = Set<String>()
        recovery.isSessionRecoveryInFlight = { claimedSessionIDs.contains($0) }
        recovery.claimSessionRecovery = { claimedSessionIDs.insert($0).inserted }
        recovery.releaseSessionRecovery = { claimedSessionIDs.remove($0) }
        var reconciliationPaused = false
        var resumeReconciliation: CheckedContinuation<Void, Never>?
        recovery.beforeManifestReconciliationForTesting = { _ in
            reconciliationPaused = true
            await withCheckedContinuation { resumeReconciliation = $0 }
        }

        let scanTask = Task { await recovery.scanNow() }
        try await waitUntil(timeout: .seconds(2)) { reconciliationPaused }
        let retryWasRejected = !(recovery.claimSessionRecovery?(sessionID) ?? true)
        resumeReconciliation?.resume()
        await scanTask.value

        #expect(retryWasRejected)
        #expect(await store.snapshot().first { $0.id == render.id }?.status == .failed)
        #expect(!claimedSessionIDs.contains(sessionID))
        #expect(try await manifestStore.load(sessionID: sessionID).status == .failed)
    }
}

@MainActor
private final class MockJobExecutor: SessionJobExecuting {
    var failKind: SessionJobKind?
    var failDisposition: JobExecutionError?
    var isPaused = false

    func execute(_ job: SessionJob) async throws {
        while isPaused {
            try? await Task.sleep(for: .milliseconds(10))
        }
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
