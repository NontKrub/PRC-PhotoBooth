import Foundation

struct EventExperienceDocument: Codable, Sendable, Equatable, Identifiable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: String
    var eventID: String
    var revision: String
    var defaultTemplateID: String
    var guestTemplateSelectionEnabled: Bool
    var allowedFilterIDs: [PhotoFilterID]
    var defaultFilterID: PhotoFilterID
    var guestFilterSelectionEnabled: Bool
    var defaultCustomerLanguage: CustomerLanguage
    var guestLanguageSelectionEnabled: Bool
    var templates: [EventTemplateDefinition]
    var gallery: EventGalleryConfiguration
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: String,
        eventID: String,
        revision: String = UUID().uuidString,
        defaultTemplateID: String,
        guestTemplateSelectionEnabled: Bool = false,
        allowedFilterIDs: [PhotoFilterID] = [.original],
        defaultFilterID: PhotoFilterID = .original,
        guestFilterSelectionEnabled: Bool = false,
        defaultCustomerLanguage: CustomerLanguage = .english,
        guestLanguageSelectionEnabled: Bool = true,
        templates: [EventTemplateDefinition],
        gallery: EventGalleryConfiguration,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.eventID = eventID
        self.revision = revision
        self.defaultTemplateID = defaultTemplateID
        self.guestTemplateSelectionEnabled = guestTemplateSelectionEnabled
        self.allowedFilterIDs = allowedFilterIDs
        self.defaultFilterID = defaultFilterID
        self.guestFilterSelectionEnabled = guestFilterSelectionEnabled
        self.defaultCustomerLanguage = defaultCustomerLanguage
        self.guestLanguageSelectionEnabled = guestLanguageSelectionEnabled
        self.templates = templates
        self.gallery = gallery
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct BoothEventSnapshot: Sendable, Equatable {
    var id: String
    var name: String
    var photoCount: Int
    var countdownSeconds: Int
    var canvasWidth: Double
    var canvasHeight: Double
    var framePNGURL: URL?
    var slots: [SharedPhotoSlot]
}

struct ImportedTemplateFrame: Sendable, Equatable {
    var fileName: String
    var url: URL
}

struct ImportedPromptImage: Sendable, Equatable {
    var fileName: String
    var url: URL
}

enum EventExperienceError: LocalizedError, Equatable {
    case invalidEventID
    case missing(URL)
    case corrupt(URL, backup: URL)
    case unsupportedSchema(Int)
    case invalid(String)
    case missingAsset(URL)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidEventID: return "Invalid event ID."
        case .missing(let url): return "Experience document is missing: \(url.path)"
        case .corrupt(let url, let backup): return "Experience document is corrupt: \(url.path). Preserved copy: \(backup.path)"
        case .unsupportedSchema(let version): return "Unsupported event experience schema: \(version)."
        case .invalid(let message): return message
        case .missingAsset(let url): return "Experience asset is missing or unreadable: \(url.path)"
        case .importFailed(let message): return message
        }
    }
}
