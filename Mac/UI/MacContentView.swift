import SwiftUI
import AppKit

struct MacContentView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @State private var selectedTab = 0
    @State private var showPINSetup = false
    @State private var showPINVerify = false
    @State private var pendingTab: Int? = nil
    @State private var isAdminUnlocked = false
    @State private var showCloudSSHSetup = false
    @AppStorage("operatorLanguage") private var operatorLanguage = OperatorLanguage.system.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            OperatorConsoleView(onOpenOperations: { selectedTab = 1 })
                .tabItem { Label("Console", systemImage: "camera.viewfinder") }
                .tag(0)

            OperationsView()
                .tabItem { Label("Operations", systemImage: "checklist") }
                .tag(1)

            EventSetupView()
                .tabItem { Label("Event Setup", systemImage: "slider.horizontal.3") }
                .tag(2)

            AdminDashboardView()
                .tabItem { Label("Analytics", systemImage: "chart.bar") }
                .tag(3)
        }
        .frame(minWidth: 940, minHeight: 640)
        .environment(\.locale, operatorLocale)
        .onChange(of: selectedTab) { old, new in
            if new == 2 || new == 3 {
                guard !isAdminUnlocked else { return }
                selectedTab = old  // revert immediately
                pendingTab = new
                if isPINSet() {
                    showPINVerify = true
                } else {
                    showPINSetup = true
                }
            }
        }
        .sheet(isPresented: $showPINSetup) {
            PINGateView(mode: .setup) {
                showPINSetup = false
                isAdminUnlocked = true
                if let t = pendingTab { selectedTab = t; pendingTab = nil }
            } onCancel: {
                showPINSetup = false; pendingTab = nil
            }
        }
        .sheet(isPresented: $showPINVerify) {
            PINGateView(mode: .verify) {
                showPINVerify = false
                isAdminUnlocked = true
                if let t = pendingTab { selectedTab = t; pendingTab = nil }
            } onCancel: {
                showPINVerify = false; pendingTab = nil
            }
        }
        .alert("Error", isPresented: Binding(
            get: { coordinator.errorMessage != nil },
            set: { if !$0 { coordinator.errorMessage = nil } }
        )) {
            Button("OK") { coordinator.errorMessage = nil }
        } message: {
            Text(coordinator.errorMessage ?? "")
        }
        .sheet(isPresented: $showCloudSSHSetup) {
            CloudSSHSetupView(setup: coordinator.cloudSSHSetup)
        }
        .task {
            if coordinator.cloudSSHSetup.shouldPresentFirstRun {
                showCloudSSHSetup = true
            }
        }
    }

    private var operatorLocale: Locale {
        switch OperatorLanguage(rawValue: operatorLanguage) ?? .system {
        case .system: return .autoupdatingCurrent
        case .english: return Locale(identifier: "en")
        case .thai: return Locale(identifier: "th")
        }
    }

}

// MARK: - Settings

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case camera = "Camera"
    case network = "iPad & Network"
    case display = "Display"
    case printing = "Printing"
    case cloud = "Cloud"
    case security = "Security"

    var id: String { rawValue }
}

struct SettingsView: View {
    let onResetPIN: () -> Void

    init(onResetPIN: @escaping () -> Void = {}) {
        self.onResetPIN = onResetPIN
    }

    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.locale) private var locale

    @AppStorage("selphyAutoPrintAfterSession") private var autoPrint = false

    @AppStorage("cloudUploadEnabled")    private var cloudEnabled   = false
    @AppStorage("cloudSSHHost")          private var sshHost        = ""
    @AppStorage("cloudRemotePath")       private var remotePath     = CloudUploadConfiguration.defaultRemoteBasePath
    @AppStorage("publicBaseURL")         private var publicBaseURL  = ""
    @AppStorage("operatorLanguage")      private var operatorLanguage = OperatorLanguage.system.rawValue
    @AppStorage(BoothCoordinator.eventFolderPathKey) private var eventFolderPath = ""
    @State private var selectedScreenIndex = 0
    @State private var selectedSection: SettingsSection = .general
    @State private var showCloudSSHSetup = false
    @State private var showResetPINConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Settings section", selection: $selectedSection) {
                ForEach(SettingsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)

            Divider().padding(.top, 14)

            ScrollView {
                settingsPage
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showCloudSSHSetup) {
            CloudSSHSetupView(setup: coordinator.cloudSSHSetup)
        }
        .task {
            coordinator.printer.refreshPrinters()
        }
    }

    @ViewBuilder
    private var settingsPage: some View {
        switch selectedSection {
        case .general:
            VStack(alignment: .leading, spacing: 24) {
                operatorLanguageSection
                eventFolderSection
            }
        case .camera:
            cameraFeatureStatusSection
        case .network:
            ipadSection
        case .display:
            externalDisplaySection
        case .printing:
            printerSection
        case .cloud:
            cloudSection
        case .security:
            securitySection
        }
    }

    private var operatorLanguageSection: some View {
        GroupBox("Application Language") {
            Picker("Language", selection: $operatorLanguage) {
                Text("System").tag(OperatorLanguage.system.rawValue)
                Text("English").tag(OperatorLanguage.english.rawValue)
                Text("ไทย").tag(OperatorLanguage.thai.rawValue)
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: iPad

    private var cameraFeatureStatusSection: some View {
        let dslr = coordinator.capture.dslr
        let support = dslr.controlSupport
        let hasFallbackPreview = coordinator.capture.camera.availableDevices.contains {
            $0.id == coordinator.capture.camera.selectedDeviceID && $0.kind != .builtIn
        }
        let previewReady = dslr.isLivePreviewActive || hasFallbackPreview

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                featureStatusRow("Connect", ready: dslr.isRunning)
                featureStatusRow("Capture", ready: dslr.isRunning && coordinator.capture.usesDSLR)
                featureStatusRow("Live Preview", ready: previewReady)
                featureStatusRow("Last Capture Preview", ready: dslr.lastCapturedImage != nil)
                featureStatusRow("ISO", ready: support.iso)
                featureStatusRow("Flash", ready: support.flash)
                featureStatusRow("Shutter Speed", ready: support.shutter)
                featureStatusRow("Aperture", ready: support.aperture)
            }
            .padding(4)
        } label: {
            Label("Feature Status", systemImage: "checklist")
                .font(.headline)
        }
    }

    private func featureStatusRow(_ title: LocalizedStringKey, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
            Text(title)
            Spacer()
            Text(LocalizedStringKey(ready ? "Ready" : "Unavailable"))
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var ipadSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                let status = coordinator.connectionStatus
                let peers = status.connectedPeerNames
                if case .connected = status.state {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Connected: \(status.peerDisplayName ?? "iPad")", systemImage: "ipad")
                        Text(connectionRouteDescription(status))
                            .font(.caption)
                            .foregroundStyle(status.isFallbackActive ? .orange : .secondary)
                    }
                } else if case .connecting = status.state {
                    Label(operatorConnectingRoute(status, locale: locale), systemImage: "network")
                        .foregroundStyle(.secondary)
                } else if peers.isEmpty {
                    Label("No iPads connected", systemImage: "ipad.slash")
                        .foregroundStyle(.secondary)
                } else if peers.count == 1 {
                    Label(peers[0], systemImage: "ipad")
                } else {
                    Picker("Active iPad", selection: Binding(
                        get: { coordinator.multipeer.activePeerName ?? peers[0] },
                        set: { coordinator.multipeer.activePeerName = $0 }
                    )) {
                        ForEach(peers, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 300)
                    Text("Only the selected iPad receives session controls.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Picker("Connection", selection: Binding(
                        get: { coordinator.requestedNetworkPreference },
                        set: { coordinator.requestedNetworkPreference = $0 }
                    )) {
                        Text("Wi-Fi").tag(BoothNetworkPreference.wifi)
                        Text("LAN").tag(BoothNetworkPreference.lan)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .labelsHidden()

                    Text(coordinator.requestedNetworkPreference == .wifi
                         ? "Use the wireless network for iPad control and live preview."
                         : "Prefer wired Ethernet for iPad control and live preview. Automatically falls back to Wi-Fi when wired LAN is unavailable.")
                        .font(.caption2).foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Image(systemName: status.isLANPathAvailable ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(status.isLANPathAvailable ? .green : .secondary)
                        Text(status.isLANPathAvailable ? "Ethernet available" : "Ethernet unavailable")
                            .font(.caption)
                    }

                    if status.isFallbackActive {
                        Label("LAN is unavailable. Wi-Fi fallback is active.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Picker("Preview quality", selection: Binding(
                        get: { coordinator.previewQualityPreset },
                        set: { coordinator.previewQualityPreset = $0 }
                    )) {
                        ForEach(PreviewQualityPreset.allCases) { preset in
                            Text(preset.rawValue.capitalized).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    Text("Auto uses Standard on Wi-Fi and High on a stable Ethernet route.")
                        .font(.caption2).foregroundStyle(.secondary)

                    Picker("Preview frame rate", selection: Binding(
                        get: { coordinator.previewFrameRate },
                        set: { coordinator.previewFrameRate = $0 }
                    )) {
                        ForEach(PreviewFrameRate.allCases) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .disabled(coordinator.previewQualityPreset == .high)
                    Text("Preview frame rate is independent of the selected network route. 60 FPS uses more bandwidth.")
                        .font(.caption2).foregroundStyle(.secondary)

                    Button {
                        coordinator.testEthernetConnection()
                    } label: {
                        Label(
                            coordinator.ethernetTestInProgress ? "Testing Ethernet…" : "Test Ethernet Connection",
                            systemImage: "cable.connector"
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(coordinator.ethernetTestInProgress || coordinator.isCaptureSessionActive)

                    if let result = coordinator.ethernetTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.hasPrefix("✓") ? .green : .orange)
                    }

                    Divider()
                    networkDiagnostics(status)
                }
            }
            .padding(4)
        } label: {
            Label("iPad", systemImage: "ipad")
                .font(.headline)
        }
    }

    private func connectionRouteDescription(_ status: BoothConnectionStatus) -> String {
        switch status.effectiveNetwork {
        case .wifi where status.isFallbackActive: return "Using Wi-Fi fallback"
        case .wifi: return "Using Wi-Fi"
        case .lan: return "Connected via Ethernet"
        case .unavailable: return "Network route unavailable"
        }
    }

    private func networkDiagnostics(_ status: BoothConnectionStatus) -> some View {
        let metrics = status.previewDiagnostics
        return VStack(alignment: .leading, spacing: 6) {
            Text("Network diagnostics").font(.headline)
            diagnosticRow("Requested connection", status.requestedNetwork == .lan ? "LAN" : "Wi-Fi")
            diagnosticRow("Effective connection", connectionRouteDescription(status))
            diagnosticRow("Ethernet path observation", pathObservationText(status.lanPathObservation))
            diagnosticRow("Wi-Fi path observation", pathObservationText(status.wifiPathObservation))
            diagnosticRow("Control channel", connectionStateText(status.state))
            diagnosticRow("Preview channel", status.isPreviewChannelConnected ? "Connected" : "Disconnected")
            diagnosticRow("Peer", status.peerDisplayName ?? "None")
            diagnosticRow("LAN handshake", handshakeText(status.lanHandshake))
            diagnosticRow("Last network error", status.lastNetworkError ?? "None")
            diagnosticRow("Preview FPS", String(format: "%.1f", metrics.fps))
            diagnosticRow("Preview throughput", ByteCountFormatter.string(fromByteCount: Int64(metrics.bytesPerSecond), countStyle: .file) + "/s")
            diagnosticRow("Frames submitted", "\(metrics.framesSubmitted)")
            diagnosticRow("Frames sent", "\(metrics.framesSent)")
            diagnosticRow("Frames coalesced", "\(metrics.framesCoalesced)")
        }
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }

    private func pathObservationText(_ observation: BoothPathObservation) -> String {
        switch observation {
        case .unknown: return "Unknown"
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        }
    }

    private func handshakeText(_ state: BoothLANHandshakeState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .timeout: return "Timeout"
        case .failed: return "Failed"
        }
    }

    private func connectionStateText(_ state: BoothConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }

    // MARK: External display

    private var externalDisplaySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if coordinator.externalScreens.isEmpty {
                    Label("No external monitor detected", systemImage: "display.trianglebadge.exclamationmark")
                        .foregroundStyle(.secondary)
                    Text("Connect a second display to use it as a customer-facing viewer instead of an iPad.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("Monitor", selection: $selectedScreenIndex) {
                        ForEach(Array(coordinator.externalScreens.enumerated()), id: \.offset) { i, screen in
                            Text(screen.localizedName).tag(i)
                        }
                    }
                    .frame(width: 300)

                    if coordinator.isExternalViewerActive {
                        Button("Hide Viewer") { coordinator.hideExternalViewer() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Show Viewer") {
                            guard selectedScreenIndex < coordinator.externalScreens.count else { return }
                            coordinator.showExternalViewer(on: coordinator.externalScreens[selectedScreenIndex])
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    Text("Mirrors the idle/countdown/review/finish screens the iPad shows, driven by this Mac directly.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("External Monitor Viewer", systemImage: "tv")
                .font(.headline)
        }
    }

    // MARK: Cloud upload

    private var eventFolderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Event folder") {
                    Text(eventFolderPath.isEmpty ? coordinator.eventFolderPath : eventFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Button("Choose Event Folder…", action: chooseEventFolder)
                    .buttonStyle(.bordered)

                Text("New sessions save here. Existing files are not moved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        } label: {
            Label("Event Output", systemImage: "folder")
                .font(.headline)
        }
    }

    private func chooseEventFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        coordinator.setEventFolder(url)
    }

    private var cloudSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Upload photos to cloud after each session", isOn: $cloudEnabled)
                    .disabled(coordinator.cloudSSHSetup.state != .complete)

                HStack(spacing: 8) {
                    Image(systemName: coordinator.cloudSSHSetup.state == .complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(coordinator.cloudSSHSetup.state == .complete ? .green : .orange)
                    Text(coordinator.cloudSSHSetup.statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Cloud SSH Setup…") {
                    showCloudSSHSetup = true
                }
                .buttonStyle(.bordered)

                if cloudEnabled {
                    Divider()

                    LabeledContent("SSH Host") {
                        if sshHost.isEmpty {
                            Text("Not configured")
                        } else {
                            Text(sshHost)
                        }
                    }
                    Text("Managed by Cloud SSH Setup in ~/.ssh/config, using Cloudflare Access.")
                        .font(.caption).foregroundStyle(.secondary)

                    LabeledContent("Remote path") {
                        TextField("/bk1/prc/photobooth", text: $remotePath)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                    }

                    LabeledContent("Public base URL") {
                        TextField("https://yourdomain.com (optional)", text: $publicBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 280)
                    }
                    Text("Used in QR codes after cloud upload succeeds. Leave blank to use the LAN server.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
        } label: {
            Label("Cloud Upload (Cloudflare Tunnel)", systemImage: "cloud.fill")
                .font(.headline)
        }
    }

    private var securitySection: some View {
        GroupBox("Admin Access") {
            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Admin PIN") {
                    Text(isPINSet() ? "Configured" : "Not configured")
                        .foregroundStyle(isPINSet() ? .green : .orange)
                }
                Button("Reset Admin PIN…", role: .destructive) {
                    showResetPINConfirmation = true
                }
                Text("Resetting re-locks Settings and requires PIN setup before protected access.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
        .confirmationDialog("Reset Admin PIN?", isPresented: $showResetPINConfirmation) {
            Button("Reset PIN", role: .destructive) {
                clearPIN()
                onResetPIN()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be asked to create a new PIN the next time Settings is opened.")
        }
    }

    // MARK: Printer

    private var printerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Text(printerStatusText)
                    .font(.caption)
                    .foregroundStyle(printerStatusColor)

                Toggle("Automatic Printing", isOn: $autoPrint)
                    .disabled(!printerIsConfigured)
                    .help("Prints the strip after required download jobs succeed.")

                Button("Print Test…") {
                    Task { try? await coordinator.printer.printTestPage() }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.printer.isPrinting)

                Divider()

                Button("Open Printers & Scanners…") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Printers-Scanners-Settings")!
                    )
                }
            }
            .padding(4)
        } label: {
            Label("Printer", systemImage: "printer")
                .font(.headline)
        }
    }

    private var printerIsConfigured: Bool {
        switch coordinator.printer.configuredPrinterStatus() {
        case .systemDefault: return true
        case .unavailable: return false
        }
    }

    private var printerStatusText: String {
        switch coordinator.printer.configuredPrinterStatus() {
        case .systemDefault: return "System default: \(NSPrintInfo.shared.printer.name)"
        case .unavailable(let name): return "System printer unavailable: \(name)"
        }
    }

    private var printerStatusColor: Color {
        if case .unavailable = coordinator.printer.configuredPrinterStatus() { return .red }
        return .secondary
    }
}
