import Foundation
import ImageIO
import UniformTypeIdentifiers

actor EventExperienceStore {
    private let baseDirectory: URL
    private let fileManager = FileManager.default

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory.appendingPathComponent("EventExperiences", isDirectory: true)
    }

    func ensureDocument(for event: BoothEventSnapshot) throws -> EventExperienceDocument {
        let documentURL = try experienceURL(eventID: event.id)
        if fileManager.fileExists(atPath: documentURL.path) { return try load(eventID: event.id) }
        let templateID = UUID().uuidString
        let templateDirectory = try templateURL(eventID: event.id, templateID: templateID)
        try fileManager.createDirectory(at: templateDirectory, withIntermediateDirectories: true)
        var frameFileName: String?
        if let source = event.framePNGURL {
            guard fileManager.fileExists(atPath: source.path) else { throw EventExperienceError.missingAsset(source) }
            let destination = templateDirectory.appendingPathComponent("frame.png")
            try atomicCopy(source, to: destination)
            frameFileName = "frame.png"
        }
        let template = EventTemplateDefinition(
            id: templateID,
            name: LocalizedText(english: event.name),
            photoCount: min(max(event.photoCount, 1), 8),
            canvasWidth: event.canvasWidth,
            canvasHeight: event.canvasHeight,
            frameFileName: frameFileName,
            previewFileName: "preview.jpg",
            slots: event.slots,
            posePrompts: []
        )
        let document = EventExperienceDocument(
            id: event.id,
            eventID: event.id,
            defaultTemplateID: templateID,
            guestTemplateSelectionEnabled: false,
            allowedFilterIDs: [.original],
            defaultFilterID: .original,
            guestFilterSelectionEnabled: false,
            defaultCustomerLanguage: .english,
            guestLanguageSelectionEnabled: true,
            templates: [template],
            gallery: EventGalleryConfiguration(title: LocalizedText(english: event.name), language: .english)
        )
        let frame = frameFileName.flatMap { loadCGImage(from: templateDirectory.appendingPathComponent($0)) }
        let preview = try TemplatePreviewRenderer().render(template: template, frame: frame)
        try TemplatePreviewRenderer().saveJPEG(preview, to: templateDirectory.appendingPathComponent("preview.jpg"))
        try save(document)
        return document
    }

    func load(eventID: String) throws -> EventExperienceDocument {
        let url = try experienceURL(eventID: eventID)
        guard fileManager.fileExists(atPath: url.path) else { throw EventExperienceError.missing(url) }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(EventExperienceDocument.self, from: Data(contentsOf: url))
            guard document.schemaVersion == EventExperienceDocument.currentSchemaVersion else {
                throw EventExperienceError.unsupportedSchema(document.schemaVersion)
            }
            try validate(document)
            return document
        } catch let error as EventExperienceError {
            throw error
        } catch {
            let backup = try preserveCorruptDocument(at: url)
            throw EventExperienceError.corrupt(url, backup: backup)
        }
    }

    func save(_ document: EventExperienceDocument) throws {
        try validate(document)
        let url = try experienceURL(eventID: document.eventID)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".experience-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    func delete(eventID: String) throws {
        let directory = try eventURL(eventID: eventID)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    func importTemplateFrame(eventID: String, templateID: String, sourceURL: URL) throws -> ImportedTemplateFrame {
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw EventExperienceError.missingAsset(sourceURL) }
        guard loadCGImage(from: sourceURL) != nil else { throw EventExperienceError.importFailed("Frame must be a readable image.") }
        let directory = try templateURL(eventID: eventID, templateID: templateID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("frame.png")
        try atomicCopy(sourceURL, to: destination)
        return ImportedTemplateFrame(fileName: "frame.png", url: destination)
    }

    func importPromptImage(eventID: String, promptID: String, sourceURL: URL) throws -> ImportedPromptImage {
        guard fileManager.fileExists(atPath: sourceURL.path),
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 1024,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let data = jpegData(from: image, quality: 0.82) else {
            throw EventExperienceError.importFailed("Prompt image must be a readable PNG, JPEG, or HEIC image.")
        }
        let directory = baseDirectory.appendingPathComponent(eventID, isDirectory: true).appendingPathComponent("Prompts", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("\(promptID).jpg")
        try atomicWrite(data, to: destination)
        return ImportedPromptImage(fileName: "\(promptID).jpg", url: destination)
    }

    func deleteTemplateAsset(eventID: String, templateID: String) throws {
        let directory = try templateURL(eventID: eventID, templateID: templateID)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    func duplicateTemplateAssets(
        eventID: String,
        sourceTemplateID: String,
        destinationTemplateID: String,
        promptIDMap: [String: String]
    ) throws {
        let source = try templateURL(eventID: eventID, templateID: sourceTemplateID)
        let destination = try templateURL(eventID: eventID, templateID: destinationTemplateID)
        guard fileManager.fileExists(atPath: source.path) else { return }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        for fileName in ["frame.png", "preview.jpg"] {
            let sourceURL = source.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: sourceURL.path) {
                try atomicCopy(sourceURL, to: destination.appendingPathComponent(fileName))
            }
        }
        let prompts = baseDirectory.appendingPathComponent(eventID, isDirectory: true).appendingPathComponent("Prompts", isDirectory: true)
        for (oldID, newID) in promptIDMap {
            let sourceURL = prompts.appendingPathComponent("\(oldID).jpg")
            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            try atomicCopy(sourceURL, to: prompts.appendingPathComponent("\(newID).jpg"))
        }
    }

    func readTemplatePreview(eventID: String, templateID: String) throws -> Data? {
        try Task.checkCancellation()
        let document = try load(eventID: eventID)
        guard let template = document.templates.first(where: { $0.id == templateID }),
              let fileName = template.previewFileName else { return nil }
        let directory = try templateURL(eventID: eventID, templateID: templateID)
        let url = try templateAssetURL(fileName, in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }

    func readTemplatePreviews(
        eventID: String,
        templates: [EventTemplateDefinition]
    ) throws -> [String: Data] {
        try Task.checkCancellation()
        var previews: [String: Data] = [:]
        for template in templates {
            try Task.checkCancellation()
            guard let fileName = template.previewFileName else { continue }
            let directory = try templateURL(eventID: eventID, templateID: template.id)
            let url = try templateAssetURL(fileName, in: directory)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            try Task.checkCancellation()
            previews[template.id] = data
        }
        return previews
    }

    func readTemplateFrame(eventID: String, templateID: String) throws -> Data? {
        let document = try load(eventID: eventID)
        guard let template = document.templates.first(where: { $0.id == templateID }),
              let fileName = template.frameFileName else { return nil }
        let directory = try templateURL(eventID: eventID, templateID: templateID)
        let url = try templateAssetURL(fileName, in: directory)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }

    func readPromptImage(eventID: String, fileName: String) throws -> Data? {
        guard !fileName.contains("/") else { throw EventExperienceError.invalid("Invalid prompt asset name.") }
        let url = try eventURL(eventID: eventID).appendingPathComponent("Prompts", isDirectory: true).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func rebuildPreview(eventID: String, templateID: String) throws -> URL {
        var document = try load(eventID: eventID)
        guard let index = document.templates.firstIndex(where: { $0.id == templateID }) else {
            throw EventExperienceError.invalid("Template does not exist.")
        }
        let template = document.templates[index]
        let directory = try templateURL(eventID: eventID, templateID: templateID)
        let frame = try template.frameFileName
            .flatMap { try? templateAssetURL($0, in: directory) }
            .flatMap { loadCGImage(from: $0) }
        let previewURL = directory.appendingPathComponent("preview.jpg")
        let image = try TemplatePreviewRenderer().render(template: template, frame: frame)
        try TemplatePreviewRenderer().saveJPEG(image, to: previewURL)
        document.templates[index].previewFileName = "preview.jpg"
        document.templates[index].updatedAt = Date()
        document.revision = UUID().uuidString
        document.updatedAt = Date()
        try save(document)
        return previewURL
    }

    func validate(_ document: EventExperienceDocument) throws {
        guard document.schemaVersion == EventExperienceDocument.currentSchemaVersion else {
            throw EventExperienceError.unsupportedSchema(document.schemaVersion)
        }
        guard !document.id.isEmpty, !document.eventID.isEmpty else { throw EventExperienceError.invalidEventID }
        guard (1...8).contains(document.templates.count) else { throw EventExperienceError.invalid("An event needs between one and eight templates.") }
        guard document.templates.contains(where: { $0.id == document.defaultTemplateID }) else { throw EventExperienceError.invalid("Default template is missing.") }
        guard document.templates.contains(where: { $0.id == document.defaultTemplateID && $0.isEnabled }) else { throw EventExperienceError.invalid("Default template must be enabled.") }
        guard document.templates.contains(where: \.isEnabled) else { throw EventExperienceError.invalid("At least one template must be enabled.") }
        guard document.allowedFilterIDs.contains(.original), document.allowedFilterIDs.count <= 7 else { throw EventExperienceError.invalid("Original filter is required and at most seven filters may be enabled.") }
        guard document.allowedFilterIDs.contains(document.defaultFilterID) else { throw EventExperienceError.invalid("Default filter must be enabled.") }
        guard Set(document.allowedFilterIDs).count == document.allowedFilterIDs.count else { throw EventExperienceError.invalid("Duplicate filters are not allowed.") }

        var templateIDs = Set<String>()
        for template in document.templates {
            guard templateIDs.insert(template.id).inserted else { throw EventExperienceError.invalid("Template IDs must be unique.") }
            guard !template.name.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !template.name.thai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EventExperienceError.invalid("Template name is required.") }
            guard (1...8).contains(template.photoCount) else { throw EventExperienceError.invalid("Template photo count must be between one and eight.") }
            guard (300...10_000).contains(template.canvasWidth), (300...10_000).contains(template.canvasHeight) else { throw EventExperienceError.invalid("Template canvas must be between 300 and 10,000 pixels.") }
            guard !template.slots.isEmpty else { throw EventExperienceError.invalid("Template needs at least one slot.") }
            guard template.slots.allSatisfy({ $0.normalizedRect.width > 0 && $0.normalizedRect.height > 0 && (0..<template.photoCount).contains($0.photoIndex) }) else { throw EventExperienceError.invalid("Template has an invalid slot.") }
            let slotIndexes = Set(template.slots.map(\.photoIndex))
            guard (0..<template.photoCount).allSatisfy(slotIndexes.contains) else { throw EventExperienceError.invalid("Every capture index needs a slot.") }
            guard template.qrCodeElements.count <= 16 else { throw EventExperienceError.invalid("A template may contain at most 16 QR elements.") }
            let slotIDs = Set(template.slots.map(\.id))
            var qrIDs = Set<String>()
            for qrCode in template.qrCodeElements {
                let rect = qrCode.normalizedRect
                guard !qrCode.id.isEmpty,
                      qrIDs.insert(qrCode.id).inserted,
                      !slotIDs.contains(qrCode.id),
                      rect.origin.x.isFinite,
                      rect.origin.y.isFinite,
                      rect.width.isFinite,
                      rect.height.isFinite,
                      rect.width > 0,
                      rect.height > 0,
                      rect.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)),
                      rect.width * template.canvasWidth >= 4,
                      rect.height * template.canvasHeight >= 4,
                      qrCode.rotation.isFinite else {
                    throw EventExperienceError.invalid("Template has an invalid QR element.")
                }
            }
            var promptIndexes = Set<Int>()
            for prompt in template.posePrompts {
                guard (0..<template.photoCount).contains(prompt.photoIndex) else { throw EventExperienceError.invalid("Pose prompt index is outside template photo count.") }
                guard promptIndexes.insert(prompt.photoIndex).inserted else { throw EventExperienceError.invalid("A template cannot contain duplicate pose prompt indexes.") }
                if prompt.isEnabled {
                    guard !prompt.title.english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !prompt.title.thai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EventExperienceError.invalid("Enabled pose prompt needs a title.") }
                }
            }
        }
    }

    private func eventURL(eventID: String) throws -> URL {
        guard !eventID.isEmpty, !eventID.contains("/"), !eventID.contains("\\"), !eventID.contains("\0") else { throw EventExperienceError.invalidEventID }
        return baseDirectory.appendingPathComponent(eventID, isDirectory: true)
    }

    private func experienceURL(eventID: String) throws -> URL {
        try eventURL(eventID: eventID).appendingPathComponent("experience.json")
    }

    private func templateURL(eventID: String, templateID: String) throws -> URL {
        guard !templateID.isEmpty, !templateID.contains("/"), !templateID.contains("\\"), !templateID.contains("\0") else { throw EventExperienceError.invalid("Invalid template ID.") }
        return try eventURL(eventID: eventID).appendingPathComponent("Templates", isDirectory: true).appendingPathComponent(templateID, isDirectory: true)
    }

    private func templateAssetURL(_ fileName: String, in directory: URL) throws -> URL {
        guard !fileName.isEmpty,
              !fileName.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" }),
              fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
            throw EventExperienceError.invalid("Invalid template asset name.")
        }
        let url = directory.appendingPathComponent(fileName)
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw EventExperienceError.invalid("Invalid template asset name.")
        }
        return url
    }

    private func atomicCopy(_ source: URL, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: temporary)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func preserveCorruptDocument(at url: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let directory = url.deletingLastPathComponent()
        var backup = directory.appendingPathComponent("experience-corrupt-\(formatter.string(from: Date())).json")
        var suffix = 2
        while fileManager.fileExists(atPath: backup.path) {
            backup = directory.appendingPathComponent("experience-corrupt-\(formatter.string(from: Date()))-\(suffix).json")
            suffix += 1
        }
        try fileManager.copyItem(at: url, to: backup)
        return backup
    }
}
