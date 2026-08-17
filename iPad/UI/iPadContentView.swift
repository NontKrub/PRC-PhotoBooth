import SwiftUI

struct iPadContentView: View {
    @Environment(iPadViewModel.self) private var vm

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch CustomerDisplayWorkflow.screen(for: vm.stateMachine.phase) {
            case .idle:
                IdleView()
            case .selectingExperience:
                ExperienceSelectionView()
            case .readyToStart:
                StartView()
            case .countdown(let idx, let secs):
                CountdownView(photoIndex: idx, secondsRemaining: secs)
            case .review(let idx):
                ReviewView(photoIndex: idx)
            case .captureRecovery(let idx, let failure):
                CaptureRecoveryView(photoIndex: idx, failure: failure)
            case .processing:
                processingIndicator
            case .finished:
                if case .finished(let qr) = vm.stateMachine.phase {
                    FinishAndQRView(qrPayload: qr)
                }
            }

            if vm.isBoothPaused && vm.stateMachine.phase == .idle {
                Color.black.opacity(0.94).ignoresSafeArea()
                VStack(spacing: 16) {
                    Image(systemName: "pause.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white)
                    Text("Booth temporarily unavailable")
                        .font(.title.bold())
                        .foregroundStyle(.white)
                    Text("Please wait for staff")
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .environment(\.locale, Locale(identifier: vm.selectedLanguage.localeIdentifier))
    }

    var processingIndicator: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(2)
                .tint(.white)
            Text("Processing…")
                .foregroundStyle(.white)
                .font(.title2)
        }
    }

}
