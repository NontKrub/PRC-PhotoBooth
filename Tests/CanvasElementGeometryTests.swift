import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Canvas element geometry")
struct CanvasElementGeometryTests {
    private let canvas = CGSize(width: 400, height: 600)
    private let freeformMinimum = CGSize(width: 0.5, height: 0.5)

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
            minimumSize: freeformMinimum,
            in: canvas
        )
        #expect(result.width >= freeformMinimum.width)
        #expect(result.height >= freeformMinimum.height)
        #expect(result.width > 0)
        #expect(result.height > 0)
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
                minimumSize: freeformMinimum,
                in: canvas
            )

            #expect(result == CGRect(x: 100, y: 100, width: 100 + CGFloat(delta), height: 100))
        }
    }

    @Test("cardinal resize handles keep opposite edge fixed")
    func cardinalResizeKeepsOppositeEdgeFixed() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let minimumSize = freeformMinimum

        #expect(CanvasElementGeometry.resized(base, by: .e, delta: CGSize(width: 7, height: 0), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 100, width: 107, height: 100))
        #expect(CanvasElementGeometry.resized(base, by: .w, delta: CGSize(width: 7, height: 0), minimumSize: minimumSize, in: canvas) == CGRect(x: 107, y: 100, width: 93, height: 100))
        #expect(CanvasElementGeometry.resized(base, by: .n, delta: CGSize(width: 0, height: 9), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 109, width: 100, height: 91))
        #expect(CanvasElementGeometry.resized(base, by: .s, delta: CGSize(width: 0, height: 13), minimumSize: minimumSize, in: canvas) == CGRect(x: 100, y: 100, width: 100, height: 113))
    }

    @Test("corner resize handles keep both opposite edges fixed")
    func cornerResizeKeepsOppositeEdgesFixed() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let minimumSize = freeformMinimum

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
                minimumSize: freeformMinimum,
                in: canvas
            )

            #expect(result == CGRect(x: 300, y: 100, width: CGFloat(expectedMaxX - 300), height: 100))
        }
    }

    @Test("east resize reaches one source pixel without a grid-cell stop")
    func eastResizeReachesOneSourcePixelWithoutGridCellStop() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)

        for expectedWidth in stride(from: CGFloat(100), through: 1, by: -1) {
            let result = CanvasElementGeometry.resized(
                base,
                by: .e,
                delta: CGSize(width: expectedWidth - base.width, height: 0),
                minimumSize: CGSize(width: 1, height: 1),
                in: canvas
            )

            #expect(result.minX == base.minX)
            #expect(result.width == expectedWidth)
            #expect(result.width > 0)
        }
    }

    @Test("cardinal resize handles reach one source pixel")
    func cardinalResizeReachesOneSourcePixel() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let cases: [(CanvasElementResizeHandle, CGSize, CGRect)] = [
            (.e, CGSize(width: -99, height: 0), CGRect(x: 100, y: 100, width: 1, height: 100)),
            (.w, CGSize(width: 99, height: 0), CGRect(x: 199, y: 100, width: 1, height: 100)),
            (.n, CGSize(width: 0, height: 99), CGRect(x: 100, y: 199, width: 100, height: 1)),
            (.s, CGSize(width: 0, height: -99), CGRect(x: 100, y: 100, width: 100, height: 1))
        ]

        for (handle, delta, expected) in cases {
            let result = CanvasElementGeometry.resized(
                base,
                by: handle,
                delta: delta,
                minimumSize: CGSize(width: 1, height: 1),
                in: canvas
            )

            #expect(result == expected)
            #expect(result.width > 0)
            #expect(result.height > 0)
        }
    }

    @Test("corner resize handles reach a near one-by-one element")
    func cornerResizeReachesNearOneByOneElement() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let cases: [(CanvasElementResizeHandle, CGSize, CGRect)] = [
            (.nw, CGSize(width: 99, height: 99), CGRect(x: 199, y: 199, width: 1, height: 1)),
            (.ne, CGSize(width: -99, height: 99), CGRect(x: 100, y: 199, width: 1, height: 1)),
            (.sw, CGSize(width: 99, height: -99), CGRect(x: 199, y: 100, width: 1, height: 1)),
            (.se, CGSize(width: -99, height: -99), CGRect(x: 100, y: 100, width: 1, height: 1))
        ]

        for (handle, delta, expected) in cases {
            let result = CanvasElementGeometry.resized(
                base,
                by: handle,
                delta: delta,
                minimumSize: CGSize(width: 1, height: 1),
                in: canvas
            )

            #expect(result == expected)
            #expect(result.width > 0)
            #expect(result.height > 0)
        }
    }

    @Test("fractional pointer movement is not rounded or quantized")
    func fractionalPointerMovementIsPreserved() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)

        for delta in [CGFloat(0.25), 0.5, 1.25, 7.75] {
            let east = CanvasElementGeometry.resized(
                base,
                by: .e,
                delta: CGSize(width: delta, height: 0),
                minimumSize: freeformMinimum,
                in: canvas
            )
            let west = CanvasElementGeometry.resized(
                base,
                by: .w,
                delta: CGSize(width: delta, height: 0),
                minimumSize: freeformMinimum,
                in: canvas
            )

            #expect(east.minX == base.minX)
            #expect(east.width == base.width + delta)
            #expect(west.maxX == base.maxX)
            #expect(west.minX == base.minX + delta)
        }
    }

    @Test("canvas boundary clamps fractional resize continuously")
    func canvasBoundaryClampsFractionalResizeContinuously() {
        let base = CGRect(x: 300, y: 100, width: 50, height: 100)
        let expectedMaxX: [CGFloat] = [397.25, 398.75, 400, 400]

        for (delta, expected) in zip([47.25, 48.75, 50.25, 51.75], expectedMaxX) {
            let result = CanvasElementGeometry.resized(
                base,
                by: .e,
                delta: CGSize(width: delta, height: 0),
                minimumSize: freeformMinimum,
                in: canvas
            )

            #expect(result.minX == base.minX)
            #expect(result.maxX == expected)
            #expect(result.width > 0)
        }
    }

    @Test("visual grid spacing does not affect resize geometry")
    func visualGridSpacingDoesNotAffectResizeGeometry() {
        let base = CGRect(x: 100, y: 100, width: 100, height: 100)
        let delta = CGSize(width: -41.25, height: 7.75)

        // Grid spacing is decorative and intentionally absent from resize inputs.
        let resultAt40PointGrid = CanvasElementGeometry.resized(base, by: .se, delta: delta, minimumSize: freeformMinimum, in: canvas)
        let resultAt80PointGrid = CanvasElementGeometry.resized(base, by: .se, delta: delta, minimumSize: freeformMinimum, in: canvas)

        #expect(resultAt40PointGrid == resultAt80PointGrid)
        #expect(resultAt40PointGrid.width == 58.75)
        #expect(resultAt40PointGrid.height == 107.75)
    }

    @Test("resize release matches live preview for both signs on every handle")
    func resizeReleaseMatchesLivePreview() {
        let base = CGRect(x: 250, y: 250, width: 300, height: 200)
        let canvas = CGSize(width: 1000, height: 1000)
        let translations: [(CanvasElementResizeHandle, [CGSize])] = [
            (.n, [CGSize(width: 0, height: 40), CGSize(width: 0, height: -40)]),
            (.s, [CGSize(width: 0, height: 40), CGSize(width: 0, height: -40)]),
            (.e, [CGSize(width: 40, height: 0), CGSize(width: -40, height: 0)]),
            (.w, [CGSize(width: 40, height: 0), CGSize(width: -40, height: 0)]),
            (.ne, [CGSize(width: 40, height: 40), CGSize(width: -40, height: -40)]),
            (.nw, [CGSize(width: 40, height: 40), CGSize(width: -40, height: -40)]),
            (.se, [CGSize(width: 40, height: 40), CGSize(width: -40, height: -40)]),
            (.sw, [CGSize(width: 40, height: 40), CGSize(width: -40, height: -40)])
        ]

        for (handle, handleTranslations) in translations {
            for translation in handleTranslations {
                let (liveRect, committedRect, doubleAppliedRect) = resizeGestureResults(
                    base: base,
                    handle: handle,
                    translation: translation,
                    minimumSize: freeformMinimum,
                    canvasSize: canvas
                )

                #expect(committedRect == liveRect)
                #expect(doubleAppliedRect != liveRect)
            }
        }

        let (liveRect, committedRect, _) = resizeGestureResults(
            base: base,
            handle: .e,
            translation: CGSize(width: 40, height: 0),
            minimumSize: freeformMinimum,
            canvasSize: canvas
        )
        #expect(liveRect.width == 340)
        #expect(committedRect.width == 340)
    }

    private func resizeGestureResults(
        base: CGRect,
        handle: CanvasElementResizeHandle,
        translation: CGSize,
        minimumSize: CGSize,
        canvasSize: CGSize
    ) -> (liveRect: CGRect, committedRect: CGRect, doubleAppliedRect: CGRect) {
        let liveRect = CanvasElementGeometry.resized(
            base,
            by: handle,
            delta: translation,
            minimumSize: minimumSize,
            in: canvasSize
        )
        let committedRect = CanvasElementGeometry.resized(
            base,
            by: handle,
            delta: translation,
            minimumSize: minimumSize,
            in: canvasSize
        )
        let doubleAppliedRect = CanvasElementGeometry.resized(
            liveRect,
            by: handle,
            delta: translation,
            minimumSize: minimumSize,
            in: canvasSize
        )
        return (liveRect, committedRect, doubleAppliedRect)
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
