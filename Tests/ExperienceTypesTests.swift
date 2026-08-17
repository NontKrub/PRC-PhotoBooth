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
        #expect(config.qrCodeElements.isEmpty)
        #expect(config.gifQualityPreset == .balanced)
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
            eventGalleryPath: "/e/token",
            qrCodeElements: [
                SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2), rotation: 5, zOrder: 3),
                SharedQRCodeElement(id: "qr-2", normalizedRect: CGRect(x: 0.6, y: 0.7, width: 0.15, height: 0.15), zOrder: 4)
            ],
            gifQualityPreset: .high
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(EventConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("GIF quality presets provide the intended defaults")
    func gifQualityPresetValues() {
        #expect(GIFQualityPreset.compact.maxDimension == 320)
        #expect(GIFQualityPreset.compact.frameRate == 8)
        #expect(GIFQualityPreset.compact.frameCount == 40)
        #expect(GIFQualityPreset.balanced.maxDimension == 360)
        #expect(GIFQualityPreset.balanced.frameRate == 8)
        #expect(GIFQualityPreset.balanced.frameCount == 40)
        #expect(abs(GIFQualityPreset.balanced.duration - 5) < 0.001)
        #expect(GIFQualityPreset.high.maxDimension == 480)
        #expect(GIFQualityPreset.high.frameRate == 12)
        #expect(GIFQualityPreset.high.frameCount == 60)
    }

    @Test("legacy experience documents default GIF quality to Balanced")
    func legacyExperienceDocumentDefaultsGIFQuality() throws {
        let document = makeExperienceDocument()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        object.removeValue(forKey: "gifQualityPreset")

        let decoded = try JSONDecoder().decode(
            EventExperienceDocument.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.gifQualityPreset == .balanced)
    }

    @Test("experience documents persist a selected GIF quality preset")
    func experienceDocumentPersistsGIFQuality() throws {
        var document = makeExperienceDocument()
        document.gifQualityPreset = .compact

        let decoded = try JSONDecoder().decode(
            EventExperienceDocument.self,
            from: JSONEncoder().encode(document)
        )

        #expect(decoded.gifQualityPreset == .compact)
    }

    @Test("legacy EventTemplateDefinition decodes without QR elements")
    func decodesLegacyTemplate() throws {
        let template = EventTemplateDefinition(
            id: "template-legacy",
            name: LocalizedText(english: "Legacy"),
            photoCount: 1,
            canvasWidth: 400,
            canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        object["qrCodeElements"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(EventTemplateDefinition.self, from: legacyData)
        #expect(decoded.qrCodeElements.isEmpty)
        #expect(decoded.slots == template.slots)
    }

    @Test("EventTemplateDefinition QR elements round trip")
    func templateQRCodeRoundTrip() throws {
        let template = EventTemplateDefinition(
            id: "template-qr",
            name: LocalizedText(english: "QR"),
            photoCount: 1,
            canvasWidth: 400,
            canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))],
            qrCodeElements: [SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2))]
        )

        let decoded = try JSONDecoder().decode(EventTemplateDefinition.self, from: JSONEncoder().encode(template))
        #expect(decoded == template)
    }

    @Test("legacy templates decode without a foreground overlay")
    func legacyTemplateDecodesWithoutForegroundOverlay() throws {
        let template = EventTemplateDefinition(
            name: LocalizedText(english: "Legacy"), photoCount: 1, canvasWidth: 400, canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as? [String: Any])
        object.removeValue(forKey: "foregroundOverlayFileName")
        let decoded = try JSONDecoder().decode(EventTemplateDefinition.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.foregroundOverlayFileName == nil)
    }

    @Test("foreground overlay filename round trips")
    func foregroundOverlayRoundTrips() throws {
        let template = EventTemplateDefinition(
            name: LocalizedText(english: "Overlay"), photoCount: 1, canvasWidth: 400, canvasHeight: 600,
            foregroundOverlayFileName: "foreground.png",
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))]
        )
        #expect(try JSONDecoder().decode(EventTemplateDefinition.self, from: JSONEncoder().encode(template)).foregroundOverlayFileName == "foreground.png")
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
            .sessionPrepared(
                config: EventConfig(
                    customerLanguage: .thai,
                    qrCodeElements: [SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))]
                ),
                presentation: SessionPresentation(sessionID: "session-1", language: .thai, templateDisplayName: "คลาสสิก", filterID: .warm, prompts: []),
                context: SessionMessageContext(sessionID: "session-1", sequence: 1)
            )
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

    @Test("selected template QR elements are copied into EventConfig")
    func eventConfigBuilderCopiesQRCodeElements() throws {
        let qrElements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), zOrder: 4),
            SharedQRCodeElement(id: "qr-2", normalizedRect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2), zOrder: 5)
        ]
        let template = EventTemplateDefinition(
            id: "template-selected",
            name: LocalizedText(english: "Selected"),
            photoCount: 1,
            canvasWidth: 900,
            canvasHeight: 1200,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)],
            qrCodeElements: qrElements
        )
        let document = EventExperienceDocument(
            id: "event-1",
            eventID: "event-1",
            revision: "revision-1",
            defaultTemplateID: template.id,
            templates: [template],
            gallery: EventGalleryConfiguration()
        )
        let selection = ValidatedCustomerSelection(
            eventID: "event-1",
            experienceRevision: "revision-1",
            template: template,
            filterID: .original,
            language: .english
        )

        let config = try EventConfigBuilder().build(
            event: BoothEventSnapshot(
                id: "event-1",
                name: "Event",
                photoCount: 1,
                countdownSeconds: 5,
                canvasWidth: 900,
                canvasHeight: 1200,
                framePNGURL: nil,
                slots: template.slots
            ),
            document: document,
            selection: selection,
            galleryPath: nil
        )

        #expect(config.qrCodeElements == qrElements)
        #expect(config.gifQualityPreset == .balanced)
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
