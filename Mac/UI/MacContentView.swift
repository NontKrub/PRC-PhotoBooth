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

    var body: some View {
        TabView(selection: $selectedTab) {
            OperatorConsoleView()
                .tabItem { Label("Console", systemImage: "camera.viewfinder") }
                .tag(0)

            EventSetupView()
                .tabItem { Label("Event Setup", systemImage: "slider.horizontal.3") }
                .tag(1)

            AdminDashboardView(onPINReset: beginPINReset)
                .tabItem { Label("Analytics", systemImage: "chart.bar") }
                .tag(2)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(3)
        }
        .frame(minWidth: 940, minHeight: 640)
        .onChange(of: selectedTab) { old, new in
            if new == 1 || new == 2 || new == 3 {
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

    private func beginPINReset() {
        clearPIN()
        isAdminUnlocked = false
        pendingTab = selectedTab
        showPINSetup = true
    }
}

// MARK: - Settings tab

private struct SettingsView: View {
    @Environment(BoothCoordinator.self) private var coordinator

    @AppStorage("selphyPaperSize")       private var paperSize      = SelphyPaperSize.postcard.rawValue
    @AppStorage("selphyCopies")          private var copies         = 1
    @AppStorage("selphySkipPrintDialog") private var skipDialog     = false

    @AppStorage("cloudUploadEnabled")    private var cloudEnabled   = false
    @AppStorage("cloudSSHHost")          private var sshHost        = ""
    @AppStorage("cloudRemotePath")       private var remotePath     = "/bk1/prc/photobooth"
    @AppStorage("publicBaseURL")         private var publicBaseURL  = ""
    @AppStorage(BoothCoordinator.eventFolderPathKey) private var eventFolderPath = ""
    @State private var selectedScreenIndex = 0
    @State private var showCloudSSHSetup = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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

    private func featureStatusRow(_ title: String, ready: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
            Text(title)
            Spacer()
            Text(ready ? "Ready" : "Unavailable")
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var ipadSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                let peers = coordinator.multipeer.connectedPeerNames
                if peers.isEmpty {
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

                // Preview connection mode — controls always use Wi-Fi; this only picks
                // which channel carries the live camera preview stream.
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Preview via", selection: Binding(
                        get: { coordinator.previewConnectionMode },
                        set: { coordinator.previewConnectionMode = $0 }
                    )) {
                        ForEach(PreviewConnectionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .labelsHidden()

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

                    Text("Session controls always use Wi-Fi. 60 FPS uses more bandwidth; choose cable preview for the smoothest result. Sony USB live view may be limited by the camera.")
                        .font(.caption2).foregroundStyle(.secondary)

                    if coordinator.previewConnectionMode == .cable {
                        supportRow(ok: coordinator.usbPreview.isSupported,
                                   okText: "Mac: cable preview ready",
                                   failText: "Mac: cable preview service unavailable")
                        supportRow(ok: coordinator.usbPreview.isClientConnected,
                                   okText: "iPad: connected via cable",
                                   failText: "iPad: not connected via cable — plug in, trust this Mac, and keep the iPad app open")
                    }
                }
            }
            .padding(4)
        } label: {
            Label("iPad", systemImage: "ipad")
                .font(.headline)
        }
    }

    private func supportRow(ok: Bool, okText: String, failText: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .font(.caption)
            Text(ok ? okText : failText)
                .font(.caption)
                .foregroundStyle(ok ? .primary : .secondary)
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
                        Text(sshHost.isEmpty ? "Not configured" : sshHost)
                            .textSelection(.enabled)
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
                    Text("Used in QR codes. Leave blank to use LAN IP instead.")
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
                Picker("Paper Size", selection: $paperSize) {
                    ForEach(SelphyPaperSize.allCases, id: \.rawValue) {
                        Text($0.rawValue).tag($0.rawValue)
                    }
                }
                .frame(width: 280)

                Stepper("Copies: \(copies)", value: $copies, in: 1...5)

                Toggle("Skip system print dialog (auto-print)", isOn: $skipDialog)
                    .help("Prints immediately after each session without showing the system print dialog.")

                Divider()

                Button("Open System Print Settings…") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Printers-Scanners-Settings")!
                    )
                }
            }
            .padding(4)
        } label: {
            Label("Printer (Canon Selphy CP1500)", systemImage: "printer")
                .font(.headline)
        }
    }
}
