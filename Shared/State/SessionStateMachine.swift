import Foundation
import Observation

@MainActor
@Observable
public final class SessionStateMachine {
    public private(set) var phase: BoothPhase = .idle
    public var config: EventConfig = EventConfig()
    public private(set) var keptShots: [Int: Data] = [:]   // photoIndex → JPEG thumbnail
    public private(set) var currentSessionID: String = ""
    public private(set) var nextPhotoIndex: Int = 0

    public init() {}

    public func startSession(config: EventConfig, sessionID: String? = nil) {
        self.config = config
        self.keptShots = [:]
        self.currentSessionID = sessionID ?? UUID().uuidString
        self.nextPhotoIndex = 0
        phase = .readyToStart
    }

    public func restoreSession(
        sessionID: String,
        config: EventConfig,
        keptShots: [Int: Data],
        nextPhotoIndex: Int
    ) {
        self.config = config
        self.currentSessionID = sessionID
        self.keptShots = keptShots
        self.nextPhotoIndex = nextPhotoIndex
        phase = .readyToStart
    }

    public func beginCountdown(photoIndex: Int) {
        nextPhotoIndex = photoIndex
        phase = .countdown(photoIndex: photoIndex, secondsRemaining: config.countdownSeconds)
    }

    public func tickCountdown() {
        guard case .countdown(let idx, let remaining) = phase else { return }
        if remaining > 1 {
            phase = .countdown(photoIndex: idx, secondsRemaining: remaining - 1)
        } else {
            phase = .captured(photoIndex: idx)
        }
    }

    public func enterReview(photoIndex: Int, thumbnailData: Data) {
        keptShots[photoIndex] = thumbnailData
        phase = .review(photoIndex: photoIndex)
    }

    public func keepShot(photoIndex: Int) {
        let next = photoIndex + 1
        nextPhotoIndex = next
        if next < config.photoCount {
            phase = .countdown(photoIndex: next, secondsRemaining: config.countdownSeconds)
        } else {
            phase = .processing
        }
    }

    public func retakeShot(photoIndex: Int) {
        keptShots.removeValue(forKey: photoIndex)
        nextPhotoIndex = photoIndex
        phase = .countdown(photoIndex: photoIndex, secondsRemaining: config.countdownSeconds)
    }

    public func finishSession(qrPayload: String) {
        phase = .finished(qrPayload: qrPayload)
    }

    public func reset() {
        phase = .idle
        keptShots = [:]
        currentSessionID = ""
        nextPhotoIndex = 0
    }

    // Direct phase override — used by coordinators to tick countdowns.
    public func transition(to newPhase: BoothPhase) {
        phase = newPhase
    }

    public func operatorOverride(_ action: OperatorAction) {
        switch action {
        case .forceStart:
            if phase == .idle || phase == .readyToStart {
                beginCountdown(photoIndex: 0)
            }
        case .forceRetake:
            if case .review(let idx) = phase { retakeShot(photoIndex: idx) }
        case .skip:
            if case .review(let idx) = phase { keepShot(photoIndex: idx) }
        case .cancelSession:
            reset()
        }
    }
}
