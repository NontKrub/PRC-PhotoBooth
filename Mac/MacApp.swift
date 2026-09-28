import SwiftUI
import SwiftData
import Security

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
        .defaultSize(width: 420, height: 580)
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
    private enum GateState {
        case checking
        case ready(AdminPINAccessState)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var isUnlocked = false
    @State private var gateState = GateState.checking
    @State private var confirmReset = false
    @State private var resetError: String?

    var body: some View {
        Group {
            if isUnlocked {
                SettingsView(onResetPIN: {
                    isUnlocked = false
                    refreshCredentialState()
                })
            } else {
                switch gateState {
                case .checking:
                    ProgressView("Checking Admin PIN…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready(.configured):
                    pinGate(mode: .verify)
                case .ready(.notConfigured):
                    pinGate(mode: .setup)
                case .ready(.unavailable(let status)):
                    credentialProblem(
                        title: "Admin credential unavailable",
                        detail: "PRC PhotoBooth could not access the saved Admin PIN.",
                        status: status
                    )
                case .ready(.malformed):
                    credentialProblem(
                        title: "Saved Admin PIN is invalid",
                        detail: "The saved Admin PIN was preserved. Retry or explicitly reset it to continue."
                    )
                }
            }
        }
        .frame(
            minWidth: isUnlocked ? 760 : 380,
            minHeight: isUnlocked ? 500 : 580
        )
        .onAppear(perform: refreshCredentialState)
        .confirmationDialog("Reset saved Admin PIN?", isPresented: $confirmReset) {
            Button("Reset Admin PIN", role: .destructive) {
                if clearPIN() {
                    resetError = nil
                    gateState = .ready(.notConfigured)
                } else {
                    resetError = "The saved Admin PIN could not be reset. Keychain access is still unavailable."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the saved Admin credential and opens PIN setup.")
        }
    }

    @ViewBuilder
    private func pinGate(mode: PINGateView.Mode) -> some View {
        PINGateView(
            mode: mode,
            onSuccess: { isUnlocked = true },
            onCancel: { dismiss() }
        )
    }

    private func credentialProblem(title: LocalizedStringKey, detail: LocalizedStringKey, status: OSStatus? = nil) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let status {
                Text(verbatim: "Keychain: \(credentialStatusName(status)) (\(status))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let resetError {
                Text(resetError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                Button("Retry", action: refreshCredentialState)
                    .buttonStyle(.bordered)
                Button("Reset Admin PIN…", role: .destructive) {
                    confirmReset = true
                }
                .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) { dismiss() }
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func refreshCredentialState() {
        resetError = nil
        gateState = .checking
        gateState = .ready(adminPINAccessState())
    }
}
