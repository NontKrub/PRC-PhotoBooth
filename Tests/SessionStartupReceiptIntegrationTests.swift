import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Application-level startup receipts", .serialized)
struct SessionStartupReceiptIntegrationTests {
    @Test("reconnect and duplicate start reuse the session; countdown waits for both receipts")
    @MainActor
    func reconnectResumesOneSessionAndRequiresCountdownReceipt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = StartupReceiptTestTransport()
        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus, previewReady: false)
        let coordinator = fixture.makeCoordinator(transport: transport)
        let requestID = UUID()
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: requestID,
            authority: .dualDisplay,
            peerID: "ipad-1"
        )
        var countdownStarts: [(CountdownDescriptor, UUID?)] = []
        coordinator.countdownDidStartForTesting = { countdownStarts.append(($0, $1)) }

        transport.controlSendOutcome = .networkSendFailed
        transport.onTransportReady?(BoothDeviceIdentity(id: "ipad-1", displayName: "Guest iPad", role: .iPad))
        #expect(coordinator.stateMachine.phase == .readyToStart)
        let failedAttempt = try #require(transport.messages.compactMap(\.preparedDelivery).last)

        transport.controlSendOutcome = .sent
        transport.onControlMessage?(.customerSessionStartRequest(
            request: CustomerSessionStartRequest(requestID: requestID, selection: nil)
        ))
        #expect(coordinator.stateMachine.phase == .readyToStart)
        #expect(coordinator.stateMachine.currentSessionID == fixture.manifest.id)
        let preparedAttempts = transport.messages.compactMap(\.preparedDelivery)
        #expect(preparedAttempts.count == 2)
        let activeAttempt = try #require(preparedAttempts.last)
        #expect(activeAttempt.deliveryID != failedAttempt.deliveryID)

        transport.onControlMessage?(.sessionSetupApplied(
            context: failedAttempt.context,
            deliveryID: failedAttempt.deliveryID
        ))
        #expect(coordinator.stateMachine.phase == .readyToStart)

        transport.onControlMessage?(.sessionSetupApplied(
            context: activeAttempt.context,
            deliveryID: activeAttempt.deliveryID
        ))
        #expect(coordinator.stateMachine.phase == .countdown(photoIndex: 0, secondsRemaining: 60))
        let countdown = try #require(transport.messages.compactMap(\.countdownDelivery).last)
        #expect(transport.messages.compactMap(\.countdownDelivery).count == 1)
        #expect(countdownStarts.isEmpty)

        transport.onControlMessage?(.sessionSetupApplied(
            context: activeAttempt.context,
            deliveryID: activeAttempt.deliveryID
        ))
        transport.onControlMessage?(.countdownInstalled(
            context: countdown.context,
            deliveryID: UUID(),
            descriptor: countdown.descriptor
        ))
        #expect(countdownStarts.isEmpty)

        transport.onControlMessage?(.countdownInstalled(
            context: countdown.context,
            deliveryID: countdown.deliveryID,
            descriptor: countdown.descriptor
        ))
        #expect(countdownStarts.count == 1)
        #expect(countdownStarts[0].1 == countdown.deliveryID)
        transport.onControlMessage?(.countdownInstalled(
            context: countdown.context,
            deliveryID: countdown.deliveryID,
            descriptor: countdown.descriptor
        ))
        #expect(countdownStarts.count == 1)
    }

    @Test("external-display-only startup begins locally without iPad receipts")
    @MainActor
    func externalDisplayOnlyDoesNotWaitForIPad() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = StartupReceiptTestTransport()
        let coordinator = fixture.makeCoordinator(transport: transport)
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: UUID(),
            authority: .externalDisplayOnly,
            peerID: nil
        )
        var countdownStarts: [(CountdownDescriptor, UUID?)] = []
        coordinator.countdownDidStartForTesting = { countdownStarts.append(($0, $1)) }

        coordinator.resumeStartupForTesting()

        #expect(coordinator.stateMachine.phase == .countdown(photoIndex: 0, secondsRemaining: 60))
        #expect(countdownStarts.count == 1)
        #expect(countdownStarts[0].1 == nil)
        #expect(transport.messages.compactMap(\.preparedDelivery).isEmpty)
        #expect(transport.messages.compactMap(\.countdownDelivery).isEmpty)
    }

    @Test("setup receipt from a cancelled session cannot start countdown")
    @MainActor
    func cancelledStartupIgnoresLateSetupReceipt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.manifestStore.create(fixture.manifest)
        let transport = StartupReceiptTestTransport()
        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus)
        let coordinator = fixture.makeCoordinator(transport: transport)
        let requestID = UUID()
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: requestID,
            authority: .iPadOnly,
            peerID: "ipad-1"
        )
        coordinator.resumeStartupForTesting()
        let pending = try #require(transport.messages.compactMap(\.preparedDelivery).last)

        await coordinator.cancelSessionForTesting(manifest: fixture.manifest)
        transport.onControlMessage?(.sessionSetupApplied(context: pending.context, deliveryID: pending.deliveryID))

        #expect(coordinator.stateMachine.phase == .readyToStart)
        #expect(coordinator.stateMachine.currentSessionID == fixture.manifest.id)
        #expect(transport.messages.compactMap(\.countdownDelivery).isEmpty)
    }

    @Test("a countdown lost during reconnect is replaced; the old receipt cannot authorize capture")
    @MainActor
    func reconnectReplacesUnconfirmedCountdown() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = StartupReceiptTestTransport()
        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus)
        let coordinator = fixture.makeCoordinator(transport: transport)
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: UUID(),
            authority: .iPadOnly,
            peerID: "ipad-1"
        )
        var countdownStarts: [UUID?] = []
        coordinator.countdownDidStartForTesting = { _, deliveryID in countdownStarts.append(deliveryID) }
        coordinator.resumeStartupForTesting()
        let setup = try #require(transport.messages.compactMap(\.preparedDelivery).last)
        transport.onControlMessage?(.sessionSetupApplied(context: setup.context, deliveryID: setup.deliveryID))
        let firstCountdown = try #require(transport.messages.compactMap(\.countdownDelivery).last)
        #expect(countdownStarts.isEmpty)

        transport.connectionStatus.publish(
            requestedNetwork: .lan,
            state: .disconnected,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .disconnected,
            effectiveNetwork: .unavailable,
            isPreviewChannelConnected: false
        )
        transport.connectionStatus.publishPairing(
            authenticated: false,
            state: .idle
        )
        transport.connectionStatus.publishSecureChannel(ready: false)
        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus)
        transport.onTransportReady?(BoothDeviceIdentity(id: "ipad-1", displayName: "Guest iPad", role: .iPad))
        let secondCountdown = try #require(transport.messages.compactMap(\.countdownDelivery).last)
        #expect(secondCountdown.deliveryID != firstCountdown.deliveryID)
        #expect(secondCountdown.descriptor.captureAt > firstCountdown.descriptor.captureAt)
        let synchronized = try #require(transport.messages.compactMap(\.sessionSyncSnapshot).last)
        #expect(synchronized.sessionID == fixture.manifest.id)
        #expect(synchronized.config == fixture.manifest.eventConfig)
        let syncIndex = try #require(transport.messages.firstIndex(where: { $0.sessionSyncSnapshot != nil }))
        let countdownIndex = try #require(transport.messages.firstIndex(where: {
            $0.countdownDelivery?.deliveryID == secondCountdown.deliveryID
        }))
        #expect(syncIndex < countdownIndex)

        transport.onControlMessage?(.countdownInstalled(
            context: firstCountdown.context,
            deliveryID: firstCountdown.deliveryID,
            descriptor: firstCountdown.descriptor
        ))
        #expect(countdownStarts.isEmpty)
        transport.onControlMessage?(.countdownInstalled(
            context: secondCountdown.context,
            deliveryID: secondCountdown.deliveryID,
            descriptor: secondCountdown.descriptor
        ))
        #expect(countdownStarts == [secondCountdown.deliveryID])
    }

    @Test("late countdown receipts consume the bounded restart budget")
    @MainActor
    func lateCountdownReceiptsCannotRestartForever() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = StartupReceiptTestTransport()
        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus)
        let coordinator = fixture.makeCoordinator(transport: transport)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        coordinator.dateProviderForTesting = { now }
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: UUID(),
            authority: .iPadOnly,
            peerID: "ipad-1"
        )
        coordinator.resumeStartupForTesting()
        let setup = try #require(transport.messages.compactMap(\.preparedDelivery).last)
        transport.onControlMessage?(.sessionSetupApplied(
            context: setup.context,
            deliveryID: setup.deliveryID
        ))

        for expectedAttemptCount in 1...3 {
            let delivery = try #require(transport.messages.compactMap(\.countdownDelivery).last)
            now = delivery.descriptor.captureAt
            transport.onControlMessage?(.countdownInstalled(
                context: delivery.context,
                deliveryID: delivery.deliveryID,
                descriptor: delivery.descriptor
            ))
            #expect(transport.messages.compactMap(\.countdownDelivery).count
                == min(expectedAttemptCount + 1, 3))
            if expectedAttemptCount < 3 {
                #expect(coordinator.stateMachine.phase == .countdown(photoIndex: 0, secondsRemaining: 60))
            }
        }

        #expect(transport.messages.compactMap(\.countdownDelivery).count == 3)
        #expect(coordinator.stateMachine.phase == .countdown(photoIndex: 0, secondsRemaining: 60))
        #expect(coordinator.errorMessage == "The iPad is not keeping up with the countdown. Reconnect it to continue safely.")
    }

    @Test("recovered setup binds the authenticated preferred iPad when it reconnects later")
    @MainActor
    func recoveredStartupBindsPeerAfterOfflineRecovery() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = StartupReceiptTestTransport()
        let coordinator = fixture.makeCoordinator(transport: transport)
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: UUID(),
            authority: .iPadOnly,
            peerID: nil
        )

        coordinator.resumeStartupForTesting()
        #expect(transport.messages.compactMap(\.preparedDelivery).isEmpty)

        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus)
        transport.onTransportReady?(BoothDeviceIdentity(id: "ipad-1", displayName: "Guest iPad", role: .iPad))
        let setup = try #require(transport.messages.compactMap(\.preparedDelivery).last)
        transport.onControlMessage?(.sessionSetupApplied(context: setup.context, deliveryID: setup.deliveryID))

        #expect(transport.messages.compactMap(\.countdownDelivery).count == 1)
    }

    @Test("startup stays bound to the original iPad and explains a peer mismatch")
    @MainActor
    func startupPeerMismatchIsRecoverableAndVisible() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = StartupReceiptTestTransport()
        publishAuthenticatedPeer("ipad-1", to: transport.connectionStatus)
        let coordinator = fixture.makeCoordinator(transport: transport)
        coordinator.prepareStartupForTesting(
            manifest: fixture.manifest,
            presentation: fixture.presentation,
            requestID: UUID(),
            authority: .iPadOnly,
            peerID: "ipad-1"
        )
        coordinator.resumeStartupForTesting()
        let originalAttemptCount = transport.messages.compactMap(\.preparedDelivery).count
        publishAuthenticatedPeer("ipad-2", to: transport.connectionStatus)
        transport.onTransportReady?(BoothDeviceIdentity(id: "ipad-2", displayName: "Other iPad", role: .iPad))

        #expect(transport.messages.compactMap(\.preparedDelivery).count == originalAttemptCount)
        #expect(coordinator.stateMachine.phase == .readyToStart)
        #expect(coordinator.errorMessage == "This session is waiting for the iPad that started it. Reconnect that iPad or cancel the session.")
    }

    @MainActor
    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PRC-Startup-\(UUID().uuidString)", isDirectory: true)
        let runtime = root.appendingPathComponent("Runtime", isDirectory: true)
        let output = root.appendingPathComponent("Output", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let config = EventConfig(eventID: "event-1", eventName: "Startup test", photoCount: 1, countdownSeconds: 60)
        let sessionID = UUID().uuidString
        let manifest = SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            id: sessionID,
            eventID: config.eventID,
            eventName: config.eventName,
            eventConfig: config,
            startedAt: Date(),
            completedAt: nil,
            cancelledAt: nil,
            status: .capturing,
            nextPhotoIndex: 0,
            outputRootPath: output.path,
            relativeDirectoryPath: "Startup test/\(sessionID)",
            absoluteDirectoryPath: output.appendingPathComponent("Startup test/\(sessionID)").path,
            frameSnapshotFileName: nil,
            stripFileName: nil,
            gifFileName: nil,
            downloadToken: UUID().uuidString,
            shots: [],
            lastError: nil,
            updatedAt: Date()
        )
        let presentation = SessionPresentation(
            sessionID: sessionID,
            language: .english,
            templateDisplayName: "Default",
            filterID: .original,
            prompts: []
        )
        let manifestStore = SessionManifestStore(baseDirectory: runtime)
        let jobStore = JobQueueStore(fileURL: root.appendingPathComponent("jobs.json"))
        let jobQueue = SessionJobQueue(store: jobStore, executor: StartupReceiptTestExecutor())
        let dataStore = DataStore.inMemoryForTesting()
        return Fixture(
            root: root,
            manifestStore: manifestStore,
            jobQueue: jobQueue,
            dataStore: dataStore,
            manifest: manifest,
            presentation: presentation
        )
    }
}

@MainActor
private struct Fixture {
    let root: URL
    let manifestStore: SessionManifestStore
    let jobQueue: SessionJobQueue
    let dataStore: DataStore
    let manifest: SessionManifest
    let presentation: SessionPresentation

    func makeCoordinator(transport: StartupReceiptTestTransport) -> BoothCoordinator {
        BoothCoordinator(
            testingManifestStore: manifestStore,
            testingJobQueue: jobQueue,
            runtimeDirectory: root.appendingPathComponent("Runtime", isDirectory: true),
            testingDataStore: dataStore,
            testingOutputDirectory: root.appendingPathComponent("Output", isDirectory: true),
            testingTransport: transport
        )
    }
}

@MainActor
private final class StartupReceiptTestTransport: BoothTransport {
    let connectionStatus = BoothConnectionStatus(requestedNetwork: .lan)
    let role = DeviceRole.mac
    var activePeerName: String?
    var onControlMessage: (@MainActor (Message) -> Void)?
    var onPreviewFrame: (@MainActor (Data) -> Void)?
    var onAssetChunk: (@MainActor (BoothAssetChunk) -> Void)?
    var onTransportEvent: (@MainActor (BoothTransportDiagnosticEvent) -> Void)?
    var onTransportReady: (@MainActor (BoothDeviceIdentity) -> Void)?
    var messages: [Message] = []
    var controlSendOutcome: BoothControlSendOutcome = .sent

    var connectionState: BoothConnectionState { connectionStatus.state }
    var peerName: String { connectionStatus.peerDisplayName ?? "" }
    var connectedPeerNames: [String] { connectionStatus.connectedPeerNames }
    var requestedNetworkPreference: BoothNetworkPreference {
        get { connectionStatus.requestedNetwork }
        set { }
    }

    func start() { }
    func restart() { }
    func sendControl(_ message: Message) -> BoothControlSendOutcome {
        messages.append(message)
        return controlSendOutcome
    }
    func sendControl(_ message: Message, completion: @escaping @MainActor (BoothControlSendOutcome) -> Void) {
        messages.append(message)
        completion(controlSendOutcome)
    }
    func sendPreviewFrame(_ jpegData: Data) { }
    func recycleAssetChannel() { }
    func disconnect() { connectionStatus.publishDisconnected() }
}

@MainActor
private final class StartupReceiptTestExecutor: SessionJobExecuting {
    func execute(_ job: SessionJob) async throws { }
}

private extension Message {
    var sessionSyncSnapshot: SessionSyncSnapshot? {
        guard case .sessionSync(let snapshot) = self else { return nil }
        return snapshot
    }

    var preparedDelivery: (context: SessionMessageContext, deliveryID: UUID)? {
        guard case .sessionPrepared(_, _, let context, let deliveryID) = self else { return nil }
        return (context, deliveryID)
    }

    var countdownDelivery: (context: SessionMessageContext, deliveryID: UUID, descriptor: CountdownDescriptor)? {
        guard case .beginCountdown(let context, let deliveryID, let descriptor) = self else { return nil }
        return (context, deliveryID, descriptor)
    }
}

@MainActor
private func publishAuthenticatedPeer(
    _ peerID: String,
    to status: BoothConnectionStatus,
    previewReady: Bool = true
) {
    status.publish(
        requestedNetwork: .lan,
        state: .connected(peerName: "Guest iPad"),
        peerID: peerID,
        peerDisplayName: "Guest iPad",
        routeState: .connectedLAN(peer: "Guest iPad"),
        effectiveNetwork: .lan,
        isPreviewChannelConnected: previewReady
    )
    status.publishPairing(
        trustedPeerIDs: [peerID],
        preferredPeerID: peerID,
        updatePreferredPeer: true,
        authenticated: true,
        state: .authenticated(peerID: peerID)
    )
    status.publishSecureChannel(ready: true)
}
