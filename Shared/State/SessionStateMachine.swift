import Foundation
import Observation

@MainActor
@Observable
public final class SessionStateMachine {
    public private(set) var phase: BoothPhase = .idle
    public var config: EventConfig = EventConfig()
    public private(set) var keptShots: [Int: Data] = [:]   // photoIndex → JPEG thumbnail
    public private(set) var acceptedPhotoIndices: Set<Int> = []
    public private(set) var deferredPhotoIndices: Set<Int> = []
    public private(set) var currentSessionID: String = ""
    public private(set) var nextPhotoIndex: Int = 0

    public init() {}

    public func startSession(config: EventConfig, sessionID: String? = nil) {
        self.config = config
        self.keptShots = [:]
        self.acceptedPhotoIndices = []
        self.deferredPhotoIndices = []
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
        self.acceptedPhotoIndices = Set(keptShots.keys)
        self.deferredPhotoIndices = Set((0..<config.photoCount).filter {
            $0 < nextPhotoIndex && !self.acceptedPhotoIndices.contains($0)
        })
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

    public func enterCaptureRecovery(photoIndex: Int, failure: CaptureFailureSummary) {
        phase = .captureRecovery(photoIndex: photoIndex, failure: failure)
    }

    public func keepShot(photoIndex: Int) {
        acceptedPhotoIndices.insert(photoIndex)
        deferredPhotoIndices.remove(photoIndex)
        advanceAfterAcceptance()
    }

    public func retakeShot(photoIndex: Int) {
        keptShots.removeValue(forKey: photoIndex)
        acceptedPhotoIndices.remove(photoIndex)
        deferredPhotoIndices.remove(photoIndex)
        nextPhotoIndex = photoIndex
        phase = .countdown(photoIndex: photoIndex, secondsRemaining: config.countdownSeconds)
    }

    @discardableResult
    public func continueAfterCaptureFailure(photoIndex: Int) -> Int? {
        deferredPhotoIndices.insert(photoIndex)
        guard let next = nextPendingPhoto() else {
            nextPhotoIndex = config.photoCount
            phase = .processing
            return nil
        }
        nextPhotoIndex = next
        return next
    }

    public func usePreviousCapture(photoIndex: Int, thumbnailData: Data) {
        keptShots[photoIndex] = thumbnailData
        acceptedPhotoIndices.insert(photoIndex)
        deferredPhotoIndices.remove(photoIndex)
        advanceAfterAcceptance()
    }

    public func finishSession(qrPayload: String) {
        phase = .finished(qrPayload: qrPayload)
    }

    public func reset() {
        phase = .idle
        keptShots = [:]
        acceptedPhotoIndices = []
        deferredPhotoIndices = []
        currentSessionID = ""
        nextPhotoIndex = 0
    }

    // Direct phase override — used by coordinators to tick countdowns.
    public func transition(to newPhase: BoothPhase) {
        phase = newPhase
    }

    private func advanceAfterAcceptance() {
        guard let next = nextPendingPhoto() else {
            nextPhotoIndex = config.photoCount
            phase = .processing
            return
        }
        nextPhotoIndex = next
        phase = .countdown(photoIndex: next, secondsRemaining: config.countdownSeconds)
    }

    private func nextPendingPhoto() -> Int? {
        if let next = (0..<config.photoCount).first(where: {
            !acceptedPhotoIndices.contains($0) && !deferredPhotoIndices.contains($0)
        }) {
            return next
        }
        return deferredPhotoIndices
            .filter { !acceptedPhotoIndices.contains($0) }
            .sorted()
            .first
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
