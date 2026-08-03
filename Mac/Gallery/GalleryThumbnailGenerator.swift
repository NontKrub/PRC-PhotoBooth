import Foundation
import ImageIO
import UniformTypeIdentifiers

struct GalleryThumbnailGenerator {
    func generate(manifest: SessionManifest) throws -> URL {
        let directory = URL(fileURLWithPath: manifest.absoluteDirectoryPath, isDirectory: true)
        guard let strip = manifest.stripFileName else {
            throw JobExecutionError.permanent("Strip is missing for gallery thumbnail.")
        }
        let sourceURL = directory.appendingPathComponent(strip).standardizedFileURL
        let destination = directory.appendingPathComponent("gallery-thumb.jpg")
        guard sourceURL.path.hasPrefix(directory.path + "/"),
              let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 640,
                  kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let data = jpegData(from: image, quality: 0.78) else {
            throw JobExecutionError.permanent("Could not create gallery thumbnail.")
        }
        if FileManager.default.fileExists(atPath: destination.path),
           let current = try? Data(contentsOf: destination),
           current == data {
            return destination
        }
        let temporary = directory.appendingPathComponent(".gallery-thumb-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
        return destination
    }
}
