import Foundation
import CoreGraphics

struct SessionWorkspaceDescriptor: Codable, Sendable, Equatable {
    var outputRootPath: String
    var relativeDirectoryPath: String
    var absoluteDirectoryPath: String
    var frameSnapshotFileName: String?
    var foregroundOverlaySnapshotFileName: String? = nil
}

struct SavedCaptureFiles: Sendable, Equatable {
    var imageFileName: String
    var gifFrameFileNames: [String]
}

struct SessionPresentationSnapshot: Codable, Sendable, Equatable {
    var language: CustomerLanguage
    var templateDisplayName: String
    var filterID: PhotoFilterID
    var prompts: [ResolvedPosePrompt]
    var assetFileNames: [String: String]
}

enum SessionWorkspaceError: LocalizedError, Equatable {
    case invalidSessionID
    case missingSource(URL)
    case imageEncodingFailed
    case fileMissing(URL)
    case invalidPath(String)
    case directoryCreationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .invalidSessionID: return "Invalid session ID."
        case .missingSource(let url): return "Frame source is missing: \(url.path)"
        case .imageEncodingFailed: return "Could not encode accepted photograph."
        case .fileMissing(let url): return "Required session file is missing or unreadable: \(url.path)"
        case .invalidPath(let path): return "Invalid session file path: \(path)"
        case .directoryCreationFailed(let url): return "Could not create session directory: \(url.path)"
        }
    }
}

struct SessionWorkspace: Sendable {
    private var fileManager: FileManager { .default }

    func createWorkspace(
        sessionID: String,
        eventName: String,
        outputRoot: URL,
        startedAt: Date,
        frameSourceURL: URL?,
        foregroundOverlaySourceURL: URL? = nil
    ) throws -> SessionWorkspaceDescriptor {
        guard !sessionID.isEmpty, !sessionID.contains("/"), !sessionID.contains("\\") else {
            throw SessionWorkspaceError.invalidSessionID
        }

        let eventDirectory = outputRoot.appendingPathComponent(Self.safeEventFolderName(eventName), isDirectory: true)
        try createDirectory(eventDirectory)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let baseName = "\(formatter.string(from: startedAt))-\(String(sessionID.prefix(8)))"
        var sessionDirectory = eventDirectory.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: sessionDirectory.path) {
            sessionDirectory = eventDirectory.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        var completed = false
        defer {
            if !completed { try? fileManager.removeItem(at: sessionDirectory) }
        }

        let workDirectory = sessionDirectory.appendingPathComponent(".work", isDirectory: true)
        try createDirectory(workDirectory.appendingPathComponent("gif", isDirectory: true))

        var frameSnapshotFileName: String?
        if let frameSourceURL {
            guard fileManager.fileExists(atPath: frameSourceURL.path) else {
                throw SessionWorkspaceError.missingSource(frameSourceURL)
            }
            let destination = workDirectory.appendingPathComponent("frame.png")
            let temporary = workDirectory.appendingPathComponent(".frame-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: frameSourceURL, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            frameSnapshotFileName = ".work/frame.png"
        }

        var foregroundOverlaySnapshotFileName: String?
        if let foregroundOverlaySourceURL {
            guard fileManager.fileExists(atPath: foregroundOverlaySourceURL.path) else {
                throw SessionWorkspaceError.missingSource(foregroundOverlaySourceURL)
            }
            let destination = workDirectory.appendingPathComponent("foreground.png")
            let temporary = workDirectory.appendingPathComponent(".foreground-\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            try fileManager.copyItem(at: foregroundOverlaySourceURL, to: temporary)
            try fileManager.moveItem(at: temporary, to: destination)
            foregroundOverlaySnapshotFileName = ".work/foreground.png"
        }

        let rootPath = outputRoot.standardizedFileURL.path
        let sessionPath = sessionDirectory.standardizedFileURL.path
        let relative = sessionPath.hasPrefix(rootPath + "/")
            ? String(sessionPath.dropFirst(rootPath.count + 1))
            : sessionDirectory.lastPathComponent
        completed = true
        return SessionWorkspaceDescriptor(
            outputRootPath: rootPath,
            relativeDirectoryPath: relative,
            absoluteDirectoryPath: sessionPath,
            frameSnapshotFileName: frameSnapshotFileName,
            foregroundOverlaySnapshotFileName: foregroundOverlaySnapshotFileName
        )
    }

    func saveAcceptedCapture(
        image: CGImage,
        gifFrames: [CGImage],
        photoIndex: Int,
        workspace: SessionWorkspaceDescriptor
    ) throws -> SavedCaptureFiles {
        guard photoIndex >= 0 else { throw SessionWorkspaceError.invalidPath("photo_\(photoIndex)") }
        let sessionDirectory = try sessionDirectory(for: workspace)
        let generation = UUID().uuidString
        let imageFileName = "shot_\(photoIndex)-\(generation).jpg"
        guard let imageData = jpegData(from: image, quality: 0.90) else {
            throw SessionWorkspaceError.imageEncodingFailed
        }

        let gifRoot = sessionDirectory.appendingPathComponent(".work/gif", isDirectory: true)
        try createDirectory(gifRoot)
        let temporaryImage = sessionDirectory.appendingPathComponent(".shot_\(photoIndex)-\(UUID().uuidString).tmp")
        try imageData.write(to: temporaryImage, options: [.atomic])
        defer { try? fileManager.removeItem(at: temporaryImage) }
        let temporaryDirectory = gifRoot.appendingPathComponent(".photo_\(photoIndex)-\(generation)", isDirectory: true)
        let destinationDirectory = gifRoot.appendingPathComponent("photo_\(photoIndex)-\(generation)", isDirectory: true)
        try createDirectory(temporaryDirectory)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        var frameFileNames: [String] = []
        for (index, frame) in gifFrames.enumerated() {
            guard let data = jpegData(from: frame, quality: 0.72) else {
                throw SessionWorkspaceError.imageEncodingFailed
            }
            let fileName = String(format: "frame_%03d.jpg", index)
            try data.write(to: temporaryDirectory.appendingPathComponent(fileName), options: [.atomic])
            frameFileNames.append(".work/gif/photo_\(photoIndex)-\(generation)/\(fileName)")
        }
        let imageDestination = sessionDirectory.appendingPathComponent(imageFileName)
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: imageDestination)
                try? fileManager.removeItem(at: destinationDirectory)
            }
        }
        do {
            try fileManager.moveItem(at: temporaryImage, to: imageDestination)
            try fileManager.moveItem(at: temporaryDirectory, to: destinationDirectory)
            committed = true
        } catch {
            throw error
        }
        return SavedCaptureFiles(imageFileName: imageFileName, gifFrameFileNames: frameFileNames)
    }

    func removeCaptureFiles(
        _ files: SavedCaptureFiles,
        workspace: SessionWorkspaceDescriptor
    ) throws {
        let directory = try sessionDirectory(for: workspace)
        let imageURL = try resolve(files.imageFileName, in: directory)
        if fileManager.fileExists(atPath: imageURL.path) {
            try fileManager.removeItem(at: imageURL)
        }
        var frameDirectories = Set<URL>()
        for fileName in files.gifFrameFileNames {
            let url = try resolve(fileName, in: directory)
            frameDirectories.insert(url.deletingLastPathComponent())
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        }
        for directory in frameDirectories where fileManager.fileExists(atPath: directory.path) {
            let contents = try fileManager.contentsOfDirectory(atPath: directory.path)
            if contents.isEmpty { try fileManager.removeItem(at: directory) }
        }
    }

    func pruneUnreferencedCaptureFiles(manifest: SessionManifest) throws {
        let directory = try manifestDirectory(for: manifest)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let referenced = Set(manifest.shots.flatMap { shot in
            [shot.imageFileName]
                .compactMap { $0 }
                + shot.gifFrameFileNames
                + (shot.previousImageFileName.map { [$0] } ?? [])
                + (shot.previousGifFrameFileNames ?? [])
        })
        let gifRoot = try resolve(".work/gif", in: directory)
        guard fileManager.fileExists(atPath: gifRoot.path) else {
            try pruneRootCaptureFiles(in: directory, referenced: referenced)
            return
        }
        if let enumerator = fileManager.enumerator(
            at: gifRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(url.path.dropFirst(directory.path.count + 1))
                if !referenced.contains(relative) { try fileManager.removeItem(at: url) }
            }
        }
        try pruneEmptyCaptureDirectories(in: gifRoot)
        try pruneRootCaptureFiles(in: directory, referenced: referenced)
    }

    private func pruneRootCaptureFiles(in directory: URL, referenced: Set<String>) throws {
        for url in try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            guard url.lastPathComponent.hasPrefix("shot_"),
                  url.pathExtension.lowercased() == "jpg",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if !referenced.contains(relative) { try fileManager.removeItem(at: url) }
        }
    }

    private func pruneEmptyCaptureDirectories(in root: URL) throws {
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return }
        let directories = enumerator.compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.path.count > $1.path.count }
        for directory in directories {
            if (try? fileManager.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    func savePresentationSnapshot(
        presentation: SessionPresentation,
        prompts: [ResolvedPosePrompt],
        workspace: SessionWorkspaceDescriptor
    ) throws {
        let directory = try sessionDirectory(for: workspace)
            .appendingPathComponent(".work/presentation", isDirectory: true)
        try createDirectory(directory)
        var snapshotPrompts = prompts
        var assetFileNames: [String: String] = [:]
        for presented in presentation.prompts {
            guard let data = presented.imageData else { continue }
            let fileName = "\(presented.promptID).jpg"
            guard !fileName.contains("/") else { continue }
            try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
            assetFileNames[presented.promptID] = fileName
            if let index = snapshotPrompts.firstIndex(where: { $0.id == presented.promptID }) {
                snapshotPrompts[index].assetID = fileName
            }
        }
        let snapshot = SessionPresentationSnapshot(
            language: presentation.language,
            templateDisplayName: presentation.templateDisplayName,
            filterID: presentation.filterID,
            prompts: snapshotPrompts,
            assetFileNames: assetFileNames
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        let url = directory.appendingPathComponent("presentation.json")
        let temporary = directory.appendingPathComponent(".presentation-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    func loadPresentationSnapshot(manifest: SessionManifest) throws -> SessionPresentation? {
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        let presentationURL = try resolve(".work/presentation/presentation.json", in: directory)
        guard fileManager.fileExists(atPath: presentationURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SessionPresentationSnapshot.self, from: Data(contentsOf: presentationURL))
        let prompts = snapshot.prompts.map { prompt in
            let fileName = snapshot.assetFileNames[prompt.id]
            let data = fileName.flatMap {
                try? Data(contentsOf: directory.appendingPathComponent(".work/presentation").appendingPathComponent($0))
            }
            return SessionPromptPresentation(
                promptID: prompt.id,
                photoIndex: prompt.photoIndex,
                title: prompt.title.value(for: snapshot.language),
                subtitle: {
                    let requested = snapshot.language == .english ? prompt.subtitle.english : prompt.subtitle.thai
                    let other = snapshot.language == .english ? prompt.subtitle.thai : prompt.subtitle.english
                    return [requested, other]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first(where: { !$0.isEmpty }) ?? ""
                }(),
                imageData: data
            )
        }
        return SessionPresentation(
            sessionID: manifest.id,
            language: snapshot.language,
            templateDisplayName: snapshot.templateDisplayName,
            filterID: snapshot.filterID,
            prompts: prompts
        )
    }

    func loadAcceptedImages(manifest: SessionManifest) throws -> [Int: CGImage] {
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
        var images: [Int: CGImage] = [:]
        for shot in manifest.shots {
            guard let imageFileName = shot.imageFileName else { continue }
            let url = try resolve(imageFileName, in: directory)
            guard let image = loadCGImage(from: url) else { throw SessionWorkspaceError.fileMissing(url) }
            images[shot.photoIndex] = image
        }
        return images
    }

    func removeWorkingFiles(manifest: SessionManifest) throws {
        let directory = try manifestDirectory(for: manifest)
        let work = directory.appendingPathComponent(".work", isDirectory: true)
        if fileManager.fileExists(atPath: work.path) { try fileManager.removeItem(at: work) }
    }

    func removeEntireSession(manifest: SessionManifest) throws {
        let directory = try manifestDirectory(for: manifest)
        if fileManager.fileExists(atPath: directory.path) { try fileManager.removeItem(at: directory) }
    }

    func removeAbandonedGIFTemporaries(manifest: SessionManifest) throws {
        let directory = try manifestDirectory(for: manifest)
        guard fileManager.fileExists(atPath: directory.path) else { return }
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for file in files where file.lastPathComponent.hasPrefix(".booth-") && file.pathExtension == "gif" {
            try fileManager.removeItem(at: file)
        }
    }

    static func safeEventFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\*?\"<>|")
        let safe = name.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty || safe == "." || safe == ".." ? "Event" : safe
    }

    private func sessionDirectory(for descriptor: SessionWorkspaceDescriptor) throws -> URL {
        let url = URL(fileURLWithPath: descriptor.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
        let root = URL(fileURLWithPath: descriptor.outputRootPath, isDirectory: true).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else {
            throw SessionWorkspaceError.invalidPath(url.path)
        }
        guard fileManager.fileExists(atPath: url.path) else { throw SessionWorkspaceError.directoryCreationFailed(url) }
        return url
    }

    private func manifestDirectory(for manifest: SessionManifest) throws -> URL {
        let root = URL(fileURLWithPath: manifest.outputRootPath, isDirectory: true).standardizedFileURL
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
        let expected = root.appendingPathComponent(manifest.relativeDirectoryPath, isDirectory: true).standardizedFileURL
        guard directory.path.hasPrefix(root.path + "/"), directory == expected else {
            throw SessionWorkspaceError.invalidPath(directory.path)
        }
        return directory
    }

    private func resolve(_ path: String, in directory: URL) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw SessionWorkspaceError.invalidPath(path) }
        let candidate = directory.appendingPathComponent(path).standardizedFileURL
        guard candidate.path == directory.path || candidate.path.hasPrefix(directory.path + "/") else {
            throw SessionWorkspaceError.invalidPath(path)
        }
        return candidate
    }

    private func createDirectory(_ url: URL) throws {
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw SessionWorkspaceError.directoryCreationFailed(url)
        }
    }

}
