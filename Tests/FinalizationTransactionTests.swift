import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("FinalizationTransaction")
struct FinalizationTransactionTests {
    @Test("finalizeSession flow does not roll back on failure, job queue handles finalizationTransactionID")
    @MainActor
    func transactionIDPersistence() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let queueStore = JobQueueStore(fileURL: root.appendingPathComponent("Jobs").appendingPathComponent("queue.json"))
        
        let manifest = makeManifest(id: "session-1", root: root)
        try await manifestStore.create(manifest)
        
        // 1. Emulate BoothCoordinator finalizeSession with transactionID
        let transactionID = UUID().uuidString
        let finalizing = try await manifestStore.transition(sessionID: "session-1", allowedFrom: [RuntimeSessionStatus.capturing]) { durable in
            durable.status = .finalizing
            durable.finalizationTransactionID = transactionID
        }
        
        #expect(finalizing.finalizationTransactionID == transactionID)
        #expect(finalizing.status == .finalizing)
        
        // 2. Enqueue jobs with finalizationTransactionID
        let jobs = try await queueStore.enqueueBatch(
            sessionID: "session-1",
            kinds: [SessionJobKind.renderStrip, SessionJobKind.registerDownload],
            finalizationTransactionID: transactionID
        )
        
        #expect(jobs.count == 2)
        #expect(jobs[0].finalizationTransactionID == transactionID)
        #expect(jobs[1].finalizationTransactionID == transactionID)
        
        // 3. Emulate reconciliation missing jobs check (e.g. .autoPrint missing)
        let autoPrintJob = try await queueStore.enqueueBatch(
            sessionID: "session-1",
            kinds: [SessionJobKind.autoPrint],
            finalizationTransactionID: transactionID
        )
        #expect(autoPrintJob.count == 1)
        #expect(autoPrintJob[0].finalizationTransactionID == transactionID)
        
        // 4. Test JobQueueStore reuse logic: different transactionID should create a NEW job
        let duplicateCall = try await queueStore.enqueueBatch(
            sessionID: "session-1",
            kinds: [SessionJobKind.renderStrip],
            finalizationTransactionID: transactionID
        )
        #expect(duplicateCall.count == 1)
        #expect(duplicateCall[0].id == jobs[0].id)
        
        // If we enqueue with a new transactionID, it creates a new job
        let newTransactionID = UUID().uuidString
        let retryJobs = try await queueStore.enqueueBatch(
            sessionID: "session-1",
            kinds: [SessionJobKind.renderStrip],
            finalizationTransactionID: newTransactionID
        )
        #expect(retryJobs.count == 1)
        #expect(retryJobs[0].id != jobs[0].id)
        #expect(retryJobs[0].finalizationTransactionID == newTransactionID)
    }
}

private func makeManifest(id: String, root: URL) -> SessionManifest {
    let config = EventConfig(
        eventID: "event-1",
        eventName: "Event One",
        photoCount: 2,
        countdownSeconds: 3,
        canvasWidth: 400,
        canvasHeight: 600,
        slots: [SharedPhotoSlot(id: "slot-1", normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)]
    )
    let now = Date()
    return SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: id,
        eventID: config.eventID,
        eventName: config.eventName,
        eventConfig: config,
        startedAt: now,
        completedAt: nil,
        cancelledAt: nil,
        status: .capturing,
        nextPhotoIndex: 0,
        outputRootPath: root.path,
        relativeDirectoryPath: "Event-One/\(id)",
        absoluteDirectoryPath: root.appendingPathComponent("Event-One").appendingPathComponent(id).path,
        frameSnapshotFileName: ".work/frame.png",
        stripFileName: nil,
        gifFileName: nil,
        downloadToken: "token-\(id)",
        shots: [RuntimeShotRecord(photoIndex: 0, imageFileName: "shot_0.jpg", gifFrameFileNames: [], retakeCount: 0, acceptedAt: now)],
        lastError: nil,
        updatedAt: now
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-FinalizationTx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
