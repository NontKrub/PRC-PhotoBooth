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
        let photoCount = min(max(event.photoCount, 1), 8)
        let slots = event.slots.isEmpty
            ? (0..<photoCount).map {
                SharedPhotoSlot(
                    normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                    zOrder: $0,
                    photoIndex: $0
                )
            }
            : event.slots
        let template = EventTemplateDefinition(
            id: templateID,
            name: LocalizedText(english: event.name),
            photoCount: photoCount,
            canvasWidth: event.canvasWidth,
            canvasHeight: event.canvasHeight,
            frameFileName: frameFileName,
            previewFileName: "preview.jpg",
            slots: slots,
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
        let preview = try TemplatePreviewRenderer().render(template: template, frame: frame, foregroundOverlay: nil)
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

    func beginEditing(eventID: String) throws -> EventExperienceEditingSession {
        _ = try eventURL(eventID: eventID)
        let session = EventExperienceEditingSession(id: UUID().uuidString, eventID: eventID)
        try fileManager.createDirectory(at: try editingSessionURL(session), withIntermediateDirectories: true)
        return session
    }

    func discardEditing(_ session: EventExperienceEditingSession) throws {
        let directory = try editingSessionURL(session)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    func importTemplateFrame(
        eventID: String,
        templateID: String,
        sourceURL: URL,
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> ImportedTemplateFrame {
        guard fileManager.fileExists(atPath: sourceURL.path) else { throw EventExperienceError.missingAsset(sourceURL) }
        guard loadCGImage(from: sourceURL) != nil else { throw EventExperienceError.importFailed("Frame must be a readable image.") }
        if let editingSession { try validateEditingSession(editingSession, eventID: eventID) }
        let directory = try editingSession.map { try stagingTemplateURL($0, templateID: templateID) }
            ?? templateURL(eventID: eventID, templateID: templateID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("frame.png")
        try atomicCopy(sourceURL, to: destination)
        return ImportedTemplateFrame(fileName: "frame.png", url: destination)
    }

    func importTemplateForegroundOverlay(
        eventID: String,
        templateID: String,
        sourceURL: URL,
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> ImportedTemplateForegroundOverlay {
        guard fileManager.fileExists(atPath: sourceURL.path),
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              CGImageSourceGetType(source) == UTType.png.identifier as CFString,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.alphaInfo != .none,
              image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast else {
            throw EventExperienceError.importFailed("Foreground overlay must be a readable PNG with transparency.")
        }
        if let editingSession { try validateEditingSession(editingSession, eventID: eventID) }
        let directory = try editingSession.map { try stagingTemplateURL($0, templateID: templateID) }
            ?? templateURL(eventID: eventID, templateID: templateID)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("foreground.png")
        try atomicCopy(sourceURL, to: destination)
        return ImportedTemplateForegroundOverlay(fileName: "foreground.png", url: destination)
    }

    func importPromptImage(
        eventID: String,
        promptID: String,
        sourceURL: URL,
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> ImportedPromptImage {
        guard isSafePathComponent(promptID) else {
            throw EventExperienceError.invalid("Invalid prompt ID.")
        }
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
        if let editingSession { try validateEditingSession(editingSession, eventID: eventID) }
        let eventDirectory = try editingSession.map { try stagingEventURL($0) }
            ?? eventURL(eventID: eventID)
        let directory = eventDirectory.appendingPathComponent("Prompts", isDirectory: true)
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
        promptIDMap: [String: String],
        editingSession: EventExperienceEditingSession? = nil
    ) throws {
        if let editingSession { try validateEditingSession(editingSession, eventID: eventID) }
        let source = try templateURL(eventID: eventID, templateID: sourceTemplateID)
        let destination = try editingSession.map { try stagingTemplateURL($0, templateID: destinationTemplateID) }
            ?? templateURL(eventID: eventID, templateID: destinationTemplateID)
        let stagedSource = try editingSession.map { try stagingTemplateURL($0, templateID: sourceTemplateID) }
        guard fileManager.fileExists(atPath: source.path)
                || stagedSource.map({ fileManager.fileExists(atPath: $0.path) }) == true else {
            return
        }
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw EventExperienceError.invalid("Destination template already exists.")
        }

        var copiedPromptURLs: [URL] = []
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for fileName in ["frame.png", "foreground.png", "preview.jpg"] {
                let stagedAsset = stagedSource.map {
                    $0.appendingPathComponent(fileName)
                }
                let sourceURL = stagedAsset.flatMap { fileManager.fileExists(atPath: $0.path) ? $0 : nil }
                    ?? source.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: sourceURL.path) {
                    try atomicCopy(sourceURL, to: destination.appendingPathComponent(fileName))
                }
            }

            let prompts = try editingSession.map { try stagingEventURL($0) }
                .map { $0.appendingPathComponent("Prompts", isDirectory: true) }
                ?? eventURL(eventID: eventID).appendingPathComponent("Prompts", isDirectory: true)
            for (oldID, newID) in promptIDMap {
                guard isSafePathComponent(oldID), isSafePathComponent(newID) else {
                    throw EventExperienceError.invalid("Invalid prompt ID.")
                }
                let sourceURL = prompts.appendingPathComponent("\(oldID).jpg")
                let livePrompts = try eventURL(eventID: eventID).appendingPathComponent("Prompts", isDirectory: true)
                let liveSourceURL = livePrompts.appendingPathComponent("\(oldID).jpg")
                let resolvedSource = fileManager.fileExists(atPath: sourceURL.path) ? sourceURL : liveSourceURL
                guard fileManager.fileExists(atPath: resolvedSource.path) else { continue }
                try fileManager.createDirectory(at: prompts, withIntermediateDirectories: true)
                let destinationURL = prompts.appendingPathComponent("\(newID).jpg")
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    throw EventExperienceError.invalid("Destination prompt already exists.")
                }
                try atomicCopy(resolvedSource, to: destinationURL)
                copiedPromptURLs.append(destinationURL)
            }
        } catch {
            for promptURL in copiedPromptURLs {
                try? fileManager.removeItem(at: promptURL)
            }
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    func readTemplatePreview(
        eventID: String,
        templateID: String,
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> Data? {
        try Task.checkCancellation()
        let document = try load(eventID: eventID)
        guard let template = document.templates.first(where: { $0.id == templateID }) else {
            guard editingSession != nil,
                  let url = try resolvedTemplateAssetURL(
                      eventID: eventID,
                      templateID: templateID,
                      fileName: "preview.jpg",
                      editingSession: editingSession
                  ) else { return nil }
            return try Data(contentsOf: url)
        }
        guard let fileName = template.previewFileName else { return nil }
        try Task.checkCancellation()
        return try readTemplatePreviewData(
            eventID: eventID,
            template: template,
            fileName: fileName,
            editingSession: editingSession
        )
    }

    func readTemplatePreviews(
        eventID: String,
        templates: [EventTemplateDefinition],
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> [String: Data] {
        try Task.checkCancellation()
        var previews: [String: Data] = [:]
        for template in templates {
            try Task.checkCancellation()
            guard let fileName = template.previewFileName else { continue }
            guard let data = try readTemplatePreviewData(
                eventID: eventID,
                template: template,
                fileName: fileName,
                editingSession: editingSession
            ) else { continue }
            try Task.checkCancellation()
            previews[template.id] = data
        }
        return previews
    }

    func readTemplateFrame(
        eventID: String,
        templateID: String,
        fileName: String,
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> Data? {
        guard let url = try resolvedTemplateAssetURL(
            eventID: eventID,
            templateID: templateID,
            fileName: fileName,
            editingSession: editingSession
        ) else { return nil }
        try Task.checkCancellation()
        return try Data(contentsOf: url)
    }

    func readTemplateForegroundOverlay(
        eventID: String,
        templateID: String,
        fileName: String,
        editingSession: EventExperienceEditingSession? = nil
    ) throws -> Data? {
        try readTemplateFrame(
            eventID: eventID,
            templateID: templateID,
            fileName: fileName,
            editingSession: editingSession
        )
    }

    func commitEditing(
        _ session: EventExperienceEditingSession,
        document: EventExperienceDocument
    ) throws {
        try validateEditingSession(session, eventID: document.eventID)
        try validate(document)
        let previous = try load(eventID: document.eventID)
        let stagingDirectory = try editingSessionURL(session)
        let assets = try stagedAssetPairs(session)
        let backupDirectory = stagingDirectory.appendingPathComponent(".backup", isDirectory: true)
        var backups: [(destination: URL, backup: URL?)] = []

        do {
            for (index, asset) in assets.enumerated() {
                let backup = backupDirectory.appendingPathComponent(String(index))
                if fileManager.fileExists(atPath: asset.destination.path) {
                    try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
                    try fileManager.copyItem(at: asset.destination, to: backup)
                    backups.append((asset.destination, backup))
                } else {
                    backups.append((asset.destination, nil))
                }
                try atomicCopy(asset.source, to: asset.destination)
            }
            try save(document)
            for oldTemplate in previous.templates {
                guard oldTemplate.foregroundOverlayFileName != nil,
                      document.templates.first(where: { $0.id == oldTemplate.id })?.foregroundOverlayFileName == nil else { continue }
                let url = try templateURL(eventID: document.eventID, templateID: oldTemplate.id)
                    .appendingPathComponent("foreground.png")
                try? fileManager.removeItem(at: url)
            }
        } catch {
            for backup in backups.reversed() {
                if let backupURL = backup.backup, fileManager.fileExists(atPath: backupURL.path) {
                    try? atomicCopy(backupURL, to: backup.destination)
                } else if fileManager.fileExists(atPath: backup.destination.path) {
                    try? fileManager.removeItem(at: backup.destination)
                }
            }
            throw error
        }

        try? fileManager.removeItem(at: stagingDirectory)
    }

    func readPromptImage(eventID: String, fileName: String) throws -> Data? {
        guard isSafePathComponent(fileName) else { throw EventExperienceError.invalid("Invalid prompt asset name.") }
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
        let frame = template.frameFileName
            .flatMap { try? templateAssetURL($0, in: directory) }
            .flatMap { loadCGImage(from: $0) }
        let previewURL = directory.appendingPathComponent("preview.jpg")
        let foreground = template.foregroundOverlayFileName
            .flatMap { try? templateAssetURL($0, in: directory) }
            .flatMap { loadCGImage(from: $0) }
        let image = try TemplatePreviewRenderer().render(template: template, frame: frame, foregroundOverlay: foreground)
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
        guard isSafePathComponent(eventID) else { throw EventExperienceError.invalidEventID }
        return baseDirectory.appendingPathComponent(eventID, isDirectory: true)
    }

    private func experienceURL(eventID: String) throws -> URL {
        try eventURL(eventID: eventID).appendingPathComponent("experience.json")
    }

    private func templateURL(eventID: String, templateID: String) throws -> URL {
        guard isSafePathComponent(templateID) else { throw EventExperienceError.invalid("Invalid template ID.") }
        return try eventURL(eventID: eventID).appendingPathComponent("Templates", isDirectory: true).appendingPathComponent(templateID, isDirectory: true)
    }

    private func editingSessionURL(_ session: EventExperienceEditingSession) throws -> URL {
        guard isSafePathComponent(session.id) else {
            throw EventExperienceError.invalid("Invalid editor session.")
        }
        _ = try eventURL(eventID: session.eventID)
        return baseDirectory
            .appendingPathComponent(".editor-staging", isDirectory: true)
            .appendingPathComponent(session.id, isDirectory: true)
    }

    private func stagingEventURL(_ session: EventExperienceEditingSession) throws -> URL {
        try editingSessionURL(session).appendingPathComponent(session.eventID, isDirectory: true)
    }

    private func stagingTemplateURL(
        _ session: EventExperienceEditingSession,
        templateID: String
    ) throws -> URL {
        guard isSafePathComponent(templateID) else {
            throw EventExperienceError.invalid("Invalid template ID.")
        }
        return try stagingEventURL(session)
            .appendingPathComponent("Templates", isDirectory: true)
            .appendingPathComponent(templateID, isDirectory: true)
    }

    private func validateEditingSession(
        _ session: EventExperienceEditingSession,
        eventID: String
    ) throws {
        guard session.eventID == eventID else {
            throw EventExperienceError.invalid("Editor session belongs to another event.")
        }
        _ = try editingSessionURL(session)
    }

    private func stagedAssetPairs(
        _ session: EventExperienceEditingSession
    ) throws -> [(source: URL, destination: URL)] {
        let eventDirectory = try stagingEventURL(session)
        let liveEventDirectory = try eventURL(eventID: session.eventID)
        var assets: [(source: URL, destination: URL)] = []
        let templates = eventDirectory.appendingPathComponent("Templates", isDirectory: true)
        if fileManager.fileExists(atPath: templates.path) {
            for templateDirectory in try fileManager.contentsOfDirectory(
                at: templates,
                includingPropertiesForKeys: [.isDirectoryKey]
            ) {
                guard (try templateDirectory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                    continue
                }
                let templateID = templateDirectory.lastPathComponent
                let liveTemplate = try templateURL(eventID: session.eventID, templateID: templateID)
                for fileName in ["frame.png", "foreground.png", "preview.jpg"] {
                    let source = templateDirectory.appendingPathComponent(fileName)
                    guard fileManager.fileExists(atPath: source.path) else { continue }
                    assets.append((source, liveTemplate.appendingPathComponent(fileName)))
                }
            }
        }

        let prompts = eventDirectory.appendingPathComponent("Prompts", isDirectory: true)
        if fileManager.fileExists(atPath: prompts.path) {
            for source in try fileManager.contentsOfDirectory(at: prompts, includingPropertiesForKeys: nil)
                where source.pathExtension.lowercased() == "jpg" {
                let destination = liveEventDirectory
                    .appendingPathComponent("Prompts", isDirectory: true)
                    .appendingPathComponent(source.lastPathComponent)
                assets.append((source, destination))
            }
        }
        return assets
    }

    private func templateAssetURL(_ fileName: String, in directory: URL) throws -> URL {
        guard isSafePathComponent(fileName),
              fileName == URL(fileURLWithPath: fileName).lastPathComponent else {
            throw EventExperienceError.invalid("Invalid template asset name.")
        }
        let url = directory.appendingPathComponent(fileName)
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw EventExperienceError.invalid("Invalid template asset name.")
        }
        return url
    }

    private func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains(where: { $0 == "/" || $0 == "\\" || $0 == "\0" })
    }

    private func resolvedTemplateAssetURL(
        eventID: String,
        templateID: String,
        fileName: String,
        editingSession: EventExperienceEditingSession?
    ) throws -> URL? {
        let liveDirectory = try templateURL(eventID: eventID, templateID: templateID)
        let liveURL = try templateAssetURL(fileName, in: liveDirectory)
        if let stagingURL = try stagedTemplateAssetURL(
            eventID: eventID,
            templateID: templateID,
            fileName: fileName,
            editingSession: editingSession
        ) { return stagingURL }
        return fileManager.fileExists(atPath: liveURL.path) ? liveURL : nil
    }

    private func stagedTemplateAssetURL(
        eventID: String,
        templateID: String,
        fileName: String,
        editingSession: EventExperienceEditingSession?
    ) throws -> URL? {
        guard let editingSession else { return nil }
        try validateEditingSession(editingSession, eventID: eventID)
        let stagingDirectory = try stagingTemplateURL(editingSession, templateID: templateID)
        let stagingURL = try templateAssetURL(fileName, in: stagingDirectory)
        return fileManager.fileExists(atPath: stagingURL.path) ? stagingURL : nil
    }

    private func readTemplatePreviewData(
        eventID: String,
        template: EventTemplateDefinition,
        fileName: String,
        editingSession: EventExperienceEditingSession?
    ) throws -> Data? {
        if editingSession != nil {
            let frame = template.frameFileName
                .flatMap { try? resolvedTemplateAssetURL(
                    eventID: eventID,
                    templateID: template.id,
                    fileName: $0,
                    editingSession: editingSession
                ) }
                .flatMap { loadCGImage(from: $0) }
            let foreground = template.foregroundOverlayFileName
                .flatMap { try? resolvedTemplateAssetURL(
                    eventID: eventID,
                    templateID: template.id,
                    fileName: $0,
                    editingSession: editingSession
                ) }
                .flatMap { loadCGImage(from: $0) }
            if frame != nil || foreground != nil {
                let preview = try TemplatePreviewRenderer().render(template: template, frame: frame, foregroundOverlay: foreground)
                guard let data = jpegData(from: preview, quality: 0.82) else {
                    throw TemplatePreviewError.encodingFailed
                }
                return data
            }
        }

        guard let url = try resolvedTemplateAssetURL(
            eventID: eventID,
            templateID: template.id,
            fileName: fileName,
            editingSession: editingSession
        ) else { return nil }
        return try Data(contentsOf: url)
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
