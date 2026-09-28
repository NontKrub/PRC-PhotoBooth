import SwiftUI
import UIKit

@main
struct iPadApp: App {
    @StateObject private var viewModel = iPadViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            iPadContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
                .onAppear { applyScenePolicy(scenePhase) }
                .onChange(of: scenePhase) { phase in
                    applyScenePolicy(phase)
                    viewModel.handleScenePhase(phase)
                }
        }
    }

    private func applyScenePolicy(_ phase: ScenePhase) {
        UIApplication.shared.isIdleTimerDisabled = phase == .active
    }
}
