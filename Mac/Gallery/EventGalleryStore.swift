import Foundation

actor EventGalleryStore {
    private let root: URL
    private let fileManager = FileManager.default

    init(baseDirectory: URL) {
        root = baseDirectory.appendingPathComponent("Gallery/Events", isDirectory: true)
    }

    func load(eventID: String) throws -> EventGalleryIndex? {
        let url = try indexURL(eventID: eventID)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let index = try decoder.decode(EventGalleryIndex.self, from: Data(contentsOf: url))
            guard index.schemaVersion == EventGalleryIndex.currentSchemaVersion else {
                throw EventGalleryStoreError.corrupt(url, backup: url)
            }
            return index
        } catch let error as EventGalleryStoreError {
            throw error
        } catch {
            let backup = try preserveCorruptFile(at: url)
            throw EventGalleryStoreError.corrupt(url, backup: backup)
        }
    }

    func save(_ index: EventGalleryIndex) throws {
        guard !index.eventID.isEmpty else { throw EventGalleryStoreError.invalidEventID }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try indexURL(eventID: index.eventID)
        var encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(index)
        let temporary = root.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    func upsertSession(
        manifest: SessionManifest,
        configuration: EventGalleryConfiguration
    ) throws {
        guard let strip = manifest.stripFileName else { return }
        var index = try load(eventID: manifest.eventID) ?? EventGalleryIndex(
            schemaVersion: EventGalleryIndex.currentSchemaVersion,
            eventID: manifest.eventID,
            eventToken: configuration.eventToken,
            title: configuration.title,
            language: configuration.language,
            showGIFLinks: configuration.showGIFLinks,
            sessions: [],
            updatedAt: Date()
        )
        index.eventToken = configuration.eventToken
        index.title = configuration.title
        index.language = configuration.language
        index.showGIFLinks = configuration.showGIFLinks
        let existing = index.sessions.first(where: { $0.sessionID == manifest.id })
        let status = existing?.approvalStatus ?? (configuration.mode == .automatic ? .approved : .pending)
        let templateName = manifest.eventConfig.templateName
        let entry = GallerySessionEntry(
            id: existing?.id ?? UUID().uuidString,
            sessionID: manifest.id,
            downloadToken: manifest.downloadToken,
            startedAt: manifest.startedAt,
            absoluteSessionDirectoryPath: manifest.absoluteDirectoryPath,
            thumbnailFileName: "gallery-thumb.jpg",
            stripFileName: strip,
            gifFileName: manifest.gifFileName,
            templateID: manifest.eventConfig.templateID,
            templateName: templateName,
            filterID: manifest.eventConfig.selectedFilterID,
            customerLanguage: manifest.eventConfig.customerLanguage,
            approvalStatus: status,
            updatedAt: Date()
        )
        index.sessions.removeAll { $0.sessionID == manifest.id }
        index.sessions.append(entry)
        index.sessions.sort { $0.startedAt > $1.startedAt }
        index.updatedAt = Date()
        try save(index)
    }

    func setApproval(eventID: String, sessionID: String, status: GalleryApprovalStatus) throws {
        guard var index = try load(eventID: eventID),
              let position = index.sessions.firstIndex(where: { $0.sessionID == sessionID }) else {
            throw EventGalleryStoreError.missingSession(sessionID)
        }
        index.sessions[position].approvalStatus = status
        index.sessions[position].updatedAt = Date()
        index.updatedAt = Date()
        try save(index)
    }

    func removeSession(eventID: String, sessionID: String) throws {
        guard var index = try load(eventID: eventID) else { return }
        index.sessions.removeAll { $0.sessionID == sessionID }
        index.updatedAt = Date()
        try save(index)
    }

    func loadAll() -> [GalleryIndexLoadResult] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.map { url in
            let eventID = url.deletingPathExtension().lastPathComponent
            do {
                guard let index = try load(eventID: eventID) else { return .failed(url, "Gallery index is missing.") }
                return .loaded(index)
            } catch {
                return .failed(url, error.localizedDescription)
            }
        }
    }

    private func indexURL(eventID: String) throws -> URL {
        guard !eventID.isEmpty, !eventID.contains("/"), !eventID.contains("\\"), !eventID.contains("\0") else {
            throw EventGalleryStoreError.invalidEventID
        }
        return root.appendingPathComponent("\(eventID).json")
    }

    private func preserveCorruptFile(at url: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-corrupt-\(formatter.string(from: Date())).json")
        var suffix = 2
        while fileManager.fileExists(atPath: backup.path) {
            backup = backup.deletingLastPathComponent()
                .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-corrupt-\(formatter.string(from: Date()))-\(suffix).json")
            suffix += 1
        }
        try fileManager.copyItem(at: url, to: backup)
        return backup
    }
}
