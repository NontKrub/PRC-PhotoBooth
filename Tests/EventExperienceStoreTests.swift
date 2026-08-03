import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PRC_PhotoBooth_Mac

@Suite("EventExperienceStore")
struct EventExperienceStoreTests {
    @Test("migrates a legacy event once and preserves template identity")
    func migrationIsIdempotent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = root.appendingPathComponent("legacy.png")
        try makeImage().writePNG(to: frame)
        let event = BoothEventSnapshot(
            id: "event-1",
            name: "Legacy",
            photoCount: 1,
            countdownSeconds: 5,
            canvasWidth: 400,
            canvasHeight: 600,
            framePNGURL: frame,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)]
        )
        let store = EventExperienceStore(baseDirectory: root)
        let first = try await store.ensureDocument(for: event)
        let second = try await store.ensureDocument(for: event)

        #expect(first.templates.count == 1)
        #expect(first.templates[0].id == second.templates[0].id)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("EventExperiences/event-1/Templates/\(first.templates[0].id)/frame.png").path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("EventExperiences/event-1/Templates/\(first.templates[0].id)/preview.jpg").path))
    }

    @Test("save is atomic and survives store recreation")
    func saveAndLoad() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = validTemplate()
        let document = EventExperienceDocument(id: "event-1", eventID: "event-1", defaultTemplateID: template.id, templates: [template], gallery: EventGalleryConfiguration())
        try await EventExperienceStore(baseDirectory: root).save(document)

        let loaded = try await EventExperienceStore(baseDirectory: root).load(eventID: "event-1")
        #expect(loaded.schemaVersion == document.schemaVersion)
        #expect(loaded.id == document.id)
        #expect(loaded.eventID == document.eventID)
        #expect(loaded.revision == document.revision)
        #expect(loaded.templates.count == document.templates.count)
        #expect(loaded.templates[0].id == document.templates[0].id)
        #expect(loaded.templates[0].name == document.templates[0].name)
        #expect(loaded.templates[0].slots == document.templates[0].slots)
        #expect(abs(loaded.templates[0].createdAt.timeIntervalSince(document.templates[0].createdAt)) < 1)
        #expect(abs(loaded.templates[0].updatedAt.timeIntervalSince(document.templates[0].updatedAt)) < 1)
        #expect(loaded.gallery == document.gallery)
        #expect(abs(loaded.createdAt.timeIntervalSince(document.createdAt)) < 1)
        #expect(abs(loaded.updatedAt.timeIntervalSince(document.updatedAt)) < 1)
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("EventExperiences/event-1"), includingPropertiesForKeys: nil)
        #expect(files.map(\.lastPathComponent).contains("experience.json"))
        #expect(files.allSatisfy { !$0.lastPathComponent.hasPrefix(".experience-") })
    }

    @Test("corrupt documents stay in place and get a timestamped preserved copy")
    func corruptDocumentIsPreserved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("EventExperiences/event-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("experience.json")
        try Data("{broken".utf8).write(to: document)

        do {
            _ = try await EventExperienceStore(baseDirectory: root).load(eventID: "event-1")
            Issue.record("Expected corrupt document error")
        } catch let error as EventExperienceError {
            guard case .corrupt = error else { Issue.record("Wrong error: \(error)"); return }
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(files.contains { $0.lastPathComponent.hasPrefix("experience-corrupt-") })
    }

    @Test("prompt import converts image to JPEG in event package")
    func importsPromptImage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try makeImage().writePNG(to: source)

        let imported = try await EventExperienceStore(baseDirectory: root)
            .importPromptImage(eventID: "event-1", promptID: "prompt-1", sourceURL: source)
        #expect(imported.fileName == "prompt-1.jpg")
        #expect(FileManager.default.fileExists(atPath: imported.url.path))
        #expect(CGImageSourceCreateWithURL(imported.url as CFURL, nil) != nil)
        #expect(imported.url.pathExtension == "jpg")
    }

    private func validTemplate(id: String = "template-1") -> EventTemplateDefinition {
        EventTemplateDefinition(
            id: id,
            name: LocalizedText(english: "Template"),
            photoCount: 1,
            canvasWidth: 400,
            canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)]
        )
    }
}

private func makeImage() -> CGImage {
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return context.makeImage()!
}

private extension CGImage {
    func writePNG(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-Experience-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
