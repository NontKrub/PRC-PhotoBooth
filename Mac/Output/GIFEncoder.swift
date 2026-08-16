import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct GIFFrameSampler {
    let targetFramesPerShot: Int

    init(targetFramesPerShot: Int = 60) {
        self.targetFramesPerShot = targetFramesPerShot
    }

    func sample(_ frames: [CGImage]) -> [CGImage] {
        guard targetFramesPerShot > 0, !frames.isEmpty else { return [] }
        guard targetFramesPerShot > 1 else { return [frames[0]] }
        guard frames.count > 1 else { return Array(repeating: frames[0], count: targetFramesPerShot) }

        let sourceRange = Double(frames.count - 1)
        let targetRange = Double(targetFramesPerShot - 1)
        return (0..<targetFramesPerShot).map { index in
            let sourceIndex = Int((Double(index) * sourceRange / targetRange).rounded())
            return frames[sourceIndex]
        }
    }

    func sampleIndices(sourceCount: Int) -> [Int] {
        guard targetFramesPerShot > 0, sourceCount > 0 else { return [] }
        guard targetFramesPerShot > 1 else { return [0] }
        guard sourceCount > 1 else { return Array(repeating: 0, count: targetFramesPerShot) }
        let sourceRange = Double(sourceCount - 1)
        let targetRange = Double(targetFramesPerShot - 1)
        return (0..<targetFramesPerShot).map {
            Int((Double($0) * sourceRange / targetRange).rounded())
        }
    }
}

// Encodes a sequence of CGImages into a looping animated GIF.
struct GIFEncoder {
    let frameDelay: Double      // seconds per frame
    let maxDimension: Int       // downscale to this before encoding

    init(frameDelay: Double = 1.0 / 12.0, maxDimension: Int = 480) {
        self.frameDelay = frameDelay
        self.maxDimension = maxDimension
    }

    // frames: ordered array across all shots — [shot0frames..., shot1frames..., ...]
    func encode(frames: [CGImage], to url: URL) throws {
        try encode(frameCount: frames.count, to: url) { frames[$0] }
    }

    func encode(
        frameCount: Int,
        to url: URL,
        frameProvider: (Int) throws -> CGImage
    ) throws {
        guard frameCount > 0 else { throw GIFError.noFrames }
        guard frameDelay > 0 else { throw GIFError.invalidFrameDelay }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw GIFError.destinationFailed }

        // GIF file-level properties (loop forever)
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)

        // Per-frame properties
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ]

        for index in 0..<frameCount {
            let frame = try frameProvider(index)
            let scaled = scaledDown(frame) ?? frame
            CGImageDestinationAddImage(dest, scaled, frameProps as CFDictionary)
        }

        guard CGImageDestinationFinalize(dest) else { throw GIFError.finalizeFailed }
    }

    private func scaledDown(_ image: CGImage) -> CGImage? {
        let w = image.width
        let h = image.height
        guard max(w, h) > maxDimension else { return image }
        let scale = Double(maxDimension) / Double(max(w, h))
        let newW = Int(Double(w) * scale)
        let newH = Int(Double(h) * scale)
        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(origin: .zero, size: CGSize(width: newW, height: newH)))
        return ctx.makeImage()
    }
}

enum GIFError: LocalizedError {
    case noFrames, invalidFrameDelay, destinationFailed, finalizeFailed
    var errorDescription: String? {
        switch self {
        case .noFrames:          return "No frames to encode"
        case .invalidFrameDelay: return "GIF frame delay must be positive"
        case .destinationFailed: return "Failed to create GIF destination"
        case .finalizeFailed:    return "Failed to finalize GIF"
        }
    }
}

// Renders one complete template per timeline tick. Source frame arrays stay
// bounded to sampled inputs; final composite frames are streamed to ImageIO.
struct TemplateGIFRenderer {
    let compositor: Compositor
    let filterPipeline: PhotoFilterPipeline
    let sampler: GIFFrameSampler
    let encoder: GIFEncoder

    init(
        compositor: Compositor,
        filterPipeline: PhotoFilterPipeline,
        sampler: GIFFrameSampler = GIFFrameSampler(),
        encoder: GIFEncoder = GIFEncoder()
    ) {
        self.compositor = compositor
        self.filterPipeline = filterPipeline
        self.sampler = sampler
        self.encoder = encoder
    }

    @discardableResult
    func render(
        manifest: SessionManifest,
        acceptedImages: [Int: CGImage],
        directory: URL,
        qrPayload: String?,
        to destination: URL
    ) async throws -> Bool {
        let shots = manifest.shots.sorted { $0.photoIndex < $1.photoIndex }
        guard shots.contains(where: { !$0.gifFrameFileNames.isEmpty }) else { return false }

        var framesByPhoto: [Int: [CGImage]] = [:]
        for shot in shots {
            guard let accepted = acceptedImages[shot.photoIndex] else {
                throw TemplateGIFRendererError.missingAcceptedImage(shot.photoIndex)
            }
            let sourceFrames: [CGImage]
            if shot.gifFrameFileNames.isEmpty {
                sourceFrames = Array(repeating: accepted, count: sampler.targetFramesPerShot)
            } else {
                let names = shot.gifFrameFileNames.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                sourceFrames = try sampler.sampleIndices(sourceCount: names.count).map { index in
                    let url = try safeURL(names[index], in: directory)
                    guard let image = loadCGImage(from: url) else {
                        throw TemplateGIFRendererError.missingGIFFrame(names[index])
                    }
                    return image
                }
            }
            framesByPhoto[shot.photoIndex] = try await filterPipeline.apply(
                manifest.eventConfig.selectedFilterID,
                to: sourceFrames
            )
        }

        let qrImage = try compositor.makeQRCode(payload: qrPayload)
        try encoder.encode(frameCount: sampler.targetFramesPerShot, to: destination) { index in
            let images = Dictionary(uniqueKeysWithValues: framesByPhoto.compactMap { photoIndex, frames in
                frames.indices.contains(index) ? (photoIndex, frames[index]) : nil
            })
            return try compositor.render(images: images, qrImage: qrImage, maxDimension: encoder.maxDimension)
        }
        return true
    }

    private func safeURL(_ path: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw TemplateGIFRendererError.invalidGIFFramePath(path)
        }
        return url
    }
}

enum TemplateGIFRendererError: LocalizedError {
    case missingAcceptedImage(Int)
    case missingGIFFrame(String)
    case invalidGIFFramePath(String)

    var errorDescription: String? {
        switch self {
        case .missingAcceptedImage(let index): return "Accepted photograph is missing for index \(index)."
        case .missingGIFFrame(let path): return "GIF frame is missing or corrupt: \(path)"
        case .invalidGIFFramePath(let path): return "Invalid GIF frame path: \(path)"
        }
    }
}
