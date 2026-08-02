import Testing
import Foundation
import CoreGraphics
@testable import PRC_PhotoBooth_Mac

@Suite("Compositor")
struct CompositorTests {
    @Test("renders without frame PNG")
    func renderNoFrame() throws {
        let config = EventConfig(
            eventID: "test",
            eventName: "Test",
            photoCount: 2,
            countdownSeconds: 5,
            canvasWidth: 400,
            canvasHeight: 600,
            slots: [
                SharedPhotoSlot(id: "s1", normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.5), zOrder: 0),
                SharedPhotoSlot(id: "s2", normalizedRect: CGRect(x: 0, y: 0.5, width: 1, height: 0.5), zOrder: 1)
            ]
        )
        let compositor = Compositor(config: config, framePNG: nil)

        // Create simple 100x100 red CGImage
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let redImage = ctx.makeImage()!

        let result = try compositor.render(images: [0: redImage, 1: redImage])
        #expect(result.width == 400)
        #expect(result.height == 600)
    }

    @Test("uses top-left canvas coordinates for frame and slots")
    func renderTopLeftCoordinates() throws {
        let config = EventConfig(
            eventID: "test",
            eventName: "Test",
            photoCount: 1,
            countdownSeconds: 5,
            canvasWidth: 4,
            canvasHeight: 4,
            slots: [
                SharedPhotoSlot(
                    id: "s1",
                    normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                    zOrder: 0,
                    photoIndex: 0
                )
            ]
        )
        let compositor = Compositor(config: config, framePNG: makeImage(width: 4, height: 4) { x, y in
            if x == 3 && y == 3 { return (0, 0, 255, 255) }
            return (255, 255, 255, 255)
        })
        let photo = makeImage(width: 2, height: 2) { x, y in
            if x == 0 && y == 0 { return (255, 0, 0, 255) }
            if x == 1 && y == 0 { return (0, 255, 0, 255) }
            if x == 0 && y == 1 { return (0, 0, 255, 255) }
            return (255, 255, 0, 255)
        }

        let result = try compositor.render(images: [0: photo])
        try expectPixel(atX: 0, y: 0, in: result, equals: Pixel(255, 0, 0, 255))
        try expectPixel(atX: 1, y: 0, in: result, equals: Pixel(0, 255, 0, 255))
        try expectPixel(atX: 0, y: 1, in: result, equals: Pixel(0, 0, 255, 255))
        try expectPixel(atX: 1, y: 1, in: result, equals: Pixel(255, 255, 0, 255))
        try expectPixel(atX: 3, y: 3, in: result, equals: Pixel(0, 0, 255, 255))
    }
}

private struct Pixel: Equatable, CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var description: String {
        "(\(red), \(green), \(blue), \(alpha))"
    }
}

private func makeImage(
    width: Int,
    height: Int,
    pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
) -> CGImage {
    var data = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let p = pixel(x, y)
            data[offset] = p.0
            data[offset + 1] = p.1
            data[offset + 2] = p.2
            data[offset + 3] = p.3
        }
    }
    return data.withUnsafeBytes { bytes in
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private func expectPixel(atX x: Int, y: Int, in image: CGImage, equals expected: Pixel) throws {
    let actual = try #require(pixel(atX: x, y: y, in: image))
    #expect(actual == expected)
}

private func pixel(atX x: Int, y: Int, in image: CGImage) -> Pixel? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let ctx = CGContext(
        data: &data,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let offset = (y * image.width + x) * 4
    return Pixel(data[offset], data[offset + 1], data[offset + 2], data[offset + 3])
}
