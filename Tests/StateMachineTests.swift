import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

@Suite("SessionStateMachine")
@MainActor
struct StateMachineTests {
    @Test("full happy path: 2-photo session")
    func happyPath() async {
        let sm = SessionStateMachine()
        let config = EventConfig(photoCount: 2, countdownSeconds: 3)
        sm.startSession(config: config)
        #expect(sm.phase == .readyToStart)

        sm.beginCountdown(photoIndex: 0)
        if case .countdown(let idx, let secs) = sm.phase {
            #expect(idx == 0); #expect(secs == 3)
        } else { Issue.record("Expected countdown") }

        sm.enterReview(photoIndex: 0, thumbnailData: Data())
        if case .review(let idx) = sm.phase { #expect(idx == 0) }
        else { Issue.record("Expected review") }

        sm.keepShot(photoIndex: 0)
        // Should advance to countdown(1)
        if case .countdown(let idx, _) = sm.phase { #expect(idx == 1) }
        else { Issue.record("Expected countdown for photo 2") }

        sm.enterReview(photoIndex: 1, thumbnailData: Data())
        sm.keepShot(photoIndex: 1)
        #expect(sm.phase == .processing)

        sm.finishSession(qrPayload: "http://test")
        if case .finished(let qr) = sm.phase { #expect(qr == "http://test") }
        else { Issue.record("Expected finished") }
    }

    @Test("retake resets the slot")
    func retake() async {
        let sm = SessionStateMachine()
        sm.startSession(config: EventConfig(photoCount: 1, countdownSeconds: 3))
        sm.enterReview(photoIndex: 0, thumbnailData: Data([0x01]))
        sm.retakeShot(photoIndex: 0)
        if case .countdown(let idx, _) = sm.phase { #expect(idx == 0) }
        else { Issue.record("Expected countdown after retake") }
        #expect(sm.keptShots[0] == nil)
    }

    @Test("session preparation waits for an explicit countdown")
    func sessionPreparationWaitsForCountdown() async {
        let sm = SessionStateMachine()
        sm.startSession(config: EventConfig(photoCount: 1, countdownSeconds: 3))

        #expect(sm.phase == .readyToStart)
    }

    @Test("restored session keeps ID and thumbnails until countdown begins")
    func restoresSession() async {
        let sm = SessionStateMachine()
        let config = EventConfig(photoCount: 3, countdownSeconds: 3)
        let thumbnail = Data([0x01, 0x02])

        sm.restoreSession(
            sessionID: "recovered-session",
            config: config,
            keptShots: [0: thumbnail, 1: Data([0x03])],
            nextPhotoIndex: 2
        )

        #expect(sm.currentSessionID == "recovered-session")
        #expect(sm.keptShots[0] == thumbnail)
        #expect(sm.phase == .readyToStart)

        sm.beginCountdown(photoIndex: 2)
        if case .countdown(let index, let seconds) = sm.phase {
            #expect(index == 2)
            #expect(seconds == 3)
        } else {
            Issue.record("Expected restored session countdown")
        }
    }

    @Test("operator cancel returns to idle")
    func operatorCancel() async {
        let sm = SessionStateMachine()
        sm.startSession(config: EventConfig(photoCount: 2, countdownSeconds: 3))
        sm.operatorOverride(.cancelSession)
        #expect(sm.phase == .idle)
    }
}
