import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import Testing
import UniformTypeIdentifiers

@testable import PRC_PhotoBooth_Mac

@Suite("EventExperienceStore")
struct EventExperienceStoreTests {
    @Test("new events without legacy slots receive usable template slots")
    func createsDefaultSlotsForNewEvent() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await EventExperienceStore(baseDirectory: root).ensureDocument(for: BoothEventSnapshot(
            id: "event-no-slots", name: "New", photoCount: 3, countdownSeconds: 5,
            canvasWidth: 400, canvasHeight: 600, framePNGURL: nil, slots: []
        ))
        #expect(document.templates[0].slots.map(\.photoIndex) == [0, 1, 2])
    }

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

        let data = try await store.readTemplateFrame(
            eventID: "event-1",
            templateID: template.id,
            fileName: "frame.png"
        )
        #expect(data != nil)
        #expect(data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) } != nil)
    }

    @Test("reads a draft frame filename without reloading the persisted document")
    func readsDraftFrameBeforeSave() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = validTemplate()
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: template))

        let directory = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/\(template.id)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeImage().writePNG(to: directory.appendingPathComponent("frame.png"))

        let data = try await store.readTemplateFrame(
            eventID: "event-1",
            templateID: template.id,
            fileName: "frame.png"
        )
        #expect(data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) } != nil)
    }

    @Test("reads a duplicated staged frame before saving")
    func readsDuplicatedStagedFrameBeforeSave() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceTemplate = validTemplate(id: "template-a")
        sourceTemplate.frameFileName = "frame.png"
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: sourceTemplate))

        let sourceURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-a/frame.png"
        )
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceData = try pngData(from: makeImage())
        try sourceData.write(to: sourceURL)

        let session = try await store.beginEditing(eventID: "event-1")
        try await store.duplicateTemplateAssets(
            eventID: "event-1",
            sourceTemplateID: sourceTemplate.id,
            destinationTemplateID: "template-b",
            promptIDMap: [:],
            editingSession: session
        )

        let data = try await store.readTemplateFrame(
            eventID: "event-1",
            templateID: "template-b",
            fileName: "frame.png",
            editingSession: session
        )
        #expect(data == sourceData)
        try await store.discardEditing(session)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-b"
        ).path))
    }

    @Test("failed template duplication removes partial staged assets before save")
    func failedDuplicationCleansStagedAssets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceTemplate = validTemplate(id: "template-a")
        sourceTemplate.frameFileName = "frame.png"
        let prompt = PosePromptDefinition(
            id: "prompt-a",
            photoIndex: 0,
            title: LocalizedText(english: "Pose"),
            imageFileName: "prompt-a.jpg"
        )
        sourceTemplate.posePrompts = [prompt]
        let store = EventExperienceStore(baseDirectory: root)
        let document = document(for: sourceTemplate)
        try await store.save(document)

        let sourceFrame = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-a/frame.png"
        )
        try FileManager.default.createDirectory(at: sourceFrame.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(from: makeImage()).write(to: sourceFrame)
        let sourcePrompt = root.appendingPathComponent("EventExperiences/event-1/Prompts/prompt-a.jpg")
        try FileManager.default.createDirectory(at: sourcePrompt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: sourcePrompt)

        let session = try await store.beginEditing(eventID: "event-1")
        let stagingEvent = root.appendingPathComponent(
            "EventExperiences/.editor-staging/\(session.id)/event-1"
        )
        try FileManager.default.createDirectory(at: stagingEvent, withIntermediateDirectories: true)
        let promptsBlocker = stagingEvent.appendingPathComponent("Prompts")
        try Data([9]).write(to: promptsBlocker)

        do {
            try await store.duplicateTemplateAssets(
                eventID: "event-1",
                sourceTemplateID: sourceTemplate.id,
                destinationTemplateID: "template-b",
                promptIDMap: ["prompt-a": "prompt-b"],
                editingSession: session
            )
            Issue.record("Expected prompt duplication to fail")
        } catch {
            // Expected: the prompt directory is deliberately a file.
        }

        let stagedTemplate = stagingEvent.appendingPathComponent("Templates/template-b")
        #expect(!FileManager.default.fileExists(atPath: stagedTemplate.path))
        try FileManager.default.removeItem(at: promptsBlocker)
        try await store.commitEditing(session, document: document)

        let loaded = try await store.load(eventID: "event-1")
        #expect(loaded.templates.map(\.id) == ["template-a"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-b"
        ).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "EventExperiences/event-1/Prompts/prompt-b.jpg"
        ).path))
    }

    @Test("draft-aware preview reads prefer staged assets")
    func draftAwarePreviewReadsPreferStagedAssets() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceTemplate = validTemplate(id: "template-a")
        sourceTemplate.previewFileName = "preview.jpg"
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: sourceTemplate))

        let livePreviewURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-a/preview.jpg"
        )
        try FileManager.default.createDirectory(at: livePreviewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([9]).write(to: livePreviewURL)

        let session = try await store.beginEditing(eventID: "event-1")
        try await store.duplicateTemplateAssets(
            eventID: "event-1",
            sourceTemplateID: sourceTemplate.id,
            destinationTemplateID: "template-b",
            promptIDMap: [:],
            editingSession: session
        )
        let stagedURL = root.appendingPathComponent("EventExperiences").appendingPathComponent(
            ".editor-staging/\(session.id)/event-1/Templates/template-b/preview.jpg"
        )
        let expected = Data([1, 2, 3])
        try expected.write(to: stagedURL)

        var duplicate = sourceTemplate
        duplicate.id = "template-b"
        let previews = try await store.readTemplatePreviews(
            eventID: "event-1",
            templates: [duplicate],
            editingSession: session
        )
        #expect(previews[duplicate.id] == expected)
        try await store.discardEditing(session)
    }

    @Test("foreground-only staging regenerates the draft preview and cancel preserves live state")
    func foregroundOnlyDraftPreview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = validTemplate()
        template.frameFileName = "frame.png"
        template.previewFileName = "preview.jpg"
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: template))

        let directory = root.appendingPathComponent("EventExperiences/event-1/Templates/template-1")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try makeImage(color: CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
            .writePNG(to: directory.appendingPathComponent("frame.png"))
        let livePreview = Data([9])
        try livePreview.write(to: directory.appendingPathComponent("preview.jpg"))

        let session = try await store.beginEditing(eventID: "event-1")
        let overlaySource = root.appendingPathComponent("overlay.png")
        try makeImage(color: CGColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 0.7))
            .writePNG(to: overlaySource)
        _ = try await store.importTemplateForegroundOverlay(
            eventID: "event-1",
            templateID: template.id,
            sourceURL: overlaySource,
            editingSession: session
        )

        var draft = template
        draft.foregroundOverlayFileName = "foreground.png"
        let previews = try await store.readTemplatePreviews(
            eventID: "event-1",
            templates: [draft],
            editingSession: session
        )
        let preview = try #require(previews[draft.id])
        #expect(preview != livePreview)
        #expect(CGImageSourceCreateWithData(preview as CFData, nil) != nil)

        try await store.discardEditing(session)
        #expect(try Data(contentsOf: directory.appendingPathComponent("preview.jpg")) == livePreview)
        #expect((try await store.load(eventID: "event-1")).templates[0].foregroundOverlayFileName == nil)
    }

    @Test("singular preview reads an unsaved duplicated template")
    func readsUnsavedDuplicatedTemplatePreview() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceTemplate = validTemplate(id: "template-a")
        sourceTemplate.previewFileName = "preview.jpg"
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: sourceTemplate))

        let sourceURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-a/preview.jpg"
        )
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let expected = Data([4, 5, 6])
        try expected.write(to: sourceURL)

        let session = try await store.beginEditing(eventID: "event-1")
        try await store.duplicateTemplateAssets(
            eventID: "event-1",
            sourceTemplateID: sourceTemplate.id,
            destinationTemplateID: "template-b",
            promptIDMap: [:],
            editingSession: session
        )

        #expect(try await store.readTemplatePreview(
            eventID: "event-1",
            templateID: "template-b",
            editingSession: session
        ) == expected)
        try await store.discardEditing(session)
    }

    @Test("duplicated staged frame saves into live template assets")
    func savesDuplicatedStagedFrame() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var sourceTemplate = validTemplate(id: "template-a")
        sourceTemplate.frameFileName = "frame.png"
        let store = EventExperienceStore(baseDirectory: root)
        var document = document(for: sourceTemplate)
        try await store.save(document)

        let sourceURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-a/frame.png"
        )
        try FileManager.default.createDirectory(at: sourceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(from: makeImage()).write(to: sourceURL)

        let session = try await store.beginEditing(eventID: "event-1")
        try await store.duplicateTemplateAssets(
            eventID: "event-1",
            sourceTemplateID: sourceTemplate.id,
            destinationTemplateID: "template-b",
            promptIDMap: [:],
            editingSession: session
        )
        var duplicate = sourceTemplate
        duplicate.id = "template-b"
        document.templates.append(duplicate)
        try await store.commitEditing(session, document: document)

        let liveURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/template-b/frame.png"
        )
        #expect(FileManager.default.fileExists(atPath: liveURL.path))
        #expect(try await store.readTemplateFrame(
            eventID: "event-1",
            templateID: "template-b",
            fileName: "frame.png"
        ) != nil)
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
            _ = try await store.readTemplateFrame(
                eventID: "event-1",
                templateID: template.id,
                fileName: template.frameFileName!
            )
            Issue.record("Expected unsafe frame filename to be rejected")
        } catch let error as EventExperienceError {
            guard case .invalid = error else { Issue.record("Wrong error: \(error)"); return }
        }
    }

    @Test("rejects dot and separator path components")
    func rejectsUnsafePathComponents() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = validTemplate()
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: template))

        for fileName in [".", "..", "/absolute.png", "a\\b", "a\0b"] {
            do {
                _ = try await store.readTemplateFrame(
                    eventID: "event-1",
                    templateID: template.id,
                    fileName: fileName
                )
                Issue.record("Expected unsafe filename to be rejected: \(fileName)")
            } catch is EventExperienceError {
                // Expected.
            }
        }

        do {
            _ = try await store.readTemplateFrame(eventID: "..", templateID: template.id, fileName: "frame.png")
            Issue.record("Expected unsafe event ID to be rejected")
        } catch is EventExperienceError {
            // Expected.
        }
        do {
            _ = try await store.readTemplateFrame(eventID: "event-1", templateID: "..", fileName: "frame.png")
            Issue.record("Expected unsafe template ID to be rejected")
        } catch is EventExperienceError {
            // Expected.
        }
    }

    @Test("staged frame replacement is discarded without touching the live asset")
    func discardsStagedFrameReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = validTemplate()
        template.frameFileName = "frame.png"
        let store = EventExperienceStore(baseDirectory: root)
        let document = document(for: template)
        try await store.save(document)

        let liveURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/\(template.id)/frame.png"
        )
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = try pngData(from: makeImage(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1)))
        try original.write(to: liveURL)
        let replacement = root.appendingPathComponent("replacement.png")
        try pngData(from: makeImage(color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))).write(to: replacement)

        let session = try await store.beginEditing(eventID: "event-1")
        let imported = try await store.importTemplateFrame(
            eventID: "event-1",
            templateID: template.id,
            sourceURL: replacement,
            editingSession: session
        )
        #expect(imported.url.path.contains(".editor-staging"))
        #expect(try Data(contentsOf: liveURL) == original)

        try await store.discardEditing(session)
        #expect(try Data(contentsOf: liveURL) == original)
    }

    @Test("saving an editor session commits the staged replacement")
    func commitsStagedFrameReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var template = validTemplate()
        template.frameFileName = "frame.png"
        let store = EventExperienceStore(baseDirectory: root)
        let document = document(for: template)
        try await store.save(document)

        let liveURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/\(template.id)/frame.png"
        )
        try FileManager.default.createDirectory(at: liveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData(from: makeImage(color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))).write(to: liveURL)
        let replacement = root.appendingPathComponent("replacement.png")
        let replacementData = try pngData(from: makeImage(color: CGColor(red: 0, green: 0, blue: 1, alpha: 1)))
        try replacementData.write(to: replacement)

        let session = try await store.beginEditing(eventID: "event-1")
        _ = try await store.importTemplateFrame(
            eventID: "event-1",
            templateID: template.id,
            sourceURL: replacement,
            editingSession: session
        )
        try await store.commitEditing(session, document: document)

        #expect(try Data(contentsOf: liveURL) == replacementData)
        #expect((try await store.load(eventID: "event-1")).templates[0].frameFileName == "frame.png")
    }

    @Test("committed editor state survives a later preview rebuild failure")
    func committedStateSurvivesPreviewFailure() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EventExperienceStore(baseDirectory: root)
        let original = document(for: validTemplate())
        try await store.save(original)

        var committed = original
        committed.templates[0].name = LocalizedText(english: "Saved", thai: "")
        let session = try await store.beginEditing(eventID: "event-1")
        try await store.commitEditing(session, document: committed)

        let templateDirectory = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/\(committed.templates[0].id)"
        )
        try FileManager.default.createDirectory(at: templateDirectory, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: templateDirectory)
        try Data([1]).write(to: templateDirectory)

        do {
            _ = try await store.rebuildPreview(eventID: "event-1", templateID: committed.templates[0].id)
            Issue.record("Expected preview rebuild to fail")
        } catch {
            // Expected: the template asset directory is deliberately blocked.
        }

        #expect((try await store.load(eventID: "event-1")).templates[0].name.english == "Saved")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            "EventExperiences/.editor-staging/\(session.id)"
        ).path))
    }

    @Test("new staged frame disappears when editing is cancelled")
    func discardsNewStagedFrame() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let template = validTemplate()
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document(for: template))
        let source = root.appendingPathComponent("replacement.png")
        try pngData(from: makeImage(color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))).write(to: source)

        let session = try await store.beginEditing(eventID: "event-1")
        _ = try await store.importTemplateFrame(
            eventID: "event-1",
            templateID: template.id,
            sourceURL: source,
            editingSession: session
        )
        try await store.discardEditing(session)

        let liveURL = root.appendingPathComponent(
            "EventExperiences/event-1/Templates/\(template.id)/frame.png"
        )
        #expect(!FileManager.default.fileExists(atPath: liveURL.path))
        #expect((try await store.load(eventID: "event-1")).templates[0].frameFileName == nil)
    }

    @Test("bulk preview reads skip missing assets")
    func readsAvailableTemplatePreviews() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var available = validTemplate(id: "template-1")
        available.previewFileName = "preview.jpg"
        var missing = validTemplate(id: "template-2")
        missing.previewFileName = "preview.jpg"
        let document = EventExperienceDocument(
            id: "event-1",
            eventID: "event-1",
            defaultTemplateID: available.id,
            templates: [available, missing],
            gallery: EventGalleryConfiguration()
        )
        let store = EventExperienceStore(baseDirectory: root)
        try await store.save(document)
        let directory = root
            .appendingPathComponent("EventExperiences", isDirectory: true)
            .appendingPathComponent("event-1", isDirectory: true)
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(available.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = Data([1, 2, 3] as [UInt8])
        try expected.write(to: directory.appendingPathComponent("preview.jpg"))

        let previews = try await store.readTemplatePreviews(
            eventID: "event-1",
            templates: [available, missing]
        )
        #expect(previews[available.id] == expected)
        #expect(previews[missing.id] == nil)
    }

    @Test("bulk preview reads honor cancellation")
    func cancelsPreviewReads() async throws {
        let store = EventExperienceStore(baseDirectory: try temporaryDirectory())
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let task = Task {
            for await _ in stream { break }
            _ = try await store.readTemplatePreviews(eventID: "event-1", templates: [])
        }
        task.cancel()
        continuation.yield(())
        continuation.finish()

        do {
            _ = try await task.value
            Issue.record("Expected preview read cancellation")
        } catch is CancellationError {
            // Expected.
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

private func makeImage(
    color: CGColor = CGColor(red: 0.8, green: 0.3, blue: 0.2, alpha: 1)
) -> CGImage {
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    return context.makeImage()!
}

private func pngData(from image: CGImage) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: url) }
    try image.writePNG(to: url)
    return try Data(contentsOf: url)
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
