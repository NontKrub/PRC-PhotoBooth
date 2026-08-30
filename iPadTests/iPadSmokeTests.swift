import Combine
import SwiftUI
import UIKit
import Testing

@testable import PRC_PhotoBooth_iPad

@Suite("iPad smoke tests")
struct iPadSmokeTests {
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
        gate.synchronize(sessionID: "current", sequence: 4)

        let staleSession = gate.accept(SessionMessageContext(sessionID: "old", sequence: 21))
        let duplicate = gate.accept(SessionMessageContext(sessionID: "current", sequence: 4))
        let current = gate.accept(SessionMessageContext(sessionID: "current", sequence: 5))
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
        #expect(viewModel.isConnectionReady)
        viewModel.multipeer.connectionStatus.publishPreviewChannel(connected: false)
        #expect(!viewModel.isConnectionReady)
        viewModel.multipeer.connectionStatus.publishPreviewChannel(connected: true)
        #expect(viewModel.isConnectionReady)

        viewModel.stateMachine.startSession(config: EventConfig(photoCount: 1))
        #expect(!viewModel.canChangeConnection)
    }
}
