import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Preview quality policy")
struct PreviewQualityTests {
    @Test("Auto uses Standard on Wi-Fi and High on stable LAN")
    func autoFollowsRouteAfterHysteresis() {
        var policy = PreviewQualityPolicy(hysteresis: 2)
        let start = Date(timeIntervalSince1970: 100)

        #expect(policy.update(effectiveNetwork: .wifi, now: start) == .standard)
        #expect(policy.update(effectiveNetwork: .lan, now: start.addingTimeInterval(1)) == .standard)
        #expect(policy.update(effectiveNetwork: .lan, now: start.addingTimeInterval(3.1)) == .high)
    }

    @Test("Explicit presets ignore route changes")
    func explicitPresetWins() {
        var standard = PreviewQualityPolicy(preset: .standard)
        var high = PreviewQualityPolicy(preset: .high)

        #expect(standard.update(effectiveNetwork: .lan) == .standard)
        #expect(high.update(effectiveNetwork: .wifi) == .high)
    }

    @Test("Auto route flapping does not oscillate immediately")
    func routeFlappingIsDebounced() {
        var policy = PreviewQualityPolicy(hysteresis: 2)
        let start = Date(timeIntervalSince1970: 200)

        _ = policy.update(effectiveNetwork: .lan, now: start)
        #expect(policy.update(effectiveNetwork: .wifi, now: start.addingTimeInterval(1)) == .standard)
        #expect(policy.update(effectiveNetwork: .lan, now: start.addingTimeInterval(1.5)) == .standard)
        #expect(policy.update(effectiveNetwork: .lan, now: start.addingTimeInterval(3.6)) == .high)
    }

    @Test("High profile only permits 30 FPS")
    func highProfileConstrainsFrameRate() {
        #expect(PreviewQualityProfile.high.defaultFramesPerSecond == 30)
        #expect(!PreviewQualityProfile.high.allows60FPS)
        #expect(PreviewQualityProfile.standard.allows60FPS)
    }
}
