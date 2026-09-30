import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@testable import PRC_PhotoBooth_Mac

@Suite("SessionWorkspace")
struct SessionWorkspaceTests {
    @Test("creates a sanitized collision-safe workspace and copies frame")
    func createsWorkspace() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = root.appendingPathComponent("source.png")
        let foreground = root.appendingPathComponent("foreground.png")
        try makeImage().writePNG(to: frame)
        try makeImage(red: false).writePNG(to: foreground)

        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "12345678-abcdef",
            eventName: "Party / One",
            outputRoot: root.appendingPathComponent("output"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            frameSourceURL: frame,
            foregroundOverlaySourceURL: foreground
        )

        #expect(descriptor.relativeDirectoryPath.contains("Party - One"))
        #expect(descriptor.absoluteDirectoryPath.hasSuffix("12345678"))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(".work/frame.png").path))
        #expect(descriptor.foregroundOverlaySnapshotFileName == ".work/foreground.png")
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(".work/foreground.png").path))
    }

    @Test("saves accepted image and immutable generations for replacement captures")
    func savesAndReplacesCapture() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "abcdefgh-1234",
            eventName: "Event",
            outputRoot: root,
            startedAt: Date(),
            frameSourceURL: nil
        )
        let first = try workspace.saveAcceptedCapture(
            image: makeImage(),
            gifFrames: [makeImage(red: true), makeImage(red: false)],
            photoIndex: 0,
            workspace: descriptor
        )
        let second = try workspace.saveAcceptedCapture(
            image: makeImage(red: false),
            gifFrames: [makeImage(red: false)],
            photoIndex: 0,
            workspace: descriptor
        )

        #expect(first.imageFileName != second.imageFileName)
        #expect(first.imageFileName.hasPrefix("shot_0-"))
        #expect(first.gifFrameFileNames.count == 2)
        #expect(second.gifFrameFileNames.count == 1)
        let firstDir = URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(
            URL(fileURLWithPath: first.gifFrameFileNames[0]).deletingLastPathComponent().path
        )
        let secondDir = URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(
            URL(fileURLWithPath: second.gifFrameFileNames[0]).deletingLastPathComponent().path
        )
        #expect(try FileManager.default.contentsOfDirectory(atPath: firstDir.path).count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: secondDir.path).count == 1)
    }

    @Test("loads accepted images, removes work only, and reports missing files")
    func loadsAndCleans() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "abcdefgh-1234",
            eventName: "Event",
            outputRoot: root,
            startedAt: Date(),
            frameSourceURL: nil
        )
        let saved = try workspace.saveAcceptedCapture(image: makeImage(), gifFrames: [], photoIndex: 0, workspace: descriptor)
        let manifest = SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            id: "abcdefgh-1234", eventID: "event", eventName: "Event",
            eventConfig: EventConfig(eventID: "event", eventName: "Event", photoCount: 1, slots: []),
            startedAt: Date(), completedAt: nil, cancelledAt: nil, status: .capturing,
            nextPhotoIndex: 1, outputRootPath: root.path, relativeDirectoryPath: descriptor.relativeDirectoryPath,
            absoluteDirectoryPath: descriptor.absoluteDirectoryPath, frameSnapshotFileName: nil,
            stripFileName: nil, gifFileName: nil, downloadToken: "token",
            shots: [RuntimeShotRecord(photoIndex: 0, imageFileName: saved.imageFileName, gifFrameFileNames: [], retakeCount: 0, acceptedAt: Date())],
            lastError: nil, updatedAt: Date()
        )

        #expect(try workspace.loadAcceptedImages(manifest: manifest)[0] != nil)
        try workspace.removeWorkingFiles(manifest: manifest)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(saved.imageFileName).path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(".work").path))

        var missing = manifest
        missing.shots[0].imageFileName = "missing.jpg"
        #expect(throws: SessionWorkspaceError.self) { try workspace.loadAcceptedImages(manifest: missing) }
    }

    @Test("slow accepted-capture persistence leaves the MainActor responsive")
    @MainActor
    func slowPersistenceDoesNotBlockMainActor() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "slow-save-session",
            eventName: "Slow Save",
            outputRoot: root,
            startedAt: Date(),
            frameSourceURL: nil
        )
        let mainActorDidRun = LockedBoolean()
        let probe = Task { @MainActor in
            await Task.yield()
            mainActorDidRun.set(true)
        }

        let saved = try await saveAcceptedCaptureInBackground(
            image: makeImage(),
            gifFrames: [],
            photoIndex: 0,
            workspace: descriptor
        ) { image, frames, index, workspace in
            Thread.sleep(forTimeInterval: 0.08)
            return try SessionWorkspace().saveAcceptedCapture(
                image: image,
                gifFrames: frames,
                photoIndex: index,
                workspace: workspace
            )
        }
        await probe.value

        #expect(mainActorDidRun.value)
        #expect(saved.imageFileName.hasPrefix("shot_0-"))
        #expect(saved.gifFrameFileNames.isEmpty)
    }

    @Test("files from a save that becomes stale are removed after the write finishes")
    @MainActor
    func staleSaveFilesAreRemoved() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "stale-save-session",
            eventName: "Stale Save",
            outputRoot: root,
            startedAt: Date(),
            frameSourceURL: nil
        )
        var currentGeneration: UInt64 = 4
        let saveTask = Task {
            try await saveAcceptedCaptureInBackground(
                image: makeImage(),
                gifFrames: [makeImage()],
                photoIndex: 0,
                workspace: descriptor
            ) { image, frames, index, workspace in
                Thread.sleep(forTimeInterval: 0.06)
                return try SessionWorkspace().saveAcceptedCapture(
                    image: image,
                    gifFrames: frames,
                    photoIndex: index,
                    workspace: workspace
                )
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        currentGeneration = 5 // Model cancellation while the atomic disk transaction is running.
        let saved = try await saveTask.value

        #expect(!AcceptedCaptureCommitPolicy.shouldCommit(
            capturedGeneration: 4,
            currentGeneration: currentGeneration,
            expectedSessionID: "stale-save-session",
            currentSessionID: "stale-save-session",
            currentManifestID: "stale-save-session",
            manifestStatus: .capturing,
            cancelledAt: nil,
            phase: .review(photoIndex: 0),
            photoIndex: 0
        ))
        let sessionDirectory = URL(fileURLWithPath: descriptor.absoluteDirectoryPath, isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(saved.imageFileName).path))
        #expect(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(saved.gifFrameFileNames[0]).path))
        try await removeCaptureFilesInBackground(saved, workspace: descriptor)
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(saved.imageFileName).path))
        #expect(!FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(saved.gifFrameFileNames[0]).path))
    }

    @Test("a failed accepted-capture save leaves review retryable")
    @MainActor
    func failedSaveCanBeRetried() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "retry-save-session",
            eventName: "Retry Save",
            outputRoot: root,
            startedAt: Date(),
            frameSourceURL: nil
        )
        let machine = SessionStateMachine()
        machine.startSession(config: EventConfig(photoCount: 1), sessionID: "retry-save-session")
        machine.beginCountdown(photoIndex: 0)
        machine.enterReview(photoIndex: 0, thumbnailData: Data([1]))

        do {
            _ = try await saveAcceptedCaptureInBackground(
                image: makeImage(),
                gifFrames: [],
                photoIndex: 0,
                workspace: descriptor
            ) { _, _, _, _ in
                throw SessionWorkspaceError.imageEncodingFailed
            }
            Issue.record("Expected the injected persistence failure.")
        } catch SessionWorkspaceError.imageEncodingFailed {
            // The coordinator reports this error and leaves the review phase active.
        } catch {
            Issue.record("Unexpected save error: \(error.localizedDescription)")
        }

        #expect(machine.phase == .review(photoIndex: 0))
        let retry = try await saveAcceptedCaptureInBackground(
            image: makeImage(),
            gifFrames: [],
            photoIndex: 0,
            workspace: descriptor
        ) { image, frames, index, workspace in
            try SessionWorkspace().saveAcceptedCapture(
                image: image,
                gifFrames: frames,
                photoIndex: index,
                workspace: workspace
            )
        }
        #expect(retry.imageFileName.hasPrefix("shot_0-"))
        #expect(machine.phase == .review(photoIndex: 0))
    }

    @Test("a stale capture save cannot commit after session cancellation")
    func staleCaptureSaveIsRejectedBeforeManifestUpdate() {
        func shouldCommit(
            capturedGeneration: UInt64 = 4,
            currentGeneration: UInt64 = 4,
            currentSessionID: String? = "session-a",
            manifestStatus: RuntimeSessionStatus? = .capturing,
            cancelledAt: Date? = nil,
            phase: BoothPhase = .review(photoIndex: 0)
        ) -> Bool {
            AcceptedCaptureCommitPolicy.shouldCommit(
                capturedGeneration: capturedGeneration,
                currentGeneration: currentGeneration,
                expectedSessionID: "session-a",
                currentSessionID: currentSessionID,
                currentManifestID: currentSessionID,
                manifestStatus: manifestStatus,
                cancelledAt: cancelledAt,
                phase: phase,
                photoIndex: 0
            )
        }

        #expect(shouldCommit())
        #expect(!shouldCommit(currentGeneration: 5))
        #expect(!shouldCommit(currentSessionID: "session-b"))
        #expect(!shouldCommit(manifestStatus: .cancelled, cancelledAt: Date()))
        #expect(!shouldCommit(phase: .idle))
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        storage = value
    }
}

private func makeImage(red: Bool = true) -> CGImage {
    let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: red ? 1 : 0, green: red ? 0 : 1, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return ctx.makeImage()!
}

private extension CGImage {
    func writePNG(to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, self, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-Workspace-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
