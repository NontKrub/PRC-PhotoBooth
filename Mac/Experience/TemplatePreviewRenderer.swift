import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TemplatePreviewRenderer {
    static let maxDimension = 640

    func render(template: EventTemplateDefinition, frame: CGImage?, foregroundOverlay: CGImage? = nil) throws -> CGImage {
        let config = EventConfig(
            photoCount: template.photoCount,
            canvasWidth: template.canvasWidth,
            canvasHeight: template.canvasHeight,
            slots: template.slots,
            qrCodeElements: template.qrCodeElements
        )
        let placeholders = Dictionary(uniqueKeysWithValues: (0..<template.photoCount).map { index in
            (index, placeholder(index: index))
        })
        let image = try Compositor(config: config, framePNG: frame, foregroundOverlayPNG: foregroundOverlay).render(
            images: placeholders,
            qrPayload: "https://example.invalid/s/preview/"
        )
        return try scaled(image)
    }

    func saveJPEG(_ image: CGImage, to url: URL, quality: CGFloat = 0.82) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let data = jpegData(from: image, quality: quality) else {
            throw TemplatePreviewError.encodingFailed
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: temporary, options: [.atomic])
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    private func placeholder(index: Int) -> CGImage {
        let size = 320
        let tones: [(CGFloat, CGFloat, CGFloat)] = [
            (0.94, 0.42, 0.35), (0.35, 0.62, 0.94), (0.38, 0.78, 0.48),
            (0.72, 0.45, 0.85), (0.92, 0.68, 0.25), (0.32, 0.78, 0.78),
            (0.70, 0.70, 0.72), (0.35, 0.35, 0.45)
        ]
        let tone = tones[index % tones.count]
        let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: tone.0, green: tone.1, blue: tone.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        context.setLineWidth(4)
        context.strokeEllipse(in: CGRect(x: 42, y: 42, width: 236, height: 236))

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 72, nil)
        let text = String(index + 1) as CFString
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text as String, attributes: [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(gray: 1, alpha: 0.9)]))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        context.textPosition = CGPoint(x: (CGFloat(size) - bounds.width) / 2 - bounds.minX, y: (CGFloat(size) - bounds.height) / 2 - bounds.minY)
        CTLineDraw(line, context)
        return context.makeImage()!
    }

    private func scaled(_ image: CGImage) throws -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > Self.maxDimension else { return image }
        let scale = CGFloat(Self.maxDimension) / CGFloat(longest)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw TemplatePreviewError.contextFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw TemplatePreviewError.contextFailed }
        return result
    }
}

enum TemplatePreviewError: LocalizedError, Equatable {
    case contextFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .contextFailed: return "Could not create template preview context."
        case .encodingFailed: return "Could not encode template preview."
        }
    }
}
