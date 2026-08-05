import Foundation

struct EventConfigBuilder {
    func build(
        event: BoothEventSnapshot,
        document: EventExperienceDocument,
        selection: ValidatedCustomerSelection,
        galleryPath: String?
    ) throws -> EventConfig {
        guard event.id == document.eventID, selection.eventID == event.id else {
            throw CustomerSelectionError.wrongEvent
        }
        let template = selection.template
        let prompts = template.posePrompts
            .filter(\.isEnabled)
            .sorted { $0.photoIndex < $1.photoIndex }
            .map {
                ResolvedPosePrompt(
                    id: $0.id,
                    photoIndex: $0.photoIndex,
                    title: $0.title,
                    subtitle: $0.subtitle,
                    assetID: $0.imageFileName
                )
            }
        return EventConfig(
            eventID: event.id,
            eventName: event.name,
            photoCount: template.photoCount,
            countdownSeconds: event.countdownSeconds,
            canvasWidth: template.canvasWidth,
            canvasHeight: template.canvasHeight,
            slots: template.slots,
            templateID: template.id,
            templateName: template.name,
            selectedFilterID: selection.filterID,
            customerLanguage: selection.language,
            posePrompts: prompts,
            experienceRevision: document.revision,
            eventGalleryPath: galleryPath,
            qrCodeElements: template.qrCodeElements
        )
    }
}
