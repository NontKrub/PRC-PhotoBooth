import SwiftUI

@main
struct iPadApp: App {
    @StateObject private var viewModel = iPadViewModel()

    var body: some Scene {
        WindowGroup {
            iPadContentView()
                .environmentObject(viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
