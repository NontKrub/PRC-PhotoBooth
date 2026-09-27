import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Soak session cleanup", .serialized)
struct SoakSessionCleanupTests {
    @Test("cleanup retry preserves diagnostics after remote failure and finishes idempotently")
    @MainActor
    func remoteFailureRetainsRetryStateThenCleanupCanRepeat() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let runID = "cleanup-run-\(UUID().uuidString)"
        let outputRoot = root.appendingPathComponent("Output", isDirectory: true)
        let runtimeRoot = root.appendingPathComponent("Runtime", isDirectory: true)
        let manifestStore = SessionManifestStore(baseDirectory: runtimeRoot)
        let dataStore = DataStore.inMemoryForTesting()
        let event = dataStore.createEvent(name: "Cleanup test event")
        let session = dataStore.startSession(
            for: event,
            origin: .soakTest,
            soakRunID: runID,
            soakCycleIndex: 1
        )
        let sessionDirectory = outputRoot.appendingPathComponent("Event/\(session.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let sentinel = sessionDirectory.appendingPathComponent("strip.png")
        try Data([0x01]).write(to: sentinel)

        var manifest = makeManifest(
            id: session.id,
            eventID: event.id,
            eventName: event.name,
            outputRoot: outputRoot,
            sessionDirectory: sessionDirectory
        )
        manifest.status = .completed
        manifest.origin = .soakTest
        manifest.soakRunID = runID
        manifest.soakCycleIndex = 1
        manifest.soakAutoCleanupEnabled = true
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: false,
            updateGalleryEnabled: true,
            renderGIFEnabled: false
        )
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example",
            remoteBasePath: "/bk1/prc/photobooth",
            sshHost: "photos.example"
        )
        try await manifestStore.create(manifest)

        let galleryStore = EventGalleryStore(baseDirectory: runtimeRoot)
        try await galleryStore.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic, eventToken: "event-token")
        )
        let jobStore = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let jobQueue = SessionJobQueue(store: jobStore, executor: CleanupTestJobExecutor())
        let commandRunner = SoakCleanupCommandRunner(results: [
            CloudCommandResult(exitCode: 1, output: "remote unavailable"),
            CloudCommandResult(exitCode: 0, output: "")
        ])
        let cloudUpload = CloudUploadService(runner: commandRunner)
        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: jobQueue,
            runtimeDirectory: runtimeRoot,
            testingDataStore: dataStore,
            testingCloudUpload: cloudUpload
        )

        let route = try CloudGuestRoute.resolve(for: manifest)
        await coordinator.server.setGuestRouteExposure(.trustedLocalHTTP)
        await coordinator.server.registerGuestRoute(
            path: route.relativePath,
            registration: SessionRouteRegistration(
                sessionDirectory: sessionDirectory,
                language: .english
            )
        )
        await coordinator.server.registerToken(manifest.downloadToken, sessionDirectory: sessionDirectory)
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 2)

        let firstWarnings = await coordinator.cleanupSoakSession(
            manifest,
            expectedRunID: runID,
            removeArtifacts: true
        )

        #expect(firstWarnings.contains { $0.contains("Remote cloud cleanup failed") })
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.path))
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 0)
        #expect(try await galleryStore.load(eventID: event.id)?.sessions.isEmpty == true)
        #expect(dataStore.fetchSession(id: session.id) != nil)
        let retained = try await manifestStore.load(sessionID: session.id)
        #expect(retained.soakCleanupWarning?.contains("Remote cloud cleanup failed") == true)
        #expect(retained.isRetainedSoakDiagnostic)
        #expect(await commandRunner.callCount == 1)

        let secondWarnings = await coordinator.cleanupSoakSession(
            manifest,
            expectedRunID: runID,
            removeArtifacts: true
        )

        #expect(secondWarnings.isEmpty)
        #expect(dataStore.fetchSession(id: session.id) == nil)
        #expect((await manifestStore.loadAll()).isEmpty)
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 0)
        #expect(await commandRunner.callCount == 2)
    }

    @Test("cleanup refuses normal sessions and mismatched soak run IDs")
    @MainActor
    func cleanupRejectsWrongSessionOwnershipWithoutSideEffects() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeRoot = root.appendingPathComponent("Runtime", isDirectory: true)
        let outputRoot = root.appendingPathComponent("Output", isDirectory: true)
        let manifestStore = SessionManifestStore(baseDirectory: runtimeRoot)
        let jobStore = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let runner = SoakCleanupCommandRunner(results: [])
        let dataStore = DataStore.inMemoryForTesting()
        let event = dataStore.createEvent(name: "Protected customer event")
        let normalSession = dataStore.startSession(for: event)
        let normalDirectory = outputRoot
            .appendingPathComponent("Event/\(normalSession.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: normalDirectory, withIntermediateDirectories: true)
        let normalPhoto = normalDirectory.appendingPathComponent("strip.png")
        try Data([0x01]).write(to: normalPhoto)

        let coordinator = BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: SessionJobQueue(store: jobStore, executor: CleanupTestJobExecutor()),
            runtimeDirectory: runtimeRoot,
            testingDataStore: dataStore,
            testingCloudUpload: CloudUploadService(runner: runner)
        )

        var normal = makeManifest(
            id: normalSession.id,
            eventID: event.id,
            eventName: event.name,
            outputRoot: outputRoot,
            sessionDirectory: normalDirectory
        )
        normal.status = .completed
        normal.downloadToken = normalSession.downloadToken
        normal.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://photos.example",
            remoteBasePath: "/bk1/prc/photobooth",
            sshHost: "photos.example"
        )
        try await manifestStore.create(normal)
        let galleryStore = EventGalleryStore(baseDirectory: runtimeRoot)
        let galleryConfiguration = EventGalleryConfiguration(mode: .automatic, eventToken: "event-token")
        try await galleryStore.upsertSession(manifest: normal, configuration: galleryConfiguration)
        let normalRoute = try CloudGuestRoute.resolve(for: normal)
        await coordinator.server.setGuestRouteExposure(.trustedLocalHTTP)
        await coordinator.server.registerGuestRoute(
            path: normalRoute.relativePath,
            registration: SessionRouteRegistration(
                sessionDirectory: normalDirectory,
                language: .english
            )
        )
        await coordinator.server.registerToken(normal.downloadToken, sessionDirectory: normalDirectory)
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 1)

        let normalWarning = await coordinator.cleanupSoakSession(
            normal,
            expectedRunID: "run-1",
            removeArtifacts: true
        )
        #expect(normalWarning.contains { $0.contains("Refused cleanup") })
        #expect(FileManager.default.fileExists(atPath: normalPhoto.path))
        #expect(dataStore.fetchSession(id: normalSession.id) === normalSession)
        let persistedNormal = try await manifestStore.load(sessionID: normal.id)
        #expect(persistedNormal.id == normal.id)
        #expect(persistedNormal.origin == .normal)
        #expect(persistedNormal.soakRunID == nil)
        #expect(persistedNormal.status == normal.status)
        #expect(persistedNormal.cloudDelivery == normal.cloudDelivery)
        let normalGallery = try await galleryStore.load(eventID: event.id)
        #expect(normalGallery?.productionVisibleSessions.map(\.sessionID) == [normalSession.id])
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 1)

        let runID = "run-1"
        let soakSession = dataStore.startSession(
            for: event,
            origin: .soakTest,
            soakRunID: runID,
            soakCycleIndex: 1
        )
        let soakDirectory = outputRoot
            .appendingPathComponent("Event/\(soakSession.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: soakDirectory, withIntermediateDirectories: true)
        let soakPhoto = soakDirectory.appendingPathComponent("strip.png")
        try Data([0x02]).write(to: soakPhoto)
        var soak = normal
        soak.id = soakSession.id
        soak.eventID = event.id
        soak.eventName = event.name
        soak.absoluteDirectoryPath = soakDirectory.path
        soak.relativeDirectoryPath = "Event/\(soakSession.id)"
        soak.downloadToken = soakSession.downloadToken
        soak.startedAt = soakSession.startedAt
        soak.outputRootPath = outputRoot.path
        soak.origin = .soakTest
        soak.soakRunID = runID
        soak.soakCycleIndex = 1
        try await manifestStore.create(soak)
        try await galleryStore.upsertSession(manifest: soak, configuration: galleryConfiguration)
        let soakRoute = try CloudGuestRoute.resolve(for: soak)
        await coordinator.server.registerGuestRoute(
            path: soakRoute.relativePath,
            registration: SessionRouteRegistration(
                sessionDirectory: soakDirectory,
                language: .english
            )
        )
        await coordinator.server.registerToken(soak.downloadToken, sessionDirectory: soakDirectory)
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 3)

        let mismatchWarning = await coordinator.cleanupSoakSession(
            soak,
            expectedRunID: "run-2",
            removeArtifacts: true
        )
        #expect(mismatchWarning.contains { $0.contains("Refused cleanup") })
        #expect(FileManager.default.fileExists(atPath: normalPhoto.path))
        #expect(FileManager.default.fileExists(atPath: soakPhoto.path))
        #expect(dataStore.fetchSession(id: normalSession.id) === normalSession)
        #expect(dataStore.fetchSession(id: soakSession.id) === soakSession)
        let persistedSoak = try await manifestStore.load(sessionID: soak.id)
        #expect(persistedSoak.id == soak.id)
        #expect(persistedSoak.origin == .soakTest)
        #expect(persistedSoak.soakRunID == soak.soakRunID)
        #expect(persistedSoak.status == soak.status)
        #expect(persistedSoak.cloudDelivery == soak.cloudDelivery)
        let persistedGallery = try await galleryStore.load(eventID: event.id)
        #expect(persistedGallery?.sessions.count == 2)
        #expect(persistedGallery?.productionVisibleSessions.map(\.sessionID) == [normalSession.id])
        #expect(await coordinator.server.statusSnapshot().registeredTokenCount == 3)
        #expect(await runner.callCount == 0)
    }
}

@MainActor
private final class CleanupTestJobExecutor: SessionJobExecuting {
    func execute(_ job: SessionJob) async throws {}
}

private actor SoakCleanupCommandRunner: CloudCommandRunning {
    private var results: [CloudCommandResult]
    private(set) var callCount = 0

    init(results: [CloudCommandResult]) {
        self.results = results
    }

    func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> CloudCommandResult {
        callCount += 1
        guard !results.isEmpty else {
            return CloudCommandResult(exitCode: 0, output: "")
        }
        return results.removeFirst()
    }
}

@MainActor
private func makeManifest(
    id: String,
    eventID: String,
    eventName: String,
    outputRoot: URL,
    sessionDirectory: URL
) -> SessionManifest {
    let eventConfig = EventConfig(eventID: eventID, eventName: eventName, photoCount: 1)
    return SessionManifest(
        schemaVersion: SessionManifest.currentSchemaVersion,
        id: id,
        eventID: eventID,
        eventName: eventName,
        eventConfig: eventConfig,
        startedAt: Date(),
        completedAt: Date(),
        cancelledAt: nil,
        status: .completed,
        nextPhotoIndex: 1,
        outputRootPath: outputRoot.path,
        relativeDirectoryPath: "Event/\(id)",
        absoluteDirectoryPath: sessionDirectory.path,
        frameSnapshotFileName: nil,
        stripFileName: "strip.png",
        gifFileName: nil,
        downloadToken: "token-\(id)",
        shots: [],
        lastError: nil,
        updatedAt: Date()
    )
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-SoakCleanup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
