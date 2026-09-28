import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("System Settings router")
struct SystemSettingsRouterTests {
    @Test("builds the Printers & Scanners deep link")
    @MainActor
    func printersURL() {
        #expect(SystemSettingsRouter.url(for: .printersAndScanners)?.absoluteString ==
                "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")
    }

    @Test("builds the Camera privacy deep link")
    @MainActor
    func cameraURL() {
        #expect(SystemSettingsRouter.url(for: .cameraPrivacy)?.absoluteString ==
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera")
    }
}
