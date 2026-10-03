import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PRC_PhotoBooth_Mac

@Suite("Template preview safety")
struct TemplatePreviewSafetyTests {
    @Test("a 10,000 by 10,000 template preview is allocated at the preview bound")
    func largeSquarePreviewIsBounded() throws {
        let template = makeTemplate(width: 10_000, height: 10_000)
        let image = try TemplatePreviewRenderer().render(template: template, frame: nil)

        #expect(image.width == TemplatePreviewRenderer.maxDimension)
        #expect(image.height == TemplatePreviewRenderer.maxDimension)
    }

    @Test("bounded previews preserve non-square aspect ratio and valid document boundaries")
    func nonSquareAndBoundaryPreviews() throws {
        let renderer = TemplatePreviewRenderer()
        let minimum = try renderer.render(template: makeTemplate(width: 300, height: 300), frame: nil)
        let portrait = try renderer.render(template: makeTemplate(width: 300, height: 10_000), frame: nil)
        let landscape = try renderer.render(template: makeTemplate(width: 10_000, height: 300), frame: nil)

        #expect(minimum.width == 300)
        #expect(minimum.height == 300)
        #expect(portrait.width == 19)
        #expect(portrait.height == TemplatePreviewRenderer.maxDimension)
        #expect(landscape.width == TemplatePreviewRenderer.maxDimension)
        #expect(landscape.height == 19)
        #expect(CanvasDimensionPolicy.isValidDocument(width: 300, height: 10_000))
        #expect(CanvasDimensionPolicy.isValidDocument(width: 10_000, height: 300))
    }

    @Test("document previews reject malformed and out-of-range dimensions")
    func documentPreviewRejectsMalformedDimensions() {
        let invalidDimensions: [Double] = [
            0,
            -1,
            .nan,
            .infinity,
            -.infinity,
            .greatestFiniteMagnitude,
            1e20,
            299.999,
            10_000.001
        ]

        for dimension in invalidDimensions {
            #expect(throws: TemplatePreviewError.invalidCanvasDimensions) {
                try TemplatePreviewRenderer().render(
                    template: makeTemplate(width: dimension, height: 300),
                    frame: nil
                )
            }
            #expect(throws: TemplatePreviewError.invalidCanvasDimensions) {
                try TemplatePreviewRenderer().render(
                    template: makeTemplate(width: 300, height: dimension),
                    frame: nil
                )
            }
        }
    }

    @Test("canvas validation explains the accepted range in English and Thai")
    func canvasValidationMessageIsLocalized() {
        #expect(
            operatorTemplateCanvasDimensionsMessage(locale: Locale(identifier: "en"))
                == "Canvas width and height must each be between 300 and 10,000 pixels."
        )
        #expect(
            operatorTemplateCanvasDimensionsMessage(locale: Locale(identifier: "th"))
                == "ความกว้างและความสูงของผืนงานต้องอยู่ระหว่าง 300 ถึง 10,000 พิกเซล"
        )
    }

    @Test("an unsaved editing preview composes imported frame, transparent foreground and QR assets")
    func unsavedPreviewUsesImportedAssetsAndPreservesLastValidImage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let eventID = "preview-safety-\(UUID().uuidString)"
        let store = EventExperienceStore(baseDirectory: root)
        let slot = SharedPhotoSlot(
            normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5),
            photoIndex: 0
        )
        let document = try await store.ensureDocument(for: BoothEventSnapshot(
            id: eventID,
            name: "Preview safety",
            photoCount: 1,
            countdownSeconds: 3,
            canvasWidth: 300,
            canvasHeight: 300,
            framePNGURL: nil,
            slots: [slot]
        ))
        let session = try await store.beginEditing(eventID: eventID)
        var template = try #require(document.templates.first)
        template.qrCodeElements = [SharedQRCodeElement(
            id: "preview-qr",
            normalizedRect: CGRect(x: 0.65, y: 0.65, width: 0.25, height: 0.25)
        )]

        let frameURL = root.appendingPathComponent("imported-frame.png")
        try writePNG(solidImage(width: 16, height: 16, red: 240, green: 210, blue: 20, alpha: 255), to: frameURL)
        let frame = try await store.importTemplateFrame(
            eventID: eventID,
            templateID: template.id,
            sourceURL: frameURL,
            editingSession: session
        )
        template.frameFileName = frame.fileName

        let overlayURL = root.appendingPathComponent("imported-overlay.png")
        let overlay = makeImage(width: 300, height: 300) { x, y in
            x < 100 && y < 100 ? (20, 40, 240, 255) : (0, 0, 0, 0)
        }
        try writePNG(overlay, to: overlayURL)
        let foreground = try await store.importTemplateForegroundOverlay(
            eventID: eventID,
            templateID: template.id,
            sourceURL: overlayURL,
            editingSession: session
        )
        template.foregroundOverlayFileName = foreground.fileName

        let renderedPreviews = try await store.readTemplatePreviews(
            eventID: eventID,
            templates: [template],
            editingSession: session
        )
        let renderedData = try #require(renderedPreviews[template.id])
        let renderedImage = try #require(image(from: renderedData))
        #expect(max(renderedImage.width, renderedImage.height) <= TemplatePreviewRenderer.maxDimension)

        let overlayPixel = try #require(pixel(atX: 40, y: 40, in: renderedImage))
        #expect(Int(overlayPixel.blue) > Int(overlayPixel.red) + 70)
        #expect(Int(overlayPixel.blue) > Int(overlayPixel.green) + 50)

        let placeholderPixel = try #require(pixel(atX: 140, y: 40, in: renderedImage))
        #expect(Int(placeholderPixel.red) > Int(placeholderPixel.green) + 30)

        let framePixel = try #require(pixel(atX: 40, y: 250, in: renderedImage))
        #expect(framePixel.red > 170)
        #expect(framePixel.green > 150)
        #expect(framePixel.blue < 100)
        #expect(darkPixelCount(in: renderedImage, rect: CGRect(x: 195, y: 195, width: 75, height: 75)) > 20)

        template.canvasWidth = Double.greatestFiniteMagnitude
        let invalidDraftPreviews = try await store.readTemplatePreviews(
            eventID: eventID,
            templates: [template],
            editingSession: session
        )
        let preservedData = try #require(invalidDraftPreviews[template.id])
        #expect(preservedData == renderedData)

        let persisted = try await store.load(eventID: eventID)
        #expect(persisted.templates.first?.canvasWidth == 300)

        var invalidDocument = document
        invalidDocument.templates[0].canvasWidth = .greatestFiniteMagnitude
        await #expect(throws: EventExperienceError.invalid(
            "Template canvas width and height must each be between 300 and 10,000 pixels."
        )) {
            try await store.commitEditing(session, document: invalidDocument)
        }
        let stillPersisted = try await store.load(eventID: eventID)
        #expect(stillPersisted.templates.first?.canvasWidth == 300)
        try await store.discardEditing(session)
    }

    @Test("bounded frame thumbnails preserve EXIF orientation for preview and output loading")
    func orientedFrameThumbnailMatchesOutputAssetOrientation() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("oriented-frame.jpg")
        let sourceImage = makeImage(width: 2_048, height: 1_024) { x, y in
            x < 1_024 ? (240, 30, 20, 255) : (20, 40, 240, 255)
        }
        try writeJPEG(sourceImage, orientation: 6, to: sourceURL)

        let previewFrame = try #require(loadOrientedImageThumbnail(from: sourceURL, maxDimension: 640))
        let outputFrame = try #require(loadOrientedImageThumbnail(from: sourceURL, maxDimension: 1_200))
        let rawFrame = try #require(loadCGImage(from: sourceURL))

        #expect(previewFrame.width == 320)
        #expect(previewFrame.height == 640)
        #expect(outputFrame.width == 600)
        #expect(outputFrame.height == 1_200)
        #expect(rawFrame.width == 2_048)
        #expect(rawFrame.height == 1_024)
        #expect(max(previewFrame.width, previewFrame.height) <= 640)
    }
}

private func makeTemplate(width: Double, height: Double) -> EventTemplateDefinition {
    EventTemplateDefinition(
        name: LocalizedText(english: "Preview", thai: "ตัวอย่าง"),
        photoCount: 1,
        canvasWidth: width,
        canvasHeight: height,
        slots: [SharedPhotoSlot(
            normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            photoIndex: 0
        )]
    )
}

private func temporaryDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
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
            let color = pixel(x, y)
            data[offset] = color.0
            data[offset + 1] = color.1
            data[offset + 2] = color.2
            data[offset + 3] = color.3
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

private func solidImage(width: Int, height: Int, red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) -> CGImage {
    makeImage(width: width, height: height) { _, _ in (red, green, blue, alpha) }
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw TemplatePreviewError.encodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TemplatePreviewError.encodingFailed }
}

private func writeJPEG(_ image: CGImage, orientation: Int, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw TemplatePreviewError.encodingFailed
    }
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImagePropertyOrientation as String: orientation] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { throw TemplatePreviewError.encodingFailed }
}

private func image(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

private struct PreviewPixel {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

private func pixel(atX x: Int, y: Int, in image: CGImage) -> PreviewPixel? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &data,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let offset = (y * image.width + x) * 4
    return PreviewPixel(red: data[offset], green: data[offset + 1], blue: data[offset + 2])
}

private func darkPixelCount(in image: CGImage, rect: CGRect) -> Int {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &data,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

    var count = 0
    for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
            let offset = (y * image.width + x) * 4
            if data[offset] < 40 && data[offset + 1] < 40 && data[offset + 2] < 40 {
                count += 1
            }
        }
    }
    return count
}
