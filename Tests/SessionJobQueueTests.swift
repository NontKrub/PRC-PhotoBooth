import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("SessionJobQueue")
struct SessionJobQueueTests {
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
        queue.enqueueFinalizationJobs(for: makeManifest(withGIFFrames: true))
        try await waitUntil { await executor.snapshot().kinds.count == 3 }

        let snapshot = await executor.snapshot()
        #expect(snapshot.kinds == [.renderStrip, .registerDownload, .renderGIF])
        #expect(snapshot.maximumConcurrentExecutions == 1)
    }

    @Test("retryable errors wait for retry and manual retry resets the job")
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
        queue.enqueueFinalizationJobs(for: makeManifest())
        try await waitUntil {
            await queue.job(status: .waitingRetry, kind: .renderStrip) != nil
        }

        guard let job = await queue.job(status: .waitingRetry, kind: .renderStrip) else {
            Issue.record("Expected render-strip retry state")
            return
        }
        queue.retry(jobID: job.id)
        try await waitUntil { await executor.snapshot().kinds.count >= 2 }
        #expect(await queue.job(status: .succeeded, kind: .renderStrip) != nil)
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
        queue.enqueueFinalizationJobs(for: makeManifest(withGIFFrames: true))
        try await waitUntil { await executor.snapshot().kinds.count == 3 }
        try await waitUntil {
            await queue.job(status: .failed, kind: .renderGIF) != nil
        }

        #expect(await queue.job(status: .succeeded, kind: .renderStrip) != nil)
        #expect(await queue.job(status: .succeeded, kind: .registerDownload) != nil)
        #expect(await queue.job(status: .failed, kind: .renderGIF) != nil)
    }
}

private actor TestJobExecutor: SessionJobExecuting {
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

private extension SessionJobQueue {
    func job(status: SessionJobStatus, kind: SessionJobKind) async -> SessionJob? {
        jobs.first { $0.status == status && $0.kind == kind }
    }
}

private func makeManifest(withGIFFrames: Bool = false) -> SessionManifest {
    let config = EventConfig(eventID: "event", eventName: "Event", photoCount: 1, slots: [])
    return SessionManifest(
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
}

private func waitUntil(
    _ condition: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw TimeoutError()
}

private struct TimeoutError: Error {}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Queue-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
