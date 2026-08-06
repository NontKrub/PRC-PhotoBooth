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
        guard !frames.isEmpty else { throw GIFError.noFrames }
        guard frameDelay > 0 else { throw GIFError.invalidFrameDelay }
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, frames.count, nil
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

        for frame in frames {
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
