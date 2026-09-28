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
        _ = try write(manifest, to: url)
    }

    func load(sessionID: String) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SessionManifestError.missing(url)
        }
        return try decode(from: url)
    }

    func save(
        _ manifest: SessionManifest,
        allowedStatuses: Set<RuntimeSessionStatus>
    ) throws {
        try validate(sessionID: manifest.id)
        let current = try load(sessionID: manifest.id)
        guard current.status != .cancelled,
              allowedStatuses.contains(current.status) else {
            throw SessionManifestError.mutationNotAllowed(
                sessionID: manifest.id,
                status: current.status
            )
        }
        guard manifest.status == current.status else {
            throw SessionManifestError.invalidTransition(
                sessionID: manifest.id,
                from: current.status,
                to: manifest.status
            )
        }
        guard manifest.updatedAt >= current.updatedAt else {
            throw SessionManifestError.staleWrite(sessionID: manifest.id)
        }
        _ = try write(manifest, to: fileURL(for: manifest.id))
    }

    func update(
        sessionID: String,
        allowedStatuses: Set<RuntimeSessionStatus>,
        _ mutation: @Sendable (inout SessionManifest) throws -> Void
    ) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        var manifest = try load(sessionID: sessionID)
        let originalStatus = manifest.status
        guard originalStatus != .cancelled,
              allowedStatuses.contains(originalStatus) else {
            throw SessionManifestError.mutationNotAllowed(
                sessionID: sessionID,
                status: originalStatus
            )
        }
        try mutation(&manifest)
        guard manifest.status == originalStatus else {
            throw SessionManifestError.invalidTransition(
                sessionID: sessionID,
                from: originalStatus,
                to: manifest.status
            )
        }
        return try write(manifest, to: url)
    }

    /// Applies one compare-and-set status transition to the latest durable
    /// manifest. Terminal sessions cannot be resurrected by a stale task.
    func transition(
        sessionID: String,
        allowedFrom: Set<RuntimeSessionStatus>,
        _ mutation: @Sendable (inout SessionManifest) throws -> Void
    ) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        var manifest = try load(sessionID: sessionID)
        let originalStatus = manifest.status
        guard allowedFrom.contains(originalStatus),
              originalStatus != .cancelled,
              originalStatus != .completed else {
            throw SessionManifestError.invalidTransition(
                sessionID: sessionID,
                from: originalStatus,
                to: originalStatus
            )
        }
        try mutation(&manifest)
        guard manifest.status != originalStatus else {
            throw SessionManifestError.invalidTransition(
                sessionID: sessionID,
                from: originalStatus,
                to: manifest.status
            )
        }
        return try write(manifest, to: url)
    }

    func delete(sessionID: String) throws {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func recordSoakCleanupResult(
        sessionID: String,
        expectedRunID: String,
        warning: String?,
        retainedForDiagnostics: Bool? = nil
    ) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        var manifest = try load(sessionID: sessionID)
        guard manifest.origin == .soakTest, manifest.soakRunID == expectedRunID else {
            throw SessionManifestError.soakCleanupNotAllowed(sessionID)
        }
        manifest.soakCleanupWarning = warning
        manifest.soakCleanupLastAttemptAt = Date()
        if let retainedForDiagnostics {
            manifest.soakDiagnosticRetained = retainedForDiagnostics
        }
        manifest.updatedAt = max(manifest.updatedAt, Date())
        _ = try write(manifest, to: url)
        return manifest
    }

    func prepareOrphanedSoakForCleanup(
        sessionID: String,
        expectedRunID: String,
        retainForDiagnostics: Bool
    ) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        var manifest = try load(sessionID: sessionID)
        guard manifest.origin == .soakTest, manifest.soakRunID == expectedRunID else {
            throw SessionManifestError.soakCleanupNotAllowed(sessionID)
        }
        if manifest.status == .capturing || manifest.status == .finalizing {
            manifest.status = .cancelled
            manifest.cancelledAt = Date()
        }
        if retainForDiagnostics {
            manifest.soakDiagnosticRetained = true
            manifest.lastError = manifest.lastError
                ?? "An interrupted soak session was retained for operator diagnostics."
        } else if manifest.soakCleanupWarning != nil {
            // A prior cleanup warning is retried at launch. Let the retry
            // remove the temporary retained marker if it now succeeds.
            manifest.soakDiagnosticRetained = false
        }
        manifest.updatedAt = max(manifest.updatedAt, Date())
        return try write(manifest, to: url)
    }

    func retainSoakFailureDiagnostics(
        sessionID: String,
        expectedRunID: String,
        reason: String
    ) throws -> SessionManifest {
        try validate(sessionID: sessionID)
        let url = try fileURL(for: sessionID)
        var manifest = try load(sessionID: sessionID)
        guard manifest.origin == .soakTest, manifest.soakRunID == expectedRunID else {
            throw SessionManifestError.soakCleanupNotAllowed(sessionID)
        }
        manifest.lastError = reason
        manifest.soakDiagnosticRetained = true
        manifest.updatedAt = max(manifest.updatedAt, Date())
        _ = try write(manifest, to: url)
        return manifest
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

    @discardableResult
    private func write(_ manifest: SessionManifest, to url: URL) throws -> SessionManifest {
        var saved = manifest
        saved.updatedAt = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(saved).write(to: url, options: [.atomic])
        return saved
    }
}
