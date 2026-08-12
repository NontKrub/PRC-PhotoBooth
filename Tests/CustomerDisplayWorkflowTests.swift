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
}
