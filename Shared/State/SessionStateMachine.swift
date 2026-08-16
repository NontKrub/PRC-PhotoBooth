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
    public private(set) var countdownDeadline: Date?

    public init() {}

    public func startSession(config: EventConfig, sessionID: String? = nil) {
        self.config = config
        self.keptShots = [:]
        self.acceptedPhotoIndices = []
        self.deferredPhotoIndices = []
        self.currentSessionID = sessionID ?? UUID().uuidString
        self.nextPhotoIndex = 0
        countdownDeadline = nil
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
        countdownDeadline = nil
        phase = .readyToStart
    }

    public func beginSelectingExperience() {
        switch phase {
        case .idle, .readyToStart, .finished:
            break
        default:
            return
        }
        phase = .selectingExperience
        countdownDeadline = nil
    }

    public func setReadyToStart() {
        guard phase == .selectingExperience || phase == .readyToStart else { return }
        phase = .readyToStart
        countdownDeadline = nil
    }

    public func beginCountdown(photoIndex: Int, captureAt: Date? = nil) {
        guard photoIndex >= 0, photoIndex < config.photoCount else { return }
        switch phase {
        case .readyToStart, .countdown(photoIndex: photoIndex, secondsRemaining: _):
            break
        default:
            return
        }
        nextPhotoIndex = photoIndex
        countdownDeadline = captureAt ?? Date().addingTimeInterval(TimeInterval(config.countdownSeconds))
        phase = .countdown(photoIndex: photoIndex, secondsRemaining: config.countdownSeconds)
    }

    public func tickCountdown() {
        guard case .countdown(let idx, let remaining) = phase else { return }
        countdownDeadline = nil
        if remaining > 1 {
            phase = .countdown(photoIndex: idx, secondsRemaining: remaining - 1)
        } else {
            phase = .captured(photoIndex: idx)
        }
    }

    public func updateCountdown(at date: Date = Date()) {
        guard case .countdown(let idx, _) = phase,
              let countdownDeadline else { return }
        let remaining = max(0, Int(ceil(countdownDeadline.timeIntervalSince(date))))
        phase = .countdown(photoIndex: idx, secondsRemaining: remaining)
    }

    public func enterReview(photoIndex: Int, thumbnailData: Data) {
        guard isCurrentPhoto(photoIndex), canEnterReview else { return }
        keptShots[photoIndex] = thumbnailData
        countdownDeadline = nil
        phase = .review(photoIndex: photoIndex)
    }

    public func enterCaptureRecovery(photoIndex: Int, failure: CaptureFailureSummary) {
        guard isCurrentPhoto(photoIndex), canEnterRecovery else { return }
        countdownDeadline = nil
        phase = .captureRecovery(photoIndex: photoIndex, failure: failure)
    }

    public func keepShot(photoIndex: Int) {
        guard case .review(let current) = phase, current == photoIndex else { return }
        acceptedPhotoIndices.insert(photoIndex)
        deferredPhotoIndices.remove(photoIndex)
        advanceAfterAcceptance()
    }

    public func retakeShot(photoIndex: Int) {
        guard isCurrentPhoto(photoIndex), canRetake else { return }
        keptShots.removeValue(forKey: photoIndex)
        acceptedPhotoIndices.remove(photoIndex)
        deferredPhotoIndices.remove(photoIndex)
        nextPhotoIndex = photoIndex
        countdownDeadline = nil
        phase = .countdown(photoIndex: photoIndex, secondsRemaining: config.countdownSeconds)
    }

    @discardableResult
    public func continueAfterCaptureFailure(photoIndex: Int) -> Int? {
        guard case .captureRecovery(let current, _) = phase, current == photoIndex else { return nil }
        deferredPhotoIndices.insert(photoIndex)
        guard let next = nextPendingPhoto() else {
            nextPhotoIndex = config.photoCount
            phase = .processing
            return nil
        }
        nextPhotoIndex = next
        countdownDeadline = nil
        phase = .countdown(photoIndex: next, secondsRemaining: config.countdownSeconds)
        return next
    }

    public func usePreviousCapture(photoIndex: Int, thumbnailData: Data) {
        guard case .captureRecovery(let current, _) = phase, current == photoIndex else { return }
        keptShots[photoIndex] = thumbnailData
        acceptedPhotoIndices.insert(photoIndex)
        deferredPhotoIndices.remove(photoIndex)
        advanceAfterAcceptance()
    }

    public func finishSession(qrPayload: String) {
        guard phase == .processing else { return }
        countdownDeadline = nil
        phase = .finished(qrPayload: qrPayload)
    }

    public func reset() {
        phase = .idle
        keptShots = [:]
        acceptedPhotoIndices = []
        deferredPhotoIndices = []
        currentSessionID = ""
        nextPhotoIndex = 0
        countdownDeadline = nil
    }

    // Trusted recovery/synchronization path. Normal workflow code must use the
    // guarded event methods above.
    public func applyAuthoritativeSnapshot(
        sessionID: String,
        config: EventConfig,
        phase: BoothPhase,
        keptShots: [Int: Data] = [:],
        nextPhotoIndex: Int = 0,
        countdownDeadline: Date? = nil,
        acceptedPhotoIndices: Set<Int>? = nil,
        deferredPhotoIndices: Set<Int>? = nil
    ) {
        self.config = config
        self.currentSessionID = sessionID
        self.keptShots = keptShots
        self.acceptedPhotoIndices = acceptedPhotoIndices ?? Set(keptShots.keys)
        self.deferredPhotoIndices = deferredPhotoIndices ?? []
        self.nextPhotoIndex = nextPhotoIndex
        self.countdownDeadline = countdownDeadline
        self.phase = phase
    }

    public func applyAuthoritativePhase(_ phase: BoothPhase, countdownDeadline: Date? = nil) {
        self.countdownDeadline = countdownDeadline
        self.phase = phase
    }

    private func advanceAfterAcceptance() {
        guard let next = nextPendingPhoto() else {
            nextPhotoIndex = config.photoCount
            phase = .processing
            return
        }
        nextPhotoIndex = next
        countdownDeadline = nil
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

    private var canEnterReview: Bool {
        switch phase {
        case .countdown, .captured, .captureRecovery: return true
        default: return false
        }
    }

    private var canEnterRecovery: Bool {
        switch phase {
        case .countdown, .captured, .captureRecovery: return true
        default: return false
        }
    }

    private var canRetake: Bool {
        switch phase {
        case .review, .captureRecovery: return true
        default: return false
        }
    }

    private func isCurrentPhoto(_ photoIndex: Int) -> Bool {
        switch phase {
        case .countdown(let current, _), .captured(let current), .review(let current), .captureRecovery(let current, _):
            return current == photoIndex
        default:
            return false
        }
    }
}
