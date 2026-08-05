import Foundation
import CoreGraphics
import ImageIO
import SwiftData
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

    @Test("reads a template frame from its package")
    func readsTemplateFrame() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = validTemplate()
        template.frameFileName = "frame.png"
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: template))
        let directory = root
            .appendingPathComponent("EventExperiences", isDirectory: true)
            .appendingPathComponent("event-1", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(template.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeImage().writePNG(to: directory.appendingPathComponent("frame.png"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frame.png").path))
        #expect((try await store.load(eventID: "event-1")).templates[0].frameFileName == "frame.png")

        let data = try await store.readTemplateFrame(eventID: "event-1", templateID: template.id)
        #expect(data != nil)
        #expect(data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) } != nil)
    }

    @Test("rejects traversal in a template frame filename")
    func rejectsUnsafeTemplateFrameFilename() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = validTemplate()
        template.frameFileName = "../outside.png"
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: template))

        do {
            _ = try await store.readTemplateFrame(eventID: "event-1", templateID: template.id)
            Issue.record("Expected unsafe frame filename to be rejected")
        } catch let error as EventExperienceError {
            guard case .invalid = error else { Issue.record("Wrong error: \(error)"); return }
        }
    }

    @Test("accepts templates with zero or multiple QR elements")
    func validatesQRCodeCounts() async throws {
        let store = EventExperienceStore(baseDirectory: try temporaryDirectory())
        try await store.validate(document(for: validTemplate()))

        var template = validTemplate()
        template.qrCodeElements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)),
            SharedQRCodeElement(id: "qr-2", normalizedRect: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2))
        ]
        try await store.validate(document(for: template))
    }

    @Test("rejects zero-size QR elements")
    func rejectsZeroSizeQRCode() async throws {
        var template = validTemplate()
        template.qrCodeElements = [SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0, y: 0, width: 0, height: 0.2))]
        try await expectInvalid(store: EventExperienceStore(baseDirectory: try temporaryDirectory()), document: document(for: template), containing: "QR")
    }

    @Test("rejects non-finite QR coordinates")
    func rejectsNonFiniteQRCode() async throws {
        var template = validTemplate()
        template.qrCodeElements = [SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: .nan, y: 0, width: 0.2, height: 0.2))]
        try await expectInvalid(store: EventExperienceStore(baseDirectory: try temporaryDirectory()), document: document(for: template), containing: "QR")
    }

    @Test("rejects duplicate QR IDs")
    func rejectsDuplicateQRCodeIDs() async throws {
        var template = validTemplate()
        template.qrCodeElements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2)),
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        ]
        try await expectInvalid(store: EventExperienceStore(baseDirectory: try temporaryDirectory()), document: document(for: template), containing: "QR")
    }

    @Test("rejects photo and QR ID collisions")
    func rejectsPhotoQRCodeIDCollision() async throws {
        var template = validTemplate()
        template.slots[0].id = "shared-id"
        template.qrCodeElements = [SharedQRCodeElement(id: "shared-id", normalizedRect: CGRect(x: 0, y: 0, width: 0.2, height: 0.2))]
        try await expectInvalid(store: EventExperienceStore(baseDirectory: try temporaryDirectory()), document: document(for: template), containing: "ID")
    }

    @Test("loads an old experience document without QR fields")
    func loadsLegacyExperienceDocument() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = document(for: validTemplate())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        var templates = try #require(object["templates"] as? [[String: Any]])
        templates[0]["qrCodeElements"] = nil
        object["templates"] = templates
        let directory = root.appendingPathComponent("EventExperiences/event-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("experience.json"))

        let loaded = try await EventExperienceStore(baseDirectory: root).load(eventID: "event-1")
        #expect(loaded.templates[0].qrCodeElements.isEmpty)
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

    private func document(for template: EventTemplateDefinition) -> EventExperienceDocument {
        EventExperienceDocument(
            id: "event-1",
            eventID: "event-1",
            defaultTemplateID: template.id,
            templates: [template],
            gallery: EventGalleryConfiguration()
        )
    }

    private func expectInvalid(
        store: EventExperienceStore,
        document: EventExperienceDocument,
        containing text: String
    ) async throws {
        do {
            try await store.validate(document)
            Issue.record("Expected validation to fail")
        } catch let error as EventExperienceError {
            guard case .invalid(let message) = error else {
                Issue.record("Expected invalid error, got \(error)")
                return
            }
            #expect(message.localizedCaseInsensitiveContains(text))
        }
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

@Suite("LegacyEventMirrorService")
struct LegacyEventMirrorServiceTests {
    @Test("mirrors the default template into legacy event fields")
    @MainActor
    func mirrorsDefaultTemplate() throws {
        let schema = Schema([BoothEvent.self, BoothSlot.self, BoothSession.self, CapturedShot.self])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let event = BoothEvent(name: "Legacy", photoCount: 1)
        context.insert(event)
        let template = EventTemplateDefinition(
            id: "template-1",
            name: LocalizedText(english: "Default"),
            photoCount: 3,
            canvasWidth: 1200,
            canvasHeight: 1800,
            frameFileName: "frame.png",
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.2), photoIndex: 2)]
        )
        let document = EventExperienceDocument(
            id: "event-1",
            eventID: "event-1",
            defaultTemplateID: template.id,
            templates: [template],
            gallery: EventGalleryConfiguration()
        )

        try LegacyEventMirrorService().updateLegacyEvent(event, using: document, modelContext: context)

        #expect(event.photoCount == 3)
        #expect(event.canvasWidth == 1200)
        #expect(event.canvasHeight == 1800)
        #expect(event.framePNGPath == "EventExperiences/event-1/Templates/template-1/frame.png")
        #expect(event.slots.count == 1)
        #expect(event.slots.first?.photoIndex == 2)
    }
}
