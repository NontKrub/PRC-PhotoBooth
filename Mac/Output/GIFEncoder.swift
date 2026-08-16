import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct GIFFrameSampler {
    let targetFramesPerShot: Int

    init(targetFramesPerShot: Int = GIFQualityPreset.balanced.frameCount) {
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

    init(preset: GIFQualityPreset = .balanced) {
        self.frameDelay = preset.frameDelay
        self.maxDimension = preset.maxDimension
    }

    init(frameDelay: Double, maxDimension: Int = GIFQualityPreset.high.maxDimension) {
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

    func encodeAsync(
        frameCount: Int,
        to url: URL,
        frameProvider: (Int) async throws -> CGImage
    ) async throws {
        guard frameCount > 0 else { throw GIFError.noFrames }
        guard frameDelay > 0 else { throw GIFError.invalidFrameDelay }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frameCount, nil
        ) else { throw GIFError.destinationFailed }

        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: frameDelay,
                kCGImagePropertyGIFUnclampedDelayTime: frameDelay
            ]
        ]

        for index in 0..<frameCount {
            try Task.checkCancellation()
            let frame = try await frameProvider(index)
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

// Renders one complete template per timeline tick. Source frames are decoded
// lazily and only the last filtered frame per animated slot is retained.
struct TemplateGIFRenderer {
    let compositor: Compositor
    let filterPipeline: PhotoFilterPipeline
    let sampler: GIFFrameSampler
    let encoder: GIFEncoder

    init(
        compositor: Compositor,
        filterPipeline: PhotoFilterPipeline,
        sampler: GIFFrameSampler = GIFFrameSampler(targetFramesPerShot: GIFQualityPreset.balanced.frameCount),
        encoder: GIFEncoder = GIFEncoder(preset: .balanced)
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

        var animatedURLsByPhoto: [Int: [URL]] = [:]
        var sampledIndicesByPhoto: [Int: [Int]] = [:]
        var stillImagesByPhoto: [Int: CGImage] = [:]
        for shot in shots {
            try Task.checkCancellation()
            guard let accepted = acceptedImages[shot.photoIndex] else {
                throw TemplateGIFRendererError.missingAcceptedImage(shot.photoIndex)
            }
            if shot.gifFrameFileNames.isEmpty {
                stillImagesByPhoto[shot.photoIndex] = try await filterPipeline.apply(
                    manifest.eventConfig.selectedFilterID,
                    to: accepted
                )
            } else {
                let names = shot.gifFrameFileNames.sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                }
                guard !names.isEmpty else {
                    throw TemplateGIFRendererError.zeroUsableFrames(shot.photoIndex)
                }
                animatedURLsByPhoto[shot.photoIndex] = try names.map { try safeURL($0, in: directory) }
                sampledIndicesByPhoto[shot.photoIndex] = sampler.sampleIndices(sourceCount: names.count)
            }
        }

        let qrImage = try compositor.makeQRCode(payload: qrPayload)
        var lastFilteredFrame: [Int: (sourceIndex: Int, image: CGImage)] = [:]
        try await encoder.encodeAsync(frameCount: sampler.targetFramesPerShot, to: destination) { index in
            try Task.checkCancellation()
            var images = stillImagesByPhoto
            for (photoIndex, urls) in animatedURLsByPhoto {
                guard let sampledIndices = sampledIndicesByPhoto[photoIndex],
                      sampledIndices.indices.contains(index) else {
                    throw TemplateGIFRendererError.zeroUsableFrames(photoIndex)
                }
                let sourceIndex = sampledIndices[index]
                if let cached = lastFilteredFrame[photoIndex], cached.sourceIndex == sourceIndex {
                    images[photoIndex] = cached.image
                    continue
                }
                guard urls.indices.contains(sourceIndex),
                      let sourceImage = loadCGImage(from: urls[sourceIndex]) else {
                    throw TemplateGIFRendererError.missingGIFFrame(urls[sourceIndex].lastPathComponent)
                }
                let filtered = try await filterPipeline.apply(
                    manifest.eventConfig.selectedFilterID,
                    to: sourceImage
                )
                lastFilteredFrame[photoIndex] = (sourceIndex, filtered)
                images[photoIndex] = filtered
            }
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
    case zeroUsableFrames(Int)

    var errorDescription: String? {
        switch self {
        case .missingAcceptedImage(let index): return "Accepted photograph is missing for index \(index)."
        case .missingGIFFrame(let path): return "GIF frame is missing or corrupt: \(path)"
        case .invalidGIFFramePath(let path): return "Invalid GIF frame path: \(path)"
        case .zeroUsableFrames(let index): return "No usable GIF frames for photo index \(index)."
        }
    }
}
