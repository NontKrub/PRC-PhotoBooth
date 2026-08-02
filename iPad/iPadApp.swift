import SwiftUI

@main
struct iPadApp: App {
    @State private var viewModel = iPadViewModel()

    var body: some Scene {
        WindowGroup {
            iPadContentView()
                .environment(viewModel)
                .preferredColorScheme(.dark)
        }
    }
}
