import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("FinalizationTransaction")
struct FinalizationTransactionTests {
    @Test("finalization plan reflects the persisted intent and rejects obsolete transactions")
    func finalizationPlanAuthority() throws {
        var manifest = makeManifest(id: "session-plan", root: FileManager.default.temporaryDirectory)
        manifest.status = .finalizing
        manifest.finalizationTransactionID = "tx-current"
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: true,
            updateGalleryEnabled: false,
            renderGIFEnabled: true
        )

        let plan = try #require(FinalizationPlan.make(from: manifest))
        #expect(plan.transactionID == "tx-current")
        #expect(plan.jobKinds == [.renderStrip, .registerDownload, .renderGIF, .cloudUpload, .autoPrint])

        let currentJob = makeJob(sessionID: manifest.id, kind: .renderStrip, transactionID: "tx-current")
        let oldJob = makeJob(sessionID: manifest.id, kind: .renderStrip, transactionID: "tx-old")
        #expect(plan.authorizes(currentJob, for: manifest))
        #expect(!plan.authorizes(oldJob, for: manifest))
        #expect(!plan.authorizes(makeJob(sessionID: "other-session", kind: .renderStrip, transactionID: "tx-current"), for: manifest))
    }

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

    @Test("a failed queue write is recovered by ensuring one complete transaction bundle")
    @MainActor
    func queueWriteFailureRepairsFullBundle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let queueStore = JobQueueStore(fileURL: root.appendingPathComponent("Jobs/queue.json"))
        var manifest = makeManifest(id: "session-fault", root: root)
        manifest.status = .finalizing
        manifest.finalizationTransactionID = "tx-fault"
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: true,
            updateGalleryEnabled: true,
            renderGIFEnabled: false
        )
        try await manifestStore.create(manifest)

        let queue = SessionJobQueue(store: queueStore, executor: NoOpFinalizationExecutor())
        queue.pauseWorkersForRecovery()
        await queueStore.failNextPersistenceForTesting()
        try await queue.enqueueFinalizationJobs(for: manifest)

        let durableManifest = try await manifestStore.load(sessionID: manifest.id)
        let jobs = try await queueStore.load().filter { $0.sessionID == manifest.id }
        let plan = try #require(FinalizationPlan.make(from: durableManifest))
        #expect(durableManifest.status == .finalizing)
        #expect(Set(jobs.map(\.kind)) == Set(plan.jobKinds))
        #expect(jobs.count == plan.jobKinds.count)
        #expect(jobs.allSatisfy { $0.finalizationTransactionID == plan.transactionID })
        #expect(jobs.filter { $0.kind == .autoPrint }.count == 1)
        #expect(jobs.filter { $0.kind == .cloudUpload }.count == 1)
    }

    @Test("mismatched transaction jobs neither satisfy the plan nor its dependencies")
    @MainActor
    func transactionScopedReconciliationAndDependencies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let store = JobQueueStore(fileURL: root.appendingPathComponent("Jobs/queue.json"))
        var manifest = makeManifest(id: "session-old-tx", root: root)
        manifest.status = .finalizing
        manifest.finalizationTransactionID = "tx-b"
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: false,
            automaticPrintEnabled: false,
            updateGalleryEnabled: false,
            renderGIFEnabled: false
        )
        try await manifestStore.create(manifest)

        let oldPrint = try await store.enqueue(
            sessionID: manifest.id,
            kind: .autoPrint,
            finalizationTransactionID: "tx-a"
        )
        var currentStrip = makeJob(sessionID: manifest.id, kind: .renderStrip, transactionID: "tx-b")
        currentStrip.status = .succeeded
        let currentRegister = makeJob(sessionID: manifest.id, kind: .registerDownload, transactionID: "tx-b")

        #expect(SessionJobDependencyPolicy.prerequisitesSatisfied(
            for: currentRegister,
            in: [currentStrip, currentRegister]
        ))
        #expect(!SessionJobDependencyPolicy.prerequisitesSatisfied(
            for: oldPrint,
            in: [oldPrint, currentStrip]
        ))
        #expect(SessionJobReconciliationDecision.evaluate(
            manifest: manifest,
            jobs: [currentStrip, oldPrint]
        ) == .enqueueMissingRequiredJobs)

        let queue = SessionJobQueue(store: store, executor: NoOpFinalizationExecutor())
        queue.pauseWorkersForRecovery()
        try await queue.enqueueFinalizationJobs(for: manifest)
        let allJobs = try await store.load().filter { $0.sessionID == manifest.id }
        #expect(allJobs.contains { $0.finalizationTransactionID == "tx-a" && $0.kind == .autoPrint })
        #expect(allJobs.filter { $0.finalizationTransactionID == "tx-b" && $0.kind == .renderStrip }.count == 1)
        #expect(allJobs.filter { $0.finalizationTransactionID == "tx-b" && $0.kind == .registerDownload }.count == 1)
    }
}

@MainActor
private final class NoOpFinalizationExecutor: SessionJobExecuting {
    func execute(_ job: SessionJob) async throws {}
}

private func makeJob(
    sessionID: String,
    kind: SessionJobKind,
    transactionID: String
) -> SessionJob {
    let now = Date()
    return SessionJob(
        id: UUID().uuidString,
        sessionID: sessionID,
        kind: kind,
        status: .pending,
        createdAt: now,
        updatedAt: now,
        lastAttemptAt: nil,
        nextAttemptAt: nil,
        attemptCount: 0,
        lastError: nil,
        finalizationTransactionID: transactionID
    )
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
