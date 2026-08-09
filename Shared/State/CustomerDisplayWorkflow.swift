import Foundation

public enum CustomerDisplayScreen: Equatable, Sendable {
    case idle
    case selectingExperience
    case readyToStart
    case countdown(photoIndex: Int, secondsRemaining: Int)
    case processing
    case review(photoIndex: Int)
    case captureRecovery(photoIndex: Int, failure: CaptureFailureSummary)
    case finished
}

public enum CustomerDisplayAction: Equatable, Sendable {
    case begin
    case confirmSelection
    case start
    case keep(photoIndex: Int)
    case retake(photoIndex: Int)
    case retryReceive(photoIndex: Int)
    case retakeFailedCapture(photoIndex: Int)
    case continueAfterCaptureFailure(photoIndex: Int)
    case usePreviousCapture(photoIndex: Int)
    case back
}

public enum CustomerDisplayWorkflow {
    public static func screen(for phase: BoothPhase) -> CustomerDisplayScreen {
        switch phase {
        case .idle: return .idle
        case .selectingExperience: return .selectingExperience
        case .readyToStart: return .readyToStart
        case .countdown(let photoIndex, let secondsRemaining):
            return .countdown(photoIndex: photoIndex, secondsRemaining: secondsRemaining)
        case .captured, .processing: return .processing
        case .review(let photoIndex): return .review(photoIndex: photoIndex)
        case .captureRecovery(let photoIndex, let failure):
            return .captureRecovery(photoIndex: photoIndex, failure: failure)
        case .finished: return .finished
        }
    }

    public static func canApply(_ action: CustomerDisplayAction, in phase: BoothPhase) -> Bool {
        switch action {
        case .begin: return phase == .idle
        case .confirmSelection: return phase == .selectingExperience
        case .start: return phase == .readyToStart
        case .keep(let photoIndex), .retake(let photoIndex):
            guard case .review(let currentIndex) = phase else { return false }
            return currentIndex == photoIndex
        case .retryReceive(let photoIndex):
            guard case .captureRecovery(let currentIndex, let failure) = phase else { return false }
            return currentIndex == photoIndex && failure.canRetryReceive
        case .retakeFailedCapture(let photoIndex):
            guard case .captureRecovery(let currentIndex, _) = phase else { return false }
            return currentIndex == photoIndex
        case .continueAfterCaptureFailure(let photoIndex):
            guard case .captureRecovery(let currentIndex, let failure) = phase else { return false }
            return currentIndex == photoIndex && failure.canContinueSession
        case .usePreviousCapture(let photoIndex):
            guard case .captureRecovery(let currentIndex, let failure) = phase else { return false }
            return currentIndex == photoIndex && failure.canUsePreviousPhoto
        case .back:
            return phase == .selectingExperience
                || phase == .readyToStart
                || phase.isFinished
        }
    }
}

private extension BoothPhase {
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
}
