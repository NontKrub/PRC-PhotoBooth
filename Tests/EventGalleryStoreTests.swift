import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("EventGalleryStore")
struct EventGalleryStoreTests {
    @Test("automatic and approval modes preserve moderation state")
    func upsertAndApproval() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = makeManifest(root: root)
        let store = EventGalleryStore(baseDirectory: root)
        let approval = EventGalleryConfiguration(mode: .approvalRequired, eventToken: "token-1")
        try await store.upsertSession(manifest: manifest, configuration: approval)
        var index = try await store.load(eventID: manifest.eventID)
        #expect(index?.sessions.first?.approvalStatus == .pending)
        try await store.setApproval(eventID: manifest.eventID, sessionID: manifest.id, status: .approved)
        try await store.upsertSession(manifest: manifest, configuration: approval)
        index = try await store.load(eventID: manifest.eventID)
        #expect(index?.sessions.first?.approvalStatus == .approved)
        #expect(index?.eventToken == "token-1")
    }

    @Test("hidden status survives retries and removal is scoped")
    func hiddenAndRemove() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = makeManifest(root: root)
        let store = EventGalleryStore(baseDirectory: root)
        try await store.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic)
        )
        try await store.setApproval(eventID: manifest.eventID, sessionID: manifest.id, status: .hidden)
        try await store.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic)
        )
        #expect(try await store.load(eventID: manifest.eventID)?.sessions.first?.approvalStatus == .hidden)
        try await store.removeSession(eventID: manifest.eventID, sessionID: manifest.id)
        #expect(try await store.load(eventID: manifest.eventID)?.sessions.isEmpty == true)
    }

    @Test("soak entries persist with run metadata and stay out of the production gallery")
    func soakEntriesAreIsolated() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventGalleryStore(baseDirectory: root)
        var normal = makeManifest(root: root)
        normal.id = "normal-session"
        var soak = makeManifest(root: root)
        soak.id = "soak-session"
        soak.origin = .soakTest
        soak.soakRunID = "run-123"
        soak.soakCycleIndex = 7
        let configuration = EventGalleryConfiguration(mode: .automatic)

        try await store.upsertSession(manifest: normal, configuration: configuration)
        try await store.upsertSession(manifest: soak, configuration: configuration)

        let loadedIndex = try await store.load(eventID: normal.eventID)
        let index = try #require(loadedIndex)
        #expect(index.sessions.count == 2)
        let soakEntry = try #require(index.sessions.first { $0.sessionID == soak.id })
        #expect(soakEntry.origin == .soakTest)
        #expect(soakEntry.soakRunID == "run-123")
        #expect(soakEntry.soakCycleIndex == 7)
        #expect(Set(index.productionVisibleSessions.map(\.sessionID)) == Set([normal.id]))

        var legacySoakEntry = soakEntry
        legacySoakEntry.originRawValue = nil
        var legacyIndex = index
        let normalEntry = try #require(index.sessions.first { $0.sessionID == normal.id })
        legacyIndex.sessions = [normalEntry, legacySoakEntry]
        #expect(Set(legacyIndex.productionRouteSessions(excludingSessionIDs: [soak.id]).map(\.sessionID)) == Set([normal.id]))
    }

    @Test("legacy gallery entries without origin remain normal")
    func legacyEntryDefaultsToNormal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = makeManifest(root: root)
        let store = EventGalleryStore(baseDirectory: root)
        try await store.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic)
        )

        let indexURL = root.appendingPathComponent("Gallery/Events/\(manifest.eventID).json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        var sessions = try #require(object["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "originRawValue")
        sessions[0].removeValue(forKey: "soakRunID")
        sessions[0].removeValue(forKey: "soakCycleIndex")
        object["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: indexURL)

        let loadedIndex = try await store.load(eventID: manifest.eventID)
        let loaded = try #require(loadedIndex)
        #expect(loaded.sessions.first?.origin == .normal)
        #expect(loaded.productionVisibleSessions.map(\.sessionID) == [manifest.id])
    }

    @Test("corrupt backup files are excluded from loadAll")
    func testCorruptBackupExcludedFromLoadAll() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventGalleryStore(baseDirectory: root)

        // Create a valid index
        let manifest = makeManifest(root: root)
        try await store.upsertSession(manifest: manifest, configuration: EventGalleryConfiguration(mode: .automatic))

        // Create corrupt backup files
        let corruptBackup1 = root.appendingPathComponent("event-1-corrupt-20260924-120000.json")
        let corruptBackup2 = root.appendingPathComponent("event-1-corrupt-20260924-120000.json.corrupt")
        try Data("corrupt json".utf8).write(to: corruptBackup1)
        try Data("corrupt json".utf8).write(to: corruptBackup2)

        let loaded = await store.loadAll()
        // Should only have the 1 valid loaded index, not 2 or 3 entries
        #expect(loaded.count == 1)
        if case .loaded(let index) = loaded.first {
            #expect(index.eventID == manifest.eventID)
        } else {
            Issue.record("Expected loaded index")
        }
    }

    @Test("malformed gallery index is moved once and can be replaced by a clean save")
    func quarantinesMalformedIndexOnce() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventGalleryStore(baseDirectory: root)
        let indexURL = root.appendingPathComponent("Gallery/Events/event-1.json")
        try FileManager.default.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let malformed = Data("{broken json".utf8)
        try malformed.write(to: indexURL)

        var quarantineURL: URL?
        do {
            _ = try await store.load(eventID: "event-1")
            Issue.record("Expected malformed gallery JSON to fail")
        } catch EventGalleryStoreError.corrupt(let source, let backup) {
            #expect(source == indexURL)
            quarantineURL = backup
        }

        #expect(!FileManager.default.fileExists(atPath: indexURL.path))
        let quarantinedURL = try #require(quarantineURL)
        #expect(try Data(contentsOf: quarantinedURL) == malformed)
        #expect(try await store.load(eventID: "event-1") == nil)
        #expect(try await store.load(eventID: "event-1") == nil)
        #expect(try FileManager.default.contentsOfDirectory(
            at: indexURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "corrupt" }.count == 1)

        let manifest = makeManifest(root: root)
        try await store.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic)
        )
        #expect(try await store.load(eventID: "event-1")?.sessions.map(\.sessionID) == [manifest.id])
        #expect(FileManager.default.fileExists(atPath: quarantinedURL.path))
    }

    @Test("unreadable gallery index is preserved rather than quarantined as malformed")
    func preservesUnreadableIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventGalleryStore(baseDirectory: root)
        let indexURL = root.appendingPathComponent("Gallery/Events/event-unreadable.json")
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: true)

        do {
            _ = try await store.load(eventID: "event-unreadable")
            Issue.record("Expected a directory at the index path to fail as unreadable")
        } catch EventGalleryStoreError.unreadable(let source, _) {
            #expect(source.lastPathComponent == indexURL.lastPathComponent)
            #expect(source.deletingLastPathComponent() == indexURL.deletingLastPathComponent())
        }

        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(try FileManager.default.contentsOfDirectory(
            at: indexURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "corrupt" }.isEmpty)
    }

    @Test("unsupported future gallery schema stays in place")
    func preservesFutureSchemaIndex() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventGalleryStore(baseDirectory: root)
        let manifest = makeManifest(root: root)
        try await store.upsertSession(
            manifest: manifest,
            configuration: EventGalleryConfiguration(mode: .automatic)
        )
        let indexURL = root.appendingPathComponent("Gallery/Events/\(manifest.eventID).json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as? [String: Any])
        object["schemaVersion"] = EventGalleryIndex.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(to: indexURL)

        do {
            _ = try await store.load(eventID: manifest.eventID)
            Issue.record("Expected unsupported gallery schema to fail")
        } catch EventGalleryStoreError.corrupt(let source, let backup) {
            #expect(source == indexURL)
            #expect(backup == indexURL)
        }
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
    }

    private func makeManifest(root: URL) -> SessionManifest {
        let directory = root.appendingPathComponent("session")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data([1, 2]).write(to: directory.appendingPathComponent("strip.png"))
        return SessionManifest(
            schemaVersion: 1,
            id: "session-1",
            eventID: "event-1",
            eventName: "Gallery",
            eventConfig: EventConfig(eventID: "event-1", eventName: "Gallery", photoCount: 1, slots: [
                SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
            ]),
            startedAt: Date(),
            completedAt: Date(),
            cancelledAt: nil,
            status: .completed,
            nextPhotoIndex: 1,
            outputRootPath: root.path,
            relativeDirectoryPath: "session",
            absoluteDirectoryPath: directory.path,
            frameSnapshotFileName: nil,
            stripFileName: "strip.png",
            gifFileName: nil,
            downloadToken: "download-1",
            shots: [],
            lastError: nil,
            updatedAt: Date()
        )
    }
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PRC-Gallery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
