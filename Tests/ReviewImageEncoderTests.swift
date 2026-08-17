import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Review image encoding")
struct ReviewImageEncoderTests {
    @Test("Portrait, landscape, and square reviews preserve useful dimensions")
    func reviewDimensions() throws {
        let context = SessionMessageContext(sessionID: "session", sequence: 1)
        for (width, height) in [(3000, 4000), (4000, 3000), (3000, 3000)] {
            let image = makeImage(width: width, height: height)
            let data = try ReviewImageEncoder.encode(image: image, context: context, index: 0)
            let size = try #require(ReviewImageEncoder.pixelSize(of: data))

            #expect(max(size.width, size.height) <= CGFloat(ReviewImageEncoder.targetLongestDimension))
            #expect(min(size.width, size.height) > 200)
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            #expect(CGImageSourceCreateImageAtIndex(source, 0, nil) != nil)
        }
    }

    @Test("Review message stays below the transport frame limit")
    func reviewMessageFitsFrame() throws {
        let image = makeImage(width: 4000, height: 3000, noisy: true)
        let context = SessionMessageContext(sessionID: "session", sequence: 2)
        let data = try ReviewImageEncoder.encode(image: image, context: context, index: 1)
        let message = Message.shotCaptured(context: context, index: 1, thumbnailData: data)

        #expect(try message.encoded().count <= ReviewImageEncoder.targetMessagePayloadLength)
        #expect(try message.encoded().count < BoothFrameParser.maximumPayloadLength)
    }

    @Test("Reconnect snapshot keeps historical shots small")
    func reconnectSnapshotKeepsHistorySmall() throws {
        let context = SessionMessageContext(sessionID: "session", sequence: 3)
        let large = try ReviewImageEncoder.encode(
            image: makeImage(width: 4000, height: 3000),
            context: context,
            index: 0
        )
        let small = try #require(ReviewImageEncoder.thumbnailData(from: large))
        let snapshot = SessionSyncSnapshot(
            config: EventConfig(),
            sessionID: "session",
            phase: .review(photoIndex: 0),
            presentation: nil,
            reviewThumbnailData: large,
            isMirrored: false,
            keptShots: [0: small, 1: small, 2: small],
        )
        let payload = try Message.sessionSync(snapshot: snapshot).encoded()

        #expect(small.count < large.count)
        #expect(payload.count < BoothFrameParser.maximumPayloadLength)
    }

    private func makeImage(width: Int, height: Int, noisy: Bool = false) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let pixel = index / 4
            bytes[index] = UInt8((pixel * 17 + (noisy ? pixel % 251 : 40)) % 255)
            bytes[index + 1] = UInt8((pixel / max(1, width) * 13 + (noisy ? pixel % 241 : 80)) % 255)
            bytes[index + 2] = UInt8((pixel % max(1, width) * 7 + (noisy ? pixel % 239 : 160)) % 255)
            bytes[index + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }
}
