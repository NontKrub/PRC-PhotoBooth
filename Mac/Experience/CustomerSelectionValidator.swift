import Foundation

struct ValidatedCustomerSelection: Sendable, Equatable {
    var eventID: String
    var experienceRevision: String
    var template: EventTemplateDefinition
    var filterID: PhotoFilterID
    var language: CustomerLanguage
}

struct CustomerSessionSelectionDraft: Sendable, Equatable {
    var eventID = ""
    var experienceRevision = ""
    var templateID = ""
    var filterID: PhotoFilterID = .original
    var language: CustomerLanguage = .english

    var selection: CustomerSessionSelection {
        CustomerSessionSelection(
            eventID: eventID,
            experienceRevision: experienceRevision,
            templateID: templateID,
            filterID: filterID,
            language: language
        )
    }
}

enum CustomerSelectionError: LocalizedError, Equatable {
    case wrongEvent
    case staleCatalog
    case missingTemplate
    case disabledTemplate
    case disallowedFilter
    case invalidTemplate(String)
    case unsupportedLanguage

    var errorDescription: String? {
        switch self {
        case .wrongEvent: return "This selection belongs to another event."
        case .staleCatalog: return "The event options changed. Please choose again."
        case .missingTemplate: return "The selected template is no longer available."
        case .disabledTemplate: return "The selected template is disabled."
        case .disallowedFilter: return "The selected filter is not available for this event."
        case .invalidTemplate(let message): return message
        case .unsupportedLanguage: return "The selected language is not supported."
        }
    }
}

struct CustomerSelectionValidator {
    func validate(
        _ selection: CustomerSessionSelection,
        against document: EventExperienceDocument
    ) throws -> ValidatedCustomerSelection {
        guard selection.eventID == document.eventID else { throw CustomerSelectionError.wrongEvent }
        guard selection.experienceRevision == document.revision else { throw CustomerSelectionError.staleCatalog }
        guard let template = document.templates.first(where: { $0.id == selection.templateID }) else {
            throw CustomerSelectionError.missingTemplate
        }
        guard template.isEnabled else { throw CustomerSelectionError.disabledTemplate }
        guard document.allowedFilterIDs.contains(selection.filterID) else {
            throw CustomerSelectionError.disallowedFilter
        }
        guard (1...8).contains(template.photoCount),
              !template.slots.isEmpty,
              (0..<template.photoCount).allSatisfy({ index in
                  template.slots.contains(where: { $0.photoIndex == index })
              }) else {
            throw CustomerSelectionError.invalidTemplate("The selected template is invalid.")
        }
        guard CustomerLanguage.allCases.contains(selection.language) else {
            throw CustomerSelectionError.unsupportedLanguage
        }
        return ValidatedCustomerSelection(
            eventID: selection.eventID,
            experienceRevision: selection.experienceRevision,
            template: template,
            filterID: selection.filterID,
            language: selection.language
        )
    }
}
