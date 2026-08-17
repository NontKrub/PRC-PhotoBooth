import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Capture recovery")
struct CaptureRecoveryTests {
    @Test("capture failure enters recovery and deferred photo returns after normal photos")
    @MainActor
    func deferredPhotoReturns() {
        let sm = SessionStateMachine()
        let config = EventConfig(photoCount: 4, countdownSeconds: 3)
        sm.startSession(config: config)

        sm.beginCountdown(photoIndex: 0)
        sm.enterReview(photoIndex: 0, thumbnailData: Data([0]))
        sm.keepShot(photoIndex: 0)
        let failure = CaptureFailureSummary(
            photoIndex: 1,
            reason: .transferTimeout,
            message: "We couldn't receive this photo.",
            shutterLikelyFired: true,
            canRetryReceive: true,
            canUsePreviousPhoto: false,
            canContinueSession: true
        )
        sm.enterCaptureRecovery(photoIndex: 1, failure: failure)

        #expect(CustomerDisplayWorkflow.screen(for: sm.phase) == .captureRecovery(photoIndex: 1, failure: failure))
        #expect(sm.continueAfterCaptureFailure(photoIndex: 1) == 2)
        sm.enterReview(photoIndex: 2, thumbnailData: Data([2]))
        sm.keepShot(photoIndex: 2)
        sm.enterReview(photoIndex: 3, thumbnailData: Data([3]))
        sm.keepShot(photoIndex: 3)

        if case .countdown(let index, _) = sm.phase {
            #expect(index == 1)
        } else {
            Issue.record("Deferred photo should return before processing")
        }
    }

    @Test("previous capture stays available after failed replacement")
    @MainActor
    func previousCaptureCanBeRestored() {
        let sm = SessionStateMachine()
        sm.startSession(config: EventConfig(photoCount: 2, countdownSeconds: 3))
        sm.beginCountdown(photoIndex: 0)
        sm.enterReview(photoIndex: 0, thumbnailData: Data([1]))
        sm.retakeShot(photoIndex: 0)
        let failure = CaptureFailureSummary(
            photoIndex: 0,
            reason: .decodeFailed,
            message: "We couldn't receive this photo.",
            shutterLikelyFired: true,
            canRetryReceive: true,
            canUsePreviousPhoto: true,
            canContinueSession: false
        )
        sm.enterCaptureRecovery(photoIndex: 0, failure: failure)
        sm.usePreviousCapture(photoIndex: 0, thumbnailData: Data([1]))

        #expect(sm.acceptedPhotoIndices.contains(0))
        #expect(sm.keptShots[0] == Data([1]))
        if case .countdown(let index, _) = sm.phase {
            #expect(index == 1)
        } else {
            Issue.record("Restored previous photo should advance session")
        }
    }

    @Test("late attempt completion cannot finish newer capture")
    func lateAttemptIsIgnored() {
        var gate = CaptureAttemptGate()
        let first = CaptureAttempt(id: UUID(), startedAt: Date(timeIntervalSince1970: 1))
        let second = CaptureAttempt(id: UUID(), startedAt: Date(timeIntervalSince1970: 2))

        gate.begin(first)
        gate.begin(second)
        #expect(!gate.isCurrent(first.id))
        #expect(gate.isCurrent(second.id))
        gate.finish(first.id)
        #expect(gate.isCurrent(second.id))
        gate.finish(second.id)
        #expect(!gate.isCurrent(second.id))
    }
}
