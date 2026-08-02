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
        try await store.update(failed)
        try await store.retry(jobID: failed.id)

        let retried = await store.snapshot().first { $0.id == failed.id }
        #expect(retried?.status == .pending)
        #expect(retried?.attemptCount == 0)
        #expect(retried?.lastError == nil)
        #expect(retried?.nextAttemptAt != nil)
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
