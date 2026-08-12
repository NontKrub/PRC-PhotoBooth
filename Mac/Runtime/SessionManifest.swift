import Foundation

enum RuntimeSessionStatus: String, Codable, Sendable {
    case capturing
    case finalizing
    case completed
    case cancelled
    case failed
}

enum CaptureAttemptResult: String, Codable, Sendable {
    case success
    case transferRecovered
    case failed
    case retaken
    case deferred
    case usedPrevious
}

struct CaptureAttemptRecord: Codable, Sendable, Equatable {
    var id: String
    var photoIndex: Int
    var startedAt: Date
    var completedAt: Date?
    var result: CaptureAttemptResult
    var reason: String?
    var receiveDuration: Double?
}

struct RuntimeShotRecord: Codable, Sendable, Equatable {
    var photoIndex: Int
    var imageFileName: String?
    var gifFrameFileNames: [String]
    var retakeCount: Int
    var acceptedAt: Date?
    // Kept while a replacement capture is pending. Optional for old manifests.
    var previousImageFileName: String?
    var previousGifFrameFileNames: [String]?
    var previousAcceptedAt: Date?
}

struct SessionCloudDeliverySnapshot: Codable, Sendable, Equatable {
    var publicBaseURL: String
    var remoteBasePath: String
    var sshHost: String
}

struct SessionManifest: Codable, Sendable, Identifiable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String
    var eventID: String
    var eventName: String
    var eventConfig: EventConfig

    var startedAt: Date
    var completedAt: Date?
    var cancelledAt: Date?

    var status: RuntimeSessionStatus
    var nextPhotoIndex: Int

    var outputRootPath: String
    var relativeDirectoryPath: String
    var absoluteDirectoryPath: String

    var frameSnapshotFileName: String?
    var stripFileName: String?
    var gifFileName: String?

    var downloadToken: String
    var shots: [RuntimeShotRecord]
    // Optional keeps older manifests recoverable with current Settings as a fallback.
    var cloudDelivery: SessionCloudDeliverySnapshot?
    // Optional keeps v1.1/v1.2 manifests readable without a migration.
    var captureAttempts: [CaptureAttemptRecord]?

    var lastError: String?
    var updatedAt: Date
}

enum SessionManifestError: LocalizedError, Equatable {
    case invalidSessionID(String)
    case missing(URL)
    case corrupt(URL, String)
    case unsupportedSchemaVersion(Int)
    case alreadyOwned(URL, String)

    var errorDescription: String? {
        switch self {
        case .invalidSessionID(let id):
            return "Invalid session ID: \(id)"
        case .missing(let url):
            return "Session manifest is missing: \(url.path)"
        case .corrupt(let url, let message):
            return "Corrupt session manifest \(url.lastPathComponent): \(message)"
        case .unsupportedSchemaVersion(let version):
            return "Unsupported session manifest schema version: \(version)"
        case .alreadyOwned(let url, let id):
            return "Manifest file \(url.lastPathComponent) belongs to another session: \(id)"
        }
    }
}
