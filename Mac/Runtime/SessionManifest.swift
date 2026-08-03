import Foundation

enum RuntimeSessionStatus: String, Codable, Sendable {
    case capturing
    case finalizing
    case completed
    case cancelled
    case failed
}

struct RuntimeShotRecord: Codable, Sendable, Equatable {
    var photoIndex: Int
    var imageFileName: String?
    var gifFrameFileNames: [String]
    var retakeCount: Int
    var acceptedAt: Date?
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
