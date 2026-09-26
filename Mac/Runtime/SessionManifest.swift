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
    // Retry uses the original host and path so a Settings change cannot redirect an old QR upload.
    var publicBaseURL: String
    var remoteBasePath: String
    var sshHost: String
}

struct SessionDeliveryIntentSnapshot: Codable, Sendable, Equatable {
    var cloudUploadEnabled: Bool
    var automaticPrintEnabled: Bool
    // Optional so manifests written before the finalization plan remain readable.
    var updateGalleryEnabled: Bool? = nil
    var renderGIFEnabled: Bool? = nil
}

struct FinalizationPlan: Sendable, Equatable {
    static let requiredJobKinds: [SessionJobKind] = [.renderStrip, .registerDownload]

    var transactionID: String
    var jobKinds: [SessionJobKind]
    var requiresCloudPublicationBeforePrint: Bool

    static func make(from manifest: SessionManifest) -> FinalizationPlan? {
        guard let transactionID = manifest.finalizationTransactionID,
              !transactionID.isEmpty else { return nil }

        let intent = manifest.deliveryIntent
        let galleryEnabled = intent?.updateGalleryEnabled
            ?? (manifest.eventConfig.eventGalleryPath != nil)
        let gifEnabled = intent?.renderGIFEnabled
            ?? manifest.shots.contains { !$0.gifFrameFileNames.isEmpty }
        let cloudEnabled = intent?.cloudUploadEnabled
            ?? (manifest.cloudDelivery != nil)
        let printEnabled = intent?.automaticPrintEnabled ?? false
        let printQRUsesPublicCloudRoute = printEnabled
            && cloudEnabled
            && !manifest.eventConfig.qrCodeElements.isEmpty
            && manifest.cloudDelivery.flatMap {
                ValidatedPublicGuestBaseURL(string: $0.publicBaseURL)
            } != nil

        var kinds = requiredJobKinds
        if galleryEnabled { kinds.append(.updateGallery) }
        if gifEnabled { kinds.append(.renderGIF) }
        if cloudEnabled { kinds.append(.cloudUpload) }
        if printEnabled { kinds.append(.autoPrint) }
        return FinalizationPlan(
            transactionID: transactionID,
            jobKinds: kinds,
            requiresCloudPublicationBeforePrint: printQRUsesPublicCloudRoute
        )
    }

    func authorizes(_ job: SessionJob, for manifest: SessionManifest) -> Bool {
        job.sessionID == manifest.id
            && job.finalizationTransactionID == transactionID
            && manifest.finalizationTransactionID == transactionID
            && jobKinds.contains(job.kind)
    }

    func cloudPublicationReadiness(in jobs: [SessionJob], for manifest: SessionManifest) -> CloudPublicationReadiness {
        guard jobKinds.contains(.cloudUpload) else { return .notRequired }
        let uploadJobs = jobs.filter { $0.kind == .cloudUpload && authorizes($0, for: manifest) }
        guard uploadJobs.count == 1, let job = uploadJobs.first else { return .pending }
        switch job.status {
        case .succeeded:
            return .published
        case .failed, .cancelled:
            return .failed
        case .pending, .running, .waitingRetry:
            return .pending
        }
    }
}

enum CloudPublicationReadiness: Sendable, Equatable {
    case notRequired
    case pending
    case published
    case failed
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
    // Optional so manifests written before foreground overlays remain recoverable.
    var foregroundOverlaySnapshotFileName: String? = nil
    var stripFileName: String?
    var gifFileName: String?

    var downloadToken: String
    var shots: [RuntimeShotRecord]
    // Optional for old manifests; recovery never redirects them to current Settings.
    var cloudDelivery: SessionCloudDeliverySnapshot?
    // Optional keeps manifests written before v1.4.3 recoverable.
    var deliveryIntent: SessionDeliveryIntentSnapshot? = nil
    // Optional keeps v1.1/v1.2 manifests readable without a migration.
    var captureAttempts: [CaptureAttemptRecord]?

    // Links manifest to its finalization job bundle. Optional for backward compatibility.
    var finalizationTransactionID: String? = nil

    // Distinguishes real customer sessions from automated event readiness soak sessions.
    var origin: SessionOrigin? = .normal
    var soakRunID: String? = nil
    var soakCycleIndex: Int? = nil
    // Retained on diagnostic manifests when soak cleanup needs a retry.
    var soakCleanupWarning: String? = nil
    var soakCleanupLastAttemptAt: Date? = nil
    // Persist the user's cleanup policy so startup can safely resume interrupted cleanup.
    var soakAutoCleanupEnabled: Bool? = nil
    var soakDiagnosticRetained: Bool? = nil

    var lastError: String?
    var updatedAt: Date

    func isEligibleForGuestPublication(activeSoakRunID _: String?) -> Bool {
        origin != .soakTest
    }

    var isRetainedSoakDiagnostic: Bool {
        guard origin == .soakTest else { return false }
        return soakDiagnosticRetained ?? (lastError != nil)
    }
}

public enum SessionOrigin: String, Codable, Sendable, Equatable {
    case normal
    case soakTest
}

enum SessionManifestError: LocalizedError, Equatable {
    case invalidSessionID(String)
    case missing(URL)
    case corrupt(URL, String)
    case unsupportedSchemaVersion(Int)
    case alreadyOwned(URL, String)
    case mutationNotAllowed(sessionID: String, status: RuntimeSessionStatus)
    case invalidTransition(sessionID: String, from: RuntimeSessionStatus, to: RuntimeSessionStatus)
    case staleWrite(sessionID: String)
    case soakCleanupNotAllowed(String)

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
        case .mutationNotAllowed(let sessionID, let status):
            return "Manifest mutation is not allowed for \(sessionID) while \(status.rawValue)"
        case .invalidTransition(let sessionID, let from, let to):
            return "Invalid session transition for \(sessionID): \(from.rawValue) -> \(to.rawValue)"
        case .staleWrite(let sessionID):
            return "Stale session manifest write rejected: \(sessionID)"
        case .soakCleanupNotAllowed(let sessionID):
            return "Refusing soak cleanup metadata update for an unrelated session: \(sessionID)"
        }
    }
}
