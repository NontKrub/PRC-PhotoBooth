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

    @Test("actual size uses image points without enlarging")
    func actualSize() {
        let rect = PrintLayoutGeometry.destinationRect(
            imageSize: CGSize(width: 120, height: 80),
            printableBounds: printableBounds,
            mode: .actualSize
        )

        #expect(rect.size == CGSize(width: 120, height: 80))
        #expect(rect.midX == printableBounds.midX)
        #expect(rect.midY == printableBounds.midY)
    }
}
