import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("SessionJobQueue")
struct SessionJobQueueTests {
    @Test("cloud upload does not block another session's finalization")
    @MainActor
    func cloudUploadDoesNotBlockAnotherSession() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingCloudJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let sessionA = makeManifest()
        let sessionB = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: sessionA)
        try await waitUntil { await executor.snapshot().kinds.count == 3 }
        try await queue.enqueueCloudUpload(for: sessionA)
        try await waitUntil { await executor.snapshot().cloudUploadStarted }

        try await queue.enqueueFinalizationJobs(for: sessionB)
        try await waitUntil {
            await queue.job(sessionID: sessionB.id, status: .succeeded, kind: .renderStrip) != nil
        }

        #expect(await executor.snapshot().cloudUploadStarted)
        #expect(await executor.snapshot().cloudUploadCompleted == false)

        await executor.releaseCloudUpload()
        try await waitUntil { await executor.snapshot().cloudUploadCompleted }
    }

    @Test("cloud QR publication completes before the automatic print starts")
    @MainActor
    func cloudPublicationPrecedesAutomaticPrint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingCloudJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        var manifest = makeManifest()
        manifest.eventConfig.qrCodeElements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        ]
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example",
            remoteBasePath: "/gallery",
            sshHost: "photos.example"
        )
        manifest.deliveryIntent?.cloudUploadEnabled = true
        manifest.deliveryIntent?.automaticPrintEnabled = true
        let sessionID = manifest.id

        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil("cloud upload start") { await executor.snapshot().cloudUploadStarted }

        #expect(await executor.snapshot().kinds.contains(.autoPrint) == false)
        #expect(await queue.job(sessionID: manifest.id, status: .pending, kind: .autoPrint) != nil)

        await executor.releaseCloudUpload()
        try await waitUntil("cloud publication and print") {
            let cloudJob = await queue.job(sessionID: sessionID, status: .succeeded, kind: .cloudUpload)
            let printJob = await queue.job(sessionID: sessionID, status: .succeeded, kind: .autoPrint)
            return cloudJob != nil && printJob != nil
        }
        let kinds = await executor.snapshot().kinds
        guard let cloudIndex = kinds.firstIndex(of: .cloudUpload),
              let printIndex = kinds.firstIndex(of: .autoPrint) else {
            Issue.record("Expected cloud upload and automatic print to execute")
            return
        }
        #expect(cloudIndex < printIndex)
    }

    @Test("failed cloud publication withholds and cancels the automatic print")
    @MainActor
    func failedCloudPublicationWithholdsAutomaticPrint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = TestJobExecutor()
        executor.fail(.cloudUpload, with: .permanent("Cloud route verification failed"))
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        var manifest = makeManifest()
        manifest.eventConfig.qrCodeElements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        ]
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example",
            remoteBasePath: "/gallery",
            sshHost: "photos.example"
        )
        manifest.deliveryIntent?.cloudUploadEnabled = true
        manifest.deliveryIntent?.automaticPrintEnabled = true
        let sessionID = manifest.id

        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil("print withheld") {
            await queue.job(sessionID: sessionID, status: .cancelled, kind: .autoPrint) != nil
        }

        #expect(await executor.snapshot().kinds.contains(.autoPrint) == false)
        #expect(await queue.job(sessionID: manifest.id, status: .failed, kind: .cloudUpload)?.lastError == "Cloud route verification failed")
        #expect(await queue.job(sessionID: manifest.id, status: .cancelled, kind: .autoPrint)?.lastError == SessionJobDependencyPolicy.printWithheldUntilCloudPublishedError)
    }

    @Test("a recovered cloud route releases its withheld first print")
    @MainActor
    func recoveredCloudPublicationReleasesPrint() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = FailFirstCloudUploadJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        var manifest = makeManifest()
        manifest.eventConfig.qrCodeElements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        ]
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example",
            remoteBasePath: "/gallery",
            sshHost: "photos.example"
        )
        manifest.deliveryIntent?.cloudUploadEnabled = true
        manifest.deliveryIntent?.automaticPrintEnabled = true
        let sessionID = manifest.id

        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil("cloud failure with print withheld") {
            await queue.job(sessionID: sessionID, status: .cancelled, kind: .autoPrint) != nil
        }
        #expect(try await queue.forceRequeueCloudUpload(
            sessionID: manifest.id,
            finalizationTransactionID: manifest.finalizationTransactionID
        ) == .queued)
        try await waitUntil("recovered cloud route and first print") {
            let cloud = await queue.job(sessionID: sessionID, status: .succeeded, kind: .cloudUpload)
            let print = await queue.job(sessionID: sessionID, status: .succeeded, kind: .autoPrint)
            return cloud != nil && print != nil
        }
        #expect(await executor.snapshot().printAttempts == 1)
    }

    @Test("cloud upload does not delay a print when the strip has no QR code")
    @MainActor
    func cloudUploadDoesNotDelayPrintWithoutQR() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingCloudJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        var manifest = makeManifest()
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example",
            remoteBasePath: "/gallery",
            sshHost: "photos.example"
        )
        manifest.deliveryIntent?.cloudUploadEnabled = true
        manifest.deliveryIntent?.automaticPrintEnabled = true
        let sessionID = manifest.id

        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil("cloud upload and print start") {
            let cloud = await executor.snapshot().cloudUploadStarted
            let print = await queue.job(sessionID: sessionID, status: .succeeded, kind: .autoPrint)
            return cloud && print != nil
        }
        #expect(await queue.job(sessionID: manifest.id, status: .running, kind: .cloudUpload) != nil)
        #expect(await executor.snapshot().kinds.contains(.autoPrint))
        await executor.releaseCloudUpload()
    }

    @Test("cloud QR print stays blocked when its required upload job is missing")
    func cloudPrintRequiresAnUploadJob() {
        let now = Date()
        let strip = SessionJob(
            id: "strip",
            sessionID: "session",
            kind: .renderStrip,
            status: .succeeded,
            createdAt: now,
            updatedAt: now,
            lastAttemptAt: now,
            nextAttemptAt: nil,
            attemptCount: 1,
            lastError: nil,
            finalizationTransactionID: "tx"
        )
        var print = SessionJob(
            id: "print",
            sessionID: "session",
            kind: .autoPrint,
            status: .pending,
            createdAt: now,
            updatedAt: now,
            lastAttemptAt: nil,
            nextAttemptAt: nil,
            attemptCount: 0,
            lastError: nil,
            finalizationTransactionID: "tx"
        )
        print.requiresCloudPublicationBeforePrint = true

        #expect(!SessionJobDependencyPolicy.prerequisitesSatisfied(
            for: print,
            in: [strip, print]
        ))
    }

    @Test("runs required jobs in priority order and one at a time")
    @MainActor
    func runsRequiredJobsInOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = TestJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )

        queue.start()
        try await queue.enqueueFinalizationJobs(for: makeManifest(withGIFFrames: true))
        try await waitUntil { await executor.snapshot().kinds.count == 4 }

        let snapshot = await executor.snapshot()
        #expect(snapshot.kinds == [.renderStrip, .registerDownload, .updateGallery, .renderGIF])
        #expect(snapshot.maximumConcurrentExecutions == 1)
    }

    @Test("older required print is not starved by newer strip arrivals")
    @MainActor
    func requiredPrintIsNotStarved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json"))
        let executor = TestJobExecutor()

        let oldStrip = try await store.enqueue(sessionID: "old-session", kind: .renderStrip)
        var completedStrip = oldStrip
        completedStrip.status = .succeeded
        completedStrip.updatedAt = Date()
        try await store.update(completedStrip)
        _ = try await store.enqueue(sessionID: "old-session", kind: .autoPrint)
        for index in 0..<8 {
            _ = try await store.enqueue(sessionID: "new-session-\(index)", kind: .renderStrip)
        }

        let queue = SessionJobQueue(store: store, executor: executor)
        queue.start()
        try await waitUntil("old print") {
            await queue.job(sessionID: "old-session", status: .succeeded, kind: .autoPrint) != nil
        }

        #expect(await executor.snapshot().kinds.contains(.autoPrint))
    }

    @Test("a blocked automatic print does not block another session's finalization")
    @MainActor
    func blockedPrintDoesNotBlockFinalization() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingPrintJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let first = makeManifest()
        let second = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: first)
        try await waitUntil("first finalization") {
            await queue.job(sessionID: first.id, status: .succeeded, kind: .updateGallery) != nil
        }
        try await queue.enqueueAutoPrint(for: first)
        try await waitUntil("first print start") { await executor.snapshot().printStarted }

        try await queue.enqueueFinalizationJobs(for: second)
        try await waitUntil("second finalization") {
            await queue.job(sessionID: second.id, status: .succeeded, kind: .updateGallery) != nil
        }

        #expect(await executor.snapshot().printCompleted == false)
        await executor.releaseFirstPrint()
        try await waitUntil("first print completion") {
            await queue.job(sessionID: first.id, status: .succeeded, kind: .autoPrint) != nil
        }
    }

    @Test("automatic print jobs execute serially")
    @MainActor
    func automaticPrintsAreSerialized() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingPrintJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let first = makeManifest()
        let second = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: first)
        try await queue.enqueueFinalizationJobs(for: second)
        try await waitUntil("both strips") {
            let firstReady = await queue.job(sessionID: first.id, status: .succeeded, kind: .renderStrip) != nil
            let secondReady = await queue.job(sessionID: second.id, status: .succeeded, kind: .renderStrip) != nil
            return firstReady && secondReady
        }
        try await queue.enqueueAutoPrint(for: first)
        try await queue.enqueueAutoPrint(for: second)

        try await waitUntil("first print start") { await executor.snapshot().printStarted }
        #expect(await executor.snapshot().printStartCount == 1)
        await executor.releaseFirstPrint()
        try await waitUntil("second print start") { await executor.snapshot().printStartCount == 2 }
        try await waitUntil("both prints") {
            let firstReady = await queue.job(sessionID: first.id, status: .succeeded, kind: .autoPrint) != nil
            let secondReady = await queue.job(sessionID: second.id, status: .succeeded, kind: .autoPrint) != nil
            return firstReady && secondReady
        }

        #expect(await executor.snapshot().maximumConcurrentPrintExecutions == 1)
    }

    @Test("a failed print does not poison the next print job")
    @MainActor
    func failedPrintDoesNotPoisonNextJob() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = FailingPrintJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let first = makeManifest()
        let second = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: first)
        try await queue.enqueueFinalizationJobs(for: second)
        try await waitUntil("both strips") {
            let firstReady = await queue.job(sessionID: first.id, status: .succeeded, kind: .renderStrip) != nil
            let secondReady = await queue.job(sessionID: second.id, status: .succeeded, kind: .renderStrip) != nil
            return firstReady && secondReady
        }
        try await queue.enqueueAutoPrint(for: first)
        try await queue.enqueueAutoPrint(for: second)

        try await waitUntil("failed first print") {
            await queue.job(sessionID: first.id, status: .failed, kind: .autoPrint) != nil
        }
        try await waitUntil("successful second print") {
            await queue.job(sessionID: second.id, status: .succeeded, kind: .autoPrint) != nil
        }
        #expect(await executor.snapshot().printStartCount == 2)
    }

    @Test("session cancellation preserves an in-flight print and releases its lane after completion")
    @MainActor
    func cancellingInFlightPrintPreservesOutcomeAndReleasesLane() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingPrintJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let first = makeManifest()
        let second = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: first)
        try await queue.enqueueFinalizationJobs(for: second)
        try await waitUntil("both strips") {
            let firstReady = await queue.job(sessionID: first.id, status: .succeeded, kind: .renderStrip) != nil
            let secondReady = await queue.job(sessionID: second.id, status: .succeeded, kind: .renderStrip) != nil
            return firstReady && secondReady
        }
        try await queue.enqueueAutoPrint(for: first)
        try await queue.enqueueAutoPrint(for: second)
        try await waitUntil("first print start") { await executor.snapshot().printStartCount == 1 }
        #expect(try await queue.cancelAndQuiesceJobs(sessionID: first.id) == .cleanupPending)
        #expect(await queue.job(sessionID: first.id, status: .running, kind: .autoPrint) != nil)
        #expect(await executor.snapshot().printStartCount == 1)

        await executor.releaseFirstPrint()
        try await waitUntil("first physical print outcome") {
            await queue.job(sessionID: first.id, status: .succeeded, kind: .autoPrint) != nil
        }
        try await waitUntil("second print after first outcome") {
            await queue.job(sessionID: second.id, status: .succeeded, kind: .autoPrint) != nil
        }
        let snapshot = await executor.snapshot()
        #expect(snapshot.printStartCount == 2)
        #expect(snapshot.maximumConcurrentPrintExecutions == 1)
    }

    @Test("a non-cooperative print keeps cleanup pending until it quiesces")
    @MainActor
    func nonCooperativePrintReturnsCleanupPending() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingPrintJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let manifest = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil("print prerequisites") {
            await queue.job(sessionID: manifest.id, status: .succeeded, kind: .renderStrip) != nil
        }
        try await queue.enqueueAutoPrint(for: manifest)
        try await waitUntil("print start") { await executor.snapshot().printStarted }

        let result = try await queue.cancelAndQuiesceJobs(sessionID: manifest.id)
        #expect(result == .cleanupPending)
        #expect(await queue.job(sessionID: manifest.id, status: .running, kind: .autoPrint) != nil)

        await executor.releaseFirstPrint()
        try await waitUntil("physical print outcome") {
            await queue.job(sessionID: manifest.id, status: .succeeded, kind: .autoPrint) != nil
        }
        #expect(try await queue.cancelAndQuiesceJobs(sessionID: manifest.id) == .quiesced)
    }

    @Test("quiescence wait resumes after the executor result is persisted")
    @MainActor
    func quiescenceWaitIncludesDurableJobCompletion() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = BlockingCloudJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let manifest = makeManifest()
        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await queue.enqueueCloudUpload(for: manifest)
        try await waitUntil("cloud upload start") { await executor.snapshot().cloudUploadStarted }

        let waitTask = Task { @MainActor in
            await queue.waitUntilQuiescent(sessionID: manifest.id)
        }
        await Task.yield()
        await executor.releaseCloudUpload()

        #expect(await waitTask.value)
        #expect(await queue.job(sessionID: manifest.id, status: .succeeded, kind: .cloudUpload) != nil)
    }

    @Test("retryable waiting jobs retain their automatic retry schedule")
    @MainActor
    func retriesRetryableErrors() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = TestJobExecutor()
        await executor.fail(.renderStrip, with: .retryable("temporary"))
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )

        queue.start()
        try await queue.enqueueFinalizationJobs(for: makeManifest())
        try await waitUntil {
            await queue.job(status: .waitingRetry, kind: .renderStrip) != nil
        }

        guard let job = await queue.job(status: .waitingRetry, kind: .renderStrip) else {
            Issue.record("Expected render-strip retry state")
            return
        }
        #expect(job.lastFailureDisposition == .retryable)
        await #expect(throws: JobQueueStoreError.manualRetryRejected(job.id, .notFailed)) {
            try await queue.retry(jobID: job.id)
        }
        #expect(await queue.job(status: .waitingRetry, kind: .renderStrip)?.id == job.id)
    }

    @Test("permanent optional failure does not block required completion")
    @MainActor
    func optionalFailureDoesNotBlockRequiredJobs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = TestJobExecutor()
        await executor.fail(.renderGIF, with: .permanent("bad frame"))
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )

        queue.start()
        try await queue.enqueueFinalizationJobs(for: makeManifest(withGIFFrames: true))
        try await waitUntil { await executor.snapshot().kinds.count == 4 }
        try await waitUntil {
            await queue.job(status: .failed, kind: .renderGIF) != nil
        }

        #expect(await queue.job(status: .succeeded, kind: .renderStrip) != nil)
        #expect(await queue.job(status: .succeeded, kind: .registerDownload) != nil)
        #expect(await queue.job(status: .failed, kind: .renderGIF) != nil)
        #expect((await queue.job(status: .failed, kind: .renderGIF))?.lastFailureDisposition == .permanent)
    }

    @Test("permanent gallery failure does not block the customer deliverable")
    @MainActor
    func galleryFailureDoesNotBlockRequiredJobs() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = TestJobExecutor()
        await executor.fail(.updateGallery, with: .permanent("gallery unavailable"))
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )

        queue.start()
        try await queue.enqueueFinalizationJobs(for: makeManifest())
        try await waitUntil {
            await queue.job(status: .succeeded, kind: .registerDownload) != nil
        }
        try await waitUntil {
            await queue.job(status: .failed, kind: .updateGallery) != nil
        }

        #expect(await queue.job(status: .succeeded, kind: .renderStrip) != nil)
        #expect(await queue.job(status: .succeeded, kind: .registerDownload) != nil)
        #expect((await queue.job(status: .failed, kind: .updateGallery))?.lastFailureDisposition == .permanent)
    }

    @Test("manual cloud requeue reports the store result")
    @MainActor
    func reportsCloudRequeueResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json"))
        var job = try await store.enqueue(sessionID: "session", kind: .cloudUpload)
        job.status = .failed
        try await store.update(job)
        let queue = SessionJobQueue(store: store, executor: TestJobExecutor())
        queue.start()

        #expect(try await queue.forceRequeueCloudUpload(sessionID: "session") == .queued)
    }

    @Test("cancelling a running cloud job cancels execution and leaves the job cancelled")
    @MainActor
    func cancellingRunningCloudJobStopsExecution() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = CancellableCloudJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let manifest = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil { await queue.job(sessionID: manifest.id, status: .succeeded, kind: .registerDownload) != nil }
        try await queue.enqueueCloudUpload(for: manifest)
        try await waitUntil { await executor.snapshot().started }

        guard let job = await queue.job(sessionID: manifest.id, status: .running, kind: .cloudUpload) else {
            Issue.record("Expected cloud upload to be running")
            return
        }
        queue.cancel(jobID: job.id)

        try await waitUntil { await queue.job(sessionID: manifest.id, status: .cancelled, kind: .cloudUpload) != nil }
        let snapshot = await executor.snapshot()
        #expect(snapshot.cancelled)
        #expect(await queue.job(sessionID: manifest.id, status: .waitingRetry, kind: .cloudUpload) == nil)
        #expect(await queue.job(sessionID: manifest.id, status: .failed, kind: .cloudUpload) == nil)
    }

    @Test("cloud worker executes another job after a cancelled upload")
    @MainActor
    func cloudWorkerContinuesAfterCancellation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executor = CancellableCloudJobExecutor()
        let queue = SessionJobQueue(
            store: JobQueueStore(fileURL: directory.appendingPathComponent("jobs.json")),
            executor: executor
        )
        let first = makeManifest()
        let second = makeManifest()

        queue.start()
        try await queue.enqueueFinalizationJobs(for: first)
        try await waitUntil { await queue.job(sessionID: first.id, status: .succeeded, kind: .registerDownload) != nil }
        try await queue.enqueueCloudUpload(for: first)
        try await waitUntil { await executor.snapshot().started }
        guard let firstJob = await queue.job(sessionID: first.id, status: .running, kind: .cloudUpload) else {
            Issue.record("Expected first cloud upload to be running")
            return
        }
        queue.cancel(jobID: firstJob.id)
        try await waitUntil { await queue.job(sessionID: first.id, status: .cancelled, kind: .cloudUpload) != nil }

        try await queue.enqueueFinalizationJobs(for: second)
        try await waitUntil("second register-download") { await queue.job(sessionID: second.id, status: .succeeded, kind: .registerDownload) != nil }
        try await queue.enqueueCloudUpload(for: second)
        try await waitUntil("second cloud-upload") { await queue.job(sessionID: second.id, status: .succeeded, kind: .cloudUpload) != nil }

        let snapshot = await executor.snapshot()
        #expect(snapshot.cancelled)
        #expect(snapshot.completed)
    }

    @Test("retryPersistenceRecovery starts workers even after startup failure set isRunning to false")
    @MainActor
    func testRecoveryStartsWorkersAfterStartupFailure() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jobsURL = directory.appendingPathComponent("jobs.json")
        // Write corrupt JSON to force startup failure
        try Data("corrupt".utf8).write(to: jobsURL)

        let executor = TestJobExecutor()
        let store = JobQueueStore(fileURL: jobsURL)
        let queue = SessionJobQueue(store: store, executor: executor)

        queue.start()
        // Wait until startup failure occurs
        try await waitUntil { await queue.lastQueueError != nil }
        #expect(queue.isRunning == false)

        // Now fix the store by removing corrupt file
        try FileManager.default.removeItem(at: jobsURL)
        let manifest = makeManifest()

        // Call retryPersistenceRecovery
        let recovered = await queue.retryPersistenceRecovery()
        #expect(recovered == true)
        #expect(queue.lastQueueError == nil)
        #expect(queue.isRunning == true)

        // Verify workers can actually process jobs now
        try await queue.enqueueFinalizationJobs(for: manifest)
        try await waitUntil { await executor.snapshot().kinds.count == 3 }
        #expect(await executor.snapshot().kinds == [.renderStrip, .registerDownload, .updateGallery])
    }
}

@MainActor
private final class TestJobExecutor: SessionJobExecuting {
    struct Snapshot: Sendable {
        var kinds: [SessionJobKind] = []
        var maximumConcurrentExecutions = 0
    }

    private var snapshotValue = Snapshot()
    private var activeExecutions = 0
    private var failures: [SessionJobKind: JobExecutionError] = [:]

    func fail(_ kind: SessionJobKind, with error: JobExecutionError) {
        failures[kind] = error
    }

    func execute(_ job: SessionJob) async throws {
        activeExecutions += 1
        snapshotValue.maximumConcurrentExecutions = max(
            snapshotValue.maximumConcurrentExecutions,
            activeExecutions
        )
        snapshotValue.kinds.append(job.kind)
        defer { activeExecutions -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        if let error = failures.removeValue(forKey: job.kind) {
            throw error
        }
    }

    func snapshot() -> Snapshot { snapshotValue }
}

@MainActor
private final class BlockingCloudJobExecutor: SessionJobExecuting {
    struct Snapshot: Sendable {
        var kinds: [SessionJobKind] = []
        var cloudUploadStarted = false
        var cloudUploadCompleted = false
    }

    private let cloudGate = AsyncGate()
    private var snapshotValue = Snapshot()

    func execute(_ job: SessionJob) async throws {
        snapshotValue.kinds.append(job.kind)
        if job.kind == .cloudUpload {
            snapshotValue.cloudUploadStarted = true
            await cloudGate.wait()
            snapshotValue.cloudUploadCompleted = true
        }
    }

    func snapshot() -> Snapshot { snapshotValue }

    func releaseCloudUpload() async {
        await cloudGate.open()
    }
}

@MainActor
private final class CancellableCloudJobExecutor: SessionJobExecuting {
    struct Snapshot: Sendable {
        var started = false
        var cancelled = false
        var completed = false
    }

    private var snapshotValue = Snapshot()

    func execute(_ job: SessionJob) async throws {
        guard job.kind == .cloudUpload else { return }
        let shouldBlock = !snapshotValue.started
        snapshotValue.started = true
        do {
            if shouldBlock {
                try await Task.sleep(for: .seconds(10))
            }
            snapshotValue.completed = true
        } catch {
            snapshotValue.cancelled = Task.isCancelled
            throw error
        }
    }

    func snapshot() -> Snapshot { snapshotValue }
}

@MainActor
private final class BlockingPrintJobExecutor: SessionJobExecuting {
    struct Snapshot: Sendable {
        var printStarted = false
        var printStartCount = 0
        var printCompleted = false
        var maximumConcurrentPrintExecutions = 0
    }

    private let firstPrintGate = AsyncGate()
    private var snapshotValue = Snapshot()
    private var activePrintExecutions = 0

    func execute(_ job: SessionJob) async throws {
        guard job.kind == .autoPrint else { return }
        activePrintExecutions += 1
        snapshotValue.printStarted = true
        snapshotValue.printStartCount += 1
        snapshotValue.maximumConcurrentPrintExecutions = max(
            snapshotValue.maximumConcurrentPrintExecutions,
            activePrintExecutions
        )
        defer { activePrintExecutions -= 1 }
        if snapshotValue.printStartCount == 1 {
            await firstPrintGate.wait()
        }
        try Task.checkCancellation()
        snapshotValue.printCompleted = true
    }

    func snapshot() -> Snapshot { snapshotValue }

    func releaseFirstPrint() async {
        await firstPrintGate.open()
    }
}

@MainActor
private final class FailingPrintJobExecutor: SessionJobExecuting {
    struct Snapshot: Sendable {
        var printStartCount = 0
    }

    private var snapshotValue = Snapshot()
    private var shouldFail = true

    func execute(_ job: SessionJob) async throws {
        guard job.kind == .autoPrint else { return }
        snapshotValue.printStartCount += 1
        if shouldFail {
            shouldFail = false
            throw JobExecutionError.permanent("Printer offline")
        }
    }

    func snapshot() -> Snapshot { snapshotValue }
}

@MainActor
private final class FailFirstCloudUploadJobExecutor: SessionJobExecuting {
    struct Snapshot: Sendable {
        var cloudAttempts = 0
        var printAttempts = 0
    }

    private var snapshotValue = Snapshot()

    func execute(_ job: SessionJob) async throws {
        switch job.kind {
        case .cloudUpload:
            snapshotValue.cloudAttempts += 1
            if snapshotValue.cloudAttempts == 1 {
                throw JobExecutionError.permanent("Cloud route verification failed")
            }
        case .autoPrint:
            snapshotValue.printAttempts += 1
        default:
            break
        }
    }

    func snapshot() -> Snapshot { snapshotValue }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let continuations = waiters
        waiters.removeAll()
        continuations.forEach { $0.resume() }
    }
}


private extension SessionJobQueue {
    func job(status: SessionJobStatus, kind: SessionJobKind) async -> SessionJob? {
        jobs.first { $0.status == status && $0.kind == kind }
    }

    func job(sessionID: String, status: SessionJobStatus, kind: SessionJobKind) async -> SessionJob? {
        jobs.first { $0.sessionID == sessionID && $0.status == status && $0.kind == kind }
    }
}

private func makeManifest(withGIFFrames: Bool = false) -> SessionManifest {
    let config = EventConfig(eventID: "event", eventName: "Event", photoCount: 1, slots: [])
    var manifest = SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: UUID().uuidString,
        eventID: config.eventID,
        eventName: config.eventName,
        eventConfig: config,
        startedAt: Date(),
        completedAt: nil,
        cancelledAt: nil,
        status: .finalizing,
        nextPhotoIndex: config.photoCount,
        outputRootPath: "/tmp",
        relativeDirectoryPath: "Event/session",
        absoluteDirectoryPath: "/tmp/Event/session",
        frameSnapshotFileName: nil,
        stripFileName: nil,
        gifFileName: nil,
        downloadToken: UUID().uuidString,
        shots: [RuntimeShotRecord(
            photoIndex: 0,
            imageFileName: "shot_0.jpg",
            gifFrameFileNames: withGIFFrames ? ["frame_000.jpg"] : [],
            retakeCount: 0,
            acceptedAt: Date()
        )],
        lastError: nil,
        updatedAt: Date()
    )
    manifest.finalizationTransactionID = UUID().uuidString
    manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
        cloudUploadEnabled: false,
        automaticPrintEnabled: false,
        updateGalleryEnabled: true,
        renderGIFEnabled: withGIFFrames
    )
    return manifest
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    try await waitUntil("condition", condition)
}

private func waitUntil(
    _ label: String,
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw TimeoutError(label: label)
}

private struct TimeoutError: Error, CustomStringConvertible {
    let label: String
    var description: String { "Timed out waiting for \(label)" }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Queue-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
