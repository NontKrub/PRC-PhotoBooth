import Testing

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
}
