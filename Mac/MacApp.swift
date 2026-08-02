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
            Text("Settings").padding()
        }
        #endif
    }
}
