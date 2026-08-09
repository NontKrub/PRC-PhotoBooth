import Foundation

public enum BoothPhase: Codable, Equatable, Sendable {
    case idle
    case selectingExperience
    case readyToStart
    case countdown(photoIndex: Int, secondsRemaining: Int)
    case captured(photoIndex: Int)
    case review(photoIndex: Int)
    case captureRecovery(photoIndex: Int, failure: CaptureFailureSummary)
    case processing
    case finished(qrPayload: String)

    public var displayName: String {
        switch self {
        case .idle:             return "Idle"
        case .selectingExperience: return "Selecting experience"
        case .readyToStart:     return "Ready"
        case .countdown(let i, let s): return "Countdown [\(i+1)] \(s)s"
        case .captured(let i):  return "Captured [\(i+1)]"
        case .review(let i):    return "Review [\(i+1)]"
        case .captureRecovery(let i, _): return "Capture recovery [\(i+1)]"
        case .processing:       return "Processing"
        case .finished:         return "Finished"
        }
    }
}

extension BoothPhase {
    private enum CodingKeys: String, CodingKey {
        case kind, photoIndex, secondsRemaining, failure, qrPayload
    }

    private enum Kind: String, Codable {
        case idle, selectingExperience, readyToStart, countdown, captured, review, captureRecovery, processing, finished
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .idle: self = .idle
        case .selectingExperience: self = .selectingExperience
        case .readyToStart: self = .readyToStart
        case .countdown:
            self = .countdown(
                photoIndex: try container.decode(Int.self, forKey: .photoIndex),
                secondsRemaining: try container.decode(Int.self, forKey: .secondsRemaining)
            )
        case .captured:
            self = .captured(photoIndex: try container.decode(Int.self, forKey: .photoIndex))
        case .review:
            self = .review(photoIndex: try container.decode(Int.self, forKey: .photoIndex))
        case .captureRecovery:
            self = .captureRecovery(
                photoIndex: try container.decode(Int.self, forKey: .photoIndex),
                failure: try container.decode(CaptureFailureSummary.self, forKey: .failure)
            )
        case .processing: self = .processing
        case .finished:
            self = .finished(qrPayload: try container.decode(String.self, forKey: .qrPayload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle: try container.encode(Kind.idle, forKey: .kind)
        case .selectingExperience: try container.encode(Kind.selectingExperience, forKey: .kind)
        case .readyToStart: try container.encode(Kind.readyToStart, forKey: .kind)
        case .countdown(let photoIndex, let secondsRemaining):
            try container.encode(Kind.countdown, forKey: .kind)
            try container.encode(photoIndex, forKey: .photoIndex)
            try container.encode(secondsRemaining, forKey: .secondsRemaining)
        case .captured(let photoIndex):
            try container.encode(Kind.captured, forKey: .kind)
            try container.encode(photoIndex, forKey: .photoIndex)
        case .review(let photoIndex):
            try container.encode(Kind.review, forKey: .kind)
            try container.encode(photoIndex, forKey: .photoIndex)
        case .captureRecovery(let photoIndex, let failure):
            try container.encode(Kind.captureRecovery, forKey: .kind)
            try container.encode(photoIndex, forKey: .photoIndex)
            try container.encode(failure, forKey: .failure)
        case .processing: try container.encode(Kind.processing, forKey: .kind)
        case .finished(let qrPayload):
            try container.encode(Kind.finished, forKey: .kind)
            try container.encode(qrPayload, forKey: .qrPayload)
        }
    }
}
