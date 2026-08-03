import CoreImage
import CoreGraphics
import Foundation

public enum PhotoFilterError: LocalizedError, Sendable {
    case unsupportedFilter(PhotoFilterID)
    case failedToCreateOutput(PhotoFilterID)
    case invalidInput

    public var errorDescription: String? {
        switch self {
        case .unsupportedFilter(let filter): return "Unsupported photo filter: \(filter.rawValue)."
        case .failedToCreateOutput(let filter): return "Could not render photo filter: \(filter.rawValue)."
        case .invalidInput: return "Photo filter input is invalid."
        }
    }
}

public actor PhotoFilterPipeline {
    private let context: CIContext

    public init() {
        context = CIContext(options: nil)
    }

    public func apply(_ filter: PhotoFilterID, to image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0 else { throw PhotoFilterError.invalidInput }
        guard filter != .original else { return image }

        let input = CIImage(cgImage: image)
        guard let output = makeOutput(filter, input: input) else {
            throw PhotoFilterError.unsupportedFilter(filter)
        }
        let extent = input.extent
        guard let result = context.createCGImage(output.cropped(to: extent), from: extent) else {
            throw PhotoFilterError.failedToCreateOutput(filter)
        }
        return result
    }

    public func apply(_ filter: PhotoFilterID, to images: [CGImage]) throws -> [CGImage] {
        try images.map { try apply(filter, to: $0) }
    }

    public func validate(_ filter: PhotoFilterID) -> Bool {
        guard let sample = Self.sampleImage() else { return false }
        return (try? apply(filter, to: sample)) != nil
    }

    private func makeOutput(_ filter: PhotoFilterID, input: CIImage) -> CIImage? {
        switch filter {
        case .original:
            return input
        case .monochrome:
            return output(of: "CIPhotoEffectMono", input: input)
        case .warm:
            guard let balanced = temperature(input, target: 5_200) else { return nil }
            return colorControls(balanced, saturation: 1.05, contrast: 1)
        case .cool:
            guard let balanced = temperature(input, target: 7_800) else { return nil }
            return colorControls(balanced, saturation: 0.98, contrast: 1)
        case .highContrast:
            return colorControls(input, saturation: 1.05, contrast: 1.22)
        case .soft:
            guard let filter = CIFilter(name: "CIHighlightShadowAdjust") else { return nil }
            filter.setValue(input, forKey: kCIInputImageKey)
            filter.setValue(0.25, forKey: "inputShadowAmount")
            filter.setValue(0.82, forKey: "inputHighlightAmount")
            guard let adjusted = filter.outputImage else { return nil }
            return colorControls(adjusted, saturation: 0.96, contrast: 0.92)
        case .vintage:
            return output(of: "CIPhotoEffectProcess", input: input)
        }
    }

    private func output(of name: String, input: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    private func temperature(_ input: CIImage, target: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CITemperatureAndTint") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 6_500, y: 0), forKey: "inputNeutral")
        filter.setValue(CIVector(x: target, y: 0), forKey: "inputTargetNeutral")
        return filter.outputImage
    }

    private func colorControls(_ input: CIImage, saturation: CGFloat, contrast: CGFloat) -> CIImage? {
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(saturation, forKey: kCIInputSaturationKey)
        filter.setValue(contrast, forKey: kCIInputContrastKey)
        filter.setValue(0, forKey: kCIInputBrightnessKey)
        return filter.outputImage
    }

    private static func sampleImage() -> CGImage? {
        let size = 16
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.8, green: 0.35, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size / 2, height: size))
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: size / 2, y: 0, width: size / 2, height: size))
        return context.makeImage()
    }
}
