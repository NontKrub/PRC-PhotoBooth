import Testing
import Foundation
import CoreGraphics
import Compression
import ImageIO
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

    @Test("live strip previews stay bounded for square, portrait, and landscape canvases")
    func largeLiveStripPreviewsAreBounded() throws {
        let cases: [(width: Int, height: Int, outputWidth: Int, outputHeight: Int)] = [
            (10_000, 10_000, 2_048, 2_048),
            (300, 10_000, 61, 2_048),
            (10_000, 300, 2_048, 61)
        ]

        for item in cases {
            let config = EventConfig(
                photoCount: 1,
                canvasWidth: CGFloat(item.width),
                canvasHeight: CGFloat(item.height),
                slots: []
            )
            let preview = try Compositor(config: config, framePNG: nil).render(
                images: [:],
                maxDimension: 2_048
            )
            #expect(preview.width == item.outputWidth)
            #expect(preview.height == item.outputHeight)
            #expect(max(preview.width, preview.height) <= 2_048)

            let jpeg = try #require(jpegData(from: preview, quality: 0.82))
            let decoded = try #require(BoothImageDecoder.decode(jpeg))
            #expect(decoded.width == preview.width)
            #expect(decoded.height == preview.height)
        }
    }

    @Test("finished strip thumbnails downsample a full-size 10,000 pixel PNG")
    func finishedStripThumbnailIsBounded() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("strip-thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stripURL = root.appendingPathComponent("strip.png")
        try makeLargeWhitePNG(width: 10_000, height: 10_000).write(to: stripURL)
        let source = try #require(CGImageSourceCreateWithURL(stripURL as CFURL, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 10_000)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 10_000)

        let thumbnail = try #require(loadOrientedImageThumbnail(from: stripURL, maxDimension: 2_048))
        #expect(max(thumbnail.width, thumbnail.height) <= 2_048)
        let jpeg = try #require(jpegData(from: thumbnail, quality: 0.82))
        let ipadImage = try #require(BoothImageDecoder.decode(jpeg))
        #expect(ipadImage.width == thumbnail.width)
        #expect(ipadImage.height == thumbnail.height)
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
        let rotated = EventConfig(canvasWidth: 80, canvasHeight: 80, qrCodeElements: [element])
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

    @Test("foreground alpha overlays photos while transparent pixels reveal them")
    func foregroundOverlayCompositesAbovePhotos() throws {
        let config = EventConfig(canvasWidth: 2, canvasHeight: 1, slots: [
            SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)
        ])
        let photo = solidImage(width: 2, height: 1, color: Pixel(255, 0, 0, 255))
        let overlay = makeImage(width: 2, height: 1) { x, _ in
            x == 0 ? (0, 0, 255, 255) : (0, 0, 0, 0)
        }
        let result = try Compositor(config: config, framePNG: nil, foregroundOverlayPNG: overlay).render(images: [0: photo])
        try expectPixel(atX: 0, y: 0, in: result, equals: Pixel(0, 0, 255, 255))
        try expectPixel(atX: 1, y: 0, in: result, equals: Pixel(255, 0, 0, 255))
    }

    @Test("bounded rendering matches an equivalent preview canvas with frame, overlay and QR")
    func boundedCompositionMatchesEquivalentPreviewCanvas() throws {
        let config = EventConfig(
            canvasWidth: 160,
            canvasHeight: 200,
            slots: [SharedPhotoSlot(
                normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
                photoIndex: 0
            )],
            qrCodeElements: [SharedQRCodeElement(
                id: "qr-1",
                normalizedRect: CGRect(x: 0.65, y: 0.55, width: 0.3, height: 0.3)
            )]
        )
        let frame = solidImage(width: 8, height: 10, color: Pixel(240, 210, 20, 255))
        let overlay = makeImage(width: 160, height: 200) { x, y in
            x < 40 && y < 40 ? (20, 40, 240, 255) : (0, 0, 0, 0)
        }
        let photo = solidImage(width: 12, height: 12, color: Pixel(240, 30, 20, 255))
        let compositor = Compositor(config: config, framePNG: frame, foregroundOverlayPNG: overlay)
        let payload = "https://example.invalid/s/preview-parity/"
        let full = try compositor.render(images: [0: photo], qrPayload: payload)
        let bounded = try compositor.render(images: [0: photo], qrPayload: payload, maxDimension: 100)
        let equivalentPreview = try Compositor(
            config: EventConfig(
                canvasWidth: 80,
                canvasHeight: 100,
                slots: config.slots,
                qrCodeElements: config.qrCodeElements
            ),
            framePNG: frame,
            foregroundOverlayPNG: makeImage(width: 80, height: 100) { x, y in
                x < 20 && y < 20 ? (20, 40, 240, 255) : (0, 0, 0, 0)
            }
        ).render(images: [0: photo], qrPayload: payload)

        #expect(full.width == 160)
        #expect(full.height == 200)
        #expect(bounded.width == 80)
        #expect(bounded.height == 100)
        let equivalentPixels = try #require(rgbaPixels(equivalentPreview))
        let boundedPixels = try #require(rgbaPixels(bounded))
        #expect(equivalentPixels == boundedPixels)
        try expectPixel(atX: 10, y: 10, in: bounded, equals: Pixel(20, 40, 240, 255))
        try expectPixel(atX: 30, y: 30, in: bounded, equals: Pixel(240, 30, 20, 255))
        try expectPixel(atX: 70, y: 10, in: bounded, equals: Pixel(240, 210, 20, 255))
        #expect(darkPixelCount(in: bounded, rect: CGRect(x: 52, y: 55, width: 24, height: 30)) > 0)
    }

    @Test("low-level rendering accepts small canvases and preserves their dimensions")
    func lowLevelRenderAcceptsSmallCanvases() throws {
        let image = try Compositor(
            config: EventConfig(canvasWidth: 4, canvasHeight: 3),
            framePNG: nil
        ).render(images: [:])

        #expect(image.width == 4)
        #expect(image.height == 3)
    }

    @Test("rejects malformed or unrepresentable low-level dimensions before rendering")
    func rejectsMalformedCanvasDimensions() {
        let malformedDimensions: [CGFloat] = [
            0,
            -1,
            .nan,
            .infinity,
            -.infinity,
            .greatestFiniteMagnitude,
            1e20,
            10_000.001
        ]

        for dimension in malformedDimensions {
            let invalidWidth = EventConfig(canvasWidth: dimension, canvasHeight: 100)
            #expect(throws: CompositorError.invalidCanvasDimensions) {
                try Compositor(config: invalidWidth, framePNG: nil).render(images: [:])
            }

            let invalidHeight = EventConfig(canvasWidth: 100, canvasHeight: dimension)
            #expect(throws: CompositorError.invalidCanvasDimensions) {
                try Compositor(config: invalidHeight, framePNG: nil).render(images: [:])
            }
        }
    }

    @Test("rejects invalid output bounds before allocating a context")
    func rejectsInvalidMaximumDimension() {
        for maximum in [0, -1, CanvasDimensionPolicy.maximumRenderDimension + 1] {
            #expect(throws: CompositorError.invalidMaximumDimension) {
                try Compositor(config: EventConfig(canvasWidth: 80, canvasHeight: 100), framePNG: nil)
                    .render(images: [:], maxDimension: maximum)
            }
        }
    }
}

private func makeLargeWhitePNG(width: Int, height: Int) throws -> Data {
    let rowByteCount = (width + 7) / 8
    var scanlines = Data(count: height * (rowByteCount + 1))
    scanlines.withUnsafeMutableBytes { rawBytes in
        guard let bytes = rawBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for row in 0..<height {
            let offset = row * (rowByteCount + 1)
            bytes[offset] = 0 // PNG filter: None
            bytes.advanced(by: offset + 1).update(repeating: 0xFF, count: rowByteCount)
        }
    }

    var compressed = Data(count: scanlines.count + 1_024)
    let compressedCapacity = compressed.count
    let compressedCount = compressed.withUnsafeMutableBytes { compressedBytes in
        scanlines.withUnsafeBytes { sourceBytes in
            guard let destination = compressedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                  let source = sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(
                destination,
                compressedCapacity,
                source,
                scanlines.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    guard compressedCount > 0 else { throw CompositorError.renderFailed }
    compressed.removeSubrange(compressedCount..<compressed.count)
    var zlibStream = Data([0x78, 0x9C])
    zlibStream.append(compressed)
    zlibStream.appendBigEndian(adler32(scanlines))

    var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
    var header = Data()
    header.appendBigEndian(UInt32(width))
    header.appendBigEndian(UInt32(height))
    header.append(contentsOf: [1, 0, 0, 0, 0]) // 1-bit grayscale, no interlace
    png.appendPNGChunk(type: "IHDR", payload: header)
    png.appendPNGChunk(type: "IDAT", payload: zlibStream)
    png.appendPNGChunk(type: "IEND", payload: Data())
    return png
}

private func adler32(_ data: Data) -> UInt32 {
    var first: UInt32 = 1
    var second: UInt32 = 0
    for byte in data {
        first = (first + UInt32(byte)) % 65_521
        second = (second + first) % 65_521
    }
    return (second << 16) | first
}

private extension Data {
    mutating func appendBigEndian(_ value: UInt32) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }

    mutating func appendPNGChunk(type: String, payload: Data) {
        appendBigEndian(UInt32(payload.count))
        let typeData = Data(type.utf8)
        append(typeData)
        append(payload)
        appendBigEndian(pngCRC32(typeData + payload))
    }
}

private func pngCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
    }
    return crc ^ 0xFFFF_FFFF
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

private func rgbaPixels(_ image: CGImage) -> [UInt8]? {
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
    return data
}
