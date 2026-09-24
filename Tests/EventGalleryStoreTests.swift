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
