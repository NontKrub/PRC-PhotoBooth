import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import PRC_PhotoBooth_Mac

@Suite("GIF encoding")
struct GIFEncoderTests {
    @Test("samples 75 source frames to 60 and keeps the final frame")
    func samplesLongSourceIncludingFinalFrame() {
        let frames = (0..<75).map { makeImage(width: $0 + 1) }
        let sampled = GIFFrameSampler(targetFramesPerShot: 60).sample(frames)

        #expect(sampled.count == 60)
        #expect(sampled.first?.width == frames.first?.width)
        #expect(sampled.last?.width == frames.last?.width)
    }

    @Test("samples fewer source frames to the target count and keeps endpoints")
    func samplesShortSourceIncludingEndpoints() {
        let frames = (0..<50).map { makeImage(width: $0 + 1) }
        let sampled = GIFFrameSampler(targetFramesPerShot: 60).sample(frames)

        #expect(sampled.count == 60)
        #expect(sampled.first?.width == frames.first?.width)
        #expect(sampled.last?.width == frames.last?.width)
    }

    @Test("repeats one source frame to the target count")
    func repeatsOneFrame() {
        let frame = makeImage(width: 7)
        let sampled = GIFFrameSampler(targetFramesPerShot: 60).sample([frame])

        #expect(sampled.count == 60)
        #expect(sampled.allSatisfy { $0.width == frame.width })
    }

    @Test("normalizes three shots to equal consecutive sections")
    func normalizesThreeShots() {
        let sampler = GIFFrameSampler(targetFramesPerShot: 60)
        let shots = (0..<3).map { shot in
            (0..<75).map { makeImage(width: shot * 100 + $0 + 1) }
        }
        let frames = shots.flatMap(sampler.sample)

        #expect(frames.count == 180)
        #expect(frames[59].width < 100)
        #expect(frames[60].width >= 101)
        #expect(frames[119].width < 200)
        #expect(frames[120].width >= 201)
        #expect(frames.last?.width == shots[2].last?.width)
    }

    @Test("GIF metadata uses exact frame count and delay")
    func encodesExactFrameCountAndDelay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-GIF-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("booth.gif")

        try GIFEncoder(preset: .high).encode(frames: Array(repeating: makeImage(width: 8), count: 180), to: url)

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 180)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        let delay = try #require(gif[kCGImagePropertyGIFDelayTime] as? Double)
        #expect(abs(delay - GIFQualityPreset.high.frameDelay) < 0.01)
    }

    @Test("provider encoder streams exact count, dimensions, and loop metadata")
    func streamsProviderFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-GIF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("stream.gif")
        try GIFEncoder(frameDelay: 0.1, maxDimension: 480).encode(frameCount: 3, to: url) { _ in self.makeImage(width: 8) }
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        let frameProperties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(frameProperties[kCGImagePropertyPixelWidth] as? Int == 8)
        let properties = try #require(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        let gif = try #require(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
        #expect(gif[kCGImagePropertyGIFLoopCount] as? Int == 0)
    }

    @Test("rejects a non-positive frame delay")
    func rejectsNonPositiveDelay() {
        #expect(throws: GIFError.self) {
            try GIFEncoder(frameDelay: 0).encode(frames: [makeImage(width: 8)], to: FileManager.default.temporaryDirectory.appendingPathComponent("invalid.gif"))
        }
    }

    @Test("quality presets produce the requested production frame counts")
    func productionRendererFrameCounts() async throws {
        for preset in GIFQualityPreset.allCases {
            let fixture = try makeRendererFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let destination = fixture.root.appendingPathComponent("\(preset.rawValue).gif")
            try await TemplateGIFRenderer(
                compositor: fixture.compositor,
                filterPipeline: PhotoFilterPipeline(),
                sampler: GIFFrameSampler(targetFramesPerShot: preset.frameCount),
                encoder: GIFEncoder(preset: preset)
            ).render(
                manifest: fixture.manifest,
                acceptedImages: fixture.acceptedImages,
                directory: fixture.root,
                qrPayload: nil,
                to: destination
            )

            let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
            #expect(CGImageSourceGetCount(source) == preset.frameCount)
        }
    }

    @Test("benchmarks old and preset GIF output on one shared rendered fixture")
    func benchmarksGIFPresets() async throws {
        let fixture = try makeBenchmarkFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cases: [(String, Int, Int, Int, GIFEncoder)] = [
            ("Old baseline", 480, 60, 12, GIFEncoder(frameDelay: 1.0 / 12.0, maxDimension: 480)),
            ("Compact", GIFQualityPreset.compact.maxDimension, GIFQualityPreset.compact.frameCount, GIFQualityPreset.compact.frameRate, GIFEncoder(preset: .compact)),
            ("Balanced", GIFQualityPreset.balanced.maxDimension, GIFQualityPreset.balanced.frameCount, GIFQualityPreset.balanced.frameRate, GIFEncoder(preset: .balanced)),
            ("High", GIFQualityPreset.high.maxDimension, GIFQualityPreset.high.frameCount, GIFQualityPreset.high.frameRate, GIFEncoder(preset: .high))
        ]

        for (label, maxDimension, frameCount, frameRate, encoder) in cases {
            let destination = fixture.root.appendingPathComponent("benchmark-\(label.replacingOccurrences(of: " ", with: "-").lowercased()).gif")
            let started = ContinuousClock.now
            try await TemplateGIFRenderer(
                compositor: fixture.compositor,
                filterPipeline: PhotoFilterPipeline(),
                sampler: GIFFrameSampler(targetFramesPerShot: frameCount),
                encoder: encoder
            ).render(
                manifest: fixture.manifest,
                acceptedImages: fixture.acceptedImages,
                directory: fixture.root,
                qrPayload: "https://example.test/benchmark",
                to: destination
            )
            let elapsed = started.duration(to: .now)
            let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
            let outputFrames = CGImageSourceGetCount(source)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            let delay = (properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
            let fileSize = try #require((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value)
            print("GIF_BENCHMARK label=\(label) dimension=\(maxDimension) fps=\(frameRate) frames=\(outputFrames) duration=\(Double(outputFrames) * delay) size=\(fileSize) renderSeconds=\(elapsed.components.seconds)\(elapsed.components.attoseconds == 0 ? "" : ".\(elapsed.components.attoseconds)")")
            #expect(outputFrames == frameCount)
            #expect(fileSize > 0)
        }
    }

    @Test("production renderer advances all animated slots on one timeline")
    func productionRendererAnimatesSlotsTogether() async throws {
        let fixture = try makeRendererFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("simultaneous.gif")
        try await TemplateGIFRenderer(
            compositor: fixture.compositor,
            filterPipeline: PhotoFilterPipeline(),
            sampler: GIFFrameSampler(targetFramesPerShot: 4),
            encoder: GIFEncoder(frameDelay: 0.1, maxDimension: 80)
        ).render(
            manifest: fixture.manifest,
            acceptedImages: fixture.acceptedImages,
            directory: fixture.root,
            qrPayload: nil,
            to: destination
        )

        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let second = try #require(CGImageSourceCreateImageAtIndex(source, 1, nil))
        #expect(pixel(first, x: 20, y: 40) != pixel(second, x: 20, y: 40))
        #expect(pixel(first, x: 60, y: 40) != pixel(second, x: 60, y: 40))
    }

    @Test("production renderer uses an accepted still while another slot animates")
    func productionRendererStillFallback() async throws {
        let fixture = try makeRendererFixture(stillPhotoIndex: 1)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = fixture.root.appendingPathComponent("still-fallback.gif")
        try await TemplateGIFRenderer(
            compositor: fixture.compositor,
            filterPipeline: PhotoFilterPipeline(),
            sampler: GIFFrameSampler(targetFramesPerShot: 4),
            encoder: GIFEncoder(frameDelay: 0.1, maxDimension: 80)
        ).render(
            manifest: fixture.manifest,
            acceptedImages: fixture.acceptedImages,
            directory: fixture.root,
            qrPayload: nil,
            to: destination
        )

        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let last = try #require(CGImageSourceCreateImageAtIndex(source, 3, nil))
        #expect(pixel(first, x: 60, y: 40) == pixel(last, x: 60, y: 40))
        #expect(pixel(first, x: 20, y: 40) != pixel(last, x: 20, y: 40))
    }

    @Test("production renderer keeps frame, photos, foreground, and QR layer order")
    func productionRendererLayerOrder() async throws {
        let fixture = try makeRendererFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var config = fixture.manifest.eventConfig
        config.qrCodeElements = [
            SharedQRCodeElement(id: "qr", normalizedRect: CGRect(x: 0.75, y: 0.75, width: 0.2, height: 0.2))
        ]
        var manifest = fixture.manifest
        manifest.eventConfig = config
        let destination = fixture.root.appendingPathComponent("layers.gif")
        try await TemplateGIFRenderer(
            compositor: Compositor(
                config: config,
                framePNG: solidImage(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 1)),
                foregroundOverlayPNG: foregroundImage()
            ),
            filterPipeline: PhotoFilterPipeline(),
            sampler: GIFFrameSampler(targetFramesPerShot: 1),
            encoder: GIFEncoder(frameDelay: 0.1, maxDimension: 80)
        ).render(
            manifest: manifest,
            acceptedImages: fixture.acceptedImages,
            directory: fixture.root,
            qrPayload: "https://example.test/session",
            to: destination
        )

        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let center = pixel(image, x: 40, y: 40)
        #expect((center >> 16) > (center >> 24))
        #expect((center >> 16) > ((center >> 8) & 0xff))
        let qrPixels = (60..<80).flatMap { y in (60..<80).map { x in pixel(image, x: x, y: y) } }
        #expect(qrPixels.contains { ($0 >> 24) < 40 && (($0 >> 16) & 0xff) < 40 && (($0 >> 8) & 0xff) < 40 })
    }

    @Test("production renderer rejects missing, corrupt, and traversing source frames")
    func productionRendererRejectsBadSources() async throws {
        let missingAccepted = try makeRendererFixture()
        defer { try? FileManager.default.removeItem(at: missingAccepted.root) }
        let missingImages = missingAccepted.acceptedImages.filter { $0.key != 0 }
        await #expect(throws: TemplateGIFRendererError.self) {
            try await TemplateGIFRenderer(
                compositor: missingAccepted.compositor,
                filterPipeline: PhotoFilterPipeline(),
                sampler: GIFFrameSampler(targetFramesPerShot: 4),
                encoder: GIFEncoder(frameDelay: 0.1, maxDimension: 80)
            ).render(
                manifest: missingAccepted.manifest,
                acceptedImages: missingImages,
                directory: missingAccepted.root,
                qrPayload: nil,
                to: missingAccepted.root.appendingPathComponent("missing.gif")
            )
        }

        let badPath = try makeRendererFixture()
        defer { try? FileManager.default.removeItem(at: badPath.root) }
        var traversalManifest = badPath.manifest
        traversalManifest.shots[0].gifFrameFileNames = ["../outside.png"]
        await #expect(throws: TemplateGIFRendererError.self) {
            try await TemplateGIFRenderer(
                compositor: badPath.compositor,
                filterPipeline: PhotoFilterPipeline(),
                sampler: GIFFrameSampler(targetFramesPerShot: 4),
                encoder: GIFEncoder(frameDelay: 0.1, maxDimension: 80)
            ).render(
                manifest: traversalManifest,
                acceptedImages: badPath.acceptedImages,
                directory: badPath.root,
                qrPayload: nil,
                to: badPath.root.appendingPathComponent("traversal.gif")
            )
        }

        let corrupt = try makeRendererFixture()
        defer { try? FileManager.default.removeItem(at: corrupt.root) }
        let corruptURL = corrupt.root.appendingPathComponent(corrupt.manifest.shots[0].gifFrameFileNames[0])
        try Data([0, 1, 2]).write(to: corruptURL)
        await #expect(throws: TemplateGIFRendererError.self) {
            try await TemplateGIFRenderer(
                compositor: corrupt.compositor,
                filterPipeline: PhotoFilterPipeline(),
                sampler: GIFFrameSampler(targetFramesPerShot: 4),
                encoder: GIFEncoder(frameDelay: 0.1, maxDimension: 80)
            ).render(
                manifest: corrupt.manifest,
                acceptedImages: corrupt.acceptedImages,
                directory: corrupt.root,
                qrPayload: nil,
                to: corrupt.root.appendingPathComponent("corrupt.gif")
            )
        }
    }

    private func makeImage(width: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        return context.makeImage()!
    }

    private struct RendererFixture {
        let root: URL
        let manifest: SessionManifest
        let acceptedImages: [Int: CGImage]
        let compositor: Compositor
    }

    private struct BenchmarkFixture {
        let root: URL
        let manifest: SessionManifest
        let acceptedImages: [Int: CGImage]
        let compositor: Compositor
    }

    private func makeRendererFixture(stillPhotoIndex: Int? = nil) throws -> RendererFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-GIF-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var acceptedImages: [Int: CGImage] = [:]
        var shots: [RuntimeShotRecord] = []
        let colors: [CGColor] = [
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        ]
        for photoIndex in 0..<2 {
            acceptedImages[photoIndex] = solidImage(colors[photoIndex])
            let names: [String]
            if photoIndex == stillPhotoIndex {
                names = []
            } else {
                names = try colors.enumerated().map { frameIndex, color in
                    let name = "gif/photo_\(photoIndex)/frame_\(String(format: "%03d", frameIndex)).png"
                    let url = root.appendingPathComponent(name)
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try writePNG(solidImage(color), to: url)
                    return name
                }
            }
            shots.append(RuntimeShotRecord(
                photoIndex: photoIndex,
                imageFileName: nil,
                gifFrameFileNames: names,
                retakeCount: 0,
                acceptedAt: Date()
            ))
        }
        let config = EventConfig(
            eventID: "event",
            eventName: "GIF Test",
            photoCount: 2,
            canvasWidth: 80,
            canvasHeight: 80,
            slots: [
                SharedPhotoSlot(id: "left", normalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1), photoIndex: 0),
                SharedPhotoSlot(id: "right", normalizedRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), photoIndex: 1)
            ]
        )
        let manifest = SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            id: "session",
            eventID: "event",
            eventName: "GIF Test",
            eventConfig: config,
            startedAt: Date(),
            completedAt: nil,
            cancelledAt: nil,
            status: .finalizing,
            nextPhotoIndex: 2,
            outputRootPath: root.path,
            relativeDirectoryPath: "GIF Test/session",
            absoluteDirectoryPath: root.path,
            frameSnapshotFileName: nil,
            stripFileName: nil,
            gifFileName: nil,
            downloadToken: "token",
            shots: shots,
            lastError: nil,
            updatedAt: Date()
        )
        return RendererFixture(
            root: root,
            manifest: manifest,
            acceptedImages: acceptedImages,
            compositor: Compositor(config: config, framePNG: nil)
        )
    }

    private func makeBenchmarkFixture() throws -> BenchmarkFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PRC-GIF-benchmark-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var acceptedImages: [Int: CGImage] = [:]
        var shots: [RuntimeShotRecord] = []
        for photoIndex in 0..<3 {
            var names: [String] = []
            for frameIndex in 0..<12 {
                let name = "gif/photo_\(photoIndex)/frame_\(String(format: "%03d", frameIndex)).png"
                let url = root.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let image = benchmarkImage(seed: photoIndex * 100 + frameIndex)
                if frameIndex == 0 { acceptedImages[photoIndex] = image }
                try writePNG(image, to: url)
                names.append(name)
            }
            shots.append(RuntimeShotRecord(
                photoIndex: photoIndex,
                imageFileName: nil,
                gifFrameFileNames: names,
                retakeCount: 0,
                acceptedAt: Date()
            ))
        }

        let config = EventConfig(
            eventID: "benchmark-event",
            eventName: "GIF benchmark",
            photoCount: 3,
            canvasWidth: 640,
            canvasHeight: 960,
            slots: [
                SharedPhotoSlot(id: "top", normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3.0), photoIndex: 0),
                SharedPhotoSlot(id: "middle", normalizedRect: CGRect(x: 0, y: 1.0 / 3.0, width: 1, height: 1.0 / 3.0), photoIndex: 1),
                SharedPhotoSlot(id: "bottom", normalizedRect: CGRect(x: 0, y: 2.0 / 3.0, width: 1, height: 1.0 / 3.0), photoIndex: 2)
            ],
            selectedFilterID: .warm,
            qrCodeElements: [
                SharedQRCodeElement(id: "qr", normalizedRect: CGRect(x: 0.78, y: 0.88, width: 0.16, height: 0.1))
            ]
        )
        let manifest = SessionManifest(
            schemaVersion: SessionManifest.currentSchemaVersion,
            id: "benchmark-session",
            eventID: "benchmark-event",
            eventName: "GIF benchmark",
            eventConfig: config,
            startedAt: Date(),
            completedAt: nil,
            cancelledAt: nil,
            status: .finalizing,
            nextPhotoIndex: 3,
            outputRootPath: root.path,
            relativeDirectoryPath: "GIF benchmark/session",
            absoluteDirectoryPath: root.path,
            frameSnapshotFileName: nil,
            stripFileName: nil,
            gifFileName: nil,
            downloadToken: "benchmark-token",
            shots: shots,
            lastError: nil,
            updatedAt: Date()
        )
        return BenchmarkFixture(
            root: root,
            manifest: manifest,
            acceptedImages: acceptedImages,
            compositor: Compositor(
                config: config,
                framePNG: benchmarkFrameImage(),
                foregroundOverlayPNG: benchmarkForegroundImage()
            )
        )
    }

    private func solidImage(_ color: CGColor) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 80,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
        return context.makeImage()!
    }

    private func foregroundImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 80,
            height: 80,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: 80, height: 80))
        context.setFillColor(CGColor(red: 0.1, green: 0.9, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 40, height: 40))
        return context.makeImage()!
    }

    private func benchmarkImage(seed: Int) -> CGImage {
        let width = 320
        let height = 480
        var value = UInt32(seed &* 1_664_525 &+ 1_013_904_223)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                value = value &* 1_664_525 &+ 1_013_904_223
                let noise = UInt8((value >> 24) & 0x1f)
                let offset = (y * width + x) * 4
                let red = x * 180 / width + Int(noise) + seed * 7
                let green = y * 180 / height + Int(noise) * 2 + seed * 11
                let blue = (x + y) * 120 / (width + height) + Int(noise) * 3 + seed * 13
                bytes[offset] = UInt8(red & 0xff)
                bytes[offset + 1] = UInt8(green & 0xff)
                bytes[offset + 2] = UInt8(blue & 0xff)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }

    private func benchmarkFrameImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 640,
            height: 960,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.12, green: 0.1, blue: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 960))
        context.setStrokeColor(CGColor(red: 0.9, green: 0.75, blue: 0.25, alpha: 1))
        context.setLineWidth(18)
        context.stroke(CGRect(x: 9, y: 9, width: 622, height: 942))
        return context.makeImage()!
    }

    private func benchmarkForegroundImage() -> CGImage {
        let context = CGContext(
            data: nil,
            width: 640,
            height: 960,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: 640, height: 960))
        context.setFillColor(CGColor(red: 0.9, green: 0.75, blue: 0.25, alpha: 0.9))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 18))
        context.fill(CGRect(x: 0, y: 942, width: 640, height: 18))
        return context.makeImage()!
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> UInt32 {
        guard let providerData = image.dataProvider?.data else { return 0 }
        let data = providerData as NSData
        let bytesPerPixel = max(1, image.bitsPerPixel / 8)
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        guard offset + 3 < data.length else { return 0 }
        var rgba = [UInt8](repeating: 0, count: 4)
        data.getBytes(&rgba, range: NSRange(location: offset, length: rgba.count))
        return UInt32(rgba[0]) << 24
            | UInt32(rgba[1]) << 16
            | UInt32(rgba[2]) << 8
            | UInt32(rgba[3])
    }
}
