import Foundation
import CoreGraphics

@MainActor
final class SessionJobExecutor: SessionJobExecuting {
    private let manifestStore: SessionManifestStore
    private let workspace: SessionWorkspace
    private let store: DataStore
    private let server: LocalWebServer
    private let cloudUpload: CloudUploadService
    private let printer: PrinterService
    private let defaults: UserDefaults
    private let filterPipeline: PhotoFilterPipeline
    private let experienceStore: EventExperienceStore
    private let galleryStore: EventGalleryStore
    private let galleryThumbnailGenerator = GalleryThumbnailGenerator()

    init(
        manifestStore: SessionManifestStore,
        workspace: SessionWorkspace,
        store: DataStore,
        server: LocalWebServer,
        cloudUpload: CloudUploadService,
        printer: PrinterService,
        defaults: UserDefaults = .standard,
        filterPipeline: PhotoFilterPipeline = PhotoFilterPipeline(),
        experienceStore: EventExperienceStore = EventExperienceStore(baseDirectory: BoothCoordinator.appSupportRootURL()),
        galleryStore: EventGalleryStore = EventGalleryStore(baseDirectory: BoothCoordinator.appSupportRootURL())
    ) {
        self.manifestStore = manifestStore
        self.workspace = workspace
        self.store = store
        self.server = server
        self.cloudUpload = cloudUpload
        self.printer = printer
        self.defaults = defaults
        self.filterPipeline = filterPipeline
        self.experienceStore = experienceStore
        self.galleryStore = galleryStore
    }

    func execute(_ job: SessionJob) async throws {
        let manifest: SessionManifest
        do {
            manifest = try await manifestStore.load(sessionID: job.sessionID)
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }

        switch job.kind {
        case .renderStrip:
            try await renderStrip(manifest)
        case .registerDownload:
            try await registerDownload(manifest)
        case .updateGallery:
            try await updateGallery(manifest)
        case .renderGIF:
            try await renderGIF(manifest)
        case .cloudUpload:
            try await upload(manifest)
        case .autoPrint:
            try await printStrip(manifest)
        }
    }

    private func renderStrip(_ manifest: SessionManifest) async throws {
        let images: [Int: CGImage]
        do {
            images = try workspace.loadAcceptedImages(manifest: manifest)
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }
        for index in 0..<manifest.eventConfig.photoCount {
            guard images[index] != nil else {
                throw JobExecutionError.permanent("Accepted photograph is missing for index \(index).")
            }
        }

        let filteredImages: [Int: CGImage]
        do {
            let source = (0..<manifest.eventConfig.photoCount).compactMap { images[$0] }
            let filtered = try await filterPipeline.apply(manifest.eventConfig.selectedFilterID, to: source)
            filteredImages = Dictionary(uniqueKeysWithValues: zip(0..<filtered.count, filtered))
        } catch {
            throw JobExecutionError.permanent("Could not apply \(manifest.eventConfig.selectedFilterID.rawValue) filter: \(error.localizedDescription)")
        }

        let directory = sessionDirectory(for: manifest)
        let frame = try loadFrame(for: manifest, in: directory)
        let compositor = Compositor(config: manifest.eventConfig, framePNG: frame)
        let strip: CGImage
        do {
            strip = try compositor.render(images: filteredImages)
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }

        do {
            try savePNGAtomically(strip, compositor: compositor, to: directory.appendingPathComponent("strip.png"))
            var updated = manifest
            updated.stripFileName = "strip.png"
            try await manifestStore.save(updated)
            if store.fetchSession(id: manifest.id) == nil {
                _ = store.restoreSessionRecord(from: updated)
            }
            store.updateSessionPaths(
                sessionID: manifest.id,
                stripPath: "\(manifest.relativeDirectoryPath)/strip.png",
                gifPath: nil
            )
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }
    }

    private func registerDownload(_ manifest: SessionManifest) async throws {
        let directory = sessionDirectory(for: manifest)
        let strip = directory.appendingPathComponent("strip.png")
        guard FileManager.default.fileExists(atPath: strip.path) else {
            throw JobExecutionError.permanent("Strip is missing: \(strip.path)")
        }
        let status = await server.statusSnapshot()
        guard case .ready = status.state else {
            throw JobExecutionError.retryable("Local download server is not ready.")
        }
        await server.registerToken(
            manifest.downloadToken,
            registration: SessionRouteRegistration(
                sessionDirectory: directory,
                language: manifest.eventConfig.customerLanguage,
                eventGalleryPath: manifest.eventConfig.eventGalleryPath
            )
        )
    }

    private func updateGallery(_ manifest: SessionManifest) async throws {
        guard let document = try? await experienceStore.load(eventID: manifest.eventID),
              document.gallery.mode != .disabled else { return }
        _ = try galleryThumbnailGenerator.generate(manifest: manifest)
        try await galleryStore.upsertSession(manifest: manifest, configuration: document.gallery)
    }

    private func renderGIF(_ manifest: SessionManifest) async throws {
        let directory = sessionDirectory(for: manifest)
        let framePaths = manifest.shots
            .sorted { $0.photoIndex < $1.photoIndex }
            .flatMap { shot in
                shot.gifFrameFileNames.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
            }

        guard !framePaths.isEmpty else {
            var updated = (try? await manifestStore.load(sessionID: manifest.id)) ?? manifest
            updated.gifFileName = nil
            try await manifestStore.save(updated)
            return
        }

        let frames = try framePaths.map { path -> CGImage in
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard url.path.hasPrefix(directory.path + "/"),
                  let image = loadCGImage(from: url) else {
                throw JobExecutionError.permanent("GIF frame is missing or corrupt: \(path)")
            }
            return image
        }
        let destination = directory.appendingPathComponent("booth.gif")
        let temporary = directory.appendingPathComponent(".booth-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let filteredFrames = try await filterPipeline.apply(manifest.eventConfig.selectedFilterID, to: frames)
            try GIFEncoder().encode(frames: filteredFrames, to: temporary)
            try replaceFile(at: destination, with: temporary)
            var updated = (try? await manifestStore.load(sessionID: manifest.id)) ?? manifest
            updated.gifFileName = "booth.gif"
            try await manifestStore.save(updated)
            if store.fetchSession(id: manifest.id) == nil {
                _ = store.restoreSessionRecord(from: updated)
            }
            store.updateSessionPaths(
                sessionID: manifest.id,
                stripPath: nil,
                gifPath: "\(manifest.relativeDirectoryPath)/booth.gif"
            )
        } catch let error as JobExecutionError {
            throw error
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }
    }

    private func upload(_ manifest: SessionManifest) async throws {
        guard defaults.bool(forKey: "cloudUploadEnabled") else {
            throw JobExecutionError.permanent("Cloud upload disabled in Settings")
        }
        let configuration = CloudUploadConfiguration(
            sshHost: defaults.string(forKey: "cloudSSHHost") ?? "",
            remoteBasePath: defaults.string(forKey: "cloudRemotePath")
                ?? CloudUploadConfiguration.defaultRemoteBasePath,
            publicBaseURL: defaults.string(forKey: "publicBaseURL") ?? ""
        )
        try await cloudUpload.upload(manifest: manifest, configuration: configuration)
    }

    private func printStrip(_ manifest: SessionManifest) async throws {
        let url = sessionDirectory(for: manifest).appendingPathComponent(manifest.stripFileName ?? "strip.png")
        try await printer.printStrip(at: url, showPrintDialog: false)
    }

    private func sessionDirectory(for manifest: SessionManifest) -> URL {
        URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
    }

    private func loadFrame(for manifest: SessionManifest, in directory: URL) throws -> CGImage? {
        guard let name = manifest.frameSnapshotFileName else { return nil }
        let url = directory.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/"),
              let image = loadCGImage(from: url) else {
            throw JobExecutionError.permanent("Frame snapshot is missing or corrupt: \(name)")
        }
        return image
    }

    private func savePNGAtomically(_ image: CGImage, compositor: Compositor, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".strip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try compositor.savePNG(image, to: temporary)
        try replaceFile(at: url, with: temporary)
    }

    private func replaceFile(at destination: URL, with temporary: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}
