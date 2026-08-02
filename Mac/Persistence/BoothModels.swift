import Foundation
import SwiftData
import CoreGraphics

@Model
final class BoothEvent {
    var id: String
    var name: String
    var createdAt: Date
    var photoCount: Int
    var countdownSeconds: Int
    var isActive: Bool
    var canvasWidth: Double
    var canvasHeight: Double
    var framePNGPath: String?      // relative to App Support
    var cameraRotationDegrees: Int // ponytail: calibration knob for physical camera mounting (0/90/180/270)
    @Relationship(deleteRule: .cascade) var slots: [BoothSlot]
    @Relationship(deleteRule: .cascade) var sessions: [BoothSession]

    init(name: String, photoCount: Int = 3, countdownSeconds: Int = 5) {
        self.id = UUID().uuidString
        self.name = name
        self.createdAt = Date()
        self.photoCount = photoCount
        self.countdownSeconds = countdownSeconds
        self.isActive = false
        self.canvasWidth = 900    // 3 inches × 300 dpi
        self.canvasHeight = 1200  // 4 inches × 300 dpi
        self.cameraRotationDegrees = 0
        self.slots = []
        self.sessions = []
    }

    func toEventConfig() -> EventConfig {
        EventConfig(
            eventID: id,
            eventName: name,
            photoCount: photoCount,
            countdownSeconds: countdownSeconds,
            canvasWidth: canvasWidth,
            canvasHeight: canvasHeight,
            slots: slots.sorted { $0.zOrder < $1.zOrder }.map {
                SharedPhotoSlot(
                    id: $0.id,
                    normalizedRect: CGRect(x: $0.normX, y: $0.normY, width: $0.normW, height: $0.normH),
                    rotation: $0.rotation,
                    zOrder: $0.zOrder,
                    photoIndex: $0.photoIndex
                )
            }
        )
    }
}

@Model
final class BoothSlot {
    var id: String
    var normX: Double
    var normY: Double
    var normW: Double
    var normH: Double
    var rotation: Double
    var zOrder: Int
    var photoIndex: Int   // which capture (0-based) this slot displays; allows mirror/duplicate
    var event: BoothEvent?

    init(normX: Double = 0.05, normY: Double = 0.05, normW: Double = 0.9, normH: Double = 0.3,
         rotation: Double = 0, zOrder: Int = 0, photoIndex: Int = 0) {
        self.id = UUID().uuidString
        self.normX = normX; self.normY = normY
        self.normW = normW; self.normH = normH
        self.rotation = rotation; self.zOrder = zOrder
        self.photoIndex = photoIndex
    }
}

@Model
final class BoothSession {
    var id: String
    var eventID: String
    var startedAt: Date
    var finishedAt: Date?
    var photoCount: Int
    var stripPath: String?        // relative to Sessions dir
    var gifPath: String?
    var downloadToken: String
    var event: BoothEvent?
    @Relationship(deleteRule: .cascade) var shots: [CapturedShot]

    init(eventID: String, photoCount: Int) {
        self.id = UUID().uuidString
        self.eventID = eventID
        self.startedAt = Date()
        self.photoCount = photoCount
        self.downloadToken = UUID().uuidString
        self.shots = []
    }
}

@Model
final class CapturedShot {
    var id: String
    var sessionID: String
    var photoIndex: Int
    var imagePath: String?
    var retakeCount: Int
    var session: BoothSession?

    init(sessionID: String, photoIndex: Int) {
        self.id = UUID().uuidString
        self.sessionID = sessionID
        self.photoIndex = photoIndex
        self.retakeCount = 0
    }
}
