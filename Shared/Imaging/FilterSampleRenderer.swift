import CoreGraphics

public enum FilterSampleRenderer {
    public static func makeSampleImage(size: Int = 256) -> CGImage? {
        guard size > 0,
              let context = CGContext(
                  data: nil,
                  width: size,
                  height: size,
                  bitsPerComponent: 8,
                  bytesPerRow: size * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let colors = [
            CGColor(red: 0.96, green: 0.62, blue: 0.48, alpha: 1),
            CGColor(red: 0.15, green: 0.42, blue: 0.86, alpha: 1),
            CGColor(red: 0.25, green: 0.78, blue: 0.36, alpha: 1),
            CGColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1)
        ]
        let rects = [
            CGRect(x: 0, y: size / 2, width: size / 2, height: size / 2),
            CGRect(x: size / 2, y: size / 2, width: size / 2, height: size / 2),
            CGRect(x: 0, y: 0, width: size / 2, height: size / 2),
            CGRect(x: size / 2, y: 0, width: size / 2, height: size / 2)
        ]
        for (rect, color) in zip(rects, colors) {
            context.setFillColor(color)
            context.fill(rect)
        }

        context.setStrokeColor(CGColor(gray: 1, alpha: 0.8))
        context.setLineWidth(2)
        for step in stride(from: 0, through: size, by: max(8, size / 16)) {
            context.move(to: CGPoint(x: step, y: 0))
            context.addLine(to: CGPoint(x: step, y: size))
            context.move(to: CGPoint(x: 0, y: step))
            context.addLine(to: CGPoint(x: size, y: step))
        }
        context.strokePath()

        context.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
        context.setLineWidth(4)
        context.strokeEllipse(in: bounds.insetBy(dx: CGFloat(size) * 0.18, dy: CGFloat(size) * 0.18))
        return context.makeImage()
    }
}
