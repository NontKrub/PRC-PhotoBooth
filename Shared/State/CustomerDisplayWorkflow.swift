import Foundation

public enum CustomerDisplayScreen: Equatable, Sendable {
    case idle
    case selectingExperience
    case readyToStart
    case countdown(photoIndex: Int, secondsRemaining: Int)
    case processing
    case review(photoIndex: Int)
    case finished
}

public enum CustomerDisplayAction: Equatable, Sendable {
    case begin
    case confirmSelection
    case start
    case keep(photoIndex: Int)
    case retake(photoIndex: Int)
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
