import CoreGraphics
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("External review layout")
struct ExternalReviewLayoutTests {
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
