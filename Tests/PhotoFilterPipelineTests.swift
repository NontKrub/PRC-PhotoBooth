import CoreGraphics
import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Photo filter pipeline")
struct PhotoFilterPipelineTests {
    @Test("Every filter preserves image dimensions")
    func dimensionsRemainStable() async throws {
        let source = try #require(makeSampleImage())
        let pipeline = PhotoFilterPipeline()

        for filter in PhotoFilterID.allCases {
            let output = try await pipeline.apply(filter, to: source)
            #expect(output.width == source.width)
            #expect(output.height == source.height)
        }
    }

    @Test("Original returns equivalent image and other filters produce output")
    func filtersProduceOutput() async throws {
        let source = try #require(makeSampleImage())
        let pipeline = PhotoFilterPipeline()
        let original = try await pipeline.apply(.original, to: source)
        #expect(original === source)

        for filter in PhotoFilterID.allCases.dropFirst() {
            #expect(try await pipeline.validate(filter))
            _ = try await pipeline.apply(filter, to: source)
        }
    }

    @Test("Monochrome reduces channel differences")
    func monochromeIsMonochrome() async throws {
        let source = try #require(makeSampleImage())
        let output = try await PhotoFilterPipeline().apply(.monochrome, to: source)
        #expect(channelDifference(output) < channelDifference(source))
    }

    @Test("Repeated application is deterministic")
    func deterministicOutput() async throws {
        let source = try #require(makeSampleImage())
        let pipeline = PhotoFilterPipeline()
        let first = try await pipeline.apply(.warm, to: source)
        let second = try await pipeline.apply(.warm, to: source)
        #expect(pixelData(first) == pixelData(second))
    }

    @Test("Concurrent requests complete")
    func concurrentRequests() async throws {
        let source = try #require(makeSampleImage())
        let pipeline = PhotoFilterPipeline()
        await withTaskGroup(of: CGImage?.self) { group in
            for filter in PhotoFilterID.allCases {
                group.addTask { try? await pipeline.apply(filter, to: source) }
            }
            var count = 0
            for await image in group {
                if image != nil { count += 1 }
            }
            #expect(count == PhotoFilterID.allCases.count)
        }
    }

    private func makeSampleImage() -> CGImage? {
        let width = 64
        let height = 64
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 0.9, green: 0.25, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        context.setStrokeColor(CGColor(red: 0.1, green: 0.8, blue: 0.25, alpha: 1))
        context.setLineWidth(2)
        for y in stride(from: 0, to: height, by: 6) {
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()
        return context.makeImage()
    }

    private func pixelData(_ image: CGImage) -> Data {
        image.dataProvider?.data as Data? ?? Data()
    }

    private func channelDifference(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data as Data? else { return 0 }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else { return 0 }
        var total = 0
        var pixels = 0
        for index in stride(from: 0, through: bytes.count - 4, by: 4) {
            total += abs(Int(bytes[index]) - Int(bytes[index + 1]))
            total += abs(Int(bytes[index + 1]) - Int(bytes[index + 2]))
            pixels += 2
        }
        return Double(total) / Double(max(1, pixels))
    }
}
