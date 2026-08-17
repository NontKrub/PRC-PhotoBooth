import Foundation
import CoreGraphics

// MARK: - QR code generation (shared between Mac external viewer + iPad finish screen)

public func generateQRCode(from string: String) -> CGImage? {
    QRCodeGenerator.makeImage(payload: string, correctionLevel: "M", scale: 8, quietZoneModules: 0)
}

public struct SharedQRCodeElement: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var normalizedRect: CGRect
    public var rotation: Double
    public var zOrder: Int

    public init(
        id: String = UUID().uuidString,
        normalizedRect: CGRect,
        rotation: Double = 0,
        zOrder: Int = 0
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.rotation = rotation
        self.zOrder = zOrder
    }
}

// MARK: - Event config (shared between Mac + iPad)

public struct EventConfig: Codable, Sendable, Equatable {
    public var eventID: String
    public var eventName: String
    public var photoCount: Int
    public var countdownSeconds: Int
    public var canvasWidth: CGFloat
    public var canvasHeight: CGFloat
    public var slots: [SharedPhotoSlot]
    public var templateID: String
    public var templateName: LocalizedText
    public var selectedFilterID: PhotoFilterID
    public var customerLanguage: CustomerLanguage
    public var posePrompts: [ResolvedPosePrompt]
    public var experienceRevision: String
    public var eventGalleryPath: String?
    public var qrCodeElements: [SharedQRCodeElement]
    public var gifQualityPreset: GIFQualityPreset

    public init(
        eventID: String = UUID().uuidString,
        eventName: String = "New Event",
        photoCount: Int = 3,
        countdownSeconds: Int = 5,
        canvasWidth: CGFloat = 1200,
        canvasHeight: CGFloat = 1800,
        slots: [SharedPhotoSlot] = [],
        templateID: String = "legacy-default",
        templateName: LocalizedText = LocalizedText(),
        selectedFilterID: PhotoFilterID = .original,
        customerLanguage: CustomerLanguage = .english,
        posePrompts: [ResolvedPosePrompt] = [],
        experienceRevision: String = "",
        eventGalleryPath: String? = nil,
        qrCodeElements: [SharedQRCodeElement] = [],
        gifQualityPreset: GIFQualityPreset = .balanced
    ) {
        self.eventID = eventID
        self.eventName = eventName
        self.photoCount = photoCount
        self.countdownSeconds = countdownSeconds
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.slots = slots
        self.templateID = templateID
        self.templateName = templateName
        self.selectedFilterID = selectedFilterID
        self.customerLanguage = customerLanguage
        self.posePrompts = posePrompts
        self.experienceRevision = experienceRevision
        self.eventGalleryPath = eventGalleryPath
        self.qrCodeElements = qrCodeElements
        self.gifQualityPreset = gifQualityPreset
    }

    private enum CodingKeys: String, CodingKey {
        case eventID, eventName, photoCount, countdownSeconds, canvasWidth, canvasHeight, slots
        case templateID, templateName, selectedFilterID, customerLanguage, posePrompts, experienceRevision, eventGalleryPath, qrCodeElements, gifQualityPreset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        eventID = try container.decode(String.self, forKey: .eventID)
        eventName = try container.decode(String.self, forKey: .eventName)
        photoCount = try container.decode(Int.self, forKey: .photoCount)
        countdownSeconds = try container.decode(Int.self, forKey: .countdownSeconds)
        canvasWidth = try container.decode(CGFloat.self, forKey: .canvasWidth)
        canvasHeight = try container.decode(CGFloat.self, forKey: .canvasHeight)
        slots = try container.decode([SharedPhotoSlot].self, forKey: .slots)
        templateID = try container.decodeIfPresent(String.self, forKey: .templateID) ?? "legacy-default"
        templateName = try container.decodeIfPresent(LocalizedText.self, forKey: .templateName) ?? LocalizedText()
        selectedFilterID = try container.decodeIfPresent(PhotoFilterID.self, forKey: .selectedFilterID) ?? .original
        customerLanguage = try container.decodeIfPresent(CustomerLanguage.self, forKey: .customerLanguage) ?? .english
        posePrompts = try container.decodeIfPresent([ResolvedPosePrompt].self, forKey: .posePrompts) ?? []
        experienceRevision = try container.decodeIfPresent(String.self, forKey: .experienceRevision) ?? ""
        eventGalleryPath = try container.decodeIfPresent(String.self, forKey: .eventGalleryPath)
        qrCodeElements = try container.decodeIfPresent([SharedQRCodeElement].self, forKey: .qrCodeElements) ?? []
        gifQualityPreset = try container.decodeIfPresent(GIFQualityPreset.self, forKey: .gifQualityPreset) ?? .balanced
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(eventID, forKey: .eventID)
        try container.encode(eventName, forKey: .eventName)
        try container.encode(photoCount, forKey: .photoCount)
        try container.encode(countdownSeconds, forKey: .countdownSeconds)
        try container.encode(canvasWidth, forKey: .canvasWidth)
        try container.encode(canvasHeight, forKey: .canvasHeight)
        try container.encode(slots, forKey: .slots)
        try container.encode(templateID, forKey: .templateID)
        try container.encode(templateName, forKey: .templateName)
        try container.encode(selectedFilterID, forKey: .selectedFilterID)
        try container.encode(customerLanguage, forKey: .customerLanguage)
        try container.encode(posePrompts, forKey: .posePrompts)
        try container.encode(experienceRevision, forKey: .experienceRevision)
        try container.encodeIfPresent(eventGalleryPath, forKey: .eventGalleryPath)
        try container.encode(qrCodeElements, forKey: .qrCodeElements)
        try container.encode(gifQualityPreset, forKey: .gifQualityPreset)
    }
}

public struct SharedPhotoSlot: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var normalizedRect: CGRect   // x,y,w,h in 0–1 of canvas
    public var rotation: Double         // degrees
    public var zOrder: Int
    public var photoIndex: Int          // which capture (0-based) this slot displays

    public init(
        id: String = UUID().uuidString,
        normalizedRect: CGRect = .zero,
        rotation: Double = 0,
        zOrder: Int = 0,
        photoIndex: Int = 0
    ) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.rotation = rotation
        self.zOrder = zOrder
        self.photoIndex = photoIndex
    }
}


// MARK: - Session output info (shared)

public struct SessionOutput: Codable, Sendable {
    public var sessionID: String
    public var qrPayload: String
    public var stripThumbData: Data?
    public var gifThumbData: Data?
}

// MARK: - Device role

public enum DeviceRole: String, Codable, Sendable {
    case mac
    case iPad
}

// MARK: - Review action

public enum ReviewAction: String, Codable, Sendable {
    case retake
    case keep
}

// MARK: - Operator override actions

public enum OperatorAction: String, Codable, Sendable {
    case forceStart
    case forceRetake
    case skip
    case cancelSession
}
