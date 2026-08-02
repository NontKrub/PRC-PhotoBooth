import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Encodes a sequence of CGImages into a looping animated GIF.
struct GIFEncoder {
    let frameDelay: Double      // seconds per frame
    let maxDimension: Int       // downscale to this before encoding
    let maxFrames: Int          // cap total frames for file size

    init(frameDelay: Double = 1.0 / 12.0, maxDimension: Int = 480, maxFrames: Int = 120) {
        self.frameDelay = frameDelay
        self.maxDimension = maxDimension
        self.maxFrames = maxFrames
    }

    // frames: ordered array across all shots — [shot0frames..., shot1frames..., ...]
    func encode(frames: [CGImage], to url: URL) throws {
        guard !frames.isEmpty else { throw GIFError.noFrames }
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

        // Subsample if over maxFrames
        let step = frames.count > maxFrames ? frames.count / maxFrames : 1
        var added = 0
        for i in stride(from: 0, to: frames.count, by: step) {
            guard added < maxFrames else { break }
            let frame = frames[i]
            let scaled = scaledDown(frame) ?? frame
            CGImageDestinationAddImage(dest, scaled, frameProps as CFDictionary)
            added += 1
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
    case noFrames, destinationFailed, finalizeFailed
    var errorDescription: String? {
        switch self {
        case .noFrames:          return "No frames to encode"
        case .destinationFailed: return "Failed to create GIF destination"
        case .finalizeFailed:    return "Failed to finalize GIF"
        }
    }
}
