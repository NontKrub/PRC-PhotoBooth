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
        sm.beginCountdown(photoIndex: 0)
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

    @Test("illegal runtime events do not mutate the phase")
    func rejectsIllegalEvents() {
        let sm = SessionStateMachine()
        sm.enterReview(photoIndex: 0, thumbnailData: Data([1]))
        #expect(sm.phase == .idle)

        sm.startSession(config: EventConfig(photoCount: 1, countdownSeconds: 5))
        sm.beginCountdown(photoIndex: 0)
        sm.enterReview(photoIndex: 0, thumbnailData: Data([1]))
        sm.keepShot(photoIndex: 2)
        #expect(sm.phase == .review(photoIndex: 0))
        sm.keepShot(photoIndex: 0)
        #expect(sm.phase == .processing)
        sm.beginCountdown(photoIndex: 0)
        #expect(sm.phase == .processing)
    }

    @Test("authoritative restore can reconstruct a remote phase")
    func authoritativeRestore() {
        let sm = SessionStateMachine()
        let config = EventConfig(photoCount: 2, countdownSeconds: 5)
        let deadline = Date(timeIntervalSince1970: 1_700_000_005)
        sm.applyAuthoritativeSnapshot(
            sessionID: "remote-session",
            config: config,
            phase: .countdown(photoIndex: 1, secondsRemaining: 3),
            keptShots: [0: Data([1])],
            nextPhotoIndex: 1,
            countdownDeadline: deadline
        )
        #expect(sm.currentSessionID == "remote-session")
        #expect(sm.keptShots[0] == Data([1]))
        #expect(sm.phase == .countdown(photoIndex: 1, secondsRemaining: 3))
        #expect(sm.countdownDeadline == deadline)
    }

    @Test("countdown remaining is derived from an absolute deadline")
    func countdownDeadline() {
        let sm = SessionStateMachine()
        let config = EventConfig(photoCount: 1, countdownSeconds: 5)
        sm.startSession(config: config)
        let deadline = Date(timeIntervalSince1970: 1_700_000_005)
        sm.beginCountdown(photoIndex: 0, captureAt: deadline)
        sm.updateCountdown(at: Date(timeIntervalSince1970: 1_700_000_002.2))
        #expect(sm.phase == .countdown(photoIndex: 0, secondsRemaining: 3))
        sm.updateCountdown(at: Date(timeIntervalSince1970: 1_700_000_005.1))
        #expect(sm.phase == .countdown(photoIndex: 0, secondsRemaining: 0))
    }

    @Test("every photo in a three-photo session gets the configured countdown")
    func repeatedCountdownsUseSameDuration() {
        let sm = SessionStateMachine()
        let config = EventConfig(photoCount: 3, countdownSeconds: 5)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        sm.startSession(config: config)

        for index in 0..<config.photoCount {
            let deadline = start.addingTimeInterval(5)
            sm.beginCountdown(photoIndex: index, captureAt: deadline)
            #expect(sm.countdownDeadline == deadline)
            sm.enterReview(photoIndex: index, thumbnailData: Data([UInt8(index)]))
            sm.keepShot(photoIndex: index)
        }

        #expect(sm.phase == .processing)
    }
}
