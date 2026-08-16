import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PRC_PhotoBooth_Mac

@Suite("GIF encoding")
struct GIFEncoderTests {
    @Test("samples 75 source frames to 60 and keeps the final frame")
    func samplesLongSourceIncludingFinalFrame() {
        let frames = (0..<75).map { makeImage(width: $0 + 1) }
        let sampled = GIFFrameSampler(targetFramesPerShot: 60).sample(frames)

        #expect(sampled.count == 60)
        #expect(sampled.first?.width == frames.first?.width)
        #expect(sampled.last?.width == frames.last?.width)
    }

    @Test("samples fewer source frames to the target count and keeps endpoints")
    func samplesShortSourceIncludingEndpoints() {
        let frames = (0..<50).map { makeImage(width: $0 + 1) }
        let sampled = GIFFrameSampler(targetFramesPerShot: 60).sample(frames)

        #expect(sampled.count == 60)
        #expect(sampled.first?.width == frames.first?.width)
        #expect(sampled.last?.width == frames.last?.width)
    }

    @Test("repeats one source frame to the target count")
    func repeatsOneFrame() {
        let frame = makeImage(width: 7)
        let sampled = GIFFrameSampler(targetFramesPerShot: 60).sample([frame])

        #expect(sampled.count == 60)
        #expect(sampled.allSatisfy { $0.width == frame.width })
    }

    @Test("normalizes three shots to equal consecutive sections")
    func normalizesThreeShots() {
        let sampler = GIFFrameSampler(targetFramesPerShot: 60)
        let shots = (0..<3).map { shot in
            (0..<75).map { makeImage(width: shot * 100 + $0 + 1) }
        }
        let frames = shots.flatMap(sampler.sample)

        #expect(frames.count == 180)
        #expect(frames[59].width < 100)
        #expect(frames[60].width >= 101)
        #expect(frames[119].width < 200)
        #expect(frames[120].width >= 201)
        #expect(frames.last?.width == shots[2].last?.width)
    }

    @Test("GIF metadata uses exact frame count and delay")
    func encodesExactFrameCountAndDelay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-GIF-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("booth.gif")

        try GIFEncoder().encode(frames: Array(repeating: makeImage(width: 8), count: 180), to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 180)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = try #require(gif[kCGImagePropertyGIFDelayTime] as? Double)
        #expect(abs(delay - (1.0 / 12.0)) < 0.01)
    }

    @Test("provider encoder streams exact count, dimensions, and loop metadata")
    func streamsProviderFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-GIF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stream.gif")
        try GIFEncoder(frameDelay: 0.1, maxDimension: 480).encode(frameCount: 3, to: url) { _ in self.makeImage(width: 8) }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let frameProperties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(frameProperties[kCGImagePropertyPixelWidth] as? Int == 8)
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)
    }

    @Test("rejects a non-positive frame delay")
    func rejectsNonPositiveDelay() {
        #expect(throws: GIFError.self) {
            try GIFEncoder(frameDelay: 0).encode(frames: [makeImage(width: 8)], to: FileManager.default.temporaryDirectory.appendingPathComponent("invalid.gif"))
        }
    }

    private func makeImage(width: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        return context.makeImage()!
    }
}
