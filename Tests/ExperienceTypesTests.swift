import Foundation
import CoreGraphics
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("V1.2 experience contracts")
struct ExperienceTypesTests {
    @Test("LocalizedText trims and falls back by language")
    func localizedTextFallback() {
        let text = LocalizedText(english: "  Hello  ", thai: "")
        #expect(text.value(for: .english) == "Hello")
        #expect(text.value(for: .thai) == "Hello")
        #expect(LocalizedText().value(for: .english) == "Untitled")
        #expect(LocalizedText().value(for: .thai) == "ไม่มีชื่อ")
    }

    @Test("photo filter names use the selected language")
    func photoFilterNamesUseSelectedLanguage() {
        #expect(PhotoFilterID.warm.displayName(for: .english) == "Warm")
        #expect(PhotoFilterID.warm.displayName(for: .thai) == "โทนอุ่น")
    }

    @Test("Version 1.1 EventConfig decodes with V1.2 defaults")
    func decodesLegacyEventConfig() throws {
        let data = Data(#"{"eventID":"event-1","eventName":"Legacy","photoCount":2,"countdownSeconds":4,"canvasWidth":900,"canvasHeight":1200,"slots":[]}"#.utf8)
        let config = try JSONDecoder().decode(EventConfig.self, from: data)

        #expect(config.eventID == "event-1")
        #expect(config.templateID == "legacy-default")
        #expect(config.templateName == LocalizedText())
        #expect(config.selectedFilterID == .original)
        #expect(config.customerLanguage == .english)
        #expect(config.posePrompts.isEmpty)
        #expect(config.experienceRevision.isEmpty)
        #expect(config.eventGalleryPath == nil)
    }

    @Test("V1.2 EventConfig fields round trip")
    func eventConfigRoundTrip() throws {
        let config = EventConfig(
            eventID: "event-2",
            templateID: "template-2",
            templateName: LocalizedText(english: "Classic", thai: "คลาสสิก"),
            selectedFilterID: .warm,
            customerLanguage: .thai,
            posePrompts: [ResolvedPosePrompt(id: "prompt-1", photoIndex: 0, title: LocalizedText(english: "Smile", thai: "ยิ้ม"), subtitle: LocalizedText(), assetID: nil)],
            experienceRevision: "rev-1",
            eventGalleryPath: "/e/token"
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(EventConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("Experience messages round trip with Thai strings")
    func experienceMessagesRoundTrip() throws {
        let catalog = CustomerExperienceCatalog(
            eventID: "event-1",
            eventName: "งานทดลอง",
            revision: "rev-1",
            defaultTemplateID: "template-1",
            guestTemplateSelectionEnabled: true,
            templates: [CustomerTemplateOption(id: "template-1", name: LocalizedText(english: "Classic", thai: "คลาสสิก"), photoCount: 3, aspectRatio: 0.75, previewAssetID: "template-1")],
            allowedFilterIDs: [.original, .warm],
            defaultFilterID: .warm,
            guestFilterSelectionEnabled: true,
            defaultLanguage: .thai,
            guestLanguageSelectionEnabled: true
        )
        let messages: [Message] = [
            .eventExperienceCatalog(catalog: catalog),
            .eventExperienceAsset(packet: ExperienceAssetPacket(eventID: "event-1", revision: "rev-1", assetID: "template-1", kind: .templatePreview, jpegData: Data([1, 2, 3]))),
            .customerSessionRequest(selection: CustomerSessionSelection(eventID: "event-1", experienceRevision: "rev-1", templateID: "template-1", filterID: .warm, language: .thai)),
            .sessionRequestRejected(reason: "เลือกใหม่"),
            .sessionPrepared(config: EventConfig(customerLanguage: .thai), presentation: SessionPresentation(sessionID: "session-1", language: .thai, templateDisplayName: "คลาสสิก", filterID: .warm, prompts: []))
        ]

        for message in messages {
            #expect(try Message.decoded(from: message.encoded()) == message)
        }
    }

    @Test("customer selection validation rejects stale or unavailable choices")
    func customerSelectionValidation() throws {
        let document = makeExperienceDocument()
        let validator = CustomerSelectionValidator()
        let valid = CustomerSessionSelection(
            eventID: "event-1",
            experienceRevision: "revision-1",
            templateID: "template-1",
            filterID: .warm,
            language: .thai
        )

        let result = try validator.validate(valid, against: document)
        #expect(result.template.id == "template-1")
        #expect(result.filterID == .warm)
        #expect(result.language == .thai)

        var wrongEvent = valid
        wrongEvent.eventID = "other-event"
        #expect(throws: CustomerSelectionError.wrongEvent) {
            try validator.validate(wrongEvent, against: document)
        }

        var stale = valid
        stale.experienceRevision = "old-revision"
        #expect(throws: CustomerSelectionError.staleCatalog) {
            try validator.validate(stale, against: document)
        }

        var disallowedFilter = valid
        disallowedFilter.filterID = .vintage
        #expect(throws: CustomerSelectionError.disallowedFilter) {
            try validator.validate(disallowedFilter, against: document)
        }

        var disabledTemplate = valid
        disabledTemplate.templateID = "disabled-template"
        #expect(throws: CustomerSelectionError.disabledTemplate) {
            try validator.validate(disabledTemplate, against: document)
        }
    }

    private func makeExperienceDocument() -> EventExperienceDocument {
        let slots = [
            SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.5), photoIndex: 0),
            SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), photoIndex: 1)
        ]
        return EventExperienceDocument(
            id: "event-1",
            eventID: "event-1",
            revision: "revision-1",
            defaultTemplateID: "template-1",
            allowedFilterIDs: [.original, .warm],
            defaultFilterID: .warm,
            templates: [
                EventTemplateDefinition(
                    id: "template-1",
                    name: LocalizedText(english: "Classic", thai: "คลาสสิก"),
                    photoCount: 2,
                    canvasWidth: 900,
                    canvasHeight: 1200,
                    slots: slots
                ),
                EventTemplateDefinition(
                    id: "disabled-template",
                    name: LocalizedText(english: "Disabled", thai: "ปิดใช้งาน"),
                    isEnabled: false,
                    photoCount: 2,
                    canvasWidth: 900,
                    canvasHeight: 1200,
                    slots: slots
                )
            ],
            gallery: EventGalleryConfiguration()
        )
    }
}
