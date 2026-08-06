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

    @Test("requires a payload when QR elements exist")
    func missingQRCodePayloadThrows() {
        let config = EventConfig(
            canvasWidth: 100,
            canvasHeight: 100,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)],
            qrCodeElements: [SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))]
        )

        #expect(throws: CompositorError.missingQRCodePayload) {
            try Compositor(config: config, framePNG: nil).render(images: [:])
        }
    }

    @Test("draws QR above the frame at top-left coordinates")
    func rendersQRCodeAtTopLeftCoordinates() throws {
        let config = EventConfig(
            canvasWidth: 80,
            canvasHeight: 80,
            qrCodeElements: [SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), zOrder: 2)]
        )
        let gray = solidImage(width: 80, height: 80, color: Pixel(120, 120, 120, 255))
        let image = try Compositor(config: config, framePNG: gray).render(
            images: [0: solidImage(width: 8, height: 8, color: Pixel(255, 0, 0, 255))],
            qrPayload: "https://example.invalid/s/test/"
        )

        try expectPixel(atX: 20, y: 20, in: image, equals: Pixel(255, 255, 255, 255))
        try expectPixel(atX: 19, y: 20, in: image, equals: Pixel(120, 120, 120, 255))
        #expect(darkPixelCount(in: image, rect: CGRect(x: 20, y: 20, width: 40, height: 40)) > 0)
    }

    @Test("two QR elements render two visible codes with unchanged output size")
    func rendersTwoQRCodes() throws {
        let config = EventConfig(
            canvasWidth: 240,
            canvasHeight: 320,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)],
            qrCodeElements: [
                SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.3), zOrder: 1),
                SharedQRCodeElement(id: "qr-2", normalizedRect: CGRect(x: 0.65, y: 0.6, width: 0.3, height: 0.3), zOrder: 2)
            ]
        )
        let image = try Compositor(config: config, framePNG: solidImage(width: 240, height: 320, color: Pixel(100, 100, 100, 255)))
            .render(images: [0: solidImage(width: 8, height: 8, color: Pixel(255, 0, 0, 255))], qrPayload: "https://example.invalid/s/test/")

        #expect(image.width == 240)
        #expect(image.height == 320)
        #expect(darkPixelCount(in: image, rect: CGRect(x: 12, y: 32, width: 72, height: 96)) > 20)
        #expect(darkPixelCount(in: image, rect: CGRect(x: 156, y: 192, width: 72, height: 96)) > 20)
    }

    @Test("QR rotation preserves the element center")
    func qrRotationPreservesCenter() throws {
        let element = SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), rotation: 37)
        var rotated = EventConfig(canvasWidth: 80, canvasHeight: 80, qrCodeElements: [element])
        var unrotated = rotated
        unrotated.qrCodeElements[0].rotation = 0
        let frame = solidImage(width: 80, height: 80, color: Pixel(100, 100, 100, 255))
        let payload = "https://example.invalid/s/test/"
        let rotatedImage = try Compositor(config: rotated, framePNG: frame).render(images: [:], qrPayload: payload)
        let unrotatedImage = try Compositor(config: unrotated, framePNG: frame).render(images: [:], qrPayload: payload)

        let expectedCenter = try #require(pixel(atX: 40, y: 40, in: unrotatedImage))
        try expectPixel(atX: 40, y: 40, in: rotatedImage, equals: expectedCenter)
    }

    @Test("QR z-order controls overlap with photos")
    func qrZOrderControlsOverlap() throws {
        let qr = SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), zOrder: 1)
        let photo = SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), zOrder: 0, photoIndex: 0)
        let frame = solidImage(width: 100, height: 100, color: Pixel(100, 100, 100, 255))
        let red = solidImage(width: 8, height: 8, color: Pixel(255, 0, 0, 255))
        let above = try Compositor(config: EventConfig(canvasWidth: 100, canvasHeight: 100, slots: [photo], qrCodeElements: [qr]), framePNG: frame)
            .render(images: [0: red], qrPayload: "https://example.invalid/s/test/")
        try expectPixel(atX: 20, y: 20, in: above, equals: Pixel(255, 255, 255, 255))

        var belowQR = qr
        belowQR.zOrder = -1
        let below = try Compositor(config: EventConfig(canvasWidth: 100, canvasHeight: 100, slots: [photo], qrCodeElements: [belowQR]), framePNG: frame)
            .render(images: [0: red], qrPayload: "https://example.invalid/s/test/")
        try expectPixel(atX: 20, y: 20, in: below, equals: Pixel(255, 0, 0, 255))
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

private func solidImage(width: Int, height: Int, color: Pixel) -> CGImage {
    makeImage(width: width, height: height) { _, _ in (color.red, color.green, color.blue, color.alpha) }
}

private func darkPixelCount(in image: CGImage, rect: CGRect) -> Int {
    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            if let pixel = pixel(atX: x, y: y, in: image), pixel.red < 40, pixel.green < 40, pixel.blue < 40 {
                count += 1
            }
        }
    }
    return count
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
