import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Keeps preview, strip, and GIF layout rules in one renderer.
struct Compositor {
    let config: EventConfig
    let framePNG: CGImage?
    let foregroundOverlayPNG: CGImage?

    init(config: EventConfig, framePNG: CGImage?, foregroundOverlayPNG: CGImage? = nil) {
        self.config = config
        self.framePNG = framePNG
        self.foregroundOverlayPNG = foregroundOverlayPNG
    }

    private enum RenderElement {
        case photo(SharedPhotoSlot)
        case qrCode(SharedQRCodeElement)

        var zOrder: Int {
            switch self {
            case .photo(let slot): return slot.zOrder
            case .qrCode(let element): return element.zOrder
            }
        }

        var stableID: String {
            switch self {
            case .photo(let slot): return "photo:\(slot.id)"
            case .qrCode(let element): return "qr:\(element.id)"
            }
        }
    }

    // images: [photoIndex → source CGImage].  A foreground opts into the new,
    // safe ordering; no foreground preserves legacy photo/QR z-order exactly.
    func render(
        images: [Int: CGImage],
        qrPayload: String? = nil,
        qrImage: CGImage? = nil,
        maxDimension: Int? = nil
    ) throws -> CGImage {
        let scale = maxDimension.map {
            min(CGFloat(1), CGFloat($0) / max(CGFloat(config.canvasWidth), CGFloat(config.canvasHeight)))
        } ?? 1
        let w = max(1, Int((config.canvasWidth * Double(scale)).rounded()))
        let h = max(1, Int((config.canvasHeight * Double(scale)).rounded()))
        let qrImage = try qrImage ?? makeQRCode(payload: qrPayload)

        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CompositorError.contextFailed }

        // Match SwiftUI/AppKit's top-left canvas used by the slot editor.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)

        // White background
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: CGSize(width: w, height: h)))

        // Draw frame first (may contain opaque placeholder boxes)
        if let frame = framePNG {
            drawImageUpright(ctx: ctx, image: frame, in: CGRect(origin: .zero, size: CGSize(width: w, height: h)))
        }

        if foregroundOverlayPNG != nil {
            // Overlay-enabled templates intentionally place all QR codes last.
            for slot in config.slots.sorted(by: { Self.renderElementSort(.photo($0), .photo($1)) }) {
                guard let image = images[slot.photoIndex] else { continue }
                drawAspectFill(ctx: ctx, image: image, in: canvasRect(for: slot.normalizedRect, width: w, height: h), rotation: slot.rotation)
            }
            if let foregroundOverlayPNG {
                drawImageUpright(ctx: ctx, image: foregroundOverlayPNG, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
            for qrCode in config.qrCodeElements.sorted(by: { Self.renderElementSort(.qrCode($0), .qrCode($1)) }) {
                guard let qrImage else { continue }
                drawQRCode(ctx: ctx, image: qrImage, in: canvasRect(for: qrCode.normalizedRect, width: w, height: h), rotation: qrCode.rotation)
            }
        } else {
            let elements = config.slots.map(RenderElement.photo) + config.qrCodeElements.map(RenderElement.qrCode)
            for element in elements.sorted(by: Self.renderElementSort) {
            switch element {
            case .photo(let slot):
                guard let image = images[slot.photoIndex] else { continue }
                drawAspectFill(ctx: ctx, image: image, in: canvasRect(for: slot.normalizedRect, width: w, height: h), rotation: slot.rotation)
            case .qrCode(let qrCode):
                guard let qrImage else { continue }
                drawQRCode(ctx: ctx, image: qrImage, in: canvasRect(for: qrCode.normalizedRect, width: w, height: h), rotation: qrCode.rotation)
            }
            }
        }

        guard let result = ctx.makeImage() else { throw CompositorError.renderFailed }
        return result
    }

    func makeQRCode(payload: String?) throws -> CGImage? {
        guard !config.qrCodeElements.isEmpty else { return nil }
        guard let payload, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CompositorError.missingQRCodePayload
        }
        guard let image = QRCodeGenerator.makeImage(
            payload: payload,
            correctionLevel: "M",
            scale: 8,
            quietZoneModules: 4
        ) else { throw CompositorError.renderFailed }
        return image
    }

    private static func renderElementSort(_ lhs: RenderElement, _ rhs: RenderElement) -> Bool {
        if lhs.zOrder == rhs.zOrder { return lhs.stableID < rhs.stableID }
        return lhs.zOrder < rhs.zOrder
    }

    private func canvasRect(for normalizedRect: CGRect, width: Int, height: Int) -> CGRect {
        CGRect(
            x: normalizedRect.minX * CGFloat(width),
            y: normalizedRect.minY * CGFloat(height),
            width: normalizedRect.width * CGFloat(width),
            height: normalizedRect.height * CGFloat(height)
        )
    }

    private func drawAspectFill(ctx: CGContext, image: CGImage, in rect: CGRect, rotation: Double) {
        ctx.saveGState()
        ctx.clip(to: rect)

        // Scale image to fill rect (aspect fill)
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)
        let scaleX = rect.width / imgW
        let scaleY = rect.height / imgH
        let scale = max(scaleX, scaleY)
        let drawW = imgW * scale
        let drawH = imgH * scale
        let drawX = rect.midX - drawW / 2
        let drawY = rect.midY - drawH / 2

        if rotation != 0 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -rotation * .pi / 180)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        drawImageUpright(ctx: ctx, image: image, in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
        ctx.restoreGState()
    }

    private func drawQRCode(ctx: CGContext, image: CGImage, in rect: CGRect, rotation: Double) {
        let side = min(rect.width, rect.height)
        let square = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )

        ctx.saveGState()
        ctx.clip(to: rect)
        if rotation != 0 {
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -rotation * .pi / 180)
            ctx.translateBy(x: -rect.midX, y: -rect.midY)
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(square)
        ctx.interpolationQuality = .none
        drawImageUpright(ctx: ctx, image: image, in: square)
        ctx.restoreGState()
    }

    private func drawImageUpright(ctx: CGContext, image: CGImage, in rect: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // Write the composited image to disk as PNG.
    func savePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw CompositorError.saveFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CompositorError.saveFailed }
    }
}

enum CompositorError: LocalizedError {
    case contextFailed, renderFailed, saveFailed, missingQRCodePayload
    var errorDescription: String? {
        switch self {
        case .contextFailed: return "Failed to create graphics context"
        case .renderFailed:  return "Failed to render composited image"
        case .saveFailed:    return "Failed to save output file"
        case .missingQRCodePayload: return "A QR code payload is required for this layout"
        }
    }
}

// MARK: - PNG loader helper

func loadCGImage(from url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
