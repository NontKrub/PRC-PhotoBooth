import Testing
import Foundation
import CoreGraphics

@testable import PRC_PhotoBooth_Mac

@Suite("SessionManifestStore")
struct SessionManifestStoreTests {
    @Test("creates and loads a manifest with ISO dates and event slots")
    func createsAndLoadsManifest() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        let expected = makeManifest()

        try await store.create(expected)
        let loaded = try await store.load(sessionID: expected.id)

        #expect(loaded.id == expected.id)
        #expect(loaded.eventConfig == expected.eventConfig)
        #expect(loaded.shots == expected.shots)
        #expect(loaded.updatedAt >= expected.updatedAt)
        let raw = try String(contentsOf: root.appendingPathComponent("Sessions/\(expected.id).json"), encoding: .utf8)
        #expect(raw.contains("T"))
        #expect(loaded.eventConfig.slots.count == 1)
        #expect(loaded.shots[0].retakeCount == 2)
    }

    @Test("saves updates atomically and keeps one file per session")
    func savesUpdates() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        var manifest = makeManifest()

        try await store.create(manifest)
        manifest.lastError = "temporary"
        try await store.save(manifest)

        let files = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("Sessions"),
            includingPropertiesForKeys: nil
        )
        #expect(files.filter { $0.pathExtension == "json" }.count == 1)
        #expect(try await store.load(sessionID: manifest.id).lastError == "temporary")
    }

    @Test("reports corrupt and unsupported manifests without deleting files")
    func reportsBadFiles() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("Sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        let corrupt = sessions.appendingPathComponent("corrupt.json")
        try Data("not-json".utf8).write(to: corrupt)

        var unsupported = makeManifest(id: "unsupported")
        unsupported.schemaVersion = SessionManifest.currentSchemaVersion + 1
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(unsupported).write(to: sessions.appendingPathComponent("unsupported.json"))

        let results = await SessionManifestStore(baseDirectory: root).loadAll()
        #expect(results.count == 2)
        #expect(FileManager.default.fileExists(atPath: corrupt.path))
        #expect(results.allSatisfy {
            if case .failed = $0 { return true }
            return false
        })
    }

    @Test("loads valid manifests, filters status, and deletes one file")
    func loadsFiltersAndDeletes() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        let first = makeManifest(id: "first")
        var second = makeManifest(id: "second")
        second.status = .completed

        try await store.create(first)
        try await store.create(second)

        #expect(await store.manifests(with: .completed).map(\.id) == [second.id])
        try await store.delete(sessionID: first.id)
        #expect((await store.loadAll()).count == 1)
    }

    @Test("old manifests decode without v1.3 capture fields")
    func decodesLegacyManifest() throws {
        let manifest = makeManifest()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(manifest)) as? [String: Any])
        object.removeValue(forKey: "captureAttempts")
        object.removeValue(forKey: "cloudDelivery")
        if var shots = object["shots"] as? [[String: Any]], var shot = shots.first {
            shot.removeValue(forKey: "previousImageFileName")
            shot.removeValue(forKey: "previousGifFrameFileNames")
            shot.removeValue(forKey: "previousAcceptedAt")
            shots[0] = shot
            object["shots"] = shots
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionManifest.self, from: data)

        #expect(decoded.id == manifest.id)
        #expect(decoded.captureAttempts == nil)
        #expect(decoded.cloudDelivery == nil)
        #expect(decoded.shots[0].previousImageFileName == nil)
    }

    @Test("persists session-stable cloud delivery settings")
    func persistsCloudDeliverySnapshot() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        var manifest = makeManifest()
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://old.example",
            remoteBasePath: "/srv/old-photos",
            sshHost: "old-host"
        )

        try await store.create(manifest)
        #expect(try await store.load(sessionID: manifest.id).cloudDelivery == manifest.cloudDelivery)
    }

    @Test("session cloud snapshot takes precedence over changed Settings")
    @MainActor
    func cloudSnapshotTakesPrecedence() throws {
        let defaults = try #require(UserDefaults(suiteName: "PRC-Cloud-(UUID().uuidString)"))
        var manifest = makeManifest()
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://old.example",
            remoteBasePath: "/srv/old-photos",
            sshHost: "old-host"
        )
        defaults.set(false, forKey: "cloudUploadEnabled")
        defaults.set("https://new.example", forKey: "publicBaseURL")
        defaults.set("/srv/new-photos", forKey: "cloudRemotePath")
        defaults.set("new-host", forKey: "cloudSSHHost")

        let configuration = try #require(
            SessionJobExecutor.cloudUploadConfiguration(for: manifest, defaults: defaults)
        )
        #expect(configuration.publicBaseURL == "https://old.example")
        #expect(configuration.remoteBasePath == "/srv/old-photos")
        #expect(configuration.sshHost == "old-host")
    }
}

private func makeManifest(id: String = UUID().uuidString) -> SessionManifest {
    let config = EventConfig(
        eventID: "event-1",
        eventName: "Event / One",
        photoCount: 2,
        countdownSeconds: 3,
        canvasWidth: 400,
        canvasHeight: 600,
        slots: [SharedPhotoSlot(id: "slot-1", normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)]
    )
    let now = Date(timeIntervalSince1970: 1_700_000_000)
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
        outputRootPath: "/tmp/output",
        relativeDirectoryPath: "Event One/20240101-010203-\(id.prefix(8))",
        absoluteDirectoryPath: "/tmp/output/Event One/20240101-010203-\(id.prefix(8))",
        frameSnapshotFileName: ".work/frame.png",
        stripFileName: nil,
        gifFileName: nil,
        downloadToken: "token-\(id)",
        shots: [RuntimeShotRecord(photoIndex: 0, imageFileName: "shot_0.jpg", gifFrameFileNames: [], retakeCount: 2, acceptedAt: now)],
        lastError: nil,
        updatedAt: now
    )
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-Manifest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
