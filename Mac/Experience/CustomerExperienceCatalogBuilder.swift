import Foundation

struct CustomerExperienceCatalogBuilder {
    func build(
        event: BoothEventSnapshot,
        document: EventExperienceDocument
    ) -> CustomerExperienceCatalog {
        let templates = document.templates
            .filter(\.isEnabled)
            .sorted { lhs, rhs in
                if lhs.sortOrder == rhs.sortOrder { return lhs.id < rhs.id }
                return lhs.sortOrder < rhs.sortOrder
            }
            .map { template in
                CustomerTemplateOption(
                    id: template.id,
                    name: template.name,
                    photoCount: template.photoCount,
                    aspectRatio: template.canvasWidth / max(template.canvasHeight, 1),
                    previewAssetID: template.id
                )
            }
        return CustomerExperienceCatalog(
            schemaVersion: 1,
            eventID: event.id,
            eventName: event.name,
            revision: document.revision,
            defaultTemplateID: document.defaultTemplateID,
            guestTemplateSelectionEnabled: document.guestTemplateSelectionEnabled,
            templates: templates,
            allowedFilterIDs: PhotoFilterID.allCases.filter(document.allowedFilterIDs.contains),
            defaultFilterID: document.defaultFilterID,
            guestFilterSelectionEnabled: document.guestFilterSelectionEnabled,
            defaultLanguage: document.defaultCustomerLanguage,
            guestLanguageSelectionEnabled: document.guestLanguageSelectionEnabled
        )
    }
}
