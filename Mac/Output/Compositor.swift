import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Composites the frame PNG over arranged photo stills to produce the final strip.
struct Compositor {
    let config: EventConfig
    let framePNG: CGImage?

    // images: [photoIndex → full-res CGImage]
    func render(images: [Int: CGImage]) throws -> CGImage {
        let w = Int(config.canvasWidth)
        let h = Int(config.canvasHeight)

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

        // Draw photos on top of frame so they replace any placeholder boxes in slot areas
        let slots = config.slots.sorted { $0.zOrder < $1.zOrder }
        for slot in slots {
            guard let image = images[slot.photoIndex] else { continue }
            let rect = slot.normalizedRect
            let destRect = CGRect(
                x: rect.minX * CGFloat(w),
                y: rect.minY * CGFloat(h),
                width: rect.width * CGFloat(w),
                height: rect.height * CGFloat(h)
            )
            drawAspectFill(ctx: ctx, image: image, in: destRect, rotation: slot.rotation)
        }

        guard let result = ctx.makeImage() else { throw CompositorError.renderFailed }
        return result
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
    case contextFailed, renderFailed, saveFailed
    var errorDescription: String? {
        switch self {
        case .contextFailed: return "Failed to create graphics context"
        case .renderFailed:  return "Failed to render composited image"
        case .saveFailed:    return "Failed to save output file"
        }
    }
}

// MARK: - PNG loader helper

func loadCGImage(from url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}
