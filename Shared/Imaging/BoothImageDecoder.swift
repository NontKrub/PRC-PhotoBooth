import CoreGraphics
import Foundation
import ImageIO

enum BoothImageDecoder {
    // Reject compressed images whose decoded bitmap would be an unsafe memory
    // commitment. Display callers should also provide a target pixel size.
    static let maximumDecodedPixelCount: Int64 = 32_000_000

    static func decode(_ data: Data, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0,
              height > 0,
              width <= maximumDecodedPixelCount,
              height <= maximumDecodedPixelCount,
              width <= maximumDecodedPixelCount / height else { return nil }

        if let maxPixelSize {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
