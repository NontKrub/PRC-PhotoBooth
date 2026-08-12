import Foundation

enum SessionJobKind: String, Codable, Sendable, CaseIterable {
    case renderStrip
    case registerDownload
    case updateGallery
    case renderGIF
    case cloudUpload
    case autoPrint

    var isOptional: Bool {
        switch self {
        case .updateGallery, .renderGIF, .cloudUpload, .autoPrint: return true
        case .renderStrip, .registerDownload: return false
        }
    }
}

enum SessionJobStatus: String, Codable, Sendable {
    case pending
    case running
    case waitingRetry
    case succeeded
    case failed
    case cancelled
}

enum CloudUploadRequeueResult: String, Sendable, Equatable {
    case queued
    case alreadyQueued
    case alreadyRunning
    case notFound
}

struct SessionJob: Codable, Sendable, Identifiable, Equatable {
    var id: String
    var sessionID: String
    var kind: SessionJobKind
    var status: SessionJobStatus

    var createdAt: Date
    var updatedAt: Date
    var lastAttemptAt: Date?
    var nextAttemptAt: Date?

    var attemptCount: Int
    var lastError: String?
}

enum JobExecutionError: LocalizedError, Sendable {
    case retryable(String)
    case permanent(String)

    var errorDescription: String? {
        switch self {
        case .retryable(let message), .permanent(let message): return message
        }
    }
}

struct SessionJobRetryPolicy {
    static func maximumAutomaticAttempts(for kind: SessionJobKind) -> Int {
        switch kind {
        case .renderStrip, .renderGIF: return 2
        case .registerDownload, .updateGallery, .autoPrint: return 3
        case .cloudUpload: return 10
        }
    }

    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        [5, 15, 60, 300, 900, 1800][min(max(attempt, 1) - 1, 5)]
    }
}

enum SessionDeliveryState: String, Codable, Sendable, Equatable {
    case localPending = "Local Pending"
    case localReady = "Local Ready"
    case localFailed = "Local Failed"
    case cloudPending = "Cloud Pending"
    case cloudUploaded = "Cloud Uploaded"
    case cloudFailed = "Cloud Failed"
    case printPending = "Print Pending"
    case printed = "Printed"
    case printFailed = "Print Failed"
}

struct SessionDeliveryStatus: Codable, Sendable, Equatable {
    var local: SessionDeliveryState
    var cloud: SessionDeliveryState?
    var print: SessionDeliveryState?
}

enum SessionDeliveryResolver {
    static func resolve(_ jobs: [SessionJob]) -> SessionDeliveryStatus {
        let localJobs = jobs.filter { $0.kind == .renderStrip || $0.kind == .registerDownload }
        let local: SessionDeliveryState
        if localJobs.contains(where: { $0.status == .failed }) {
            local = .localFailed
        } else if localJobs.count == 2 && localJobs.allSatisfy({ $0.status == .succeeded }) {
            local = .localReady
        } else {
            local = .localPending
        }
        return SessionDeliveryStatus(
            local: local,
            cloud: state(for: jobs.first(where: { $0.kind == .cloudUpload }), pending: .cloudPending, succeeded: .cloudUploaded, failed: .cloudFailed),
            print: state(for: jobs.first(where: { $0.kind == .autoPrint }), pending: .printPending, succeeded: .printed, failed: .printFailed)
        )
    }

    private static func state(
        for job: SessionJob?,
        pending: SessionDeliveryState,
        succeeded: SessionDeliveryState,
        failed: SessionDeliveryState
    ) -> SessionDeliveryState? {
        guard let job else { return nil }
        switch job.status {
        case .succeeded: return succeeded
        case .failed, .cancelled: return failed
        case .pending, .running, .waitingRetry: return pending
        }
    }
}
