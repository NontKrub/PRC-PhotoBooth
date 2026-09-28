import CoreGraphics
import Foundation

/// The template slot geometry used to frame a live capture preview.
///
/// This intentionally mirrors the compositor's unrotated destination rect.
/// Rotation is applied to the image inside that rect and does not change the
/// capture viewport's aspect ratio.
public struct CaptureFramingGeometry: Sendable, Equatable {
    public let photoIndex: Int
    public let slotID: String
    public let pixelSize: CGSize
    public let aspectRatio: CGFloat

    public static func framing(
        for photoIndex: Int,
        in config: EventConfig
    ) -> CaptureFramingGeometry? {
        guard config.canvasWidth.isFinite,
              config.canvasHeight.isFinite,
              config.canvasWidth > 0,
              config.canvasHeight > 0 else {
            return nil
        }

        let framings = config.slots
            .filter { $0.photoIndex == photoIndex }
            .sorted { lhs, rhs in
                if lhs.zOrder == rhs.zOrder { return lhs.id < rhs.id }
                return lhs.zOrder < rhs.zOrder
            }
            .compactMap { slot in
                makeGeometry(for: slot, photoIndex: photoIndex, in: config)
            }

        guard let primary = framings.first else { return nil }

#if DEBUG
        if let conflicting = framings.dropFirst().first(where: {
            abs($0.aspectRatio - primary.aspectRatio) > 0.001
        }) {
            NSLog(
                "[CaptureFraming] photoIndex=%d has conflicting destination ratios: primary=%g secondary=%g",
                photoIndex,
                Double(primary.aspectRatio),
                Double(conflicting.aspectRatio)
            )
        }
#endif

        return primary
    }

    private static func makeGeometry(
        for slot: SharedPhotoSlot,
        photoIndex: Int,
        in config: EventConfig
    ) -> CaptureFramingGeometry? {
        let rect = slot.normalizedRect
        guard rect.origin.x.isFinite,
              rect.origin.y.isFinite,
              rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return nil
        }

        let pixelSize = CGSize(
            width: rect.width * config.canvasWidth,
            height: rect.height * config.canvasHeight
        )
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width > 0,
              pixelSize.height > 0 else {
            return nil
        }

        let aspectRatio = pixelSize.width / pixelSize.height
        guard aspectRatio.isFinite, aspectRatio > 0 else { return nil }

        return CaptureFramingGeometry(
            photoIndex: photoIndex,
            slotID: slot.id,
            pixelSize: pixelSize,
            aspectRatio: aspectRatio
        )
    }
}
