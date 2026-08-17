import Foundation

public enum CustomerLanguage: String, Codable, Sendable, CaseIterable {
    case english
    case thai

    public var localeIdentifier: String {
        switch self {
        case .english: return "en"
        case .thai: return "th"
        }
    }
}

public enum OperatorLanguage: String, Codable, Sendable, CaseIterable {
    case system
    case english
    case thai
}

public struct PosePromptDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var photoIndex: Int
    public var title: LocalizedText
    public var subtitle: LocalizedText
    public var imageFileName: String?
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        photoIndex: Int,
        title: LocalizedText = LocalizedText(),
        subtitle: LocalizedText = LocalizedText(),
        imageFileName: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.photoIndex = photoIndex
        self.title = title
        self.subtitle = subtitle
        self.imageFileName = imageFileName
        self.isEnabled = isEnabled
    }
}

public struct ResolvedPosePrompt: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var photoIndex: Int
    public var title: LocalizedText
    public var subtitle: LocalizedText
    public var assetID: String?

    public init(
        id: String,
        photoIndex: Int,
        title: LocalizedText,
        subtitle: LocalizedText,
        assetID: String?
    ) {
        self.id = id
        self.photoIndex = photoIndex
        self.title = title
        self.subtitle = subtitle
        self.assetID = assetID
    }
}

public struct EventTemplateDefinition: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: LocalizedText
    public var isEnabled: Bool
    public var sortOrder: Int
    public var photoCount: Int
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var frameFileName: String?
    public var foregroundOverlayFileName: String?
    public var previewFileName: String?
    public var slots: [SharedPhotoSlot]
    public var qrCodeElements: [SharedQRCodeElement]
    public var posePrompts: [PosePromptDefinition]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: LocalizedText,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        photoCount: Int,
        canvasWidth: Double,
        canvasHeight: Double,
        frameFileName: String? = nil,
        foregroundOverlayFileName: String? = nil,
        previewFileName: String? = nil,
        slots: [SharedPhotoSlot],
        qrCodeElements: [SharedQRCodeElement] = [],
        posePrompts: [PosePromptDefinition] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.photoCount = photoCount
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.frameFileName = frameFileName
        self.foregroundOverlayFileName = foregroundOverlayFileName
        self.previewFileName = previewFileName
        self.slots = slots
        self.qrCodeElements = qrCodeElements
        self.posePrompts = posePrompts
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, sortOrder, photoCount, canvasWidth, canvasHeight
        case frameFileName, foregroundOverlayFileName, previewFileName, slots, qrCodeElements, posePrompts, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(LocalizedText.self, forKey: .name)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        sortOrder = try container.decode(Int.self, forKey: .sortOrder)
        photoCount = try container.decode(Int.self, forKey: .photoCount)
        canvasWidth = try container.decode(Double.self, forKey: .canvasWidth)
        canvasHeight = try container.decode(Double.self, forKey: .canvasHeight)
        frameFileName = try container.decodeIfPresent(String.self, forKey: .frameFileName)
        foregroundOverlayFileName = try container.decodeIfPresent(String.self, forKey: .foregroundOverlayFileName)
        previewFileName = try container.decodeIfPresent(String.self, forKey: .previewFileName)
        slots = try container.decode([SharedPhotoSlot].self, forKey: .slots)
        qrCodeElements = try container.decodeIfPresent([SharedQRCodeElement].self, forKey: .qrCodeElements) ?? []
        posePrompts = try container.decodeIfPresent([PosePromptDefinition].self, forKey: .posePrompts) ?? []
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(sortOrder, forKey: .sortOrder)
        try container.encode(photoCount, forKey: .photoCount)
        try container.encode(canvasWidth, forKey: .canvasWidth)
        try container.encode(canvasHeight, forKey: .canvasHeight)
        try container.encodeIfPresent(frameFileName, forKey: .frameFileName)
        try container.encodeIfPresent(foregroundOverlayFileName, forKey: .foregroundOverlayFileName)
        try container.encodeIfPresent(previewFileName, forKey: .previewFileName)
        try container.encode(slots, forKey: .slots)
        try container.encode(qrCodeElements, forKey: .qrCodeElements)
        try container.encode(posePrompts, forKey: .posePrompts)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

public enum EventGalleryMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case approvalRequired
    case automatic
}

public struct EventGalleryConfiguration: Codable, Sendable, Equatable {
    public var mode: EventGalleryMode
    public var eventToken: String
    public var title: LocalizedText
    public var language: CustomerLanguage
    public var showGIFLinks: Bool

    public init(
        mode: EventGalleryMode = .disabled,
        eventToken: String = UUID().uuidString,
        title: LocalizedText = LocalizedText(),
        language: CustomerLanguage = .english,
        showGIFLinks: Bool = true
    ) {
        self.mode = mode
        self.eventToken = eventToken
        self.title = title
        self.language = language
        self.showGIFLinks = showGIFLinks
    }
}

public struct CustomerTemplateOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: LocalizedText
    public var photoCount: Int
    public var aspectRatio: Double
    public var previewAssetID: String

    public init(id: String, name: LocalizedText, photoCount: Int, aspectRatio: Double, previewAssetID: String) {
        self.id = id
        self.name = name
        self.photoCount = photoCount
        self.aspectRatio = aspectRatio
        self.previewAssetID = previewAssetID
    }
}

public struct CustomerExperienceCatalog: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var eventID: String
    public var eventName: String
    public var revision: String
    public var defaultTemplateID: String
    public var guestTemplateSelectionEnabled: Bool
    public var templates: [CustomerTemplateOption]
    public var allowedFilterIDs: [PhotoFilterID]
    public var defaultFilterID: PhotoFilterID
    public var guestFilterSelectionEnabled: Bool
    public var defaultLanguage: CustomerLanguage
    public var guestLanguageSelectionEnabled: Bool

    public init(
        schemaVersion: Int = 1,
        eventID: String,
        eventName: String,
        revision: String,
        defaultTemplateID: String,
        guestTemplateSelectionEnabled: Bool,
        templates: [CustomerTemplateOption],
        allowedFilterIDs: [PhotoFilterID],
        defaultFilterID: PhotoFilterID,
        guestFilterSelectionEnabled: Bool,
        defaultLanguage: CustomerLanguage,
        guestLanguageSelectionEnabled: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.eventName = eventName
        self.revision = revision
        self.defaultTemplateID = defaultTemplateID
        self.guestTemplateSelectionEnabled = guestTemplateSelectionEnabled
        self.templates = templates
        self.allowedFilterIDs = allowedFilterIDs
        self.defaultFilterID = defaultFilterID
        self.guestFilterSelectionEnabled = guestFilterSelectionEnabled
        self.defaultLanguage = defaultLanguage
        self.guestLanguageSelectionEnabled = guestLanguageSelectionEnabled
    }
}

public struct CustomerSessionSelection: Codable, Sendable, Equatable {
    public var eventID: String
    public var experienceRevision: String
    public var templateID: String
    public var filterID: PhotoFilterID
    public var language: CustomerLanguage

    public init(eventID: String, experienceRevision: String, templateID: String, filterID: PhotoFilterID, language: CustomerLanguage) {
        self.eventID = eventID
        self.experienceRevision = experienceRevision
        self.templateID = templateID
        self.filterID = filterID
        self.language = language
    }
}

public enum ExperienceAssetKind: String, Codable, Sendable {
    case templatePreview
}

public struct ExperienceAssetPacket: Codable, Sendable, Equatable {
    public var eventID: String
    public var revision: String
    public var assetID: String
    public var kind: ExperienceAssetKind
    public var jpegData: Data

    public init(eventID: String, revision: String, assetID: String, kind: ExperienceAssetKind, jpegData: Data) {
        self.eventID = eventID
        self.revision = revision
        self.assetID = assetID
        self.kind = kind
        self.jpegData = jpegData
    }
}

public struct SessionPromptPresentation: Codable, Sendable, Equatable {
    public var promptID: String
    public var photoIndex: Int
    public var title: String
    public var subtitle: String
    public var imageData: Data?

    public init(promptID: String, photoIndex: Int, title: String, subtitle: String, imageData: Data?) {
        self.promptID = promptID
        self.photoIndex = photoIndex
        self.title = title
        self.subtitle = subtitle
        self.imageData = imageData
    }
}

public struct SessionPresentation: Codable, Sendable, Equatable {
    public var sessionID: String
    public var language: CustomerLanguage
    public var templateDisplayName: String
    public var filterID: PhotoFilterID
    public var prompts: [SessionPromptPresentation]

    public init(sessionID: String, language: CustomerLanguage, templateDisplayName: String, filterID: PhotoFilterID, prompts: [SessionPromptPresentation]) {
        self.sessionID = sessionID
        self.language = language
        self.templateDisplayName = templateDisplayName
        self.filterID = filterID
        self.prompts = prompts
    }
}
