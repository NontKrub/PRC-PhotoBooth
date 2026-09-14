import Foundation
import CoreGraphics
import ImageIO

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
        } catch is CancellationError {
            throw CancellationError()
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
        let directory = sessionDirectory(for: manifest)
        let qrPayload = try qrPayload(for: manifest)
        let workspace = workspace
        let filterPipeline = filterPipeline
        let eventConfig = manifest.eventConfig
        let frameName = manifest.frameSnapshotFileName
        let foregroundName = manifest.foregroundOverlaySnapshotFileName
        do {
            try await Task.detached(priority: .userInitiated) {
                let images = try workspace.loadAcceptedImages(manifest: manifest)
                for index in 0..<eventConfig.photoCount {
                    guard images[index] != nil else {
                        throw JobExecutionError.permanent("Accepted photograph is missing for index \(index).")
                    }
                }

                let filtered: [CGImage]
                do {
                    let source = (0..<eventConfig.photoCount).compactMap { images[$0] }
                    filtered = try await filterPipeline.apply(eventConfig.selectedFilterID, to: source)
                } catch {
                    throw JobExecutionError.permanent("Could not apply \(eventConfig.selectedFilterID.rawValue) filter: \(error.localizedDescription)")
                }
                let filteredImages = Dictionary(uniqueKeysWithValues: zip(0..<filtered.count, filtered))
                let frame = try Self.loadImage(named: frameName, label: "Frame", in: directory)
                let foreground = try Self.loadImage(
                    named: foregroundName,
                    label: "Foreground overlay",
                    in: directory
                )
                let strip = try Compositor(
                    config: eventConfig,
                    framePNG: frame,
                    foregroundOverlayPNG: foreground
                ).render(images: filteredImages, qrPayload: qrPayload)
                try Self.savePNGAtomically(
                    strip,
                    compositor: Compositor(config: eventConfig, framePNG: nil),
                    to: directory.appendingPathComponent("strip.png")
                )
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as JobExecutionError {
            throw error
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }

        do {
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
        } catch is CancellationError {
            throw CancellationError()
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
                eventGalleryPath: manifest.eventConfig.eventGalleryPath,
                gifState: manifest.shots.contains(where: { !$0.gifFrameFileNames.isEmpty }) ? .preparing : .none
            )
        )
    }

    private func updateGallery(_ manifest: SessionManifest) async throws {
        let document: EventExperienceDocument
        do {
            document = try await experienceStore.load(eventID: manifest.eventID)
        } catch {
            throw JobExecutionError.permanent("Gallery configuration could not load: \(error.localizedDescription)")
        }
        guard document.gallery.mode != .disabled else { return }
        do {
            _ = try await Task.detached(priority: .utility) {
                try GalleryThumbnailGenerator().generate(manifest: manifest)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }
        try await galleryStore.upsertSession(manifest: manifest, configuration: document.gallery)
    }

    private func renderGIF(_ manifest: SessionManifest) async throws {
        let directory = sessionDirectory(for: manifest)
        guard manifest.shots.contains(where: { !$0.gifFrameFileNames.isEmpty }) else {
            var updated = try await manifestStore.load(sessionID: manifest.id)
            updated.gifFileName = nil
            try await manifestStore.save(updated)
            return
        }
        let destination = directory.appendingPathComponent("booth.gif")
        let temporary = directory.appendingPathComponent(".booth-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let qrPayload = try qrPayload(for: manifest)
            let preset = manifest.eventConfig.gifQualityPreset
            let workspace = workspace
            let filterPipeline = filterPipeline
            let didRender = try await Task.detached(priority: .userInitiated) {
                let acceptedImages = try workspace.loadAcceptedImages(manifest: manifest)
                let frame = try Self.loadImage(named: manifest.frameSnapshotFileName, label: "Frame", in: directory)
                let foreground = try Self.loadImage(
                    named: manifest.foregroundOverlaySnapshotFileName,
                    label: "Foreground overlay",
                    in: directory
                )
                let didRender = try await TemplateGIFRenderer(
                    compositor: Compositor(
                        config: manifest.eventConfig,
                        framePNG: frame,
                        foregroundOverlayPNG: foreground
                    ),
                    filterPipeline: filterPipeline,
                    sampler: GIFFrameSampler(targetFramesPerShot: preset.frameCount),
                    encoder: GIFEncoder(preset: preset)
                ).render(
                    manifest: manifest,
                    acceptedImages: acceptedImages,
                    directory: directory,
                    qrPayload: qrPayload,
                    to: temporary
                )
                guard didRender else { return false }
                _ = try Self.validatedFileByteCount(at: temporary)
                try Self.replaceFile(at: destination, with: temporary)
                return true
            }.value
            guard didRender else { return }
            var updated = try await manifestStore.load(sessionID: manifest.id)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as JobExecutionError {
            throw error
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }
    }

    private func upload(_ manifest: SessionManifest) async throws {
        guard let configuration = Self.cloudUploadConfiguration(for: manifest, defaults: defaults) else {
            throw JobExecutionError.permanent("Cloud upload disabled in Settings")
        }
        try await cloudUpload.upload(manifest: manifest, configuration: configuration)
    }

    static func cloudUploadConfiguration(
        for manifest: SessionManifest,
        defaults: UserDefaults
    ) -> CloudUploadConfiguration? {
        if let snapshot = manifest.cloudDelivery {
            return CloudUploadConfiguration(snapshot: snapshot)
        }
        guard defaults.bool(forKey: "cloudUploadEnabled") else { return nil }
        return CloudUploadConfiguration(
            sshHost: defaults.string(forKey: "cloudSSHHost") ?? "",
            remoteBasePath: defaults.string(forKey: "cloudRemotePath")
                ?? CloudUploadConfiguration.defaultRemoteBasePath,
            publicBaseURL: defaults.string(forKey: "publicBaseURL") ?? ""
        )
    }

    private func printStrip(_ manifest: SessionManifest) async throws {
        try Task.checkCancellation()
        let url = sessionDirectory(for: manifest).appendingPathComponent(manifest.stripFileName ?? "strip.png")
        try await printer.printStrip(at: url, showPrintDialog: false)
        try Task.checkCancellation()
    }

    private func sessionDirectory(for manifest: SessionManifest) -> URL {
        URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true).standardizedFileURL
    }

    nonisolated private static func loadImage(named name: String?, label: String, in directory: URL) throws -> CGImage? {
        guard let name else { return nil }
        let url = directory.appendingPathComponent(name).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/"),
              let image = loadCGImage(from: url) else {
            throw JobExecutionError.permanent("\(label) snapshot is missing or corrupt: \(name)")
        }
        return image
    }

    private func qrPayload(for manifest: SessionManifest) throws -> String? {
        guard !manifest.eventConfig.qrCodeElements.isEmpty else { return nil }
        return try SessionQRCodePayloadResolver.resolve(
            token: manifest.downloadToken,
            localBaseURL: "http://\(LocalWebServer.lanIPAddress() ?? "localhost"):\(server.port)",
            publicBaseURL: manifest.cloudDelivery?.publicBaseURL ?? defaults.string(forKey: "publicBaseURL"),
            cloudUploadEnabled: manifest.cloudDelivery != nil || defaults.bool(forKey: "cloudUploadEnabled")
        )
    }

    nonisolated private static func savePNGAtomically(_ image: CGImage, compositor: Compositor, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".strip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try compositor.savePNG(image, to: temporary)
        try replaceFile(at: url, with: temporary)
    }

    nonisolated private static func replaceFile(at destination: URL, with temporary: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    nonisolated private static func validatedFileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw JobExecutionError.permanent("GIF output was empty or invalid.")
        }
        return byteCount
    }
}
