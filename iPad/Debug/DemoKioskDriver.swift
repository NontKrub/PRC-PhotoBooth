#if DEBUG
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum DemoKioskDriver {
    static func install(on vm: iPadViewModel) {
        let classicID = "demo-classic"
        let squareID = "demo-square"
        vm.experienceCatalog = CustomerExperienceCatalog(
            eventID: "demo-event",
            eventName: "PRC PhotoBooth 1.2 Demo",
            revision: "demo-revision",
            defaultTemplateID: classicID,
            guestTemplateSelectionEnabled: true,
            templates: [
                CustomerTemplateOption(
                    id: classicID,
                    name: LocalizedText(english: "Classic Strip", thai: "สตริปคลาสสิก"),
                    photoCount: 3,
                    aspectRatio: 0.56,
                    previewAssetID: classicID
                ),
                CustomerTemplateOption(
                    id: squareID,
                    name: LocalizedText(english: "Square Collage", thai: "คอลลาจสี่เหลี่ยม"),
                    photoCount: 4,
                    aspectRatio: 1,
                    previewAssetID: squareID
                )
            ],
            allowedFilterIDs: [.original, .monochrome, .warm, .highContrast, .vintage],
            defaultFilterID: .original,
            guestFilterSelectionEnabled: true,
            defaultLanguage: .english,
            guestLanguageSelectionEnabled: true
        )
        if let image = FilterSampleRenderer.makeSampleImage() {
            vm.experienceAssets[classicID] = image
            vm.experienceAssets[squareID] = image
        }
        vm.eventConfig = EventConfig(
            eventID: "demo-event",
            eventName: "PRC PhotoBooth 1.2 Demo",
            photoCount: 3,
            countdownSeconds: 2,
            canvasWidth: 900,
            canvasHeight: 1600,
            slots: (0..<3).map { index in
                SharedPhotoSlot(
                    normalizedRect: CGRect(x: 0.1, y: 0.05 + Double(index) * 0.3, width: 0.8, height: 0.25),
                    zOrder: index,
                    photoIndex: index
                )
            },
        )
        vm.selectedTemplateID = classicID
        vm.selectedFilterID = .original
        vm.selectedLanguage = .english
    }

    static func startSession(on vm: iPadViewModel) {
        guard let catalog = vm.experienceCatalog,
              let templateID = vm.selectedTemplateID,
              let filterID = vm.selectedFilterID,
              let template = catalog.templates.first(where: { $0.id == templateID }) else { return }
        let config = EventConfig(
            eventID: catalog.eventID,
            eventName: catalog.eventName,
            photoCount: template.photoCount,
            countdownSeconds: 2,
            canvasWidth: template.aspectRatio == 1 ? 1200 : 900,
            canvasHeight: template.aspectRatio == 1 ? 1200 : 1600,
            slots: (0..<template.photoCount).map { index in
                SharedPhotoSlot(
                    normalizedRect: CGRect(
                        x: template.aspectRatio == 1 ? (index % 2 == 0 ? 0.05 : 0.525) : 0.1,
                        y: template.aspectRatio == 1 ? (index < 2 ? 0.05 : 0.525) : 0.05 + Double(index) * (0.9 / Double(template.photoCount)),
                        width: template.aspectRatio == 1 ? 0.425 : 0.8,
                        height: template.aspectRatio == 1 ? 0.425 : 0.2
                    ),
                    zOrder: index,
                    photoIndex: index
                )
            },
            templateID: template.id,
            templateName: template.name,
            selectedFilterID: filterID,
            customerLanguage: vm.selectedLanguage,
            experienceRevision: catalog.revision
        )
        let prompts = (0..<template.photoCount).map { index in
            SessionPromptPresentation(
                promptID: "demo-prompt-\(index)",
                photoIndex: index,
                title: vm.selectedLanguage == .thai
                    ? ["ยิ้ม", "ชี้ไปที่เพื่อน", "ทำหน้าตลก", "ฟรีสไตล์"][min(index, 3)]
                    : ["Smile", "Point at a friend", "Funny face", "Freestyle"][min(index, 3)],
                subtitle: "",
                imageData: nil
            )
        }
        vm.demoPrepareSession(
            config: config,
            presentation: SessionPresentation(
                sessionID: UUID().uuidString,
                language: vm.selectedLanguage,
                templateDisplayName: template.name.value(for: vm.selectedLanguage),
                filterID: filterID,
                prompts: prompts
            )
        )
    }
}

func jpegDataForDemo(_ image: CGImage) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}
#endif
