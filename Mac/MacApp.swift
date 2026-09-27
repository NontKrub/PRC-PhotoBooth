import SwiftUI
import SwiftData

@main
struct MacApp: App {
    @State private var coordinator = BoothCoordinator()
    @AppStorage("operatorLanguage") private var operatorLanguage = OperatorLanguage.system.rawValue

    var body: some Scene {
        WindowGroup("PRC PhotoBooth — Operator") {
            MacContentView()
                .environment(coordinator)
                .environment(coordinator.connectionStatus)
                .environment(coordinator.stateMachine)
                .modelContainer(DataStore.shared.container)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        #if os(macOS)
        Settings {
            ProtectedSettingsView()
                .environment(coordinator)
                .environment(coordinator.connectionStatus)
                .environment(\.locale, operatorLocale)
        }
        .defaultSize(width: 420, height: 360)
        .windowResizability(.contentSize)
        #endif
    }

    private var operatorLocale: Locale {
        switch OperatorLanguage(rawValue: operatorLanguage) ?? .system {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .thai: return Locale(identifier: "th")
        }
    }
}

private struct ProtectedSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isUnlocked = false

    var body: some View {
        Group {
            if isUnlocked {
                SettingsView(onResetPIN: { isUnlocked = false })
            } else {
                PINGateView(
                    mode: isPINSet() ? .verify : .setup,
                    onSuccess: { isUnlocked = true },
                    onCancel: { dismiss() }
                )
            }
        }
        .frame(
            minWidth: isUnlocked ? 760 : 380,
            minHeight: isUnlocked ? 500 : 340
        )
    }
}
