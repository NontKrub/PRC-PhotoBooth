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
            case .processing:
                processingIndicator
            case .finished:
                if case .finished(let qr) = vm.stateMachine.phase {
                    FinishAndQRView(qrPayload: qr)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    previewTransportMenu
                }
                Spacer()
            }
            .padding(24)
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

    private var previewTransportMenu: some View {
        Menu {
            Section("Preview connection") {
                Button {
                    vm.selectPreviewTransport(.wireless)
                } label: {
                    Label("Wireless", systemImage: vm.previewTransport == .wireless ? "checkmark" : "wifi")
                }

                Button {
                    vm.selectPreviewTransport(.usb)
                } label: {
                    Label(vm.usbPreviewConnected ? "USB cable" : "USB cable (not connected)",
                          systemImage: vm.previewTransport == .usb ? "checkmark" : "cable.connector")
                }
            }

            Section {
                Text("Controls remain connected over Wi-Fi. USB carries the live preview.")
            }
        } label: {
            Image(systemName: vm.previewTransport == .usb ? "cable.connector" : "wifi")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.4), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        }
        .accessibilityLabel("Preview connection")
    }
}
