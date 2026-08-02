import Foundation

public enum BoothPhase: Equatable, Sendable {
    case idle
    case readyToStart
    case countdown(photoIndex: Int, secondsRemaining: Int)
    case captured(photoIndex: Int)
    case review(photoIndex: Int)
    case processing
    case finished(qrPayload: String)

    public var displayName: String {
        switch self {
        case .idle:             return "Idle"
        case .readyToStart:     return "Ready"
        case .countdown(let i, let s): return "Countdown [\(i+1)] \(s)s"
        case .captured(let i):  return "Captured [\(i+1)]"
        case .review(let i):    return "Review [\(i+1)]"
        case .processing:       return "Processing"
        case .finished:         return "Finished"
        }
    }
}
