import CoreGraphics
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Rolling video buffer")
struct RollingVideoBufferTests {
    @Test("downscales frames before retaining them for GIF encoding")
    func downscalesFramesBeforeBuffering() throws {
        let buffer = RollingVideoBuffer(windowSeconds: 1, maxFPS: 15, maxDimension: 480)
        buffer.append(try makeImage(width: 1_920, height: 1_080))

        let frame = try #require(buffer.drain(lastSeconds: 1).first)
        #expect(frame.width == 480)
        #expect(frame.height == 270)
    }

    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        return try #require(context.makeImage())
    }
}
