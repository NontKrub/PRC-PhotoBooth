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
    var gifQualityPreset: GIFQualityPreset
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
        gifQualityPreset: GIFQualityPreset = .balanced,
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
        self.gifQualityPreset = gifQualityPreset
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, eventID, revision, defaultTemplateID
        case guestTemplateSelectionEnabled, allowedFilterIDs, defaultFilterID
        case guestFilterSelectionEnabled, defaultCustomerLanguage, guestLanguageSelectionEnabled
        case templates, gallery, gifQualityPreset, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        id = try container.decode(String.self, forKey: .id)
        eventID = try container.decode(String.self, forKey: .eventID)
        revision = try container.decode(String.self, forKey: .revision)
        defaultTemplateID = try container.decode(String.self, forKey: .defaultTemplateID)
        guestTemplateSelectionEnabled = try container.decode(Bool.self, forKey: .guestTemplateSelectionEnabled)
        allowedFilterIDs = try container.decode([PhotoFilterID].self, forKey: .allowedFilterIDs)
        defaultFilterID = try container.decode(PhotoFilterID.self, forKey: .defaultFilterID)
        guestFilterSelectionEnabled = try container.decode(Bool.self, forKey: .guestFilterSelectionEnabled)
        defaultCustomerLanguage = try container.decode(CustomerLanguage.self, forKey: .defaultCustomerLanguage)
        guestLanguageSelectionEnabled = try container.decode(Bool.self, forKey: .guestLanguageSelectionEnabled)
        templates = try container.decode([EventTemplateDefinition].self, forKey: .templates)
        gallery = try container.decode(EventGalleryConfiguration.self, forKey: .gallery)
        gifQualityPreset = try container.decodeIfPresent(GIFQualityPreset.self, forKey: .gifQualityPreset) ?? .balanced
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(revision, forKey: .revision)
        try container.encode(defaultTemplateID, forKey: .defaultTemplateID)
        try container.encode(guestTemplateSelectionEnabled, forKey: .guestTemplateSelectionEnabled)
        try container.encode(allowedFilterIDs, forKey: .allowedFilterIDs)
        try container.encode(defaultFilterID, forKey: .defaultFilterID)
        try container.encode(guestFilterSelectionEnabled, forKey: .guestFilterSelectionEnabled)
        try container.encode(defaultCustomerLanguage, forKey: .defaultCustomerLanguage)
        try container.encode(guestLanguageSelectionEnabled, forKey: .guestLanguageSelectionEnabled)
        try container.encode(templates, forKey: .templates)
        try container.encode(gallery, forKey: .gallery)
        try container.encode(gifQualityPreset, forKey: .gifQualityPreset)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
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

struct ImportedTemplateForegroundOverlay: Sendable, Equatable {
    var fileName: String
    var url: URL
}

struct ImportedPromptImage: Sendable, Equatable {
    var fileName: String
    var url: URL
}

struct EventExperienceEditingSession: Sendable, Equatable {
    var id: String
    var eventID: String
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
