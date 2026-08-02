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
        try makeImage().writePNG(to: frame)

        let workspace = SessionWorkspace()
        let descriptor = try workspace.createWorkspace(
            sessionID: "12345678-abcdef",
            eventName: "Party / One",
            outputRoot: root.appendingPathComponent("output"),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            frameSourceURL: frame
        )

        #expect(descriptor.relativeDirectoryPath.contains("Party - One"))
        #expect(descriptor.absoluteDirectoryPath.hasSuffix("12345678"))
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(".work/frame.png").path))
    }

    @Test("saves accepted image and deterministic GIF frames, replacing an index safely")
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

        #expect(first.imageFileName == "shot_0.jpg")
        #expect(first.gifFrameFileNames == [
            ".work/gif/photo_0/frame_000.jpg",
            ".work/gif/photo_0/frame_001.jpg"
        ])
        #expect(second.gifFrameFileNames == [".work/gif/photo_0/frame_000.jpg"])
        let frameDir = URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(".work/gif/photo_0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: frameDir.path).sorted() == ["frame_000.jpg"])
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
            nextPhotoIndex: 1, outputRootPath: root.path, relativeDirectoryPath: "Event/dir",
            absoluteDirectoryPath: descriptor.absoluteDirectoryPath, frameSnapshotFileName: nil,
            stripFileName: nil, gifFileName: nil, downloadToken: "token",
            shots: [RuntimeShotRecord(photoIndex: 0, imageFileName: saved.imageFileName, gifFrameFileNames: [], retakeCount: 0, acceptedAt: Date())],
            lastError: nil, updatedAt: Date()
        )

        #expect(try workspace.loadAcceptedImages(manifest: manifest)[0] != nil)
        try workspace.removeWorkingFiles(manifest: manifest)
        #expect(FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent("shot_0.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: descriptor.absoluteDirectoryPath).appendingPathComponent(".work").path))

        var missing = manifest
        missing.shots[0].imageFileName = "missing.jpg"
        #expect(throws: SessionWorkspaceError.self) { try workspace.loadAcceptedImages(manifest: missing) }
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
