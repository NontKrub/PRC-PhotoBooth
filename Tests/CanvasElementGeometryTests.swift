import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Canvas element geometry")
struct CanvasElementGeometryTests {
    private let canvas = CGSize(width: 400, height: 600)
    private let rect = CGRect(x: 100, y: 100, width: 100, height: 100)
    private let minimum = CGSize(width: 40, height: 40)

    @Test("moving clamps an element inside the canvas")
    func moveClampsToCanvas() {
        let result = CanvasElementGeometry.moved(CGRect(x: 340, y: 520, width: 60, height: 60), by: CGSize(width: 100, height: 100), in: canvas)
        #expect(result == CGRect(x: 340, y: 540, width: 60, height: 60))
    }

    @Test("each resize handle preserves its opposite edges")
    func resizeAnchorsOppositeEdges() {
        let cases: [(CanvasElementResizeHandle, CGSize, CGRect)] = [
            (.w, CGSize(width: 20, height: 0), CGRect(x: 120, y: 100, width: 80, height: 100)),
            (.e, CGSize(width: 20, height: 0), CGRect(x: 100, y: 100, width: 120, height: 100)),
            (.n, CGSize(width: 0, height: 20), CGRect(x: 100, y: 120, width: 100, height: 80)),
            (.s, CGSize(width: 0, height: 20), CGRect(x: 100, y: 100, width: 100, height: 120)),
            (.nw, CGSize(width: 20, height: 20), CGRect(x: 120, y: 120, width: 80, height: 80)),
            (.ne, CGSize(width: 20, height: 20), CGRect(x: 100, y: 120, width: 120, height: 80)),
            (.sw, CGSize(width: 20, height: 20), CGRect(x: 120, y: 100, width: 80, height: 120)),
            (.se, CGSize(width: 20, height: 20), CGRect(x: 100, y: 100, width: 120, height: 120))
        ]

        for (handle, delta, expected) in cases {
            #expect(CanvasElementGeometry.resized(rect, by: handle, delta: delta, minimumSize: minimum, in: canvas) == expected)
        }
    }

    @Test("resizing clamps the moved edge without moving its anchor")
    func resizeClampsMovedEdge() {
        let westMinimum = CanvasElementGeometry.resized(rect, by: .w, delta: CGSize(width: 200, height: 0), minimumSize: minimum, in: canvas)
        #expect(westMinimum == CGRect(x: 160, y: 100, width: 40, height: 100))

        let westBoundary = CanvasElementGeometry.resized(rect, by: .w, delta: CGSize(width: -200, height: 0), minimumSize: minimum, in: canvas)
        #expect(westBoundary == CGRect(x: 0, y: 100, width: 200, height: 100))

        let eastBoundary = CanvasElementGeometry.resized(rect, by: .e, delta: CGSize(width: 400, height: 0), minimumSize: minimum, in: canvas)
        #expect(eastBoundary == CGRect(x: 100, y: 100, width: 300, height: 100))

        let northMinimum = CanvasElementGeometry.resized(rect, by: .n, delta: CGSize(width: 0, height: 200), minimumSize: minimum, in: canvas)
        #expect(northMinimum == CGRect(x: 100, y: 160, width: 100, height: 40))

        let southBoundary = CanvasElementGeometry.resized(rect, by: .s, delta: CGSize(width: 0, height: 600), minimumSize: minimum, in: canvas)
        #expect(southBoundary == CGRect(x: 100, y: 100, width: 100, height: 500))
    }

    @Test("resizing rejects invalid input and clamps oversized minimums")
    func resizeHandlesInvalidInput() {
        #expect(CanvasElementGeometry.resized(rect, by: .se, delta: CGSize(width: CGFloat.nan, height: 0), minimumSize: minimum, in: canvas) == rect)
        #expect(CanvasElementGeometry.resized(rect, by: .se, delta: .zero, minimumSize: minimum, in: .zero) == rect)

        let result = CanvasElementGeometry.resized(
            CGRect(x: 0, y: 0, width: 20, height: 20),
            by: .se,
            delta: .zero,
            minimumSize: CGSize(width: 500, height: 700),
            in: canvas
        )
        #expect(result == CGRect(origin: .zero, size: canvas))
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

    @Test("normalized geometry round-trips and stays inside bounds")
    func normalizedGeometryRoundTripsAndClamps() {
        let original = CGRect(x: 100, y: 150, width: 200, height: 300)
        let normalized = CanvasElementGeometry.normalizedRect(original, in: canvas)
        #expect(CanvasElementGeometry.canvasRect(normalized, in: canvas) == original)

        let clamped = CanvasElementGeometry.normalizedAndClampedRect(
            CGRect(x: -20, y: 550, width: 100, height: 100),
            in: canvas
        )
        #expect(clamped == CGRect(x: 0, y: 550.0 / 600.0, width: 0.2, height: 50.0 / 600.0))
    }
}
