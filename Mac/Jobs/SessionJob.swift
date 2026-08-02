import Foundation

enum SessionJobKind: String, Codable, Sendable, CaseIterable {
    case renderStrip
    case renderGIF
    case registerDownload
    case cloudUpload
    case autoPrint

    var isOptional: Bool {
        switch self {
        case .renderGIF, .cloudUpload, .autoPrint: return true
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
        case .registerDownload, .autoPrint: return 3
        case .cloudUpload: return 10
        }
    }

    static func delay(afterAttempt attempt: Int) -> TimeInterval {
        [5, 15, 60, 300, 900, 1800][min(max(attempt, 1) - 1, 5)]
    }
}
