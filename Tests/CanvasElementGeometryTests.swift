import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Canvas element geometry")
struct CanvasElementGeometryTests {
    private let canvas = CGSize(width: 400, height: 600)

    @Test("moving clamps an element inside the canvas")
    func moveClampsToCanvas() {
        let result = CanvasElementGeometry.moved(CGRect(x: 340, y: 520, width: 60, height: 60), by: CGSize(width: 100, height: 100), in: canvas)
        #expect(result == CGRect(x: 340, y: 540, width: 60, height: 60))
    }

    @Test("resizing keeps a positive minimum display size")
    func resizeEnforcesMinimumSize() {
        let result = CanvasElementGeometry.resized(
            CGRect(x: 100, y: 100, width: 100, height: 100),
            by: .nw,
            delta: CGSize(width: 300, height: 300),
            minimumSize: CGSize(width: 40, height: 40),
            in: canvas
        )
        #expect(result.width >= 40)
        #expect(result.height >= 40)
        #expect(result.minX >= 0)
        #expect(result.minY >= 0)
    }

    @Test("east resize follows every pixel without moving the anchored edge")
    func eastResizeIsContinuous() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)

        for delta in 1...20 {
            let result = CanvasElementGeometry.resized(
                base,
                by: .e,
                delta: CGSize(width: CGFloat(delta), height: 0),
                minimumSize: CGSize(width: 40, height: 40),
                in: canvas
            )

            #expect(result == CGRect(x: 100, y: 100, width: 100 + CGFloat(delta), height: 100))
        }
    }

    @Test("cardinal resize handles keep opposite edge fixed")
    func cardinalResizeKeepsOppositeEdgeFixed() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let minimumSize = CGSize(width: 40, height: 40)

        #expect(CanvasElementGeometry.resized(base, by: .e, delta: CGSize(width: 7, height: 0), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 100, width: 107, height: 100))
        #expect(CanvasElementGeometry.resized(base, by: .w, delta: CGSize(width: 7, height: 0), minimumSize: minimumSize, in: canvas) == CGRect(x: 107, y: 100, width: 93, height: 100))
        #expect(CanvasElementGeometry.resized(base, by: .n, delta: CGSize(width: 0, height: 9), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 109, width: 100, height: 91))
        #expect(CanvasElementGeometry.resized(base, by: .s, delta: CGSize(width: 0, height: 13), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 100, width: 100, height: 113))
    }

    @Test("corner resize handles keep both opposite edges fixed")
    func cornerResizeKeepsOppositeEdgesFixed() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let minimumSize = CGSize(width: 40, height: 40)

        #expect(CanvasElementGeometry.resized(base, by: .nw, delta: CGSize(width: 7, height: 9), minimumSize: minimumSize, in: canvas) == CGRect(x: 107, y: 109, width: 93, height: 91))
        #expect(CanvasElementGeometry.resized(base, by: .ne, delta: CGSize(width: 7, height: 9), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 109, width: 107, height: 91))
        #expect(CanvasElementGeometry.resized(base, by: .sw, delta: CGSize(width: 7, height: 13), minimumSize: minimumSize, in: canvas) == CGRect(x: 107, y: 100, width: 93, height: 113))
        #expect(CanvasElementGeometry.resized(base, by: .se, delta: CGSize(width: 7, height: 13), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 100, width: 107, height: 113))
    }

    @Test("east resize stops one pixel at a time at the canvas boundary")
    func eastResizeStopsAtCanvasBoundary() {
        let base = CGRect(x: 300, y: 100, width: 50, height: 100)

        for (delta, expectedMaxX) in zip(47...51, [397, 398, 399, 400, 400]) {
            let result = CanvasElementGeometry.resized(
                base,
                by: .e,
                delta: CGSize(width: CGFloat(delta), height: 0),
                minimumSize: CGSize(width: 40, height: 40),
                in: canvas
            )

            #expect(result == CGRect(x: 300, y: 100, width: CGFloat(expectedMaxX - 300), height: 100))
        }
    }

    @Test("resize stops one pixel at a time at minimum size")
    func resizeStopsAtMinimumSize() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let expectedWidths = [43, 42, 41, 40, 40]

        for (delta, expectedWidth) in zip([57, 58, 59, 60, 61], expectedWidths) {
            let result = CanvasElementGeometry.resized(
                base,
                by: .e,
                delta: CGSize(width: -CGFloat(delta), height: 0),
                minimumSize: CGSize(width: 40, height: 40),
                in: canvas
            )

            #expect(result.width == CGFloat(expectedWidth))
        }
    }

    @Test("duplicate offset is clamped at the bottom-right edge")
    func duplicateClampsAtEdge() {
        let result = CanvasElementGeometry.duplicated(CGRect(x: 330, y: 530, width: 60, height: 60), offset: CGSize(width: 30, height: 30), in: canvas)
        #expect(result == CGRect(x: 340, y: 540, width: 60, height: 60))
    }

    @Test("centered square uses the shorter dimension")
    func centeredSquare() {
        #expect(CanvasElementGeometry.centeredSquare(in: CGRect(x: 20, y: 40, width: 120, height: 80)) == CGRect(x: 40, y: 40, width: 80, height: 80))
    }
}
