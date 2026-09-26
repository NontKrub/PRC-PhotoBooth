import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("JobQueueStore")
struct JobQueueStoreTests {
    @Test("enqueue is idempotent by session, transaction, and job kind")
    func enqueueIsIdempotent() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)

        let first = try await store.enqueue(sessionID: "session", kind: .renderStrip)
        let second = try await store.enqueue(sessionID: "session", kind: .renderStrip)
        let otherKind = try await store.enqueue(sessionID: "session", kind: .renderGIF)
        let otherSession = try await store.enqueue(sessionID: "other", kind: .renderStrip)
        let transactionA = try await store.enqueue(
            sessionID: "transactional",
            kind: .renderStrip,
            finalizationTransactionID: "tx-a"
        )
        let transactionB = try await store.enqueue(
            sessionID: "transactional",
            kind: .renderStrip,
            finalizationTransactionID: "tx-b"
        )
        let transactionARetry = try await store.enqueue(
            sessionID: "transactional",
            kind: .renderStrip,
            finalizationTransactionID: "tx-a"
        )

        #expect(first == second)
        #expect(first.id != otherKind.id)
        #expect(first.id != otherSession.id)
        #expect(transactionA == transactionARetry)
        #expect(transactionA.id != transactionB.id)
        #expect((await store.snapshot()).count == 5)
    }

    @Test("jobs in different transactions survive duplicate recovery")
    func preservesJobsAcrossTransactions() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        let first = try await store.enqueue(
            sessionID: "session",
            kind: .renderStrip,
            finalizationTransactionID: "tx-a"
        )
        let second = try await store.enqueue(
            sessionID: "session",
            kind: .renderStrip,
            finalizationTransactionID: "tx-b"
        )

        let recovered = try await JobQueueStore(fileURL: file).load()
        #expect(recovered.first { $0.id == first.id }?.status == .pending)
        #expect(recovered.first { $0.id == second.id }?.status == .pending)
    }

    @Test("running jobs reset to pending after reload")
    func resetsRunningJobs() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var job = try await store.enqueue(sessionID: "session", kind: .cloudUpload)
        job.status = .running
        job.attemptCount = 3
        job.lastAttemptAt = Date(timeIntervalSince1970: 1)
        try await store.update(job)

        let reloaded = JobQueueStore(fileURL: file)
        let jobs = try await reloaded.load()
        #expect(jobs[0].status == .pending)
        #expect(jobs[0].lastAttemptAt == nil)
        #expect(jobs[0].attemptCount == 3)
        #expect(jobs[0].nextAttemptAt != nil)
    }

    @Test("interrupted auto print is failed with unknown side effect after reload")
    func quarantinesInterruptedAutoPrint() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var job = try await store.enqueue(sessionID: "print-session", kind: .autoPrint)
        job.status = .running
        job.attemptCount = 1
        job.lastAttemptAt = Date()
        try await store.update(job)

        let recovered = try await JobQueueStore(fileURL: file).load()
        let interrupted = try #require(recovered.first { $0.id == job.id })
        #expect(interrupted.status == .failed)
        #expect(interrupted.lastFailureDisposition == .sideEffectUnknown)
        #expect(interrupted.nextAttemptAt == nil)
    }

    @Test("manual retry resets an eligible failed job")
    func retriesJobs() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var failed = try await store.enqueue(sessionID: "failed", kind: .autoPrint)
        failed.status = .failed
        failed.attemptCount = 4
        failed.lastError = "printer offline"
        failed.lastFailureDisposition = .retryable
        try await store.update(failed)
        try await store.retry(jobID: failed.id)

        let retried = await store.snapshot().first { $0.id == failed.id }
        #expect(retried?.status == .pending)
        #expect(retried?.attemptCount == 0)
        #expect(retried?.lastError == nil)
        #expect(retried?.lastFailureDisposition == nil)
        #expect(retried?.nextAttemptAt != nil)
    }

    @Test("manual retry eligibility is shared and excludes non-retryable states")
    func manualRetryEligibility() {
        let now = Date()
        let retryable = SessionJob(
            id: "retryable",
            sessionID: "retryable-session",
            kind: .renderStrip,
            status: .failed,
            createdAt: now,
            updatedAt: now,
            lastAttemptAt: now,
            nextAttemptAt: nil,
            attemptCount: 1,
            lastError: "temporary failure",
            lastFailureDisposition: .retryable
        )
        #expect(ManualJobRetryEligibility.evaluate(retryable) == .eligible)
        #expect(ManualJobRetryEligibility.evaluate(retryable, sessionIsCancelled: true) == .sessionCancelled)
        #expect(ManualJobRetryEligibility.evaluate(retryable, manifestIsCancelled: true) == .sessionCancelled)

        var permanent = retryable
        permanent.lastFailureDisposition = .permanent
        #expect(ManualJobRetryEligibility.evaluate(permanent) == .permanent)
        var unknown = retryable
        unknown.lastFailureDisposition = .sideEffectUnknown
        #expect(ManualJobRetryEligibility.evaluate(unknown) == .sideEffectUnknown)
        var cancelled = retryable
        cancelled.status = .cancelled
        #expect(ManualJobRetryEligibility.evaluate(cancelled) == .cancelled)
        var waiting = retryable
        waiting.status = .waitingRetry
        #expect(ManualJobRetryEligibility.evaluate(waiting) == .notFailed)
    }

    @Test("force requeue resets every recoverable cloud upload state")
    func forceRequeuesCloudUploads() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)

        for (sessionID, status) in [
            ("failed", SessionJobStatus.failed),
            ("cancelled", SessionJobStatus.cancelled),
            ("succeeded", SessionJobStatus.succeeded)
        ] {
            var job = try await store.enqueue(sessionID: sessionID, kind: .cloudUpload)
            job.status = status
            job.attemptCount = 4
            job.lastError = "old error"
            try await store.update(job)

            #expect(try await store.forceRequeueCloudUpload(sessionID: sessionID) == .queued)
            let queued = await store.snapshot().first { $0.sessionID == sessionID }
            #expect(queued?.status == .pending)
            #expect(queued?.attemptCount == 0)
            #expect(queued?.lastError == nil)
            #expect(queued?.lastFailureDisposition == nil)
            #expect(queued?.nextAttemptAt != nil)
        }
    }

    @Test("force requeue never creates a duplicate or overlaps an upload")
    func forceRequeueDoesNotDuplicate() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        let job = try await store.enqueue(sessionID: "session", kind: .cloudUpload)

        #expect(try await store.forceRequeueCloudUpload(sessionID: "session") == .alreadyQueued)
        var running = job
        running.status = .running
        try await store.update(running)
        #expect(try await store.forceRequeueCloudUpload(sessionID: "session") == .alreadyRunning)
        #expect((await store.snapshot().filter { $0.kind == .cloudUpload }).count == 1)
        #expect(try await store.forceRequeueCloudUpload(sessionID: "missing") == .notFound)
    }

    @Test("force requeue survives store recreation")
    func forceRequeuePersists() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var job = try await store.enqueue(sessionID: "session", kind: .cloudUpload)
        job.status = .succeeded
        try await store.update(job)

        #expect(try await store.forceRequeueCloudUpload(sessionID: "session") == .queued)
        let reloaded = JobQueueStore(fileURL: file)
        let loaded = try await reloaded.load()
        #expect(loaded[0].status == .pending)
        #expect(loaded[0].attemptCount == 0)
    }

    @Test("automatic cloud recovery requeues failed uploads only")
    func requeuesFailedCloudUploadsOnly() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var failed = try await store.enqueue(sessionID: "failed", kind: .cloudUpload)
        failed.status = .failed
        failed.attemptCount = 4
        failed.lastError = "offline"
        failed.lastFailureDisposition = .retryable
        try await store.update(failed)
        var permanent = try await store.enqueue(sessionID: "permanent", kind: .cloudUpload)
        permanent.status = .failed
        permanent.lastError = "strip missing"
        permanent.lastFailureDisposition = .permanent
        try await store.update(permanent)
        var legacy = try await store.enqueue(sessionID: "legacy", kind: .cloudUpload)
        legacy.status = .failed
        legacy.lastError = "old queue error"
        try await store.update(legacy)
        var succeeded = try await store.enqueue(sessionID: "succeeded", kind: .cloudUpload)
        succeeded.status = .succeeded
        try await store.update(succeeded)
        var cancelled = try await store.enqueue(sessionID: "cancelled", kind: .cloudUpload)
        cancelled.status = .cancelled
        try await store.update(cancelled)
        var outside = try await store.enqueue(sessionID: "outside", kind: .cloudUpload)
        outside.status = .failed
        outside.lastFailureDisposition = .retryable
        try await store.update(outside)

        #expect(try await store.requeueFailedCloudUploads(sessionIDs: [
            "failed", "permanent", "legacy", "succeeded", "cancelled"
        ]) == 1)
        let jobs = await store.snapshot()
        #expect(jobs.first { $0.sessionID == "failed" }?.status == .pending)
        #expect(jobs.first { $0.sessionID == "failed" }?.attemptCount == 0)
        #expect(jobs.first { $0.sessionID == "permanent" }?.status == .failed)
        #expect(jobs.first { $0.sessionID == "legacy" }?.status == .failed)
        #expect(jobs.first { $0.sessionID == "succeeded" }?.status == .succeeded)
        #expect(jobs.first { $0.sessionID == "cancelled" }?.status == .cancelled)
        #expect(jobs.first { $0.sessionID == "outside" }?.status == .failed)
    }

    @Test("corrupt queue is preserved and remains fail-closed")
    func preservesCorruptQueue() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("corrupt".utf8).write(to: file)
        let store = JobQueueStore(fileURL: file)

        do {
            _ = try await store.load()
            Issue.record("Corrupt queue load unexpectedly succeeded.")
        } catch is JobQueueStoreError {
            // Expected: corrupt queue must remain visible to Operations.
        } catch {
            Issue.record("Unexpected queue error: \(error)")
        }
        let files = try FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent.hasPrefix("jobs-corrupt-") })
        do {
            _ = try await store.load()
            Issue.record("Failed queue became loadable after the first error.")
        } catch is JobQueueStoreError {
            // Expected: the in-memory store remains failed closed.
        }
        let reloaded = JobQueueStore(fileURL: file)
        do {
            _ = try await reloaded.load()
            Issue.record("Corrupt queue became loadable after store recreation.")
        } catch is JobQueueStoreError {
            // Expected: the corrupt source file is still present.
        }
    }

    @Test("cancelled jobs do not run and optional cancellation is scoped")
    func cancellation() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        let required = try await store.enqueue(sessionID: "session", kind: .renderStrip)
        let optional = try await store.enqueue(sessionID: "session", kind: .cloudUpload)
        try await store.cancel(jobID: required.id)
        try await store.cancelOptionalJobs(sessionID: "session")

        let jobs = await store.snapshot()
        #expect(jobs.first { $0.id == required.id }?.status == .cancelled)
        #expect(jobs.first { $0.id == optional.id }?.status == .cancelled)
    }

    @Test("durable cancellation blocks delayed enqueue after store recreation")
    func cancellationBarrierSurvivesReload() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)

        try await store.cancelJobs(sessionID: "cancelled")
        do {
            _ = try await store.enqueue(sessionID: "cancelled", kind: .renderStrip)
            Issue.record("Cancelled session accepted an enqueue")
        } catch let error as JobQueueStoreError {
            #expect(error == .sessionCancelled("cancelled"))
        }

        let reloaded = JobQueueStore(fileURL: file)
        _ = try await reloaded.load()
        do {
            _ = try await reloaded.enqueue(sessionID: "cancelled", kind: .cloudUpload)
            Issue.record("Reloaded cancellation barrier accepted an enqueue")
        } catch let error as JobQueueStoreError {
            #expect(error == .sessionCancelled("cancelled"))
        }
    }

    @Test("batch enqueue rolls back all jobs on persistence failure")
    func batchEnqueueRollsBackOnPersistenceFailure() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        _ = try await store.load()
        await store.failNextPersistenceForTesting()

        do {
            _ = try await store.enqueueBatch(
                sessionID: "batch",
                kinds: [.renderStrip, .registerDownload, .updateGallery]
            )
            Issue.record("Batch enqueue unexpectedly succeeded")
        } catch let error as JobQueueStoreError {
            guard case .persistenceFailed = error else {
                Issue.record("Unexpected batch failure: \(error)")
                return
            }
        }
        #expect(await store.snapshot().isEmpty)
    }

    @Test("corrupt cancellation barrier fails closed on every mutation")
    func corruptCancellationBarrierFailsClosed() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let barrier = file.deletingPathExtension().appendingPathExtension("cancelled-sessions.json")
        try Data("not-json".utf8).write(to: barrier)
        let store = JobQueueStore(fileURL: file)

        for operation in 0..<4 {
            do {
                switch operation {
                case 0:
                    _ = try await store.enqueue(sessionID: "blocked", kind: .renderStrip)
                case 1:
                    _ = try await store.claim(jobID: "missing")
                case 2:
                    try await store.retry(jobID: "missing")
                default:
                    _ = try await store.forceRequeueCloudUpload(sessionID: "blocked")
                }
                Issue.record("Corrupt cancellation barrier failed open")
            } catch is JobQueueStoreError {
                // Every operation must continue rejecting the failed load.
            }
        }
    }

    @Test("valid queue stays unavailable when recovery normalization cannot persist")
    func recoveryPersistenceFailureCanBeRetried() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let seed = JobQueueStore(fileURL: file)
        var running = try await seed.enqueue(sessionID: "session", kind: .cloudUpload)
        running.status = .running
        try await seed.update(running)

        let reloaded = JobQueueStore(fileURL: file)
        await reloaded.failNextPersistenceForTesting()
        do {
            _ = try await reloaded.load()
            Issue.record("Recovery unexpectedly succeeded after the injected write failure")
        } catch let error as JobQueueStoreError {
            guard case .persistenceFailed = error else {
                Issue.record("Unexpected recovery error: \(error)")
                return
            }
        }
        #expect(await reloaded.durabilityState() == .persistenceUnavailable)

        let recovered = try await reloaded.recoverDurableState()
        #expect(recovered.first?.status == .pending)
        #expect(await reloaded.durabilityState() == .loaded)
    }

    @Test("recovery deterministically reconciles duplicate jobs")
    func reconcilesDuplicateJobs() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let jobs = [
            storedJob(id: "pending", status: .pending, createdAt: now),
            storedJob(
                id: "unknown",
                status: .failed,
                createdAt: now.addingTimeInterval(10),
                lastError: "unknown",
                disposition: .sideEffectUnknown
            ),
            storedJob(id: "succeeded", status: .succeeded, createdAt: now.addingTimeInterval(20))
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(jobs).write(to: file)

        let recovered = try await JobQueueStore(fileURL: file).load()
        #expect(recovered.first { $0.id == "succeeded" }?.status == .succeeded)
        #expect(recovered.first { $0.id == "unknown" }?.status == .cancelled)
        #expect(recovered.first { $0.id == "pending" }?.status == .cancelled)
    }

    @Test("safe cancellation-barrier compaction allows future sessions")
    func compactsCancellationBarrierAfterJobDeletion() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        try await store.cancelJobs(sessionID: "cancelled")
        try await store.deleteJobs(sessionID: "cancelled")
        try await store.forgetCancellationBarrierIfSafe(sessionID: "cancelled")

        let reloaded = JobQueueStore(fileURL: file)
        _ = try await reloaded.load()
        _ = try await reloaded.enqueue(sessionID: "cancelled", kind: .renderStrip)
        #expect(await reloaded.snapshot().count == 1)
    }

    @Test("unknown print resolution does not spend a retry")
    func resolvesUnknownPrintWithoutRetryCost() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var job = try await store.enqueue(sessionID: "print", kind: .autoPrint)
        job.status = .failed
        job.attemptCount = 1
        job.lastFailureDisposition = .sideEffectUnknown
        try await store.update(job)

        let retried = try await store.resolveUnknownPrint(jobID: job.id, resolution: .notPrinted)
        #expect(retried.status == .pending)
        #expect(retried.attemptCount == 0)

        _ = try await store.claim(jobID: job.id)
        var unknown = try #require(await store.snapshot().first { $0.id == job.id })
        unknown.status = .failed
        unknown.lastFailureDisposition = .sideEffectUnknown
        try await store.update(unknown)
        let printed = try await store.resolveUnknownPrint(jobID: job.id, resolution: .printed)
        #expect(printed.status == .succeeded)
    }

    @Test("old succeeded jobs purge while failed jobs remain")
    func purgesOnlyOldSucceeded() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var succeeded = try await store.enqueue(sessionID: "done", kind: .renderStrip)
        succeeded.status = .succeeded
        succeeded.updatedAt = Date(timeIntervalSince1970: 1)
        try await store.update(succeeded)
        var failed = try await store.enqueue(sessionID: "failed", kind: .renderStrip)
        failed.status = .failed
        failed.updatedAt = Date(timeIntervalSince1970: 1)
        try await store.update(failed)

        try await store.purgeOldSucceededJobs(olderThan: Date(timeIntervalSince1970: 2))
        let jobs = await store.snapshot()
        #expect(!jobs.contains { $0.id == succeeded.id })
        #expect(jobs.contains { $0.id == failed.id })
    }

    @Test("pruning skips succeeded jobs when session has active non-terminal work")
    func testPruneSkipsSessionsWithActiveWork() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)

        var strip = try await store.enqueue(sessionID: "session-active", kind: .renderStrip)
        strip.status = .succeeded
        strip.updatedAt = Date(timeIntervalSince1970: 1)
        try await store.update(strip)

        var cloud = try await store.enqueue(sessionID: "session-active", kind: .cloudUpload)
        cloud.status = .failed
        cloud.updatedAt = Date(timeIntervalSince1970: 1)
        try await store.update(cloud)

        try await store.purgeOldSucceededJobs(olderThan: Date(timeIntervalSince1970: 2))
        let remaining = await store.snapshot()
        // renderStrip must NOT be pruned because cloudUpload is still failed / retryable
        #expect(remaining.contains { $0.id == strip.id })
        #expect(remaining.contains { $0.id == cloud.id })
    }
}

private func temporaryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-Jobs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("jobs.json")
}

private func storedJob(
    id: String,
    status: SessionJobStatus,
    createdAt: Date,
    lastError: String? = nil,
    disposition: SessionJobFailureDisposition? = nil,
    transactionID: String? = nil
) -> SessionJob {
    SessionJob(
        id: id,
        sessionID: "session",
        kind: .autoPrint,
        status: status,
        createdAt: createdAt,
        updatedAt: createdAt,
        lastAttemptAt: nil,
        nextAttemptAt: nil,
        attemptCount: 0,
        lastError: lastError,
        lastFailureDisposition: disposition,
        finalizationTransactionID: transactionID
    )
}
