import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("QR code generator")
struct QRCodeGeneratorTests {
    @Test("rejects empty payload")
    func rejectsEmptyPayload() {
        #expect(QRCodeGenerator.makeImage(payload: "") == nil)
        #expect(QRCodeGenerator.makeImage(payload: "   ") == nil)
    }

    @Test("integer scaling and quiet zone produce a larger square image")
    func scalesWithQuietZone() throws {
        let base = try #require(QRCodeGenerator.makeImage(payload: "https://example.invalid/s/test/", scale: 4))
        let printable = try #require(QRCodeGenerator.makeImage(payload: "https://example.invalid/s/test/", scale: 4, quietZoneModules: 4))

        #expect(base.width == base.height)
        #expect(printable.width == printable.height)
        #expect(printable.width > base.width)
        #expect(printable.width - base.width == 32)
        try expectPixel(atX: 0, y: 0, in: printable, equals: Pixel.white)
    }
}

private struct Pixel: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    static let white = Pixel(red: 255, green: 255, blue: 255, alpha: 255)
}

private func expectPixel(atX x: Int, y: Int, in image: CGImage, equals expected: Pixel) throws {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = try #require(CGContext(
        data: &data,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let offset = (y * image.width + x) * 4
    #expect(Pixel(red: data[offset], green: data[offset + 1], blue: data[offset + 2], alpha: data[offset + 3]) == expected)
}
