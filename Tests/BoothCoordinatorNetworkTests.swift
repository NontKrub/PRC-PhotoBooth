import Testing

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
