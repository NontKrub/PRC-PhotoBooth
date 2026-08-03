#if DEBUG
import Foundation
import SwiftData

@MainActor
struct DemoDataSeeder {
    static let eventName = "PRC PhotoBooth 1.2 Demo"

    func seed(
        store: DataStore,
        experienceStore: EventExperienceStore,
        reset: Bool
    ) async throws -> BoothEvent {
        var event = store.fetchEvents().first { $0.name == Self.eventName }
        if !reset, let event { return event }
        if reset, let existing = event {
            try? await experienceStore.delete(eventID: existing.id)
            store.context.delete(existing)
            try? store.context.save()
            event = nil
        }
        let demoEvent = event ?? store.createEvent(name: Self.eventName, photoCount: 3, countdownSeconds: 3)
        demoEvent.isActive = true
        demoEvent.canvasWidth = 900
        demoEvent.canvasHeight = 1600
        demoEvent.photoCount = 3
        if demoEvent.slots.isEmpty {
            demoEvent.slots = (0..<3).map { index in
                BoothSlot(normX: 0.1, normY: 0.05 + Double(index) * 0.30, normW: 0.8, normH: 0.25, zOrder: index, photoIndex: index)
            }
            demoEvent.slots.forEach { store.context.insert($0) }
        }
        try store.context.save()

        var document = try await experienceStore.ensureDocument(for: BoothEventSnapshot(
            id: demoEvent.id,
            name: demoEvent.name,
            photoCount: demoEvent.photoCount,
            countdownSeconds: demoEvent.countdownSeconds,
            canvasWidth: demoEvent.canvasWidth,
            canvasHeight: demoEvent.canvasHeight,
            framePNGURL: nil,
            slots: demoEvent.slots.map {
                SharedPhotoSlot(
                    id: $0.id,
                    normalizedRect: CGRect(x: $0.normX, y: $0.normY, width: $0.normW, height: $0.normH),
                    rotation: $0.rotation,
                    zOrder: $0.zOrder,
                    photoIndex: $0.photoIndex
                )
            }
        ))
        let classicID = document.defaultTemplateID
        document.templates[0].name = LocalizedText(english: "Classic Strip", thai: "สตริปคลาสสิก")
        document.templates[0].photoCount = 3
        document.templates[0].canvasWidth = 900
        document.templates[0].canvasHeight = 1600
        document.templates[0].posePrompts = [
            PosePromptDefinition(photoIndex: 0, title: LocalizedText(english: "Smile", thai: "ยิ้ม")),
            PosePromptDefinition(photoIndex: 1, title: LocalizedText(english: "Point at a friend", thai: "ชี้ไปที่เพื่อน")),
            PosePromptDefinition(photoIndex: 2, title: LocalizedText(english: "Funny face", thai: "ทำหน้าตลก"))
        ]
        let square = EventTemplateDefinition(
            id: "00000000-0000-0000-0000-000000000002",
            name: LocalizedText(english: "Square Collage", thai: "คอลลาจสี่เหลี่ยม"),
            sortOrder: 1,
            photoCount: 4,
            canvasWidth: 1200,
            canvasHeight: 1200,
            slots: (0..<4).map { index in
                SharedPhotoSlot(
                    normalizedRect: CGRect(
                        x: index % 2 == 0 ? 0.05 : 0.525,
                        y: index < 2 ? 0.05 : 0.525,
                        width: 0.425,
                        height: 0.425
                    ),
                    zOrder: index,
                    photoIndex: index
                )
            },
            posePrompts: (0..<4).map { index in
                let titles = [
                    LocalizedText(english: "Smile", thai: "ยิ้ม"),
                    LocalizedText(english: "Point at a friend", thai: "ชี้ไปที่เพื่อน"),
                    LocalizedText(english: "Funny face", thai: "ทำหน้าตลก"),
                    LocalizedText(english: "Freestyle", thai: "ฟรีสไตล์")
                ]
                return PosePromptDefinition(photoIndex: index, title: titles[index])
            }
        )
        if !document.templates.contains(where: { $0.id == square.id }) {
            document.templates = [document.templates[0], square]
        }
        document.defaultTemplateID = classicID
        document.guestTemplateSelectionEnabled = true
        document.allowedFilterIDs = [.original, .monochrome, .warm, .highContrast, .vintage]
        document.defaultFilterID = .original
        document.guestFilterSelectionEnabled = true
        document.defaultCustomerLanguage = .english
        document.guestLanguageSelectionEnabled = true
        document.gallery = EventGalleryConfiguration(
            mode: .approvalRequired,
            title: LocalizedText(english: Self.eventName, thai: Self.eventName),
            language: .english,
            showGIFLinks: true
        )
        document.revision = UUID().uuidString
        document.updatedAt = Date()
        try await experienceStore.save(document)
        for template in document.templates {
            _ = try? await experienceStore.rebuildPreview(eventID: document.eventID, templateID: template.id)
        }
        try LegacyEventMirrorService().updateLegacyEvent(demoEvent, using: document, modelContext: store.context)
        for otherEvent in store.fetchEvents() where otherEvent.id != demoEvent.id {
            otherEvent.isActive = false
        }
        demoEvent.isActive = true
        try store.context.save()
        return demoEvent
    }
}
#endif
