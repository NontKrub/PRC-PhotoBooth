import Foundation
import CoreGraphics

@MainActor
final class StillCaptureLifecycleCoordinator {
    struct PendingStillCapture {
        let requestID: Int64
        let continuation: CheckedContinuation<CGImage, any Error>
        let timeoutTask: Task<Void, Never>
        let startedAt: Date
    }

    private(set) var pendingCapture: PendingStillCapture?
    var isCapturing: Bool { pendingCapture != nil }
    let timeoutDuration: TimeInterval

    init(timeoutDuration: TimeInterval = 10.0) {
        self.timeoutDuration = timeoutDuration
    }

    func beginCapture(
        requestID: Int64,
        continuation: CheckedContinuation<CGImage, any Error>,
        onTimeout: @escaping @MainActor (Int64) -> Void
    ) throws {
        guard pendingCapture == nil else {
            throw CameraError.captureInProgress
        }
        let timeoutNanos = UInt64(timeoutDuration * 1_000_000_000)
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanos)
            guard !Task.isCancelled else { return }
            guard let self, self.pendingCapture?.requestID == requestID else { return }
            onTimeout(requestID)
        }
        pendingCapture = PendingStillCapture(
            requestID: requestID,
            continuation: continuation,
            timeoutTask: timeoutTask,
            startedAt: Date()
        )
    }

    @discardableResult
    func finish(requestID: Int64, result: Result<CGImage, any Error>) -> Bool {
        guard let current = pendingCapture, current.requestID == requestID else {
            return false
        }
        pendingCapture = nil
        current.timeoutTask.cancel()
        current.continuation.resume(with: result)
        return true
    }

    @discardableResult
    func cancelCurrent(requestID: Int64? = nil, error: any Error = CameraError.cancelled) -> Bool {
        guard let current = pendingCapture else { return false }
        if let requestID, current.requestID != requestID { return false }
        pendingCapture = nil
        current.timeoutTask.cancel()
        current.continuation.resume(throwing: error)
        return true
    }

    @discardableResult
    func abortAll(error: any Error) -> Bool {
        guard let current = pendingCapture else { return false }
        pendingCapture = nil
        current.timeoutTask.cancel()
        current.continuation.resume(throwing: error)
        return true
    }
}
