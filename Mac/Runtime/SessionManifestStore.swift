import Foundation

enum SessionManifestLoadResult: Sendable {
    case loaded(SessionManifest)
    case failed(fileURL: URL, message: String)
}

actor SessionManifestStore {
    private let baseDirectory: URL

    init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    func create(_ manifest: SessionManifest) throws {
        try validate(sessionID: manifest.id)
        let url = try fileURL(for: manifest.id)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try decode(from: url)
            guard existing.id == manifest.id else {
                throw SessionManifestError.alreadyOwned(url, existing.id)
            }
            return
        }
        try write(manifest, to: url)
    }

    func load(sessionID: String) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionManifestError.missing(url)
        }
        return try decode(from: url)
    }

    func save(_ manifest: SessionManifest) throws {
        try validate(sessionID: manifest.id)
        try write(manifest, to: fileURL(for: manifest.id))
    }

    func delete(sessionID: String) throws {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func loadAll() -> [SessionManifestLoadResult] {
        do {
            let directory = try sessionsDirectory()
            let files = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            return files
                .filter { $0.pathExtension.lowercased() == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .map { url in
                    do {
                        return .loaded(try decode(from: url))
                    } catch {
                        return .failed(fileURL: url, message: error.localizedDescription)
                    }
                }
        } catch {
            return [.failed(fileURL: baseDirectory.appendingPathComponent("Sessions"), message: error.localizedDescription)]
        }
    }

    func manifests(with status: RuntimeSessionStatus) -> [SessionManifest] {
        loadAll().compactMap {
            guard case .loaded(let manifest) = $0, manifest.status == status else { return nil }
            return manifest
        }
    }

    private func sessionsDirectory() throws -> URL {
        let directory = baseDirectory.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileURL(for sessionID: String) throws -> URL {
        try sessionsDirectory().appendingPathComponent("\(sessionID).json", isDirectory: false)
    }

    private func validate(sessionID: String) throws {
        guard !sessionID.isEmpty,
              sessionID != ".",
              sessionID != "..",
              !sessionID.contains("/"),
              !sessionID.contains("\\") else {
            throw SessionManifestError.invalidSessionID(sessionID)
        }
    }

    private func decode(from url: URL) throws -> SessionManifest {
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(SessionManifest.self, from: data)
            guard manifest.schemaVersion == SessionManifest.currentSchemaVersion else {
                throw SessionManifestError.unsupportedSchemaVersion(manifest.schemaVersion)
            }
            return manifest
        } catch let error as SessionManifestError {
            throw error
        } catch {
            throw SessionManifestError.corrupt(url, error.localizedDescription)
        }
    }

    private func write(_ manifest: SessionManifest, to url: URL) throws {
        var saved = manifest
        saved.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(saved).write(to: url, options: [.atomic])
    }
}
