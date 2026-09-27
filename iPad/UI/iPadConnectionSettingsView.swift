import SwiftUI
import UniformTypeIdentifiers

struct iPadConnectionSettingsView: View {
    @EnvironmentObject private var vm: iPadViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var editedDeviceName = ""
    @State private var showPINEntry = false
    @State private var showQRScanner = false
    @State private var selectedPeerForPIN: String?
    @State private var automaticPairingPeerID: String?
    @State private var lastPairingPeerID: String?
    @State private var selectedPairingMacName: String?
    @State private var peerToForget: String?
    @State private var pairingError: String?
    @State private var diagnosticsExportError: String?
    @State private var diagnosticsDocument = ConnectionLogDocument(text: "")
    @State private var isExportingDiagnostics = false
    @State private var discoveryCache = BoothDiscoveryPresentationCache()
    @State private var discoveryNow = Date()

    private var transport: NetworkBoothTransport? { vm.networkTransport }
    private var status: BoothConnectionStatus { vm.connectionStatus }
    private var discoveredMacs: [BoothDiscoveredPeer] { status.discoveredPeers.filter { $0.role == .mac } }
    private var nearbyMacs: [BoothNearbyMacPresentation] {
        discoveryCache.nearbyMacs(
            at: discoveryNow,
            trustedPeers: transport?.trustedPeers ?? [],
            preferredPeerID: status.preferredPeerID
        )
    }
    private var hasActiveControlAttempt: Bool {
        transport?.hasActiveControlAttempt ?? (status.peerID != nil)
    }
    private var hasPreferredControlAttempt: Bool {
        guard let preferredID = status.preferredPeerID,
              hasActiveControlAttempt else { return false }
        return status.peerID == preferredID
            || transport?.discoveryDiagnostics.targetPeerID == preferredID
    }
    private var preferredMac: BoothPreferredMacPresentation {
        BoothPreferredMacPresentation.resolve(
            preferredPeerID: status.preferredPeerID,
            trustedPeers: transport?.trustedPeers ?? [],
            nearbyMacs: nearbyMacs,
            connectionState: status.state,
            connectedPeerID: status.peerID,
            isAuthenticated: status.isPeerAuthenticated,
            isSecureChannelEstablished: status.isSecureChannelEstablished,
            isReconnectInProgress: status.isReconnectInProgress,
            hasPreferredControlAttempt: hasPreferredControlAttempt
        )
    }
    private var connectionTransitionInProgress: Bool {
        if status.pairingStage == .verificationPending { return true }
        if status.preferredPeerID == nil {
            switch status.pairingState {
            case .idle, .authenticated:
                return false
            default:
                break
            }
        }
        guard hasActiveControlAttempt else { return false }
        if case .connecting = status.state { return true }
        if case .connected = status.state,
           status.peerID == status.preferredPeerID,
           (!status.isPeerAuthenticated || !status.isSecureChannelEstablished) {
            return true
        }
        return status.isReconnectInProgress || status.pairingStage == .authenticating
    }
    private var canChangeConnection: Bool {
        vm.canChangeConnection && !connectionTransitionInProgress
    }

    var body: some View {
        NavigationStack {
            List {
                thisIPadSection
                preferredMacSection
                connectedMacSection
                nearbyMacsSection
                pairingSection
                diagnosticsSection
            }
            .navigationTitle("Mac Connection")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileExporter(
            isPresented: $isExportingDiagnostics,
            document: diagnosticsDocument,
            contentType: .plainText,
            defaultFilename: "PRC-PhotoBooth-iPad-connection-log"
        ) { result in
            if case .failure(let error) = result {
                diagnosticsExportError = error.localizedDescription
            }
        }
        .task {
            if editedDeviceName.isEmpty {
                editedDeviceName = transport?.deviceIdentity.displayName ?? "PRC Booth iPad"
            }
            discoveryCache.update(status.discoveredPeers, at: Date())
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                discoveryNow = Date()
                discoveryCache.pruneExpired(at: discoveryNow)
            }
        }
        .onChange(of: status.discoveredPeers) { discoveries in
            discoveryNow = Date()
            discoveryCache.update(discoveries, at: discoveryNow)
        }
        .onChange(of: status.pairingState) { pairingState in
            switch pairingState {
            case .pairing:
                if let automaticPairingPeerID {
                    selectedPeerForPIN = automaticPairingPeerID
                    self.automaticPairingPeerID = nil
                    showPINEntry = true
                }
            case .failed:
                self.automaticPairingPeerID = nil
                showPINEntry = false
            default:
                break
            }
        }
        .sheet(isPresented: $showPINEntry) {
            PairingPINEntryView(
                peers: discoveredMacs,
                initialPeerID: selectedPeerForPIN,
                initialPeerName: selectedPairingMacName
            ) { peerID, pin in
                lastPairingPeerID = peerID
                vm.pair(peerID: peerID, pin: pin)
            }
        }
        .sheet(isPresented: $showQRScanner) {
            PairingQRScannerView { rawValue in
                do {
                    let payload = try BoothPairingQRCodePayload.decode(rawValue)
                    lastPairingPeerID = payload.macDeviceID
                    vm.pair(qrPayload: payload)
                    pairingError = nil
                } catch {
                    pairingError = error.localizedDescription
                }
            } onEnterPIN: {
                showPINEntry = true
            }
        }
        .alert("Forget Device", isPresented: Binding(
            get: { peerToForget != nil },
            set: { if !$0 { peerToForget = nil } }
        )) {
            Button("Cancel", role: .cancel) { peerToForget = nil }
            Button("Forget", role: .destructive) {
                if let peerToForget { vm.forget(peerID: peerToForget) }
                peerToForget = nil
            }
        } message: {
            Text("This Mac must be paired again before it can reconnect.")
        }
        .alert("Pairing Error", isPresented: Binding(
            get: { pairingError != nil },
            set: { if !$0 { pairingError = nil } }
        )) {
            Button("OK", role: .cancel) { pairingError = nil }
        } message: {
            Text(pairingError ?? "")
        }
        .alert("Export Failed", isPresented: Binding(
            get: { diagnosticsExportError != nil },
            set: { if !$0 { diagnosticsExportError = nil } }
        )) {
            Button("OK", role: .cancel) { diagnosticsExportError = nil }
        } message: {
            Text(diagnosticsExportError ?? "")
        }
    }

    private var thisIPadSection: some View {
        Section("This iPad") {
            TextField("Device Name", text: $editedDeviceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!canChangeConnection)
                .onSubmit { vm.renameDevice(editedDeviceName) }
            Button("Save Device Name") { vm.renameDevice(editedDeviceName) }
                .disabled(!canChangeConnection || editedDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var preferredMacSection: some View {
        Section("Preferred Mac") {
            if preferredMac.peerID != nil {
                Text(preferredMac.displayName)
                    .font(.headline)
            }

            switch preferredMac.state {
            case .none:
                Text("No Mac selected")
                    .foregroundStyle(.secondary)
            case .connected:
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .reconnecting:
                Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            case .available:
                Label("Available", systemImage: "wifi")
                    .foregroundStyle(.secondary)
            case .notConnected:
                Label("Preferred Mac unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if transport?.preferredPeerNeedsRepair == true {
                Label("Pairing key missing", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Forget this Mac on both devices, then pair again with PIN or QR.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let preferredID = preferredMac.peerID {
                if !((transport?.preferredPeerNeedsRepair) ?? false),
                   preferredMac.state == .available || preferredMac.state == .notConnected {
                    HStack {
                        Button("Reconnect") {
                            if transport?.trustedPeers.contains(where: { $0.id == preferredID }) == true {
                                vm.connect(to: preferredID)
                            } else {
                                vm.refreshNearbyMacs()
                            }
                        }
                        .disabled(!canChangeConnection)
                        .accessibilityIdentifier("Retry Preferred Mac")

                        Button("Choose Another Mac") {
                            transport?.selectPreferredPeer(nil)
                        }
                        .disabled(!vm.canChangeConnection || status.pairingStage == .verificationPending)
                        .accessibilityIdentifier("Choose Another Mac")
                    }
                }

                if preferredMac.state == .reconnecting {
                    Button("Stop Reconnecting") {
                        transport?.selectPreferredPeer(nil)
                    }
                    .disabled(!vm.canChangeConnection || status.pairingStage == .verificationPending)
                }

                if let transport {
                    Toggle("Automatically reconnect to selected Mac", isOn: Binding(
                        get: { transport.automaticallyReconnectToPreferredPeer },
                        set: { transport.automaticallyReconnectToPreferredPeer = $0 }
                    ))
                    .disabled(!canChangeConnection)
                }
                Button("Forget Preferred Mac", role: .destructive) {
                    peerToForget = preferredID
                }
                .disabled(!vm.canChangeConnection || status.pairingStage == .verificationPending)
                .accessibilityIdentifier("Forget Mac")
            }
        }
    }

    @ViewBuilder
    private var connectedMacSection: some View {
        Section("Connection") {
            if status.pairingStage == .verificationPending,
               let code = transport?.pairingVerificationCodeForDisplay,
               let name = resolvedPeerName(status.peerID, fallback: status.peerDisplayName ?? transport?.pairingPeerDisplayName) {
                Label(name, systemImage: "checkmark.shield")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("Pairing Verification Mac")
                Text("Verify connection")
                    .font(.headline)
                    .accessibilityIdentifier("Pairing Verification Status")
                Text("Confirm that this code matches the one shown on the Mac:")
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .accessibilityLabel("Verification code " + code.map { String($0) }.joined(separator: " "))
                    .accessibilityIdentifier("Pairing Verification Code")
                Text("Ask the operator to tap Codes Match on the Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if case .connected = status.state,
                      status.isPeerAuthenticated,
                      status.isSecureChannelEstablished {
                Label(connectedMacName, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("Connected Mac")
                LabeledContent("Authentication", value: "Trusted")
                LabeledContent("Connection", value: connectionLabel)
                LabeledContent("Secure transport", value: "Ready")
                LabeledContent("Asset delivery", value: status.isAssetChannelReady ? "Ready" : "Reconnecting")
                if let latency = status.roundTripLatency {
                    LabeledContent("Round trip", value: "\(Int(latency * 1000)) ms")
                }
            } else if connectionTransitionInProgress {
                Label(connectedMacName, systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("Reconnecting Mac")
                LabeledContent("Authentication", value: status.isPeerAuthenticated ? "Securing connection" : "Authenticating")
                LabeledContent("Connection", value: connectionLabel)
            } else {
                switch status.pairingState {
                case .idle, .authenticated:
                    if status.preferredPeerID == nil {
                        Text("Select or pair a Mac.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }
                case .authenticating where !hasActiveControlAttempt:
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                case .failed(let reason):
                    Text(reason)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("Pairing Failure")
                    Button("Retry Pairing") { retryPairing() }
                        .disabled(!canChangeConnection)
                        .accessibilityIdentifier("Pairing Retry")
                case .pairing(let expiresAt):
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pairingStateText)
                            .accessibilityIdentifier("Pairing Status")
                        HStack(spacing: 4) {
                            Text("Expires in")
                            Text(expiresAt, style: .timer)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Pairing Expiry")
                    }
                case .waitingForMac:
                    VStack(alignment: .leading, spacing: 4) {
                        Text(pairingStateText)
                            .accessibilityIdentifier("Pairing Status")
                        if let expiresAt = transport?.pairingExpiresAt {
                            HStack(spacing: 4) {
                                Text("Expires in")
                                Text(expiresAt, style: .timer)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("Pairing Expiry")
                        }
                    }
                default:
                    Text(pairingStateText)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("Pairing Status")
                }
            }
        }
    }

    @ViewBuilder
    private var nearbyMacsSection: some View {
        Section("Nearby Macs") {
            if nearbyMacs.isEmpty {
                if preferredMac.state == .reconnecting {
                    Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.secondary)
                } else if (transport?.discoveryDiagnostics.activeBrowserCount ?? 0) > 0 {
                    HStack {
                        ProgressView()
                        Text("Searching for Macs…")
                    }
                } else {
                    Text("No Macs found")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(nearbyMacs) { peer in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName)
                                    .font(.headline)
                                Text(peer.isStale
                                     ? "Recently seen"
                                     : "\(peer.appVersion) • \(transportLabel(peer.availableInterfaces))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if peer.isPreferred {
                                Label("Preferred", systemImage: "star.fill")
                                    .font(.caption)
                            }
                        }

                        if peer.isStale {
                            Label(peer.isPreferred ? "Reconnecting…" : "Recently seen", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if peer.protocolVersion != 0,
                           peer.protocolVersion != BoothTransportHello.currentProtocolVersion {
                            Text("Version incompatible")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            HStack {
                                Text(peer.isTrusted ? "Trusted" : "Not Paired")
                                    .font(.caption)
                                    .foregroundStyle(peer.isTrusted ? .green : .orange)
                                Spacer()
                                if peer.isTrusted {
                                    Button("Connect") {
                                        lastPairingPeerID = peer.id
                                        vm.connect(to: peer.id)
                                    }
                                        .disabled(!canChangeConnection || status.peerID == peer.id && status.isPeerAuthenticated && status.isSecureChannelEstablished)
                                        .accessibilityIdentifier("Connect Mac")
                                } else {
                                    Button("Connect") {
                                        startPairing(with: peer.id)
                                    }
                                    .disabled(!canChangeConnection)
                                    .accessibilityIdentifier("Connect Mac")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("Nearby Mac")
                }
            }

            Button("Refresh") { vm.refreshNearbyMacs() }
                .disabled(!canChangeConnection)
        }
    }

    private var pairingSection: some View {
        Section("Pairing") {
            Button {
                showQRScanner = true
            } label: {
                Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
            }
            .disabled(!canChangeConnection)
            .accessibilityHint("Recommended for the fastest pairing.")
            .accessibilityIdentifier("Scan Pairing QR")

            Button {
                selectedPeerForPIN = lastPairingPeerID
                    ?? status.preferredPeerID
                    ?? discoveredMacs.first?.id
                selectedPairingMacName = nearbyMacs.first { $0.id == selectedPeerForPIN }?.displayName
                showPINEntry = true
            } label: {
                Label("Enter Pairing PIN", systemImage: "number.square")
            }
            .disabled(!canChangeConnection || (discoveredMacs.isEmpty && lastPairingPeerID == nil))
            .accessibilityIdentifier("Enter Pairing PIN")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            Button {
                diagnosticsDocument = ConnectionLogDocument(text: vm.connectionDiagnosticsReport())
                isExportingDiagnostics = true
            } label: {
                Label("Export Connection Log", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Saves a text log you can send to support. Pairing secrets are not included.")
            .accessibilityIdentifier("Export Connection Log")

            Text("Includes current connection, pairing, discovery, preview, and recent transport events.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var pairingStateText: String {
        switch status.pairingState {
        case .idle:
            return status.preferredPeerID == nil ? "Select or pair a Mac." : "Not connected"
        case .waitingForMac(let peerID):
            let macName = nearbyMacs.first { $0.id == peerID }?.displayName ?? "the selected Mac"
            return "Waiting for Mac…\nA pairing code will appear on \"\(macName)\"."
        case .pairing:
            return "Pairing"
        case .incoming:
            return "Pairing"
        case .authenticating:
            return "Authenticating"
        case .authenticated:
            return status.isPeerAuthenticated && status.isSecureChannelEstablished
                ? "Connected"
                : "Not connected"
        case .failed(let reason):
            return reason
        }
    }

    private func retryPairing() {
        guard let peerID = lastPairingPeerID
                ?? nearbyMacs.first(where: { !$0.isTrusted })?.id else { return }
        lastPairingPeerID = peerID
        selectedPairingMacName = nearbyMacs.first { $0.id == peerID }?.displayName
        automaticPairingPeerID = peerID
        vm.retryPairing(with: peerID)
    }

    private func startPairing(with peerID: String) {
        lastPairingPeerID = peerID
        selectedPairingMacName = nearbyMacs.first { $0.id == peerID }?.displayName
        automaticPairingPeerID = peerID
        vm.requestPairing(with: peerID)
    }

    private var connectionLabel: String {
        if case .disconnected = status.state { return "Disconnected" }
        if case .connecting = status.state { return "Reconnecting" }
        if status.isReconnectInProgress || !status.isPeerAuthenticated || !status.isSecureChannelEstablished {
            return "Reconnecting"
        }
        switch status.effectiveNetwork {
        case .lan: return "Connected via Ethernet"
        case .wifi: return status.isFallbackActive ? "Wi-Fi fallback" : "Connected via Wi-Fi"
        case .unavailable: return "Connecting"
        }
    }

    private func transportLabel(_ interfaces: Set<BoothNetworkInterfacePolicy>) -> String {
        if interfaces.contains(.wiredEthernet) && interfaces.contains(.wifi) { return "Ethernet + Wi-Fi" }
        if interfaces.contains(.wiredEthernet) { return "Ethernet" }
        if interfaces.contains(.wifi) { return "Wi-Fi" }
        return "Available"
    }

    private var connectedMacName: String {
        resolvedPeerName(status.peerID, fallback: status.peerDisplayName) ?? "Mac"
    }

    private func resolvedPeerName(_ peerID: String?, fallback: String?) -> String? {
        guard let peerID else {
            return BoothPeerDisplayName.usable(fallback, deviceID: "")
        }
        let trustedName = transport?.trustedPeers.first { $0.id == peerID }?.displayName
        let discoveredName = status.discoveredPeers.first { $0.id == peerID }?.displayName ?? fallback
        return BoothPeerDisplayName.resolve(
            trustedName: trustedName,
            discoveredName: discoveredName,
            deviceID: peerID,
            fallback: "Mac"
        )
    }
}

private struct ConnectionLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = String(
            data: configuration.file.regularFileContents ?? Data(),
            encoding: .utf8
        ) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct PairingPINEntryView: View {
    let peers: [BoothDiscoveredPeer]
    let initialPeerID: String?
    let initialPeerName: String?
    let onSubmit: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedPeerID: String?
    @State private var pin = ""

    init(
        peers: [BoothDiscoveredPeer],
        initialPeerID: String?,
        initialPeerName: String?,
        onSubmit: @escaping (String, String) -> Void
    ) {
        self.peers = peers
        self.initialPeerID = initialPeerID
        self.initialPeerName = initialPeerName
        self.onSubmit = onSubmit
        _selectedPeerID = State(initialValue: initialPeerID ?? peers.first?.id)
    }

    var body: some View {
        NavigationStack {
            Form {
                if peers.isEmpty, let initialPeerID {
                    LabeledContent("Mac", value: initialPeerName ?? initialPeerID)
                } else {
                    Picker("Mac", selection: $selectedPeerID) {
                        ForEach(peers) { peer in
                            Text(peer.displayName).tag(Optional(peer.id))
                        }
                    }
                }
                SecureField("6-digit PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .onChange(of: pin) { value in
                        pin = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                    }
                    .accessibilityLabel("6-digit PIN")
                    .accessibilityIdentifier("Pairing PIN Entry")

                Button("Pair") {
                    guard let selectedPeerID = selectedPeerID ?? initialPeerID else { return }
                    onSubmit(selectedPeerID, pin)
                    dismiss()
                }
                .disabled((selectedPeerID ?? initialPeerID) == nil || pin.count != 6)
                .accessibilityIdentifier("Pairing Pair Button")
            }
            .navigationTitle("Enter Pairing PIN")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}
