import AppKit
import Foundation

enum SystemSettingsDestination {
    case printersAndScanners
    case cameraPrivacy
}

@MainActor
enum SystemSettingsRouter {
    static func url(for destination: SystemSettingsDestination) -> URL? {
        switch destination {
        case .printersAndScanners:
            return URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")
        case .cameraPrivacy:
            return URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera")
        }
    }

    @discardableResult
    static func open(_ destination: SystemSettingsDestination) -> Bool {
        if let url = url(for: destination), NSWorkspace.shared.open(url) {
            return true
        }
        guard let fallbackURL = URL(string: "x-apple.systempreferences:") else { return false }
        return NSWorkspace.shared.open(fallbackURL)
    }
}
