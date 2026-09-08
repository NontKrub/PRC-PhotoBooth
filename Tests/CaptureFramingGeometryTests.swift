import CoreGraphics
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Capture framing geometry")
struct CaptureFramingGeometryTests {
    @Test("scales normalized dimensions by the canvas")
    func scalesNormalizedDimensionsByCanvas() throws {
        let framing = try #require(CaptureFramingGeometry.framing(
            for: 0,
            in: config(canvas: CGSize(width: 1200, height: 1800), slots: [
                slot("slot", rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.25))
            ])
        ))

        #expect(framing.pixelSize == CGSize(width: 600, height: 450))
        expectRatio(framing.aspectRatio, equals: 4.0 / 3.0)
    }

    @Test(arguments: [
        (CGSize(width: 600, height: 900), 2.0 / 3.0),
        (CGSize(width: 900, height: 600), 3.0 / 2.0),
        (CGSize(width: 500, height: 500), 1.0),
        (CGSize(width: 1000, height: 400), 2.5)
    ])
    func usesExpectedSlotAspectRatio(pixelSize: CGSize, expectedRatio: CGFloat) throws {
        let framing = try #require(CaptureFramingGeometry.framing(
            for: 0,
            in: config(canvas: pixelSize, slots: [slot("slot", rect: CGRect(x: 0, y: 0, width: 1, height: 1))])
        ))

        expectRatio(framing.aspectRatio, equals: expectedRatio)
    }

    @Test("selects the requested photo index")
    func selectsRequestedPhotoIndex() throws {
        let framing = try #require(CaptureFramingGeometry.framing(
            for: 1,
            in: config(canvas: CGSize(width: 1200, height: 1800), slots: [
                slot("photo-0", rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), photoIndex: 0),
                slot("photo-1", rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.75), photoIndex: 1)
            ])
        ))

        #expect(framing.slotID == "photo-1")
        expectRatio(framing.aspectRatio, equals: 4.0 / 9.0)
    }

    @Test("returns nil for missing or invalid slots")
    func rejectsMissingAndInvalidSlots() {
        let canvas = CGSize(width: 1200, height: 1800)
        #expect(CaptureFramingGeometry.framing(for: 1, in: config(canvas: canvas, slots: [
            slot("photo-0", rect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)
        ])) == nil)
        #expect(CaptureFramingGeometry.framing(for: 0, in: config(canvas: canvas, slots: [
            slot("zero", rect: CGRect(x: 0, y: 0, width: 0, height: 1))
        ])) == nil)
    }

    @Test("uses z-order then slot ID for primary framing")
    func choosesPrimarySlotDeterministically() throws {
        let base = config(canvas: CGSize(width: 1200, height: 1800), slots: [
            slot("z-last", rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), zOrder: 2),
            slot("b", rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.25), zOrder: 1),
            slot("a", rect: CGRect(x: 0, y: 0, width: 0.25, height: 0.5), zOrder: 1)
        ])

        let framing = try #require(CaptureFramingGeometry.framing(for: 0, in: base))
        #expect(framing.slotID == "a")
        expectRatio(framing.aspectRatio, equals: 1.0 / 3.0)
    }

    @Test("rotation does not invert the capture aspect ratio")
    func preservesUnrotatedSlotAspectRatio() throws {
        let framing = try #require(CaptureFramingGeometry.framing(
            for: 0,
            in: config(canvas: CGSize(width: 1200, height: 1800), slots: [
                SharedPhotoSlot(
                    id: "rotated",
                    normalizedRect: CGRect(x: 0, y: 0, width: 0.75, height: 1.0 / 3.0),
                    rotation: 90,
                    photoIndex: 0
                )
            ])
        ))

        #expect(framing.aspectRatio == 1.5)
    }

    @Test("matches the compositor destination rect ratio")
    func matchesCompositorDestinationRectRatio() throws {
        let template = config(canvas: CGSize(width: 1200, height: 1800), slots: [
            slot("compositor-slot", rect: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.25))
        ])
        let framing = try #require(CaptureFramingGeometry.framing(for: 0, in: template))
        let compositorRect = CGRect(
            x: template.slots[0].normalizedRect.minX * template.canvasWidth,
            y: template.slots[0].normalizedRect.minY * template.canvasHeight,
            width: template.slots[0].normalizedRect.width * template.canvasWidth,
            height: template.slots[0].normalizedRect.height * template.canvasHeight
        )

        expectRatio(framing.aspectRatio, equals: compositorRect.width / compositorRect.height)
    }

    private func config(canvas: CGSize, slots: [SharedPhotoSlot]) -> EventConfig {
        EventConfig(canvasWidth: canvas.width, canvasHeight: canvas.height, slots: slots)
    }

    private func slot(
        _ id: String,
        rect: CGRect,
        zOrder: Int = 0,
        photoIndex: Int = 0
    ) -> SharedPhotoSlot {
        SharedPhotoSlot(id: id, normalizedRect: rect, zOrder: zOrder, photoIndex: photoIndex)
    }

    private func expectRatio(_ actual: CGFloat, equals expected: CGFloat) {
        #expect(abs(actual - expected) < 0.000_001)
    }
}
