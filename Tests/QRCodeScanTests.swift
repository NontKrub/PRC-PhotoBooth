import CoreGraphics
import Testing
import Vision

@testable import PRC_PhotoBooth_Mac

@Suite("QR code scanning")
struct QRCodeScanTests {
    @Test("Vision decodes printed-size QR elements and a downscaled rotated strip")
    func scansRenderedQRCodes() throws {
        let payload = "https://example.invalid/s/vision-test/"
        let elements = [
            SharedQRCodeElement(id: "qr-1", normalizedRect: CGRect(x: 0.08, y: 0.1, width: 0.28, height: 0.28), rotation: 12),
            SharedQRCodeElement(id: "qr-2", normalizedRect: CGRect(x: 0.64, y: 0.62, width: 0.28, height: 0.28))
        ]
        let image = try Compositor(
            config: EventConfig(canvasWidth: 1200, canvasHeight: 1800, qrCodeElements: elements),
            framePNG: nil
        ).render(images: [:], qrPayload: payload)

        for element in elements {
            let crop = try #require(image.cropping(to: pixelRect(for: element.normalizedRect, width: image.width, height: image.height)))
            #expect(try scan(crop) == payload)
        }

        let downscaled = try #require(resized(image, width: 600, height: 900))
        for element in elements {
            let crop = try #require(downscaled.cropping(to: pixelRect(for: element.normalizedRect, width: downscaled.width, height: downscaled.height)))
            #expect(try scan(crop) == payload)
        }
    }

    private func scan(_ image: CGImage) throws -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.compactMap(\.payloadStringValue).first
    }

    private func pixelRect(for normalizedRect: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: normalizedRect.minX * CGFloat(width),
            y: normalizedRect.minY * CGFloat(height),
            width: normalizedRect.width * CGFloat(width),
            height: normalizedRect.height * CGFloat(height)
        )
    }

    private func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
