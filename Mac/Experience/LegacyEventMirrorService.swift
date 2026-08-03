import Foundation
import SwiftData

@MainActor
struct LegacyEventMirrorService {
    func updateLegacyEvent(
        _ event: BoothEvent,
        using document: EventExperienceDocument,
        modelContext: ModelContext
    ) throws {
        guard let template = document.templates.first(where: { $0.id == document.defaultTemplateID }) else {
            throw EventExperienceError.invalid("Default template is missing.")
        }
        event.photoCount = template.photoCount
        event.canvasWidth = template.canvasWidth
        event.canvasHeight = template.canvasHeight
        event.framePNGPath = template.frameFileName.map {
            "EventExperiences/\(document.eventID)/Templates/\(template.id)/\($0)"
        }

        for slot in event.slots {
            modelContext.delete(slot)
        }
        event.slots = template.slots.sorted { $0.zOrder < $1.zOrder }.map { slot in
            BoothSlot(
                normX: slot.normalizedRect.origin.x,
                normY: slot.normalizedRect.origin.y,
                normW: slot.normalizedRect.width,
                normH: slot.normalizedRect.height,
                rotation: slot.rotation,
                zOrder: slot.zOrder,
                photoIndex: slot.photoIndex
            )
        }
        try modelContext.save()
    }
}
