import Foundation

enum GalleryApprovalStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case approved
    case hidden
}

struct GallerySessionEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var sessionID: String
    var downloadToken: String
    var startedAt: Date
    var absoluteSessionDirectoryPath: String
    var thumbnailFileName: String
    var stripFileName: String
    var gifFileName: String?
    var templateID: String
    var templateName: LocalizedText
    var filterID: PhotoFilterID
    var customerLanguage: CustomerLanguage
    var approvalStatus: GalleryApprovalStatus
    var updatedAt: Date
}

struct EventGalleryIndex: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int
    var eventID: String
    var eventToken: String
    var title: LocalizedText
    var language: CustomerLanguage
    var showGIFLinks: Bool
    var sessions: [GallerySessionEntry]
    var updatedAt: Date
}

enum GalleryIndexLoadResult: Sendable, Equatable {
    case loaded(EventGalleryIndex)
    case failed(URL, String)
}

struct SessionRouteRegistration: Sendable, Equatable {
    var sessionDirectory: URL
    var language: CustomerLanguage
    var eventGalleryPath: String?
    var gifState: GIFAvailabilityState = .none
}

struct EventGalleryRouteRegistration: Sendable, Equatable {
    var eventID: String
    var eventToken: String
    var title: String
    var language: CustomerLanguage
    var showGIFLinks: Bool
    var approvedSessions: [GalleryRouteSession]
}

struct GalleryRouteSession: Sendable, Equatable {
    var sessionID: String
    var downloadToken: String
    var startedAt: Date
    var thumbnailURL: URL
    var gifAvailable: Bool
    var templateName: String
    var filterID: PhotoFilterID
}

enum EventGalleryStoreError: LocalizedError, Equatable {
    case invalidEventID
    case corrupt(URL, backup: URL)
    case missingSession(String)

    var errorDescription: String? {
        switch self {
        case .invalidEventID: return "Invalid gallery event ID."
        case .corrupt(let url, let backup):
            return "Corrupt gallery index \(url.path). Preserved copy: \(backup.path)"
        case .missingSession(let id): return "Gallery session not found: \(id)"
        }
    }
}
