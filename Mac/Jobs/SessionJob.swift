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
        case .renderGIF, .cloudUpload, .autoPrint, .updateGallery: return true
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

enum SessionJobFailureDisposition: String, Codable, Sendable {
    case retryable
    case permanent
    case sideEffectUnknown
}

enum UnknownPrintResolution: Sendable, Equatable {
    case printed
    case notPrinted
}

enum CloudUploadRequeueResult: String, Sendable, Equatable {
    case queued
    case alreadyQueued
    case alreadyRunning
    case notFound
    case sessionCancelled
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
    var lastFailureDisposition: SessionJobFailureDisposition? = nil
    
    // Links job to its finalization transaction. Optional for backward compatibility.
    var finalizationTransactionID: String? = nil
}

enum JobExecutionError: LocalizedError, Sendable {
    case retryable(String)
    case permanent(String)
    case sideEffectUnknown(String)
    case obsoleteTransaction(String)

    var errorDescription: String? {
        switch self {
        case .retryable(let message), .permanent(let message), .sideEffectUnknown(let message),
             .obsoleteTransaction(let message): return message
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

enum SessionJobDependencyPolicy {
    static func prerequisitesSatisfied(for job: SessionJob, in jobs: [SessionJob]) -> Bool {
        func latest(_ kind: SessionJobKind) -> SessionJob? {
            jobs
                .filter {
                    $0.sessionID == job.sessionID
                        && $0.finalizationTransactionID == job.finalizationTransactionID
                        && $0.kind == kind
                        && $0.status != .cancelled
                }
                .max { $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt }
        }

        func succeeded(_ kind: SessionJobKind) -> Bool {
            latest(kind)?.status == .succeeded
        }

        switch job.kind {
        case .renderStrip:
            return true
        case .registerDownload, .updateGallery, .autoPrint:
            return succeeded(.renderStrip)
        case .renderGIF:
            guard let download = latest(.registerDownload) else { return true }
            return download.status == .succeeded || download.status == .failed || download.status == .cancelled
        case .cloudUpload:
            guard succeeded(.renderStrip) else { return false }
            guard let gif = latest(.renderGIF) else { return true }
            return gif.status == .succeeded || gif.status == .failed || gif.status == .cancelled
        }
    }

    static func hasRunnableWork(_ job: SessionJob, in jobs: [SessionJob]) -> Bool {
        switch job.status {
        case .running:
            return true
        case .pending, .waitingRetry:
            return prerequisitesSatisfied(for: job, in: jobs)
        case .succeeded, .failed, .cancelled:
            return false
        }
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
    static func resolve(_ jobs: [SessionJob], transactionID: String? = nil) -> SessionDeliveryStatus {
        let matchingJobs = transactionID.map { transactionID in
            jobs.filter { $0.finalizationTransactionID == transactionID }
        } ?? jobs
        let localJobs = matchingJobs.filter { $0.kind == .renderStrip || $0.kind == .registerDownload }
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
            cloud: state(for: matchingJobs.first(where: { $0.kind == .cloudUpload }), pending: .cloudPending, succeeded: .cloudUploaded, failed: .cloudFailed),
            print: state(for: matchingJobs.first(where: { $0.kind == .autoPrint }), pending: .printPending, succeeded: .printed, failed: .printFailed)
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
