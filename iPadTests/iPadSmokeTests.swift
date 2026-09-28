import Combine
import CryptoKit
import SwiftUI
import UIKit
import Testing

@testable import PRC_PhotoBooth_iPad

private let iPadTestAuthorityEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!

@Suite("iPad smoke tests")
struct iPadSmokeTests {
    @Test("connection log includes actionable state and redacts secrets")
    @MainActor
    func connectionLogIsSafeAndActionable() {
        let status = BoothConnectionStatus(requestedNetwork: .lan)
        status.publish(
            requestedNetwork: .lan,
            state: .connecting,
            peerID: "mac-1",
            peerDisplayName: "Operator Mac",
            routeState: .connectingLAN,
            effectiveNetwork: .unavailable,
            fallbackReason: "Ethernet unavailable",
            isLANPathAvailable: false,
            isWiFiPathAvailable: true,
            lanPathObservation: .unavailable,
            wifiPathObservation: .available,
            lanHandshake: .timeout,
            lastNetworkError: "Authorization: Bearer do-not-export"
        )
        status.publishPairing(
            trustedPeerIDs: ["mac-1"],
            preferredPeerID: "mac-1",
            updatePreferredPeer: true,
            authenticated: false,
            state: .failed("Pairing timed out"),
            stage: .failed
        )

        let event = BoothTransportDiagnosticEvent(
            kind: .browserFailed,
            timestamp: Date(timeIntervalSince1970: 0),
            reason: "token=do-not-export"
        )
        let redactedEvent = BoothConnectionDiagnosticsReport.redacted(event)
        #expect(redactedEvent.reason == "[redacted]")

        let report = BoothConnectionDiagnosticsReport.make(
            appVersion: "1.4.2",
            appBuild: "6",
            operatingSystem: "iPadOS test",
            deviceName: "Booth iPad",
            status: status,
            discoveryDiagnostics: BoothDiscoveryDiagnostics(
                generation: 7,
                activeBrowserCount: 1,
                discoveredPeerCount: 2,
                targetPeerID: "mac-1",
                targetCandidateAvailable: false,
                targetCandidateSource: nil,
                controlConnectionState: "preparing",
                controlConnectionGeneration: 3,
                helloSent: true,
                helloReceived: false,
                authenticated: false,
                secureChannelReady: false,
                previewReady: false,
                assetReady: false
            ),
            recentEvents: [redactedEvent]
        )

        for line in [
            "PRC PhotoBooth Connection Log",
            "Version: 1.4.2",
            "Requested: LAN",
            "Fallback: Ethernet unavailable",
            "Pairing stage: failed",
            "Discovery",
            "Generation: 7",
            "browserFailed"
        ] {
            #expect(report.contains(line))
        }
        #expect(!report.contains("do-not-export"))
        #expect(report.contains("[redacted]"))
    }

    @Test("view model forwards language, session, state, and connection changes")
    @MainActor
    func observationForwarding() {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }

        var changeCount = 0
        let cancellable = viewModel.objectWillChange.sink { _ in changeCount += 1 }
        viewModel.selectedLanguage = .thai
        viewModel.sessionPresentation = SessionPresentation(
            sessionID: "session-1",
            language: .thai,
            templateDisplayName: "Test",
            filterID: .original,
            prompts: []
        )
        viewModel.stateMachine.beginSelectingExperience()
        viewModel.multipeer.connectionStatus.publish(
            requestedNetwork: .wifi,
            state: .connecting,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .connectingWiFi,
            effectiveNetwork: .unavailable
        )

        _ = cancellable
        #expect(viewModel.selectedLanguage == .thai)
        #expect(viewModel.sessionPresentation?.sessionID == "session-1")
        #expect(viewModel.stateMachine.phase == .selectingExperience)
        #expect(changeCount >= 4)
    }

    @Test("authoritative sync baseline rejects stale session messages")
    @MainActor
    func authoritativeSyncRejectsStaleMessages() {
        var gate = SessionMessageGate(currentSessionID: "old", latestAcceptedSequence: 20)
        gate.synchronize(sessionID: "current", sequence: 4, authorityEpoch: iPadTestAuthorityEpoch)

        let staleSession = gate.accept(SessionMessageContext(sessionID: "old", sequence: 21, authorityEpoch: iPadTestAuthorityEpoch))
        let duplicate = gate.accept(SessionMessageContext(sessionID: "current", sequence: 4, authorityEpoch: iPadTestAuthorityEpoch))
        let current = gate.accept(SessionMessageContext(sessionID: "current", sequence: 5, authorityEpoch: iPadTestAuthorityEpoch))
        #expect(!staleSession)
        #expect(!duplicate)
        #expect(current)

        let stateMachine = SessionStateMachine()
        stateMachine.applyAuthoritativeSnapshot(
            sessionID: "current",
            config: EventConfig(photoCount: 1),
            phase: .readyToStart
        )
        #expect(stateMachine.currentSessionID == "current")
        #expect(stateMachine.phase == .readyToStart)
    }

    @Test("same-session sync rejects stale and duplicate snapshots without side effects")
    @MainActor
    func sameSessionSyncDoesNotRewindMessageGate() {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let config = EventConfig(photoCount: 3)
        let current = SessionSyncSnapshot(
            config: config,
            sessionID: "sync-session",
            phase: .countdown(photoIndex: 2, secondsRemaining: 1),
            presentation: nil,
            isMirrored: true,
            isBoothPaused: true,
            sequence: 20,
            keptShots: [0: Data([0x01])],
            acceptedPhotoIndices: [0],
            deferredPhotoIndices: [1],
            nextPhotoIndex: 2,
            authorityEpoch: iPadTestAuthorityEpoch
        )
        viewModel.multipeer.onControlMessage?(.sessionSync(snapshot: current))

        var stale = current
        stale.sequence = 4
        stale.config = EventConfig(photoCount: 1)
        stale.phase = .idle
        stale.isMirrored = false
        stale.isBoothPaused = false
        stale.keptShots = [:]
        stale.acceptedPhotoIndices = []
        stale.deferredPhotoIndices = []
        stale.nextPhotoIndex = 0
        viewModel.multipeer.onControlMessage?(.sessionSync(snapshot: stale))

        var duplicate = stale
        duplicate.sequence = current.sequence
        viewModel.multipeer.onControlMessage?(.sessionSync(snapshot: duplicate))

        viewModel.multipeer.onControlMessage?(.operatorOverride(
            context: SessionMessageContext(sessionID: "sync-session", sequence: 5, authorityEpoch: iPadTestAuthorityEpoch),
            action: .forceStart
        ))

        #expect(viewModel.eventConfig == current.config)
        #expect(viewModel.stateMachine.phase == current.phase)
        #expect(viewModel.stateMachine.keptShots == current.keptShots)
        #expect(viewModel.stateMachine.acceptedPhotoIndices == Set(current.acceptedPhotoIndices))
        #expect(viewModel.stateMachine.deferredPhotoIndices == Set(current.deferredPhotoIndices))
        #expect(viewModel.stateMachine.nextPhotoIndex == current.nextPhotoIndex)
        #expect(viewModel.isMirrored)
        #expect(viewModel.isBoothPaused)
    }

    @Test("cross-session and idle syncs cannot rewind an authority epoch")
    @MainActor
    func crossSessionSyncDoesNotRewindMessageGate() {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let current = SessionSyncSnapshot(
            config: EventConfig(photoCount: 2),
            sessionID: "session-b",
            phase: .readyToStart,
            presentation: nil,
            isMirrored: true,
            isBoothPaused: true,
            sequence: 100,
            keptShots: [0: Data([0x01])],
            acceptedPhotoIndices: [0],
            deferredPhotoIndices: [1],
            nextPhotoIndex: 1,
            authorityEpoch: iPadTestAuthorityEpoch
        )
        viewModel.multipeer.onControlMessage?(.sessionSync(snapshot: current))

        var staleOldSession = current
        staleOldSession.sessionID = "session-a"
        staleOldSession.sequence = 80
        staleOldSession.phase = .idle
        staleOldSession.keptShots = [:]
        staleOldSession.acceptedPhotoIndices = []
        staleOldSession.deferredPhotoIndices = []
        staleOldSession.nextPhotoIndex = 0
        viewModel.multipeer.onControlMessage?(.sessionSync(snapshot: staleOldSession))

        var staleIdle = staleOldSession
        staleIdle.sessionID = nil
        staleIdle.sequence = 90
        viewModel.multipeer.onControlMessage?(.sessionSync(snapshot: staleIdle))

        #expect(viewModel.eventConfig == current.config)
        #expect(viewModel.stateMachine.phase == current.phase)
        #expect(viewModel.stateMachine.currentSessionID == current.sessionID)
        #expect(viewModel.stateMachine.keptShots == current.keptShots)
        #expect(viewModel.stateMachine.acceptedPhotoIndices == Set(current.acceptedPhotoIndices))
        #expect(viewModel.stateMachine.deferredPhotoIndices == Set(current.deferredPhotoIndices))
        #expect(viewModel.stateMachine.nextPhotoIndex == current.nextPhotoIndex)
        #expect(viewModel.isMirrored)
        #expect(viewModel.isBoothPaused)
    }

    @Test("all customer phases construct with the environment object")
    @MainActor
    func constructsEveryPhase() {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let failure = CaptureFailureSummary(
            photoIndex: 0,
            reason: .transferTimeout,
            message: "Test failure",
            shutterLikelyFired: true,
            canRetryReceive: true,
            canUsePreviousPhoto: true,
            canContinueSession: true
        )
        let phases: [BoothPhase] = [
            .idle,
            .selectingExperience,
            .readyToStart,
            .countdown(photoIndex: 0, secondsRemaining: 3),
            .review(photoIndex: 0),
            .captureRecovery(photoIndex: 0, failure: failure),
            .processing,
            .finished(qrPayload: "https://example.invalid/s/test/")
        ]

        for phase in phases {
            viewModel.stateMachine.applyAuthoritativePhase(phase)
            let host = UIHostingController(
                rootView: iPadContentView().environmentObject(viewModel)
            )
            _ = host.view
            #expect(host.viewIfLoaded != nil)
        }
    }

    @Test("connection settings require authentication and stay locked during a session")
    @MainActor
    func connectionSettingsPolicy() {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }

        #expect(viewModel.canChangeConnection)
        #expect(!viewModel.isConnectionReady)

        viewModel.multipeer.connectionStatus.publish(
            requestedNetwork: .lan,
            state: .connected(peerName: "PRC-Booth-01"),
            peerID: "mac-1",
            peerDisplayName: "PRC-Booth-01",
            routeState: .connectedLAN(peer: "PRC-Booth-01"),
            effectiveNetwork: .lan,
            isPreviewChannelConnected: true
        )
        viewModel.multipeer.connectionStatus.publishPairing(
            trustedPeerIDs: ["mac-1"],
            preferredPeerID: "mac-1",
            updatePreferredPeer: true,
            authenticated: false,
            state: .authenticating(peerID: "mac-1")
        )
        #expect(!viewModel.isConnectionReady)

        viewModel.multipeer.connectionStatus.publishPairing(
            authenticated: true,
            state: .authenticated(peerID: "mac-1")
        )
        viewModel.multipeer.connectionStatus.publishSecureChannel(ready: true)
        viewModel.multipeer.connectionStatus.publishAssetChannel(connected: true, verified: true)
        viewModel.multipeer.connectionStatus.publishControlActivity()
        #expect(viewModel.isAuthoritativeControlReady)
        #expect(viewModel.isConnectionReady)
        viewModel.multipeer.connectionStatus.publishPreviewChannel(connected: false)
        #expect(viewModel.isAuthoritativeControlReady)
        #expect(!viewModel.isBoothFullyReady)
        #expect(!viewModel.isConnectionReady)
        viewModel.multipeer.connectionStatus.publishPreviewChannel(connected: true)
        #expect(viewModel.isConnectionReady)

        viewModel.stateMachine.startSession(config: EventConfig(photoCount: 1))
        #expect(!viewModel.canChangeConnection)
    }

    @Test("foreground recovery restarts only when authoritative control is unhealthy")
    func foregroundRecoveryPolicy() {
        #expect(
            BoothForegroundRecoveryAction.action(
                controlReady: false,
                previewReady: false,
                assetReady: false
            ) == .restartControl
        )
        #expect(
            BoothForegroundRecoveryAction.action(
                controlReady: true,
                previewReady: false,
                assetReady: true
            ) == .waitForSecondaryChannels
        )
        #expect(
            BoothForegroundRecoveryAction.action(
                controlReady: true,
                previewReady: true,
                assetReady: true
            ) == .none
        )
        #expect(BoothAssetRetryPolicy.shouldRetry(after: 0))
        #expect(BoothAssetRetryPolicy.shouldRetry(after: 1))
        #expect(!BoothAssetRetryPolicy.shouldRetry(after: 2))
    }

    @Test("asset pipeline can reset a failed assembly in the current generation")
    func assetPipelineResetsCurrentGeneration() async throws {
        let data = Data(repeating: 0x41, count: 500_000)
        let reference = BoothAssetReference(
            assetID: "prompt-1",
            sessionID: "session-1",
            revision: "revision-1",
            kind: .promptImage,
            byteCount: data.count,
            sha256: Data(SHA256.hash(data: data))
        )
        let chunks = try BoothAssetTransfer.chunks(data: data, reference: reference)
        let pipeline = BoothAssetReceivePipeline()
        await pipeline.reset(to: 4)
        _ = try await pipeline.append(chunks[0], generation: 4)
        await pipeline.resetCurrent(generation: 4)

        var completed: (BoothAssetReference, Data)?
        for chunk in chunks {
            completed = try await pipeline.append(chunk, generation: 4) ?? completed
        }
        #expect(completed?.0 == reference)
        #expect(completed?.1 == data)
    }

    @Test("countdown derives framing from its active photo slot")
    @MainActor
    func countdownUsesActiveSlotFraming() throws {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let config = framingConfig()
        viewModel.eventConfig = config
        viewModel.stateMachine.applyAuthoritativeSnapshot(
            sessionID: "framing",
            config: config,
            phase: .countdown(photoIndex: 0, secondsRemaining: 3)
        )

        let framing = try #require(viewModel.captureFraming(for: 0))
        #expect(abs(framing.aspectRatio - 2.0 / 3.0) < 0.000_001)
    }

    @Test("countdown and retake restore each photo's framing")
    @MainActor
    func countdownAndRetakeUseCurrentPhotoIndex() throws {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let config = framingConfig()
        viewModel.eventConfig = config
        viewModel.stateMachine.startSession(config: config)
        viewModel.stateMachine.beginCountdown(photoIndex: 0)
        let firstRatio = try #require(viewModel.captureFraming(for: 0)).aspectRatio

        viewModel.stateMachine.applyAuthoritativePhase(.countdown(photoIndex: 1, secondsRemaining: 3))
        let secondRatio = try #require(viewModel.captureFraming(for: 1)).aspectRatio
        #expect(abs(firstRatio - 2.0 / 3.0) < 0.000_001)
        #expect(abs(secondRatio - 3.0 / 2.0) < 0.000_001)

        viewModel.stateMachine.applyAuthoritativePhase(.review(photoIndex: 1))
        viewModel.stateMachine.retakeShot(photoIndex: 1)
        #expect(viewModel.stateMachine.phase == .countdown(photoIndex: 1, secondsRemaining: config.countdownSeconds))
        let retakeRatio = try #require(viewModel.captureFraming(for: 1)).aspectRatio
        #expect(abs(retakeRatio - secondRatio) < 0.000_001)
    }

    @Test("countdown view builds when slot framing falls back")
    @MainActor
    func countdownBuildsWithMissingOrInvalidSlot() {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let invalid = EventConfig(
            photoCount: 1,
            canvasWidth: 1200,
            canvasHeight: 1800,
            slots: [SharedPhotoSlot(id: "invalid", normalizedRect: CGRect(x: 0, y: 0, width: 0, height: 1))]
        )
        viewModel.eventConfig = invalid
        viewModel.stateMachine.applyAuthoritativeSnapshot(
            sessionID: "invalid-framing",
            config: invalid,
            phase: .countdown(photoIndex: 0, secondsRemaining: 3)
        )

        #expect(viewModel.captureFraming(for: 0) == nil)
        let host = UIHostingController(
            rootView: CountdownView(photoIndex: 0, secondsRemaining: 3).environmentObject(viewModel)
        )
        _ = host.view
        #expect(host.viewIfLoaded != nil)
    }

    private func framingConfig() -> EventConfig {
        EventConfig(
            photoCount: 2,
            canvasWidth: 1200,
            canvasHeight: 1800,
            slots: [
                SharedPhotoSlot(id: "portrait", normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), photoIndex: 0),
                SharedPhotoSlot(id: "landscape", normalizedRect: CGRect(x: 0, y: 0, width: 0.75, height: 1.0 / 3.0), photoIndex: 1)
            ]
        )
    }
}

@Suite("Asset retry recovery")
struct AssetRetryRecoveryTests {
    private func reference(_ index: Int, sessionID: String = "session") -> BoothAssetReference {
        BoothAssetReference(
            assetID: "asset-\(index)",
            sessionID: sessionID,
            revision: "revision-\(index)",
            kind: .reviewImage,
            byteCount: 1,
            sha256: Data([UInt8(truncatingIfNeeded: index)])
        )
    }

    @Test("retry exhaustion stops requests in the current generation")
    func retryExhaustionStopsRequests() {
        let asset = reference(0)
        var tracker = BoothAssetRetryTracker()

        let initial = tracker.activate(generation: 41, missing: [asset])
        let firstFailureCanRetry = tracker.recordFailure(asset, generation: 41)
        let secondFailureCanRetry = tracker.recordFailure(asset, generation: 41)
        let thirdFailureCanRetry = tracker.recordFailure(asset, generation: 41)
        #expect(initial == .initial)
        #expect(firstFailureCanRetry)
        #expect(secondFailureCanRetry)
        #expect(!thirdFailureCanRetry)
        #expect(!tracker.canRequest(asset))
        #expect(tracker.shouldRecycleCurrentGeneration(asset))
    }

    @Test("fresh asset reconnect restores bounded retry allowance")
    func freshReconnectRestoresRetryAllowance() throws {
        let asset = reference(0)
        var tracker = BoothAssetRetryTracker()
        _ = tracker.activate(generation: 41, missing: [asset])
        _ = tracker.recordFailure(asset, generation: 41)
        _ = tracker.recordFailure(asset, generation: 41)
        _ = tracker.recordFailure(asset, generation: 41)

        let transition = tracker.activate(generation: 42, missing: [asset])
        #expect(transition == .advanced)
        #expect(tracker.canRequest(asset))
        #expect(try #require(tracker.state(for: asset)).recoveryGenerationsUsed == 1)
        tracker.markCompleted(asset)
        #expect(tracker.state(for: asset) == nil)
    }

    @Test("duplicate ready does not reset retry state")
    func duplicateReadyDoesNotReset() throws {
        let asset = reference(0)
        var tracker = BoothAssetRetryTracker()
        _ = tracker.activate(generation: 41, missing: [asset])
        _ = tracker.recordFailure(asset, generation: 41)
        _ = tracker.recordFailure(asset, generation: 41)
        _ = tracker.recordFailure(asset, generation: 41)
        let before = try #require(tracker.state(for: asset))

        let transition = tracker.activate(generation: 41, missing: [asset])
        #expect(transition == .duplicate)
        #expect(tracker.state(for: asset) == before)
        #expect(!tracker.canRequest(asset))
    }

    @Test("stale asset generation cannot replace current recovery state")
    func staleGenerationIsIgnored() throws {
        let asset = reference(0)
        var tracker = BoothAssetRetryTracker()
        _ = tracker.activate(generation: 41, missing: [asset])
        _ = tracker.recordFailure(asset, generation: 41)
        _ = tracker.activate(generation: 42, missing: [asset])
        let current = try #require(tracker.state(for: asset))

        let transition = tracker.activate(generation: 41, missing: [asset])
        #expect(transition == .stale)
        #expect(!tracker.acceptsDisconnect(generation: 41))
        #expect(tracker.state(for: asset) == current)
    }

    @Test("persistent corruption stops after two recovery generations")
    func persistentCorruptionRemainsBounded() throws {
        let asset = reference(0)
        var tracker = BoothAssetRetryTracker()

        for generation in 41...43 {
            _ = tracker.activate(generation: generation, missing: [asset])
            #expect(tracker.canRequest(asset))
            let firstFailureCanRetry = tracker.recordFailure(asset, generation: generation)
            let secondFailureCanRetry = tracker.recordFailure(asset, generation: generation)
            let thirdFailureCanRetry = tracker.recordFailure(asset, generation: generation)
            #expect(firstFailureCanRetry)
            #expect(secondFailureCanRetry)
            #expect(!thirdFailureCanRetry)
        }

        #expect(try #require(tracker.state(for: asset)).recoveryGenerationsUsed == 2)
        #expect(!tracker.canRequest(asset))
        #expect(!tracker.shouldRecycleCurrentGeneration(asset))
        _ = tracker.activate(generation: 44, missing: [asset])
        #expect(!tracker.canRequest(asset))
    }

    @Test("successful asset removes all retry metadata")
    func successRemovesRetryState() {
        let asset = reference(0)
        var tracker = BoothAssetRetryTracker()
        _ = tracker.activate(generation: 41, missing: [asset])
        _ = tracker.recordFailure(asset, generation: 41)
        tracker.markCompleted(asset)

        #expect(tracker.state(for: asset) == nil)
        #expect(tracker.canRequest(asset))
    }

    @Test("session rollover cannot reuse prior session retry state")
    func sessionRolloverClearsRetryState() {
        let oldAsset = reference(0, sessionID: "session-a")
        let newAsset = reference(0, sessionID: "session-b")
        var tracker = BoothAssetRetryTracker()
        _ = tracker.activate(generation: 41, missing: [oldAsset])
        _ = tracker.recordFailure(oldAsset, generation: 41)
        tracker.resetForSession()

        #expect(tracker.state(for: oldAsset) == nil)
        #expect(tracker.currentGeneration == nil)
        #expect(tracker.canRequest(newAsset))
    }

    @Test("customer recovery status uses localized, non-technical copy")
    func recoveryStatusCopyIsCustomerSafe() {
        #expect(
            BoothAssetRecoveryStatus.connectionRecovered.title(for: .english)
                == "Connection recovered. Retrying image."
        )
        #expect(
            BoothAssetRecoveryStatus.reconnectRequired.detail(for: .english)
                == "Reconnect to retry the image."
        )
        #expect(
            BoothAssetRecoveryStatus.operatorRecoveryRequired.detail(for: .thai)
                == "โปรดขอให้เจ้าหน้าที่เริ่มการกู้คืนสำหรับเซสชันนี้อีกครั้ง"
        )
    }

    @Test("a later asset batch preserves earlier response deadlines")
    func laterAssetBatchPreservesEarlierDeadlines() {
        let expected = (0..<9).map { reference($0) }
        var pump = BoothAssetRequestPump(maximumInFlight: 8)
        var registry = BoothAssetResponseDeadlineRegistry()
        let firstBatch = pump.nextBatch(expected: expected, cached: [])
        registry.arm(firstBatch)

        pump.markCompleted(firstBatch[0])
        let laterBatch = pump.nextBatch(expected: expected, cached: [firstBatch[0]])
        registry.cancel(firstBatch[0])
        registry.arm(laterBatch)

        #expect(registry.contains(firstBatch[1]))
        #expect(registry.contains(laterBatch[0]))
        #expect(registry.pending.count == 8)
    }

    @Test("review actions require decoded authoritative media")
    @MainActor
    func reviewActionsRequireAuthoritativeMedia() async {
        let viewModel = iPadViewModel()
        defer { viewModel.multipeer.disconnect() }
        let config = EventConfig(photoCount: 1)

        viewModel.stateMachine.applyAuthoritativeSnapshot(
            sessionID: "review-media",
            config: config,
            phase: .review(photoIndex: 0),
            reviewImageData: nil
        )
        #expect(viewModel.isReviewMediaMissing)
        #expect(!viewModel.isReviewMediaReady)
        #expect(!CustomerDisplayWorkflow.canUseReviewActions(
            in: viewModel.stateMachine.phase,
            reviewMediaReady: viewModel.isReviewMediaReady
        ))

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1))
        let data = renderer.jpegData(withCompressionQuality: 1) { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        viewModel.multipeer.onControlMessage?(
            .sessionSync(snapshot: SessionSyncSnapshot(
                config: config,
                sessionID: "review-media",
                phase: .review(photoIndex: 0),
                presentation: nil,
                reviewThumbnailData: data,
                isMirrored: false,
                authorityEpoch: iPadTestAuthorityEpoch
            ))
        )

        for _ in 0..<200 {
            if viewModel.isReviewMediaReady { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            viewModel.isReviewMediaReady,
            "review image decode failed: \(viewModel.reviewImageDecodeFailed)"
        )
        #expect(CustomerDisplayWorkflow.canUseReviewActions(
            in: viewModel.stateMachine.phase,
            reviewMediaReady: viewModel.isReviewMediaReady
        ))

        let host = UIHostingController(
            rootView: ReviewView(photoIndex: 0).environmentObject(viewModel)
        )
        _ = host.view
        #expect(host.viewIfLoaded != nil)
    }

    @Test("large request pump remains ordered and bounded")
    func thirtyReferencePumpRemainsBounded() {
        let expected = (0..<30).map { reference($0) }
        var pump = BoothAssetRequestPump(maximumInFlight: 8)
        var requested: [BoothAssetReference] = []
        var cached = Set<BoothAssetReference>()

        while requested.count < expected.count {
            let batch = pump.nextBatch(expected: expected, cached: cached)
            requested.append(contentsOf: batch)
            for asset in batch {
                pump.markCompleted(asset)
                cached.insert(asset)
            }
        }

        #expect(requested == expected)
    }
}
