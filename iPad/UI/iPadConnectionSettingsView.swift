import SwiftUI

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

    private var transport: NetworkBoothTransport? { vm.networkTransport }
    private var status: BoothConnectionStatus { vm.connectionStatus }
    private var nearbyMacs: [BoothDiscoveredPeer] { status.discoveredPeers.filter { $0.role == .mac } }

    var body: some View {
        NavigationStack {
            List {
                thisIPadSection
                preferredMacSection
                connectedMacSection
                nearbyMacsSection
                pairingSection
            }
            .navigationTitle("Mac Connection")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if editedDeviceName.isEmpty {
                editedDeviceName = transport?.deviceIdentity.displayName ?? "PRC Booth iPad"
            }
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
                peers: nearbyMacs,
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
    }

    private var thisIPadSection: some View {
        Section("This iPad") {
            TextField("Device Name", text: $editedDeviceName)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .disabled(!vm.canChangeConnection)
                .onSubmit { vm.renameDevice(editedDeviceName) }
            Button("Save Device Name") { vm.renameDevice(editedDeviceName) }
                .disabled(!vm.canChangeConnection || editedDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private var preferredMacSection: some View {
        Section("Preferred Mac") {
            if let preferredID = status.preferredPeerID {
                let preferred = nearbyMacs.first { $0.id == preferredID }
                let trusted = transport?.trustedPeers.first { $0.id == preferredID }
                Text(preferred?.displayName ?? trusted?.displayName ?? "Preferred Mac")
                if preferred == nil && status.peerID != preferredID {
                    Label("Preferred Mac unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Retry") { vm.refreshNearbyMacs() }
                            .accessibilityIdentifier("Retry Preferred Mac")
                        Button("Choose Another Mac") {
                            transport?.selectPreferredPeer(nil)
                        }
                        .accessibilityIdentifier("Choose Another Mac")
                    }
                }
                if let transport {
                    Toggle("Automatically reconnect to selected Mac", isOn: Binding(
                        get: { transport.automaticallyReconnectToPreferredPeer },
                        set: { transport.automaticallyReconnectToPreferredPeer = $0 }
                    ))
                    .disabled(!vm.canChangeConnection)
                }
                Button("Forget Preferred Mac", role: .destructive) {
                    peerToForget = preferredID
                }
                .disabled(!vm.canChangeConnection)
                .accessibilityIdentifier("Forget Mac")
            } else {
                Text("No Mac selected")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var connectedMacSection: some View {
        Section("Connected") {
            if status.isPeerAuthenticated, let name = status.peerDisplayName {
                Label(name, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("Connected Mac")
                LabeledContent("Authentication", value: "Trusted")
                LabeledContent("Connection", value: connectionLabel)
                if let latency = status.roundTripLatency {
                    LabeledContent("Round trip", value: "\(Int(latency * 1000)) ms")
                }
            } else {
                switch status.pairingState {
                case .failed(let reason):
                    Text(reason)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("Pairing Failure")
                    Button("Retry Pairing") { retryPairing() }
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
                HStack {
                    ProgressView()
                    Text("Searching")
                }
            } else {
                ForEach(nearbyMacs) { peer in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(peer.displayName)
                                    .font(.headline)
                                Text("\(peer.appVersion) • \(transportLabel(peer.availableInterfaces))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if peer.isPreferred {
                                Label("Preferred", systemImage: "star.fill")
                                    .font(.caption)
                            }
                        }

                        if peer.protocolVersion != BoothTransportHello.currentProtocolVersion {
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
                                        .disabled(!vm.canChangeConnection || status.peerID == peer.id && status.isPeerAuthenticated)
                                        .accessibilityIdentifier("Connect Mac")
                                } else {
                                    Button("Connect") {
                                        startPairing(with: peer.id)
                                    }
                                    .disabled(!vm.canChangeConnection)
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
                .disabled(!vm.canChangeConnection)
        }
    }

    private var pairingSection: some View {
        Section("Pairing") {
            Button {
                showQRScanner = true
            } label: {
                Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
            }
            .disabled(!vm.canChangeConnection)
            .accessibilityIdentifier("Scan Pairing QR")

            Button {
                selectedPeerForPIN = lastPairingPeerID
                    ?? status.preferredPeerID
                    ?? nearbyMacs.first?.id
                selectedPairingMacName = nearbyMacs.first { $0.id == selectedPeerForPIN }?.displayName
                showPINEntry = true
            } label: {
                Label("Enter Pairing PIN", systemImage: "number.square")
            }
            .disabled(!vm.canChangeConnection || (nearbyMacs.isEmpty && lastPairingPeerID == nil))
            .accessibilityIdentifier("Enter Pairing PIN")
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
            return "Connected"
        case .failed(let reason):
            return reason
        }
    }

    private func retryPairing() {
        guard let peerID = lastPairingPeerID
                ?? nearbyMacs.first(where: { !$0.isTrusted })?.id else { return }
        startPairing(with: peerID)
    }

    private func startPairing(with peerID: String) {
        lastPairingPeerID = peerID
        selectedPairingMacName = nearbyMacs.first { $0.id == peerID }?.displayName
        automaticPairingPeerID = peerID
        vm.requestPairing(with: peerID)
    }

    private var connectionLabel: String {
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
                TextField("6-digit PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .onChange(of: pin) { value in
                        pin = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                    }
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
