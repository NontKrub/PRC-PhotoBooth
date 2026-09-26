import Testing
import Foundation
import CoreGraphics

@testable import PRC_PhotoBooth_Mac

@Suite("SessionRecoveryService")
struct SessionRecoveryTests {
    @Test("selects newest capturing session and marks older duplicate failed")
    @MainActor
    func selectsNewestCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let queue = makeQueue(root: root)
        let service = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )
        let older = makeManifest(id: "older", status: .capturing, startedAt: Date(timeIntervalSince1970: 10), directory: root)
        let newer = makeManifest(id: "newer", status: .capturing, startedAt: Date(timeIntervalSince1970: 20), directory: root)
        try await manifestStore.create(older)
        try await manifestStore.create(newer)

        service.scanAtStartup()
        try await waitUntil { service.recoverableCaptureSession?.manifest.id == "newer" }

        let repaired = try await manifestStore.load(sessionID: "older")
        #expect(repaired.status == .failed)
        #expect(repaired.lastError == "A newer unfinished capture session exists.")
    }

    @Test("resume loads accepted images and preserves manifest identity")
    @MainActor
    func resumesAcceptedImages() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "session",
            eventName: "Event",
            outputRoot: root,
            startedAt: Date(),
            frameSourceURL: nil
        )
        let saved = try workspace.saveAcceptedCapture(
            image: makeImage(),
            gifFrames: [],
            photoIndex: 0,
            workspace: descriptor
        )
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(makeManifest(
            id: "session",
            status: .capturing,
            startedAt: Date(),
            directory: URL(fileURLWithPath: descriptor.absoluteDirectoryPath),
            shotFileName: saved.imageFileName,
            nextPhotoIndex: 1
        ))
        let service = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: workspace,
            jobQueue: makeQueue(root: root)
        )
        var resumedID = ""
        var resumedImages = 0
        service.onResume = { manifest, images in
            resumedID = manifest.id
            resumedImages = images.count
        }

        service.scanAtStartup()
        try await waitUntil { service.recoverableCaptureSession != nil }
        service.resumeCaptureSession(sessionID: "session")
        try await waitUntil { resumedImages == 1 }

        #expect(resumedID == "session")
        #expect(service.recoverableCaptureSession == nil)
    }

    @Test("finalizing session recreates rendering jobs without operator confirmation")
    @MainActor
    func restoresFinalizingJobs() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let queue = makeQueue(root: root)
        let service = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue
        )
        let manifest = makeManifest(id: "finalizing", status: .finalizing, startedAt: Date(), directory: root)
        try await manifestStore.create(manifest)

        service.scanAtStartup()
        try await waitUntil { service.automaticallyRecoveringSessions.contains("finalizing") }
        try await waitUntil {
            let jobs = await queue.snapshotForTesting()
            return jobs.contains { $0.sessionID == "finalizing" && $0.kind == .renderStrip }
        }
    }

    @Test("legacy finalization migration is stable and quarantines interrupted print")
    @MainActor
    func migratesLegacyFinalizationAndUnknownPrint() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "PRC-Recovery-Legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: "cloudUploadEnabled")
        defaults.set(false, forKey: "selphyAutoPrintAfterSession")

        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        let manifest = makeManifest(
            id: "legacy-session",
            status: .finalizing,
            startedAt: Date(timeIntervalSince1970: 20),
            directory: root
        )
        try await manifestStore.create(manifest)

        let queueStore = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var interruptedPrint = try await queueStore.enqueue(sessionID: manifest.id, kind: .autoPrint)
        interruptedPrint.status = .running
        interruptedPrint.attemptCount = 1
        interruptedPrint.lastAttemptAt = Date()
        try await queueStore.update(interruptedPrint)

        let queue = SessionJobQueue(store: queueStore, executor: RecoveryTestExecutor())
        queue.pauseWorkersForRecovery()
        queue.start()
        await queue.waitUntilReady()
        let service = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: queue,
            defaults: defaults
        )

        await service.scanNow()
        let migrated = try await manifestStore.load(sessionID: manifest.id)
        let plan = try #require(FinalizationPlan.make(from: migrated))
        let jobs = try await queueStore.load().filter { $0.sessionID == manifest.id }
        let migratedPrint = try #require(jobs.first { $0.kind == .autoPrint })
        #expect(migrated.finalizationTransactionID == "legacy-legacy-session")
        #expect(migrated.deliveryIntent?.automaticPrintEnabled == true)
        #expect(plan.jobKinds.contains(.autoPrint))
        #expect(migratedPrint.finalizationTransactionID == plan.transactionID)
        #expect(migratedPrint.status == .failed)
        #expect(migratedPrint.lastFailureDisposition == .sideEffectUnknown)
        #expect(jobs.filter { $0.kind == .autoPrint }.count == 1)

        await service.scanNow()
        let rescanned = try await manifestStore.load(sessionID: manifest.id)
        let rescannedJobs = try await queueStore.load().filter { $0.sessionID == manifest.id }
        #expect(rescanned.finalizationTransactionID == migrated.finalizationTransactionID)
        #expect(rescannedJobs.filter { $0.kind == .autoPrint }.count == 1)
        queue.stop()
    }

    @Test("startup removes abandoned temporary GIF files")
    @MainActor
    func removesAbandonedGIFTemporaries() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let temporaryGIF = root.appendingPathComponent(".booth-abandoned.gif")
        try Data([1, 2, 3]).write(to: temporaryGIF)
        let manifestStore = SessionManifestStore(baseDirectory: root.appendingPathComponent("Runtime"))
        try await manifestStore.create(makeManifest(
            id: "finalizing",
            status: .finalizing,
            startedAt: Date(),
            directory: root
        ))
        let service = SessionRecoveryService(
            manifestStore: manifestStore,
            workspace: SessionWorkspace(),
            jobQueue: makeQueue(root: root)
        )

        await service.scanNow()

        #expect(!FileManager.default.fileExists(atPath: temporaryGIF.path))
    }
}

@MainActor
private func makeQueue(root: URL) -> SessionJobQueue {
    SessionJobQueue(
        store: JobQueueStore(fileURL: root.appendingPathComponent("jobs.json")),
        executor: RecoveryTestExecutor()
    )
}

@MainActor
private final class RecoveryTestExecutor: SessionJobExecuting {
    func execute(_ job: SessionJob) async throws {}
}

private extension SessionJobQueue {
    func snapshotForTesting() async -> [SessionJob] { jobs }
}

private func makeManifest(
    id: String,
    status: RuntimeSessionStatus,
    startedAt: Date,
    directory: URL,
    shotFileName: String? = nil,
    nextPhotoIndex: Int = 0
) -> SessionManifest {
    let config = EventConfig(eventID: "event", eventName: "Event", photoCount: 1)
    return SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: id,
        eventID: config.eventID,
        eventName: config.eventName,
        eventConfig: config,
        startedAt: startedAt,
        completedAt: nil,
        cancelledAt: nil,
        status: status,
        nextPhotoIndex: nextPhotoIndex,
        outputRootPath: directory.deletingLastPathComponent().path,
        relativeDirectoryPath: directory.lastPathComponent,
        absoluteDirectoryPath: directory.path,
        frameSnapshotFileName: nil,
        stripFileName: nil,
        gifFileName: nil,
        downloadToken: "token-\(id)",
        shots: [RuntimeShotRecord(
            photoIndex: 0,
            imageFileName: shotFileName,
            gifFrameFileNames: [],
            retakeCount: 0,
            acceptedAt: shotFileName == nil ? nil : startedAt
        )],
        lastError: nil,
        updatedAt: startedAt
    )
}

private func makeImage() -> CGImage {
    let context = CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return context.makeImage()!
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Recovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func waitUntil(
    _ condition: @escaping @MainActor @Sendable () async -> Bool
) async throws {
    for _ in 0..<100 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    throw RecoveryTimeout()
}

private struct RecoveryTimeout: Error {}
