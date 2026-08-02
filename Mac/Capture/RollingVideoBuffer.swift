import Foundation
import CoreGraphics
import CoreImage
import AVFoundation

// Keeps the last N seconds of preview frames for GIF assembly.
final class RollingVideoBuffer: @unchecked Sendable {
    struct Frame: Sendable {
        let image: CGImage
        let timestamp: TimeInterval
    }

    private let lock = NSLock()
    private var frames: [Frame] = []
    private var lastAcceptedFrameTime: TimeInterval = -.infinity
    let capacity: Int          // max frame count
    let windowSeconds: Double
    let maxDimension: Int
    private let minimumFrameInterval: TimeInterval

    private let ciContext = CIContext()

    init(windowSeconds: Double = 6, maxFPS: Int = 15, maxDimension: Int = 480) {
        precondition(maxFPS > 0)
        precondition(maxDimension > 0)
        self.windowSeconds = windowSeconds
        self.capacity = Int(windowSeconds * Double(maxFPS))
        self.maxDimension = maxDimension
        self.minimumFrameInterval = 1 / Double(maxFPS)
    }

    func append(_ pixelBuffer: CVPixelBuffer) {
        let timestamp = CACurrentMediaTime()
        guard reserveFrameSlot(at: timestamp) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = scaledDown(ciImage) else { return }
        append(cgImage, at: timestamp)
    }

    func append(_ image: CGImage) {
        let timestamp = CACurrentMediaTime()
        guard reserveFrameSlot(at: timestamp) else { return }
        append(scaledDown(image) ?? image, at: timestamp)
    }

    private func reserveFrameSlot(at timestamp: TimeInterval) -> Bool {
        lock.withLock {
            guard timestamp - lastAcceptedFrameTime >= minimumFrameInterval else { return false }
            lastAcceptedFrameTime = timestamp
            return true
        }
    }

    private func append(_ image: CGImage, at timestamp: TimeInterval) {
        let frame = Frame(image: image, timestamp: timestamp)
        lock.withLock {
            frames.append(frame)
            if frames.count > capacity { frames.removeFirst() }
        }
    }

    private func scaledDown(_ image: CIImage) -> CGImage? {
        let scale = min(1, CGFloat(maxDimension) / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return ciContext.createCGImage(scaled, from: scaled.extent)
    }

    private func scaledDown(_ image: CGImage) -> CGImage? {
        let longestSide = max(image.width, image.height)
        guard longestSide > maxDimension else { return image }
        let scale = CGFloat(maxDimension) / CGFloat(longestSide)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // Returns frames within the last `seconds` of the buffer.
    func drain(lastSeconds: Double) -> [CGImage] {
        let cutoff = CACurrentMediaTime() - lastSeconds
        return lock.withLock {
            let result = frames.filter { $0.timestamp >= cutoff }.map { $0.image }
            frames.removeAll()
            return result
        }
    }

    func clear() {
        lock.withLock {
            frames.removeAll()
            lastAcceptedFrameTime = -.infinity
        }
    }
}
