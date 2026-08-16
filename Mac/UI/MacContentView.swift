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

            AdminDashboardView(onPINReset: beginPINReset)
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

    private func beginPINReset() {
        clearPIN()
        isAdminUnlocked = false
        pendingTab = selectedTab
        showPINSetup = true
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(BoothCoordinator.self) private var coordinator
    @Environment(\.locale) private var locale

    @AppStorage("selphyPaperSize")       private var paperSize      = SelphyPaperSize.postcard.rawValue
    @AppStorage("selphyCopies")          private var copies         = 1
    @AppStorage("selphySkipPrintDialog") private var skipDialog     = false
    @AppStorage("selphyPrinterName")     private var printerName    = ""
    @AppStorage("selphyAutoPrintAfterSession") private var autoPrint = false

    @AppStorage("cloudUploadEnabled")    private var cloudEnabled   = false
    @AppStorage("cloudSSHHost")          private var sshHost        = ""
    @AppStorage("cloudRemotePath")       private var remotePath     = CloudUploadConfiguration.defaultRemoteBasePath
    @AppStorage("publicBaseURL")         private var publicBaseURL  = ""
    @AppStorage("operatorLanguage")      private var operatorLanguage = OperatorLanguage.system.rawValue
    @AppStorage(BoothCoordinator.eventFolderPathKey) private var eventFolderPath = ""
    @State private var selectedScreenIndex = 0
    @State private var showCloudSSHSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                operatorLanguageSection
                cameraFeatureStatusSection
                ipadSection
                externalDisplaySection
                eventFolderSection
                printerSection
                cloudSection
            }
            .padding(24)
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showCloudSSHSetup) {
            CloudSSHSetupView(setup: coordinator.cloudSSHSetup)
        }
        .onChange(of: skipDialog) { _, value in
            if !value { autoPrint = false }
            coordinator.printer.invalidateTestResult()
        }
        .onChange(of: printerName) { _, _ in coordinator.printer.invalidateTestResult() }
        .onChange(of: paperSize) { _, _ in coordinator.printer.invalidateTestResult() }
        .task {
            coordinator.printer.refreshPrinters()
            if !skipDialog { autoPrint = false }
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
                    Label("No iPads connected", systemImage: "ipad.slash")
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
                    Text("Preview frame rate is independent of the selected network route. 60 FPS uses more bandwidth.")
                        .font(.caption2).foregroundStyle(.secondary)
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

    // MARK: Printer

    private var printerSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Printer", selection: $printerName) {
                    Text("System Default").tag("")
                    ForEach(coordinator.printer.availablePrinterNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(width: 360)

                Text(printerStatusText)
                    .font(.caption)
                    .foregroundStyle(printerStatusColor)

                Picker("Paper Size", selection: $paperSize) {
                    ForEach(SelphyPaperSize.allCases, id: \.rawValue) {
                        Text(operatorPaperSizeName($0, locale: locale)).tag($0.rawValue)
                    }
                }
                .frame(width: 280)

                Stepper("Copies: \(copies)", value: $copies, in: 1...5)

                Toggle("Skip system print dialog", isOn: $skipDialog)
                    .help("Suppresses the macOS print dialog. Enable Automatic Printing separately to print after each session.")

                Toggle("Automatic Printing", isOn: $autoPrint)
                    .disabled(!skipDialog || !printerIsConfigured)
                    .help("Prints the strip after required download jobs succeed.")

                Button("Test Print") {
                    Task { try? await coordinator.printer.printTestPage() }
                }
                .buttonStyle(.bordered)
                .disabled(coordinator.printer.isPrinting || !printerIsConfigured)

                Divider()

                Button("Open System Print Settings…") {
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
        case .systemDefault: return NSPrinter.printerNames.contains(NSPrintInfo.shared.printer.name)
        case .available: return true
        case .unavailable: return false
        }
    }

    private var printerStatusText: String {
        switch coordinator.printer.configuredPrinterStatus() {
        case .systemDefault: return operatorString("Using the macOS System Default printer.", locale: locale)
        case .available(let name): return operatorFormat("Configured printer: %@", locale: locale, name)
        case .unavailable(let name): return operatorFormat("Configured printer unavailable: %@", locale: locale, name)
        }
    }

    private var printerStatusColor: Color {
        if case .unavailable = coordinator.printer.configuredPrinterStatus() { return .red }
        return .secondary
    }
}
