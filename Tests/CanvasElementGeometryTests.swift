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
