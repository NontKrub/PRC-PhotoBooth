import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("External review layout")
struct ExternalReviewLayoutTests {
    @Test(arguments: [
        (CGSize(width: 1920, height: 1080), CGFloat(2.0 / 3.0)),
        (CGSize(width: 1080, height: 1920), CGFloat(3.0 / 2.0)),
        (CGSize(width: 3840, height: 2160), CGFloat(1))
    ])
    func countdownViewportFitsSlot(display: CGSize, ratio: CGFloat) {
        let viewport = ExternalReviewLayout.previewSize(for: display, aspectRatio: ratio)
        #expect(viewport.width <= display.width)
        #expect(viewport.height <= display.height)
        #expect(abs(viewport.width / viewport.height - ratio) < 0.000_001)
        #expect(abs(viewport.width - display.width) < 0.001 || abs(viewport.height - display.height) < 0.001)
    }

    @Test("countdown and review use each active canvas slot")
    func framesEachActiveSlot() throws {
        let config = EventConfig(canvasWidth: 1200, canvasHeight: 1800, slots: [
            SharedPhotoSlot(id: "portrait", normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), photoIndex: 0),
            SharedPhotoSlot(id: "landscape", normalizedRect: CGRect(x: 0, y: 0.5, width: 0.75, height: 1.0 / 3.0), photoIndex: 1)
        ])
        let display = CGSize(width: 1920, height: 1080)
        for index in 0..<2 {
            let framing = try #require(CaptureFramingGeometry.framing(for: index, in: config))
            let countdown = ExternalReviewLayout.previewSize(for: display, aspectRatio: framing.aspectRatio)
            let review = ExternalReviewLayout.imageSize(for: display, image: framing.pixelSize)
            #expect(abs(countdown.width / countdown.height - review.width / review.height) < 0.000_001)
            #expect(abs(review.width / review.height - (index == 0 ? 2.0 / 3.0 : 1.5)) < 0.000_001)
        }
    }

    @Test("missing or invalid framing keeps the original viewport")
    func previewFallsBackWithoutValidFraming() {
        let display = CGSize(width: 1920, height: 1080)
        for ratio: CGFloat? in [nil, 0, -1, .nan, .infinity] {
            #expect(ExternalReviewLayout.previewSize(for: display, aspectRatio: ratio) == display)
        }
    }

    @Test("fits a landscape image inside a 1080p display")
    func fitsLandscape() {
        let display = CGSize(width: 1920, height: 1080)
        let image = CGSize(width: 1800, height: 1200)
        let result = ExternalReviewLayout.imageSize(for: display, image: image)

        #expect(result.width <= display.width * 0.92)
        #expect(result.height <= display.height * 0.68)
        #expect(abs(result.width / result.height - image.width / image.height) < 0.001)
    }

    @Test("fits portrait and square images without cropping")
    func fitsPortraitAndSquare() {
        let display = CGSize(width: 3840, height: 2160)
        let portrait = ExternalReviewLayout.imageSize(for: display, image: CGSize(width: 1200, height: 1800))
        let square = ExternalReviewLayout.imageSize(for: display, image: CGSize(width: 1200, height: 1200))

        #expect(portrait.height <= display.height * 0.68)
        #expect(square.width <= display.width * 0.92)
        #expect(abs(portrait.width / portrait.height - 1200.0 / 1800.0) < 0.001)
        #expect(abs(square.width / square.height - 1) < 0.001)
    }

    @Test("invalid dimensions return an empty region")
    func rejectsInvalidDimensions() {
        #expect(ExternalReviewLayout.imageSize(for: CGSize(width: 1920, height: 1080), image: .zero) == .zero)
        #expect(ExternalReviewLayout.imageSize(for: .zero, image: CGSize(width: 1200, height: 800)) == .zero)
    }
}
