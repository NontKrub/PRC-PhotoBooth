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
    private let guestDeliverySelection: @MainActor () -> GuestDeliveryInterfaceSelection

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
        galleryStore: EventGalleryStore = EventGalleryStore(baseDirectory: BoothCoordinator.appSupportRootURL()),
        guestDeliverySelection: @escaping @MainActor () -> GuestDeliveryInterfaceSelection = { .automatic }
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
        self.guestDeliverySelection = guestDeliverySelection
    }

    var isAutoPrintLaneAvailable: Bool { printer.isIdle }

    func execute(_ job: SessionJob) async throws {
        let manifest: SessionManifest
        do {
            manifest = try await manifestStore.load(sessionID: job.sessionID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }

        guard let plan = FinalizationPlan.make(from: manifest),
              plan.authorizes(job, for: manifest) else {
            throw JobExecutionError.obsoleteTransaction(
                "Job \(job.id) does not belong to the manifest's active finalization plan."
            )
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
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let images = try workspace.loadAcceptedImages(manifest: manifest)
                for index in 0..<eventConfig.photoCount {
                    try Task.checkCancellation()
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
                try Task.checkCancellation()
                try Self.savePNGAtomically(
                    strip,
                    compositor: Compositor(config: eventConfig, framePNG: nil),
                    to: directory.appendingPathComponent("strip.png")
                )
            }
            try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as JobExecutionError {
            throw error
        } catch {
            throw JobExecutionError.permanent(error.localizedDescription)
        }

        do {
            try Task.checkCancellation()
            let updated = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.finalizing]
            ) {
                $0.stripFileName = "strip.png"
            }
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
        try Task.checkCancellation()
        let directory = sessionDirectory(for: manifest)
        let strip = directory.appendingPathComponent("strip.png")
        guard FileManager.default.fileExists(atPath: strip.path) else {
            throw JobExecutionError.permanent("Strip is missing: \(strip.path)")
        }
        let status = await server.statusSnapshot()
        guard case .ready = status.state else {
            throw JobExecutionError.retryable("Local download server is not ready.")
        }
        try Task.checkCancellation()
        try await registerGuestRoute(
            for: manifest,
            registration: SessionRouteRegistration(
                sessionDirectory: directory,
                language: manifest.eventConfig.customerLanguage,
                eventGalleryPath: manifest.eventConfig.eventGalleryPath,
                gifState: manifest.shots.contains(where: { !$0.gifFrameFileNames.isEmpty })
                    ? (manifest.gifFileName != nil ? .ready : .preparing)
                    : .none
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
        do {
            let worker = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                _ = try GalleryThumbnailGenerator().generate(manifest: manifest)
            }
            try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
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
            try Task.checkCancellation()
            _ = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.finalizing, .completed]
            ) {
                $0.gifFileName = nil
            }
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
            let worker = Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
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
                try Task.checkCancellation()
                _ = try Self.validatedFileByteCount(at: temporary)
                try Task.checkCancellation()
                try Self.replaceFile(at: destination, with: temporary)
                return true
            }
            let didRender = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            guard didRender else { return }
            try Task.checkCancellation()
            let updated = try await manifestStore.update(
                sessionID: manifest.id,
                allowedStatuses: [.finalizing, .completed]
            ) {
                $0.gifFileName = "booth.gif"
            }
            if store.fetchSession(id: manifest.id) == nil {
                _ = store.restoreSessionRecord(from: updated)
            }
            store.updateSessionPaths(
                sessionID: manifest.id,
                stripPath: nil,
                gifPath: "\(manifest.relativeDirectoryPath)/booth.gif"
            )
            do {
                if let document = try? await experienceStore.load(eventID: updated.eventID),
                   FinalizationPlan.make(from: updated)?.jobKinds.contains(.updateGallery) == true {
                    try await galleryStore.upsertSession(manifest: updated, configuration: document.gallery)
                }
            } catch {
                NSLog("[Jobs] Gallery GIF refresh failed: %@", error.localizedDescription)
            }
            try await registerGuestRoute(
                for: updated,
                registration: SessionRouteRegistration(
                    sessionDirectory: directory,
                    language: updated.eventConfig.customerLanguage,
                    eventGalleryPath: updated.eventConfig.eventGalleryPath,
                    gifState: .ready
                )
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
        guard let configuration = Self.cloudUploadConfiguration(for: manifest) else {
            let message = manifest.deliveryIntent?.cloudUploadEnabled == true
                ? "Saved cloud destination is unavailable for this session."
                : "Cloud upload is not enabled for this session."
            throw JobExecutionError.permanent(message)
        }
        try await cloudUpload.upload(manifest: manifest, configuration: configuration)
    }

    static func cloudUploadConfiguration(for manifest: SessionManifest) -> CloudUploadConfiguration? {
        guard manifest.deliveryIntent?.cloudUploadEnabled ?? (manifest.cloudDelivery != nil),
              let snapshot = manifest.cloudDelivery else { return nil }
        return CloudUploadConfiguration(snapshot: snapshot)
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
        let cloudUploadEnabled = manifest.deliveryIntent?.cloudUploadEnabled ?? (manifest.cloudDelivery != nil)
        let allowTrustedLocalHTTP = defaults.bool(forKey: "allowTrustedLocalHTTP")
        let localBaseURL = LocalWebServer.guestDeliveryEndpoint(
            selection: guestDeliverySelection(),
            port: server.port
        ).endpoint?.baseURL ?? ""
        return try SessionQRCodePayloadResolver.resolve(
            manifest: manifest,
            localBaseURL: localBaseURL,
            publicBaseURL: manifest.cloudDelivery?.publicBaseURL,
            cloudUploadEnabled: cloudUploadEnabled,
            allowTrustedLocalHTTP: allowTrustedLocalHTTP
        )
    }

    private func registerGuestRoute(
        for manifest: SessionManifest,
        registration: SessionRouteRegistration
    ) async throws {
        try Task.checkCancellation()
        let route = try CloudGuestRoute.resolve(for: manifest)
        if manifest.origin == .soakTest {
            await server.registerGuestRoute(path: route.relativePath, registration: registration)
        } else {
            await server.registerToken(manifest.downloadToken, registration: registration)
        }
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
