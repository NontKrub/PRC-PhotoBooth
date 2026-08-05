import CoreGraphics
import CoreImage
import Foundation

public enum QRCodeGenerator {
    public static func makeImage(
        payload: String,
        correctionLevel: String = "M",
        scale: Int = 8,
        quietZoneModules: Int = 0
    ) -> CGImage? {
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              scale > 0,
              quietZoneModules >= 0,
              let data = payload.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        filter.setValue(data, forKey: "inputMessage")
        filter.setValue(correctionLevel, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let baseImage = CIContext().createCGImage(output, from: output.extent) else { return nil }

        let quietZone = quietZoneModules * scale
        let width = baseImage.width * scale + quietZone * 2
        let height = baseImage.height * scale + quietZone * 2
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .none
        context.draw(
            baseImage,
            in: CGRect(x: quietZone, y: quietZone, width: baseImage.width * scale, height: baseImage.height * scale)
        )
        return context.makeImage()
    }
}
