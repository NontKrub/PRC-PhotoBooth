import Foundation
import CoreGraphics
import CoreImage

// MARK: - QR code generation (shared between Mac external viewer + iPad finish screen)

public func generateQRCode(from string: String) -> CGImage? {
    guard let data = string.data(using: .utf8) else { return nil }
    let filter = CIFilter(name: "CIQRCodeGenerator")
    filter?.setValue(data, forKey: "inputMessage")
    filter?.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter?.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    return CIContext().createCGImage(scaled, from: scaled.extent)
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

    public init(
        eventID: String = UUID().uuidString,
        eventName: String = "New Event",
        photoCount: Int = 3,
        countdownSeconds: Int = 5,
        canvasWidth: CGFloat = 1200,
        canvasHeight: CGFloat = 1800,
        slots: [SharedPhotoSlot] = []
    ) {
        self.eventID = eventID
        self.eventName = eventName
        self.photoCount = photoCount
        self.countdownSeconds = countdownSeconds
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.slots = slots
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
