import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Print layout geometry")
struct PrintLayoutGeometryTests {
    private let printableBounds = CGRect(x: 10, y: 20, width: 400, height: 300)

    @Test("fit keeps the whole image inside the printable area")
    func fit() {
        let rect = PrintLayoutGeometry.destinationRect(
            imageSize: CGSize(width: 800, height: 400),
            printableBounds: printableBounds,
            mode: .fit
        )

        #expect(abs(rect.width - 400) < 0.001)
        #expect(abs(rect.height - 200) < 0.001)
        #expect(rect.midX == printableBounds.midX)
        #expect(rect.midY == printableBounds.midY)
    }

    @Test("fill covers the printable area and preserves aspect ratio")
    func fill() {
        let rect = PrintLayoutGeometry.destinationRect(
            imageSize: CGSize(width: 800, height: 400),
            printableBounds: printableBounds,
            mode: .fill
        )

        #expect(rect.width >= printableBounds.width)
        #expect(rect.height >= printableBounds.height)
        #expect(abs(rect.width / rect.height - 2) < 0.001)
        #expect(rect.midX == printableBounds.midX)
        #expect(rect.midY == printableBounds.midY)
    }

    @Test("portrait fit and fill handle a tall strip")
    func portraitTallStrip() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 700)
        let imageSize = CGSize(width: 600, height: 1200)
        let fit = PrintLayoutGeometry.destinationRect(
            imageSize: imageSize,
            printableBounds: bounds,
            mode: .fit
        )
        let fill = PrintLayoutGeometry.destinationRect(
            imageSize: imageSize,
            printableBounds: bounds,
            mode: .fill
        )

        #expect(fit.width <= bounds.width)
        #expect(fit.height <= bounds.height)
        #expect(fill.width >= bounds.width)
        #expect(fill.height >= bounds.height)
        #expect(abs(fit.width / fit.height - 0.5) < 0.001)
        #expect(abs(fill.width / fill.height - 0.5) < 0.001)
    }

    @Test("landscape fit and fill handle a wide image")
    func landscapeWideImage() {
        let bounds = CGRect(x: 24, y: 18, width: 700, height: 400)
        let imageSize = CGSize(width: 1600, height: 800)
        let fit = PrintLayoutGeometry.destinationRect(
            imageSize: imageSize,
            printableBounds: bounds,
            mode: .fit
        )
        let fill = PrintLayoutGeometry.destinationRect(
            imageSize: imageSize,
            printableBounds: bounds,
            mode: .fill
        )

        #expect(abs(fit.minX - 24) < 0.001)
        #expect(abs(fit.minY - 43) < 0.001)
        #expect(abs(fit.width - 700) < 0.001)
        #expect(abs(fit.height - 350) < 0.001)
        #expect(abs(fill.minX + 26) < 0.001)
        #expect(abs(fill.minY - 18) < 0.001)
        #expect(abs(fill.width - 800) < 0.001)
        #expect(abs(fill.height - 400) < 0.001)
        #expect(abs(fit.width / fit.height - 2) < 0.001)
        #expect(abs(fill.width / fill.height - 2) < 0.001)
    }

}
