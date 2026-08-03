#if DEBUG
import Foundation
import CoreGraphics
import CoreText

enum DemoImageFactory {
    static func image(width: Int = 1280, height: Int = 720, captureNumber: Int = 0, timestamp: Date = Date()) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scene = captureNumber % 4
        let palettes: [[CGColor]] = [
            [CGColor(red: 0.95, green: 0.33, blue: 0.25, alpha: 1), CGColor(red: 0.12, green: 0.25, blue: 0.70, alpha: 1)],
            [CGColor(red: 0.98, green: 0.68, blue: 0.25, alpha: 1), CGColor(red: 0.20, green: 0.65, blue: 0.32, alpha: 1)],
            [CGColor(red: 0.55, green: 0.20, blue: 0.70, alpha: 1), CGColor(red: 0.10, green: 0.70, blue: 0.75, alpha: 1)],
            [CGColor(red: 0.12, green: 0.12, blue: 0.18, alpha: 1), CGColor(red: 0.95, green: 0.35, blue: 0.55, alpha: 1)]
        ]
        let palette = palettes[scene]
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: palette as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.12))
        for index in 0..<8 {
            let size = CGFloat(70 + (index * 17) % 100)
            let xRange = max(1, width - Int(size))
            let yRange = max(1, height - Int(size))
            let x = CGFloat((index * 181 + captureNumber * 37) % xRange)
            let y = CGFloat((index * 83 + scene * 61) % yRange)
            context.fillEllipse(in: CGRect(x: x, y: y, width: size, height: size))
        }
        drawText("DEMO CAPTURE \(captureNumber + 1)", in: CGPoint(x: 42, y: 54), context: context, size: 34)
        drawText(Self.timestampFormatter.string(from: timestamp), in: CGPoint(x: 42, y: 96), context: context, size: 20)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.7))
        context.setLineWidth(3)
        context.stroke(bounds.insetBy(dx: 24, dy: 24))
        return context.makeImage()
    }

    static func gifFrames(for captureNumber: Int) -> [CGImage] {
        (0..<8).compactMap {
            image(captureNumber: captureNumber + $0, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double($0)))
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static func drawText(_ text: String, in point: CGPoint, context: CGContext, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil),
            .foregroundColor: CGColor(gray: 1, alpha: 0.9)
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }
}
#endif
