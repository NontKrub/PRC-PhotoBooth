import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("JobQueueStore")
struct JobQueueStoreTests {
    @Test("enqueue is idempotent by session and job kind")
    func enqueueIsIdempotent() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)

        let first = try await store.enqueue(sessionID: "session", kind: .renderStrip)
        let second = try await store.enqueue(sessionID: "session", kind: .renderStrip)
        let otherKind = try await store.enqueue(sessionID: "session", kind: .renderGIF)
        let otherSession = try await store.enqueue(sessionID: "other", kind: .renderStrip)

        #expect(first == second)
        #expect(first.id != otherKind.id)
        #expect(first.id != otherSession.id)
        #expect((await store.snapshot()).count == 3)
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

    @Test("manual retry resets failed and cancelled jobs")
    func retriesJobs() async throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = JobQueueStore(fileURL: file)
        var failed = try await store.enqueue(sessionID: "failed", kind: .autoPrint)
        failed.status = .failed
        failed.attemptCount = 4
        failed.lastError = "printer offline"
        failed.lastFailureDisposition = .permanent
        try await store.update(failed)
        try await store.retry(jobID: failed.id)

        let retried = await store.snapshot().first { $0.id == failed.id }
        #expect(retried?.status == .pending)
        #expect(retried?.attemptCount == 0)
        #expect(retried?.lastError == nil)
        #expect(retried?.lastFailureDisposition == nil)
        #expect(retried?.nextAttemptAt != nil)
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

        #expect(try await store.requeueFailedCloudUploads() == 1)
        let jobs = await store.snapshot()
        #expect(jobs.first { $0.sessionID == "failed" }?.status == .pending)
        #expect(jobs.first { $0.sessionID == "failed" }?.attemptCount == 0)
        #expect(jobs.first { $0.sessionID == "permanent" }?.status == .failed)
        #expect(jobs.first { $0.sessionID == "legacy" }?.status == .failed)
        #expect(jobs.first { $0.sessionID == "succeeded" }?.status == .succeeded)
        #expect(jobs.first { $0.sessionID == "cancelled" }?.status == .cancelled)
    }

    @Test("corrupt queue is preserved before a new empty queue is created")
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
        #expect(try await store.load().isEmpty)
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
}

private func temporaryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-Jobs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("jobs.json")
}
