import SwiftUI
import SwiftData

@main
struct MacApp: App {
    @State private var coordinator = BoothCoordinator()

    var body: some Scene {
        WindowGroup("PRC PhotoBooth — Operator") {
            MacContentView()
                .environment(coordinator)
                .environment(coordinator.stateMachine)
                .modelContainer(DataStore.shared.container)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentSize)

        #if os(macOS)
        Settings {
            ProtectedSettingsView()
                .environment(coordinator)
        }
        #endif
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
        .frame(minWidth: 940, minHeight: 640)
    }
}
