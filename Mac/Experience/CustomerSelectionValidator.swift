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

    func message(for language: CustomerLanguage) -> String {
        switch self {
        case .wrongEvent:
            return LocalizedText(english: "This selection belongs to another event.", thai: "ตัวเลือกนี้เป็นของงานอื่น")
                .value(for: language)
        case .staleCatalog:
            return LocalizedText(english: "The event options changed. Please choose again.", thai: "ตัวเลือกของงานเปลี่ยนแปลงแล้ว กรุณาเลือกใหม่อีกครั้ง")
                .value(for: language)
        case .missingTemplate:
            return LocalizedText(english: "The selected template is no longer available.", thai: "เทมเพลตที่เลือกไม่พร้อมใช้งานแล้ว")
                .value(for: language)
        case .disabledTemplate:
            return LocalizedText(english: "The selected template is disabled.", thai: "เทมเพลตที่เลือกถูกปิดใช้งาน")
                .value(for: language)
        case .disallowedFilter:
            return LocalizedText(english: "The selected filter is not available for this event.", thai: "ฟิลเตอร์ที่เลือกไม่พร้อมใช้งานสำหรับงานนี้")
                .value(for: language)
        case .invalidTemplate:
            return LocalizedText(english: "The selected template is invalid.", thai: "เทมเพลตที่เลือกไม่ถูกต้อง")
                .value(for: language)
        case .unsupportedLanguage:
            return LocalizedText(english: "The selected language is not supported.", thai: "ไม่รองรับภาษาที่เลือก")
                .value(for: language)
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
