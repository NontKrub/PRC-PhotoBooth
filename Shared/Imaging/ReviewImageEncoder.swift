import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ReviewImageEncodingError: Error, Equatable {
    case unableToCreateImage
    case unableToEncode
    case payloadTooLarge(Int)
}

public enum ReviewImageEncoder {
    // Keep headroom for the JSON envelope and future control-message fields.
    public static let targetMessagePayloadLength = 1_700_000
    public static let targetLongestDimension = 1_600

    public static func encode(
        image: CGImage,
        context: SessionMessageContext,
        index: Int
    ) throws -> Data {
        let dimensions = [
            targetLongestDimension, 1_400, 1_200, 1_000, 800, 640
        ]
        let qualities: [Double] = [0.82, 0.72, 0.62, 0.52, 0.42]

        for dimension in dimensions {
            for quality in qualities {
                guard let jpeg = jpegData(image: image, longestDimension: dimension, quality: quality) else {
                    continue
                }
                let message = Message.shotCaptured(
                    context: context,
                    index: index,
                    thumbnailData: jpeg
                )
                guard let payload = try? message.encoded() else { continue }
                if payload.count <= targetMessagePayloadLength {
                    return jpeg
                }
            }
        }
        throw ReviewImageEncodingError.payloadTooLarge(image.width * image.height)
    }

    public static func thumbnailData(from data: Data, longestDimension: Int = 320) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return jpegData(image: image, longestDimension: longestDimension, quality: 0.65)
    }

    public static func pixelSize(of jpegData: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(jpegData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        return CGSize(width: width.intValue, height: height.intValue)
    }

    private static func jpegData(
        image: CGImage,
        longestDimension: Int,
        quality: Double
    ) -> Data? {
        let scale = min(1, CGFloat(longestDimension) / CGFloat(max(image.width, image.height)))
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaledImage = context.makeImage() else { return nil }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, scaledImage, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
