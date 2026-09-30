import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Customer display workflow")
struct CustomerDisplayWorkflowTests {
    @Test("maps shared phases to customer screens")
    func mapsScreens() {
        #expect(CustomerDisplayWorkflow.screen(for: .idle) == .idle)
        #expect(CustomerDisplayWorkflow.screen(for: .selectingExperience) == .selectingExperience)
        #expect(CustomerDisplayWorkflow.screen(for: .captured(photoIndex: 1)) == .processing)
        #expect(CustomerDisplayWorkflow.screen(for: .review(photoIndex: 1)) == .review(photoIndex: 1))
        #expect(CustomerDisplayWorkflow.screen(for: .finished(qrPayload: "qr")) == .finished)
    }

    @Test("allows only actions valid for the current customer phase")
    func gatesActions() {
        #expect(CustomerDisplayWorkflow.canApply(.begin, in: .idle))
        #expect(CustomerDisplayWorkflow.canApply(.confirmSelection, in: .selectingExperience))
        #expect(CustomerDisplayWorkflow.canApply(.start, in: .readyToStart))
        #expect(CustomerDisplayWorkflow.canApply(.keep(photoIndex: 1), in: .review(photoIndex: 1)))
        #expect(!CustomerDisplayWorkflow.canApply(.keep(photoIndex: 0), in: .review(photoIndex: 1)))
        #expect(!CustomerDisplayWorkflow.canApply(.retake(photoIndex: 1), in: .processing))
        #expect(CustomerDisplayWorkflow.canApply(.back, in: .finished(qrPayload: "qr")))

        let failure = CaptureFailureSummary(
            photoIndex: 1,
            reason: .transferTimeout,
            message: "We couldn't receive this photo.",
            shutterLikelyFired: true,
            canRetryReceive: true,
            canUsePreviousPhoto: true,
            canContinueSession: true
        )
        let recovery = BoothPhase.captureRecovery(photoIndex: 1, failure: failure)
        #expect(CustomerDisplayWorkflow.canApply(.retryReceive(photoIndex: 1), in: recovery))
        #expect(CustomerDisplayWorkflow.canApply(.retakeFailedCapture(photoIndex: 1), in: recovery))
        #expect(CustomerDisplayWorkflow.canApply(.continueAfterCaptureFailure(photoIndex: 1), in: recovery))
        #expect(CustomerDisplayWorkflow.canApply(.usePreviousCapture(photoIndex: 1), in: recovery))
        #expect(!CustomerDisplayWorkflow.canApply(.retryReceive(photoIndex: 0), in: recovery))
    }

    @Test("Review actions require the authoritative review media")
    func reviewActionsRequireMedia() {
        #expect(CustomerDisplayWorkflow.canUseReviewActions(
            in: .review(photoIndex: 1),
            reviewMediaReady: true
        ))
        #expect(!CustomerDisplayWorkflow.canUseReviewActions(
            in: .review(photoIndex: 1),
            reviewMediaReady: false
        ))
        #expect(!CustomerDisplayWorkflow.canUseReviewActions(
            in: .processing,
            reviewMediaReady: true
        ))
    }

    @Test("BoothPhase isFinished property accurately matches finished phase")
    func boothPhaseIsFinished() {
        #expect(!BoothPhase.idle.isFinished)
        #expect(!BoothPhase.readyToStart.isFinished)
        #expect(!BoothPhase.processing.isFinished)
        #expect(BoothPhase.finished(qrPayload: "qr").isFinished)
    }

    @Test("evaluates complete customer display authority matrix (Finding A05)")
    func evaluatesAuthorityMatrix() {
        // Neither display active
        let none = CustomerDisplayAuthority.evaluate(
            isAuthenticatedIPadConnected: false,
            isExternalViewerActive: false
        )
        #expect(none == .none)
        #expect(!none.isCustomerDisplayReady)
        #expect(!none.requiresIPadSetupSend)
        #expect(!none.shouldStartCountdownImmediatelyLocally)

        // iPad only
        let ipadOnly = CustomerDisplayAuthority.evaluate(
            isAuthenticatedIPadConnected: true,
            isExternalViewerActive: false
        )
        #expect(ipadOnly == .iPadOnly)
        #expect(ipadOnly.isCustomerDisplayReady)
        #expect(ipadOnly.requiresIPadSetupSend)
        #expect(!ipadOnly.shouldStartCountdownImmediatelyLocally)

        // External viewer only
        let externalOnly = CustomerDisplayAuthority.evaluate(
            isAuthenticatedIPadConnected: false,
            isExternalViewerActive: true
        )
        #expect(externalOnly == .externalDisplayOnly)
        #expect(externalOnly.isCustomerDisplayReady)
        #expect(!externalOnly.requiresIPadSetupSend)
        #expect(externalOnly.shouldStartCountdownImmediatelyLocally)

        // Dual display (both active)
        let dual = CustomerDisplayAuthority.evaluate(
            isAuthenticatedIPadConnected: true,
            isExternalViewerActive: true
        )
        #expect(dual == .dualDisplay)
        #expect(dual.isCustomerDisplayReady)
        #expect(dual.requiresIPadSetupSend)
        #expect(!dual.shouldStartCountdownImmediatelyLocally)
    }

    @Test("ready session setup is replayed only for its current iPad display")
    func readySessionSetupReplayEligibility() {
        #expect(SessionSetupDeliveryPolicy.shouldDeliverSetup(
            phase: .readyToStart,
            sessionID: "session-a",
            stateMachineSessionID: "session-a",
            hasPresentation: true,
            authority: .iPadOnly
        ))
        #expect(SessionSetupDeliveryPolicy.shouldDeliverSetup(
            phase: .readyToStart,
            sessionID: "session-a",
            stateMachineSessionID: "session-a",
            hasPresentation: true,
            authority: .dualDisplay
        ))
        #expect(!SessionSetupDeliveryPolicy.shouldDeliverSetup(
            phase: .readyToStart,
            sessionID: "session-a",
            stateMachineSessionID: "session-a",
            hasPresentation: true,
            authority: .externalDisplayOnly
        ))
        #expect(!SessionSetupDeliveryPolicy.shouldDeliverSetup(
            phase: .countdown(photoIndex: 0, secondsRemaining: 5),
            sessionID: "session-a",
            stateMachineSessionID: "session-a",
            hasPresentation: true,
            authority: .iPadOnly
        ))
        #expect(!SessionSetupDeliveryPolicy.shouldDeliverSetup(
            phase: .readyToStart,
            sessionID: "old-session",
            stateMachineSessionID: "new-session",
            hasPresentation: true,
            authority: .iPadOnly
        ))
    }

    @Test("only a sent setup callback for the current ready session can start countdown")
    func setupCompletionRejectsFailedAndStaleCallbacks() {
        func mayStart(
            outcome: BoothControlSendOutcome = .sent,
            capturedGeneration: UInt64 = 7,
            currentGeneration: UInt64 = 7,
            currentSessionID: String? = "session-a",
            stateMachineSessionID: String = "session-a",
            phase: BoothPhase = .readyToStart,
            isCancelled: Bool = false
        ) -> Bool {
            SessionSetupDeliveryPolicy.shouldBeginCountdown(
                outcome: outcome,
                capturedGeneration: capturedGeneration,
                currentGeneration: currentGeneration,
                expectedSessionID: "session-a",
                currentSessionID: currentSessionID,
                stateMachineSessionID: stateMachineSessionID,
                phase: phase,
                isCancelled: isCancelled
            )
        }

        #expect(mayStart())
        #expect(!mayStart(outcome: .networkSendFailed))
        #expect(!mayStart(capturedGeneration: 6))
        #expect(!mayStart(currentSessionID: "session-b", stateMachineSessionID: "session-b"))
        #expect(!mayStart(stateMachineSessionID: "session-b"))
        #expect(!mayStart(phase: .countdown(photoIndex: 0, secondsRemaining: 5)))
        #expect(!mayStart(isCancelled: true))

        var phase: BoothPhase = .readyToStart
        var countdownStarts = 0
        for _ in 0..<2 where SessionSetupDeliveryPolicy.shouldBeginCountdown(
            outcome: .sent,
            capturedGeneration: 7,
            currentGeneration: 7,
            expectedSessionID: "session-a",
            currentSessionID: "session-a",
            stateMachineSessionID: "session-a",
            phase: phase,
            isCancelled: false
        ) {
            countdownStarts += 1
            phase = .countdown(photoIndex: 0, secondsRemaining: 5)
        }
        #expect(countdownStarts == 1)
    }

    @Test("a duplicate start request reuses its session and resumes only while setup is pending")
    func duplicateStartReusesSession() {
        let requestID = UUID()
        #expect(SessionSetupDeliveryPolicy.duplicateStartDisposition(
            requestID: requestID,
            lastRequestID: requestID,
            lastSessionID: "session-a",
            currentSessionID: "session-a",
            phase: .readyToStart
        ) == .accepted(sessionID: "session-a", resumeSetup: true))
        #expect(SessionSetupDeliveryPolicy.duplicateStartDisposition(
            requestID: requestID,
            lastRequestID: requestID,
            lastSessionID: "session-a",
            currentSessionID: "session-a",
            phase: .countdown(photoIndex: 0, secondsRemaining: 5)
        ) == .accepted(sessionID: "session-a", resumeSetup: false))
        #expect(SessionSetupDeliveryPolicy.duplicateStartDisposition(
            requestID: UUID(),
            lastRequestID: requestID,
            lastSessionID: "session-a",
            currentSessionID: "session-a",
            phase: .readyToStart
        ) == .notDuplicate)
    }
}
