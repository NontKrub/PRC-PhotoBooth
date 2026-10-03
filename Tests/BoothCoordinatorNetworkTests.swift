import Testing
import Foundation
import CoreGraphics

@testable import PRC_PhotoBooth_Mac

@Suite("Booth network recovery")
struct BoothCoordinatorNetworkTests {
    @Test("schedules recovery on startup and offline-to-online transitions only")
    func recoveryTransitions() {
        #expect(shouldScheduleAutomaticCloudRetry(previous: nil, isSatisfied: true))
        #expect(shouldScheduleAutomaticCloudRetry(previous: false, isSatisfied: true))
        #expect(!shouldScheduleAutomaticCloudRetry(previous: true, isSatisfied: true))
        #expect(!shouldScheduleAutomaticCloudRetry(previous: nil, isSatisfied: false))
    }
}

@Suite("Strip preview render queue")
@MainActor
struct StripPreviewRenderQueueTests {
    @Test("only one render runs and the latest pending preview wins")
    func latestPreviewWinsWithoutOverlappingRenders() async throws {
        let queue = LatestStripPreviewRenderQueue()
        let probe = PreviewRenderProbe()
        let results = PreviewRenderResults()

        for width in 1...3 {
            queue.submit(render: {
                probe.render(width: width)
            }, publish: { image in
                results.append(image?.width)
            })
        }

        for _ in 0..<200 where !results.contains(3) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(probe.renderedWidths == [1, 3])
        #expect(probe.peakConcurrentRenders == 1)
        #expect(results.values == [3])
    }

    @Test("invalidating a running render discards its stale result")
    func lifecycleInvalidationDropsOldResult() async throws {
        let queue = LatestStripPreviewRenderQueue()
        let probe = PreviewRenderProbe()
        let results = PreviewRenderResults()
        queue.submit(render: {
            probe.render(width: 1)
        }, publish: { image in
            results.append(image?.width)
        })
        queue.invalidate()

        for _ in 0..<200 where probe.activeRenders > 0 || probe.renderedWidths.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(probe.renderedWidths == [1])
        #expect(results.values.isEmpty)
    }
}

private final class PreviewRenderProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var widths: [Int] = []

    var activeRenders: Int {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    var peakConcurrentRenders: Int {
        lock.lock()
        defer { lock.unlock() }
        return peak
    }

    var renderedWidths: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return widths
    }

    func render(width: Int) -> CGImage? {
        lock.lock()
        active += 1
        peak = max(peak, active)
        lock.unlock()
        defer {
            lock.lock()
            active -= 1
            widths.append(width)
            lock.unlock()
        }
        Thread.sleep(forTimeInterval: 0.04)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 1))
        return context.makeImage()
    }
}

@MainActor
private final class PreviewRenderResults {
    private(set) var values: [Int] = []
    func append(_ width: Int?) {
        if let width { values.append(width) }
    }
    func contains(_ width: Int) -> Bool { values.contains(width) }
}
