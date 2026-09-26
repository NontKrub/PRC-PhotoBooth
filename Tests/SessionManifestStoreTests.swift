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
        manifest = try await store.load(sessionID: manifest.id)
        manifest.lastError = "temporary"
        try await store.save(manifest, allowedStatuses: [.capturing])

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
        object.removeValue(forKey: "deliveryIntent")
        object.removeValue(forKey: "soakAutoCleanupEnabled")
        object.removeValue(forKey: "soakDiagnosticRetained")
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
        #expect(decoded.deliveryIntent == nil)
        #expect(decoded.soakAutoCleanupEnabled == nil)
        #expect(decoded.soakDiagnosticRetained == nil)
        #expect(decoded.shots[0].previousImageFileName == nil)
    }

    @Test("cleanup diagnostics persist only for the matching soak run")
    func soakCleanupDiagnosticIsRunScoped() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        var manifest = makeManifest()
        manifest.id = "soak-session"
        manifest.origin = .soakTest
        manifest.soakRunID = "run-123"
        try await store.create(manifest)

        _ = try await store.recordSoakCleanupResult(
            sessionID: manifest.id,
            expectedRunID: "run-123",
            warning: "Remote deletion failed"
        )
        let updated = try await store.load(sessionID: manifest.id)
        #expect(updated.soakCleanupWarning == "Remote deletion failed")
        #expect(updated.soakCleanupLastAttemptAt != nil)

        do {
            _ = try await store.recordSoakCleanupResult(
                sessionID: manifest.id,
                expectedRunID: "another-run",
                warning: nil
            )
            Issue.record("A different run changed this session's cleanup state.")
        } catch SessionManifestError.soakCleanupNotAllowed(let sessionID) {
            #expect(sessionID == manifest.id)
        }
        #expect(try await store.load(sessionID: manifest.id).soakCleanupWarning == "Remote deletion failed")
    }

    @Test("failed soak diagnostics are retained only by the owning run")
    func soakFailureDiagnosticsAreRunScoped() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        var manifest = makeManifest()
        manifest.id = "diagnostic-soak-session"
        manifest.origin = .soakTest
        manifest.soakRunID = "run-123"
        try await store.create(manifest)

        let retained = try await store.retainSoakFailureDiagnostics(
            sessionID: manifest.id,
            expectedRunID: "run-123",
            reason: "QR verification failed"
        )
        #expect(retained.lastError == "QR verification failed")
        #expect(retained.isRetainedSoakDiagnostic)

        do {
            _ = try await store.retainSoakFailureDiagnostics(
                sessionID: manifest.id,
                expectedRunID: "another-run",
                reason: "wrong owner"
            )
            Issue.record("A different run changed this session's diagnostic reason.")
        } catch SessionManifestError.soakCleanupNotAllowed(let sessionID) {
            #expect(sessionID == manifest.id)
        }
        #expect(try await store.load(sessionID: manifest.id).lastError == "QR verification failed")
    }

    @Test("cleanup retains soak data when print outcome is unresolved without manifest failure metadata")
    func cleanupRetainsUnknownPrintDiagnostics() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var manifest = makeManifest()
        manifest.id = "unknown-print-soak-session"
        manifest.origin = .soakTest
        manifest.soakRunID = "run-123"
        manifest.status = .completed
        manifest.lastError = nil
        manifest.soakDiagnosticRetained = nil

        let queue = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        var printJob = try await queue.enqueue(sessionID: manifest.id, kind: .autoPrint)
        printJob.status = .failed
        printJob.lastFailureDisposition = .sideEffectUnknown
        printJob.lastError = "AppKit completion is unknown"

        #expect(BoothSoakCleanupPolicy.shouldRetainDiagnostics(manifest: manifest, jobs: [printJob]))
        manifest.origin = .normal
        #expect(!BoothSoakCleanupPolicy.shouldRetainDiagnostics(manifest: manifest, jobs: [printJob]))
    }

    @Test("startup cleanup retry can clear only the previous cleanup retention marker")
    func cleanupRetryClearsTemporaryRetentionMarker() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        var manifest = makeManifest()
        manifest.id = "cleanup-retry-soak-session"
        manifest.origin = .soakTest
        manifest.soakRunID = "run-123"
        manifest.status = .completed
        manifest.soakAutoCleanupEnabled = true
        manifest.soakDiagnosticRetained = true
        manifest.soakCleanupWarning = "Remote deletion failed"
        try await store.create(manifest)

        let prepared = try await store.prepareOrphanedSoakForCleanup(
            sessionID: manifest.id,
            expectedRunID: "run-123",
            retainForDiagnostics: false
        )

        #expect(prepared.soakDiagnosticRetained == false)
        #expect(prepared.soakCleanupWarning == "Remote deletion failed")
        #expect(prepared.lastError == nil)
    }

    @Test("automatic cleanup warning does not become permanent diagnostic retention")
    func cleanupWarningRemainsRetryable() {
        var manifest = makeManifest()
        manifest.origin = .soakTest
        manifest.soakRunID = "run-123"
        manifest.status = .completed
        manifest.soakAutoCleanupEnabled = true
        manifest.soakCleanupWarning = "Remote cloud cleanup failed."
        manifest.soakDiagnosticRetained = true

        #expect(!BoothSoakCleanupPolicy.shouldRetainDiagnostics(manifest: manifest, jobs: []))

        manifest.lastError = "Production pipeline failed."
        #expect(BoothSoakCleanupPolicy.shouldRetainDiagnostics(manifest: manifest, jobs: []))
    }

    @Test("status changes require an explicit compare-and-set transition")
    func statusTransitionsAreAuthoritative() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        let manifest = makeManifest()
        try await store.create(manifest)

        _ = try await store.transition(sessionID: manifest.id, allowedFrom: [.capturing]) {
            $0.status = .finalizing
        }
        var stale = try await store.load(sessionID: manifest.id)
        stale.updatedAt = Date(timeIntervalSince1970: 1)
        do {
            try await store.save(stale, allowedStatuses: [.finalizing])
            Issue.record("Stale manifest write was accepted")
        } catch let error as SessionManifestError {
            guard case .staleWrite = error else {
                Issue.record("Unexpected stale-write error: \(error)")
                return
            }
        }
        do {
            _ = try await store.update(
                sessionID: manifest.id,
                allowedStatuses: [.finalizing]
            ) { $0.status = .capturing }
            Issue.record("Generic manifest update changed status")
        } catch let error as SessionManifestError {
            guard case .invalidTransition = error else {
                Issue.record("Unexpected manifest error: \(error)")
                return
            }
        }

        _ = try await store.transition(sessionID: manifest.id, allowedFrom: [.finalizing]) {
            $0.status = .completed
        }
        do {
            _ = try await store.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing]
            ) { $0.lastError = "late capture" }
            Issue.record("Completed manifest accepted a capturing mutation")
        } catch let error as SessionManifestError {
            guard case .mutationNotAllowed = error else {
                Issue.record("Unexpected completed-mutation error: \(error)")
                return
            }
        }
        do {
            _ = try await store.transition(sessionID: manifest.id, allowedFrom: [.completed]) {
                $0.status = .capturing
            }
            Issue.record("Terminal manifest was resurrected")
        } catch let error as SessionManifestError {
            guard case .invalidTransition = error else {
                Issue.record("Unexpected terminal transition error: \(error)")
                return
            }
        }
    }

    @Test("cancelled manifest rejects late ordinary mutation")
    func cancelledManifestRejectsLateMutation() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionManifestStore(baseDirectory: root)
        let manifest = makeManifest()
        try await store.create(manifest)
        _ = try await store.transition(sessionID: manifest.id, allowedFrom: [.capturing]) {
            $0.status = .cancelled
            $0.cancelledAt = Date()
        }
        let before = try await store.load(sessionID: manifest.id)
        do {
            _ = try await store.update(
                sessionID: manifest.id,
                allowedStatuses: [.capturing, .finalizing]
            ) { $0.lastError = "late work" }
            Issue.record("Cancelled manifest accepted late mutation")
        } catch let error as SessionManifestError {
            guard case .mutationNotAllowed = error else {
                Issue.record("Unexpected cancelled-mutation error: \(error)")
                return
            }
        }
        #expect(try await store.load(sessionID: manifest.id) == before)
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
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: true,
            automaticPrintEnabled: false
        )

        try await store.create(manifest)
        #expect(try await store.load(sessionID: manifest.id).cloudDelivery == manifest.cloudDelivery)
        #expect(try await store.load(sessionID: manifest.id).deliveryIntent == manifest.deliveryIntent)
    }

    @Test("session cloud snapshot takes precedence over changed Settings")
    @MainActor
    func cloudSnapshotTakesPrecedence() throws {
        let suiteName = "PRC-Cloud-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var manifest = makeManifest()
        manifest.cloudDelivery = SessionCloudDeliverySnapshot(
            publicBaseURL: "https://old.example",
            remoteBasePath: "/srv/old-photos",
            sshHost: "old-host"
        )
        manifest.deliveryIntent = SessionDeliveryIntentSnapshot(
            cloudUploadEnabled: false,
            automaticPrintEnabled: false
        )
        defaults.set(true, forKey: "cloudUploadEnabled")
        defaults.set("https://new.example", forKey: "publicBaseURL")
        defaults.set("/srv/new-photos", forKey: "cloudRemotePath")
        defaults.set("new-host", forKey: "cloudSSHHost")

        // The historical manifest resolver has no current-Settings input.
        #expect(SessionJobExecutor.cloudUploadConfiguration(for: manifest) == nil)

        manifest.deliveryIntent?.cloudUploadEnabled = true
        let configuration = try #require(SessionJobExecutor.cloudUploadConfiguration(for: manifest))
        #expect(configuration.publicBaseURL == "https://old.example")
        #expect(configuration.remoteBasePath == "/srv/old-photos")
        #expect(configuration.sshHost == "old-host")
    }

    @Test("current cloud Settings do not create a legacy upload destination")
    @MainActor
    func legacyCloudUploadNeedsHistoricalDestination() throws {
        let suiteName = "PRC-Cloud-Legacy-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "cloudUploadEnabled")
        defaults.set("https://new.example", forKey: "publicBaseURL")
        defaults.set("/srv/new-photos", forKey: "cloudRemotePath")
        defaults.set("new-host", forKey: "cloudSSHHost")

        var legacy = makeManifest()
        legacy.cloudDelivery = nil
        legacy.deliveryIntent = nil
        // Today's enabled flag and destination cannot fill missing session history.
        #expect(SessionJobExecutor.cloudUploadConfiguration(for: legacy) == nil)
    }

    @Test("soak manifests are never eligible for production guest publication")
    func soakGuestPublicationIsAlwaysIsolated() {
        let normal = makeManifest()
        var soak = normal
        soak.id = "soak-session"
        soak.origin = .soakTest
        soak.soakRunID = "run-123"

        #expect(normal.isEligibleForGuestPublication(activeSoakRunID: nil))
        #expect(!soak.isEligibleForGuestPublication(activeSoakRunID: "run-123"))
        #expect(!soak.isEligibleForGuestPublication(activeSoakRunID: nil))
        #expect(!soak.isEligibleForGuestPublication(activeSoakRunID: "different-run"))

        soak.soakRunID = nil
        #expect(!soak.isEligibleForGuestPublication(activeSoakRunID: nil))
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

@Suite("SessionFlowOperationRegistry")
struct SessionFlowOperationRegistryTests {
    @Test("non-cooperative session work blocks cleanup until timeout")
    @MainActor
    func nonCooperativeWorkReturnsPending() async {
        let registry = SessionFlowOperationRegistry()
        let gate = SessionFlowTestGate()
        registry.start(sessionID: "session", kind: .capture) {
            await gate.wait()
        }

        #expect(!(await registry.cancelAndQuiesce(sessionID: "session", timeout: .milliseconds(20))))
        await gate.open()
        #expect(await registry.cancelAndQuiesce(sessionID: "session", timeout: .seconds(1)))
    }
}

private actor SessionFlowTestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
