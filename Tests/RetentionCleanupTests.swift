import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Retention cleanup", .serialized)
struct RetentionCleanupTests {
    @Test("expired approved session leaves gallery and all local routes before deleting files")
    @MainActor
    func removesGalleryBeforeExpiredSessionFiles() async throws {
        let root = try makeRetentionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        let sessionDirectory = output.appendingPathComponent("Event/session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(to: sessionDirectory.appendingPathComponent("strip.png"))

        let dataStore = DataStore.inMemoryForTesting()
        let event = dataStore.createEvent(name: "Retention event")
        let completedAt = Date(timeIntervalSinceNow: -61 * 24 * 60 * 60)
        let manifest = retentionManifest(
            id: "session",
            eventID: event.id,
            eventName: event.name,
            output: output,
            sessionDirectory: sessionDirectory,
            completedAt: completedAt
        )
        _ = dataStore.restoreSessionRecord(from: manifest)

        let manifestStore = SessionManifestStore(baseDirectory: runtime)
        try await manifestStore.create(manifest)
        let galleryStore = EventGalleryStore(baseDirectory: runtime)
        try await galleryStore.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic, eventToken: "event-token")
        )
        let jobStore = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        _ = try await jobStore.enqueue(sessionID: manifest.id, kind: .updateGallery)
        let queue = SessionJobQueue(store: jobStore, executor: RetentionTestExecutor())
        let workspace = SessionWorkspace()
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: runtime,
            testingWorkspace: workspace,
            testingDataStore: dataStore
        )

        await coordinator.server.setGuestRouteExposure(.trustedLocalHTTP)
        await coordinator.server.registerToken(manifest.downloadToken, sessionDirectory: sessionDirectory)
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 1)
        #expect(try await galleryStore.load(eventID: event.id)?.productionVisibleSessions.map(\.sessionID) == [manifest.id])

        await coordinator.cleanupOldSessionsForTesting(keepDays: 60)

        #expect(try await galleryStore.load(eventID: event.id)?.sessions.isEmpty == true)
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect((await manifestStore.loadAll()).isEmpty)
        #expect((await jobStore.snapshot()).isEmpty)
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 0)
        #expect(dataStore.fetchSession(id: manifest.id) == nil)
    }

    @Test("gallery removal failure keeps workspace manifest jobs and route")
    @MainActor
    func galleryFailureRetainsSessionArtifacts() async throws {
        let root = try makeRetentionTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        let sessionDirectory = output.appendingPathComponent("Event/session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let strip = sessionDirectory.appendingPathComponent("strip.png")
        try Data([0x01]).write(to: strip)

        let dataStore = DataStore.inMemoryForTesting()
        let event = dataStore.createEvent(name: "Retention event")
        let manifest = retentionManifest(
            id: "session",
            eventID: event.id,
            eventName: event.name,
            output: output,
            sessionDirectory: sessionDirectory,
            completedAt: Date(timeIntervalSinceNow: -61 * 24 * 60 * 60)
        )
        _ = dataStore.restoreSessionRecord(from: manifest)

        let manifestStore = SessionManifestStore(baseDirectory: runtime)
        try await manifestStore.create(manifest)
        let galleryIndexURL = runtime
            .appendingPathComponent("Gallery/Events", isDirectory: true)
            .appendingPathComponent("\(event.id).json")
        try FileManager.default.createDirectory(
            at: galleryIndexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{invalid json".utf8).write(to: galleryIndexURL)

        let jobStore = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let job = try await jobStore.enqueue(sessionID: manifest.id, kind: .updateGallery)
        let queue = SessionJobQueue(store: jobStore, executor: RetentionTestExecutor())
        let workspace = SessionWorkspace()
        let recovery = SessionRecoveryService(manifestStore: manifestStore, workspace: workspace, jobQueue: queue)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: queue,
            runtimeDirectory: runtime,
            testingRecoveryService: recovery,
            testingWorkspace: workspace,
            testingDataStore: dataStore
        )

        await coordinator.server.setGuestRouteExposure(.trustedLocalHTTP)
        await coordinator.server.registerToken(manifest.downloadToken, sessionDirectory: sessionDirectory)
        await coordinator.cleanupOldSessionsForTesting(keepDays: 60)

        #expect(FileManager.default.fileExists(atPath: strip.path))
        #expect(try await manifestStore.load(sessionID: manifest.id).id == manifest.id)
        #expect((await jobStore.snapshot()).contains { $0.id == job.id })
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 1)
        #expect(dataStore.fetchSession(id: manifest.id) != nil)
        #expect(recovery.cleanupPendingSessionIDs.contains(manifest.id))
        #expect(recovery.recoveryErrors.contains { $0.contains("gallery entry or files could not be removed") })
    }
}

@MainActor
private final class RetentionTestExecutor: SessionJobExecuting {
    func execute(_ job: SessionJob) async throws {}
}

private func retentionManifest(
    id: String,
    eventID: String,
    eventName: String,
    output: URL,
    sessionDirectory: URL,
    completedAt: Date
) -> SessionManifest {
    let config = EventConfig(eventID: eventID, eventName: eventName, photoCount: 1)
    return SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: id,
        eventID: eventID,
        eventName: eventName,
        eventConfig: config,
        startedAt: completedAt.addingTimeInterval(-60),
        completedAt: completedAt,
        cancelledAt: nil,
        status: .completed,
        nextPhotoIndex: 1,
        outputRootPath: output.path,
        relativeDirectoryPath: "Event/\(id)",
        absoluteDirectoryPath: sessionDirectory.path,
        frameSnapshotFileName: nil,
        stripFileName: "strip.png",
        gifFileName: nil,
        downloadToken: "token-\(id)",
        shots: [],
        lastError: nil,
        updatedAt: completedAt
    )
}

private func makeRetentionTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
