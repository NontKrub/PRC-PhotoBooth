import Foundation
import Network
#if os(iOS)
import UIKit
#endif

@MainActor
public final class NetworkBoothTransport: BoothTransport {
    public static let lanHandshakeTimeout: TimeInterval = 5
    private static let reconnectDelays: [TimeInterval] = [0.5, 1, 2, 4, 5]
    private static let controlServiceType = "_prc-control._tcp"
    private static let previewServiceType = "_prc-preview._tcp"
    static let routeDiscoveryGracePeriod: TimeInterval = 2.0
    private static let lanRecoveryStabilityPeriod: TimeInterval = 2
    private static let lanRecoveryCooldown: TimeInterval = 5
    private static let pairingCapability = "pairing-v1"
    private static let previewIdentityCapability = "preview-identity"
    private static let heartbeatInterval: TimeInterval = 2
    private static let heartbeatTimeout: TimeInterval = 8

    public let role: DeviceRole
    public let connectionStatus: BoothConnectionStatus
    public private(set) var connectionState: BoothConnectionState = .disconnected
    public private(set) var peerName = ""
    public private(set) var connectedPeerNames: [String] = []
    public var activePeerName: String? {
        get { peerName.isEmpty ? nil : peerName }
        set { /* Network transport has one authoritative peer. */ }
    }
    public var onControlMessage: (@MainActor (Message) -> Void)?
    public var onPreviewFrame: (@MainActor (Data) -> Void)?

    private var requestedPreference: BoothNetworkPreference
    private var routeMachine: BoothNetworkRouteMachine
    private var activeInterface: BoothNetworkInterfacePolicy?
    private var fallbackActive = false
    private var fallbackReason: String?

    public var requestedNetworkPreference: BoothNetworkPreference {
        get { requestedPreference }
        set {
            guard requestedPreference != newValue else { return }
            cancelLANRecovery()
            let oldValue = requestedPreference
            requestedPreference = newValue
            fallbackActive = false
            fallbackReason = nil
            print("[NetworkRoute] Preference changed: \(oldValue.rawValue) -> \(newValue.rawValue)")
            let command = routeMachine.preferenceChanged(
                to: newValue,
                // LAN selection starts a real wired attempt; the monitor is diagnostic and
                // must not turn a known-unsatisfied sample into an immediate fallback.
                lanAvailable: newValue == .lan || pathAvailable(.wiredEthernet),
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: nil)
        }
    }

    private let identityStore: BoothDeviceIdentityStore
    private let trustedStore: BoothTrustedPeerStore
    private var localIdentity: BoothDeviceIdentity
    private var targetPeerID: String?
    private var pendingPairingRequest: BoothPairingRequest?
    private var currentPairingSession: BoothPairingSession?
    private var peerHello: BoothTransportHello?
    private var peerAuthenticated = false
    private var pendingAuthChallenge: BoothAuthChallenge?
    private var didInitiateAuthentication = false
    private var discoveredPeersByID: [String: BoothDiscoveredPeer] = [:]
    private var controlListener: NWListener?
    private var previewListener: NWListener?
    private var controlBrowser: NWBrowser?
    private var previewBrowser: NWBrowser?
    private var wifiRouteDiscoveryBrowser: NWBrowser?
    private var lanRouteDiscoveryBrowser: NWBrowser?
    private var routeDiscoverySelection = BoothRouteDiscoverySelection()
    private var pendingWiFiRouteEndpoint: NWEndpoint?
    private var pendingLANRouteEndpoint: NWEndpoint?
    private var routeDiscoveryFallbackTask: Task<Void, Never>?
    private var routeDiscoveryGate = BoothRouteDiscoveryGenerationGate()
    private var callbackGate = BoothTransportCallbackGate()
    private var controlConnection: NWConnection?
    private var previewConnection: NWConnection?
    private var controlParser = BoothFrameParser()
    private var previewParser = BoothFrameParser()
    private var previewFrames = LatestFrameCoalescer()
    private var heartbeatTimer: Timer?
    private var lanHandshakeTask: Task<Void, Never>?
    private var lastControlMessageAt = Date.distantPast
    private var reconnectTask: Task<Void, Never>?
    private var lanRecoveryTask: Task<Void, Never>?
    private var lanRecoveryPending = false
    private var lastLANRecoveryAttemptAt: Date?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var controlEndpointDescription: String?
    private var previewEndpointDescription: String?
    private var didReceiveHello = false
    private var peerDeviceID: String?
    private var expectedPeerDeviceID: String?
    private var previewPeerID: String?
    private var previewPeerSupportsIdentity = false
    private var didSendPreviewHello = false
    private var previewIdentityVerified = false
    private var lanPathMonitor: NWPathMonitor?
    private var wifiPathMonitor: NWPathMonitor?
    private var didReceiveLANPathUpdate = false
    private var didReceiveWiFiPathUpdate = false
    private var isLANPathAvailable = false
    private var isWiFiPathAvailable = false
    private var previewMetricsStartedAt = Date()
    private var previewFramesSubmitted = 0
    private var previewFramesSent = 0
    private var previewBytesSent = 0
    private var lanHandshakeState: BoothLANHandshakeState = .unknown
    private var lastNetworkError: String?

    public var canAttemptPreferredLANRecovery: @MainActor () -> Bool = { true }

    public init(
        role: DeviceRole,
        networkPreference: BoothNetworkPreference = .wifi,
        connectionStatus: BoothConnectionStatus? = nil
    ) {
        self.role = role
        self.requestedPreference = networkPreference
        self.routeMachine = BoothNetworkRouteMachine(preference: networkPreference)
        self.connectionStatus = connectionStatus ?? BoothConnectionStatus(requestedNetwork: networkPreference)
        let identityStore = BoothDeviceIdentityStore()
        self.identityStore = identityStore
        self.trustedStore = BoothTrustedPeerStore()
        self.localIdentity = identityStore.load(role: role, defaultName: Self.localDeviceName(for: role))
        if role == .iPad, trustedStore.autoReconnect {
            self.targetPeerID = trustedStore.preferredPeerID
        }
        publishPairingStatus()
    }

    public var deviceIdentity: BoothDeviceIdentity { localIdentity }
    public var trustedPeers: [TrustedBoothPeer] { trustedStore.trustedPeers }
    public var preferredPeerID: String? { trustedStore.preferredPeerID }
    public var currentPairingSessionInfo: BoothPairingSessionInfo? { currentPairingSession?.info }
    public var pairingPINForDisplay: String? { currentPairingSession?.pin }
    public var pairingQRCodePayload: BoothPairingQRCodePayload? { currentPairingSession?.qrPayload }
    public var automaticallyReconnectToPreferredPeer: Bool {
        get { trustedStore.autoReconnect }
        set {
            trustedStore.autoReconnect = newValue
            if role == .iPad {
                targetPeerID = newValue ? trustedStore.preferredPeerID : nil
                restartDiscoveryForPeerSelection()
            }
            publishPairingStatus()
        }
    }

    public func renameLocalDevice(_ name: String) {
        let updated = identityStore.rename(localIdentity, to: name)
        guard updated != localIdentity else { return }
        localIdentity = updated
        refreshAdvertisedServices()
        publishPairingStatus()
    }

    @discardableResult
    public func startPairingSession() -> Bool {
        guard role == .mac else { return false }
        do {
            if !peerAuthenticated {
                controlConnection?.cancel()
            }
            currentPairingSession?.invalidate()
            currentPairingSession = try BoothPairingSession.make(macIdentity: localIdentity)
            if let expiresAt = currentPairingSession?.info.expiresAt {
                connectionStatus.publishPairing(state: .pairing(expiresAt: expiresAt))
            }
            refreshAdvertisedServices()
            return true
        } catch {
            lastNetworkError = error.localizedDescription
            connectionStatus.publishPairing(state: .failed(error.localizedDescription))
            return false
        }
    }

    public func cancelPairingSession() {
        currentPairingSession?.invalidate()
        currentPairingSession = nil
        if !peerAuthenticated {
            controlConnection?.cancel()
        }
        connectionStatus.publishPairing(state: .idle)
        refreshAdvertisedServices()
    }

    public func selectPreferredPeer(_ peerID: String?) {
        guard peerID.map(trustedStore.trustedPeerIDs.contains) ?? true else { return }
        trustedStore.preferredPeerID = peerID
        if role == .iPad {
            targetPeerID = peerID
            trustedStore.autoReconnect = peerID != nil
            restartDiscoveryForPeerSelection()
        } else if let currentPeerID = peerDeviceID, currentPeerID != peerID {
            controlConnection?.cancel()
        }
        publishPairingStatus()
    }

    public func connectToPeer(_ peerID: String) {
        guard role == .iPad, trustedStore.trustedPeerIDs.contains(peerID) else { return }
        trustedStore.preferredPeerID = peerID
        targetPeerID = peerID
        restartDiscoveryForPeerSelection()
        publishPairingStatus()
    }

    public func pairWithPIN(peerID: String, pin: String) {
        guard role == .iPad else { return }
        guard BoothPairingSession.isValidPIN(pin) else {
            connectionStatus.publishPairing(state: .failed(BoothPairingError.invalidPIN.localizedDescription))
            return
        }
        guard let peer = discoveredPeersByID[peerID], peer.role == .mac else {
            connectionStatus.publishPairing(state: .failed("The selected Mac was not found."))
            return
        }
        guard peer.protocolVersion == BoothTransportHello.currentProtocolVersion else {
            connectionStatus.publishPairing(state: .failed(BoothPairingError.incompatibleProtocol.localizedDescription))
            return
        }
        guard let sessionID = peer.pairingSessionID, !sessionID.isEmpty else {
            connectionStatus.publishPairing(state: .failed("Pairing session unavailable."))
            return
        }
        beginPairing(peerID: peerID, sessionID: sessionID, method: .pin(pin))
    }

    public func pairWithQRCode(_ payload: BoothPairingQRCodePayload) {
        guard role == .iPad else { return }
        do {
            try payload.validate()
            beginPairing(
                peerID: payload.macDeviceID,
                sessionID: payload.pairingSessionID,
                method: .qrToken(payload.oneTimeToken)
            )
        } catch {
            connectionStatus.publishPairing(state: .failed(error.localizedDescription))
        }
    }

    public func forgetPeer(_ peerID: String) {
        let wasCurrent = peerDeviceID == peerID
        trustedStore.forget(peerID: peerID)
        if targetPeerID == peerID { targetPeerID = nil }
        if wasCurrent { controlConnection?.cancel() }
        publishPairingStatus()
        if role == .iPad { restartDiscoveryForPeerSelection() }
    }

    public func forgetAllPeers() {
        trustedStore.forgetAll()
        targetPeerID = nil
        pendingPairingRequest = nil
        peerAuthenticated = false
        controlConnection?.cancel()
        publishPairingStatus()
        if role == .iPad { restartDiscoveryForPeerSelection() }
    }

    public func start() {
        shouldReconnect = true
        cancelLANRecovery()
        reconnectAttempt = 0
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        startPathMonitors()

        if role == .iPad {
            startRouteDiscovery()
        } else {
            let lanAvailable = pathAvailable(.wiredEthernet)
            let wifiAvailable = pathAvailable(.wifi)
            let command = routeMachine.start(
                lanAvailable: requestedPreference == .lan ? true : lanAvailable,
                wifiAvailable: wifiAvailable
            )
            apply(command, reason: nil)
        }
    }

    public func disconnect() {
        shouldReconnect = false
        cancelLANRecovery()
        cancelRouteDiscovery()
        stopPathMonitors()
        tearDownActiveTransport()
        fallbackActive = false
        fallbackReason = nil
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        publishStatus()
    }

    @discardableResult
    public func retryPreferredLANNow() -> Bool {
        guard shouldReconnect,
              requestedPreference == .lan,
              activeInterface == .wifi,
              fallbackActive,
              canAttemptPreferredLANRecovery() else { return false }

        cancelLANRecovery()
        let command = routeMachine.manualPreferredLANRetry(
            lanAvailable: true,
            wifiAvailable: true,
            boothIsIdle: true
        )
        guard command == .startLAN else { return false }
        lastLANRecoveryAttemptAt = Date()
        print("[NetworkRoute] Manual LAN retry")
        apply(command, reason: "Manual LAN retry")
        return true
    }

    public func sendControl(_ message: Message) {
        send(message, on: controlConnection, channel: .control)
    }

    public func sendPreviewFrame(_ jpegData: Data) {
        previewFrames.enqueue(jpegData)
        previewFramesSubmitted += 1
        flushPreviewFrame()
        publishPreviewMetricsIfNeeded()
    }

    public func probeEthernet() async -> EthernetProbeResult {
        let startedAt = Date()
        let interfaceAvailable = isLANPathAvailable || activeInterface == .wiredEthernet
        let usingLAN = activeInterface == .wiredEthernet
        let peerDiscovered = usingLAN && !peerName.isEmpty
        let identityMatched = peerDiscovered && peerDeviceID == trustedStore.preferredPeerID
        let trustedPairing = peerDeviceID.map(trustedStore.trustedPeerIDs.contains) ?? false
        let authenticated = connectionStatus.isPeerAuthenticated
        let controlConnected = usingLAN && connectionState == .connected(peerName: peerName)
        let handshakeSucceeded = usingLAN && lanHandshakeState == .ready
        let previewConnected = usingLAN && connectionStatus.isPreviewChannelConnected

        let error: String?
        if !interfaceAvailable {
            error = "No Ethernet interface available."
        } else if !usingLAN {
            error = "Current route verification only. Switch Connection to LAN for a full booth connection test."
        } else if !peerDiscovered {
            error = "No PRC PhotoBooth iPad found over Ethernet."
        } else if !identityMatched {
            error = "The discovered iPad does not match the selected preferred device."
        } else if !trustedPairing {
            error = "The preferred iPad is not paired with this Mac."
        } else if !authenticated {
            error = "Preferred iPad authentication is not ready."
        } else if !controlConnected || !handshakeSucceeded {
            error = "Ethernet control handshake is not ready."
        } else if !previewConnected {
            error = "Ethernet preview channel is not ready."
        } else {
            error = nil
        }

        return EthernetProbeResult(
            interfaceAvailable: interfaceAvailable,
            peerDiscovered: peerDiscovered,
            identityMatched: identityMatched,
            trustedPairing: trustedPairing,
            authenticated: authenticated,
            controlConnected: controlConnected,
            handshakeSucceeded: handshakeSucceeded,
            previewConnected: previewConnected,
            duration: Date().timeIntervalSince(startedAt),
            error: error,
            roundTripLatency: connectionStatus.roundTripLatency
        )
    }

    private enum PathKind {
        case wifi
        case wiredEthernet
    }

    private func makeParameters(for interface: BoothNetworkInterfacePolicy) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = switch interface {
        case .wifi: .wifi
        case .wiredEthernet: .wiredEthernet
        }
        return parameters
    }

    private func pathAvailable(_ kind: PathKind) -> Bool {
        switch kind {
        case .wifi:
            return didReceiveWiFiPathUpdate ? isWiFiPathAvailable : true
        case .wiredEthernet:
            return didReceiveLANPathUpdate ? isLANPathAvailable : true
        }
    }

    private func startPathMonitors() {
        stopPathMonitors()
        didReceiveLANPathUpdate = false
        didReceiveWiFiPathUpdate = false

        let lanMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        lanMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleLANPathUpdate(path.status == .satisfied)
            }
        }
        lanMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.WiredEthernetPath"))
        lanPathMonitor = lanMonitor

        let wifiMonitor = NWPathMonitor(requiredInterfaceType: .wifi)
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handleWiFiPathUpdate(path.status == .satisfied)
            }
        }
        wifiMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.WiFiPath"))
        wifiPathMonitor = wifiMonitor
    }

    private func stopPathMonitors() {
        lanPathMonitor?.cancel()
        wifiPathMonitor?.cancel()
        lanPathMonitor = nil
        wifiPathMonitor = nil
    }

    private func handleLANPathUpdate(_ available: Bool) {
        didReceiveLANPathUpdate = true
        isLANPathAvailable = available
        publishPathAvailability()
        if available {
            if activeInterface == .wifi,
               requestedPreference == .lan,
               fallbackActive {
                scheduleLANRecovery(after: Self.lanRecoveryStabilityPeriod)
                return
            }
            guard role == .mac, activeInterface == nil else { return }
            let command = routeMachine.lanPathChanged(
                isAvailable: true,
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: command == .startLAN ? "LAN returned" : nil)
            return
        }
        if activeInterface == .wifi {
            cancelLANRecovery()
            return
        }
        if role == .mac, activeInterface == nil {
            let command = routeMachine.wifiPathChanged(
                isAvailable: isWiFiPathAvailable,
                lanAvailable: false
            )
            apply(command, reason: command == .startWiFi(fallback: true) ? "LAN unavailable" : nil)
            return
        }
        guard activeInterface == .wiredEthernet else { return }
        if case .connectingLAN = routeMachine.state {
            // Initial monitor samples can race route establishment.
            return
        }
        if role == .iPad || requestedPreference == .lan {
            activateWiFiFallback(reason: "LAN unavailable")
        }
    }

    private func scheduleLANRecovery(after delay: TimeInterval) {
        guard lanRecoveryTask == nil,
              shouldReconnect,
              activeInterface == .wifi,
              requestedPreference == .lan,
              fallbackActive,
              isLANPathAvailable else { return }

        lanRecoveryPending = true
        lanRecoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.lanRecoveryTask = nil
            guard self.isLANPathAvailable,
                  self.shouldReconnect,
                  self.activeInterface == .wifi,
                  self.requestedPreference == .lan,
                  self.fallbackActive else { return }
            self.attemptPendingLANRecoveryIfIdle()
        }
    }

    public func attemptPendingLANRecoveryIfIdle() {
        guard lanRecoveryPending,
              shouldReconnect,
              activeInterface == .wifi,
              requestedPreference == .lan,
              fallbackActive,
              isLANPathAvailable,
              canAttemptPreferredLANRecovery() else { return }
        if let lastAttempt = lastLANRecoveryAttemptAt,
           Date().timeIntervalSince(lastAttempt) < Self.lanRecoveryCooldown {
            scheduleLANRecovery(after: Self.lanRecoveryCooldown - Date().timeIntervalSince(lastAttempt))
            return
        }
        lanRecoveryPending = false
        lastLANRecoveryAttemptAt = Date()
        let command = routeMachine.lanPathChanged(
            isAvailable: true,
            wifiAvailable: pathAvailable(.wifi),
            boothIsIdle: true
        )
        guard command == .startLAN else { return }
        print("[NetworkRoute] LAN stable; attempting preferred LAN recovery")
        apply(command, reason: "LAN returned")
    }

    private func cancelLANRecovery() {
        lanRecoveryTask?.cancel()
        lanRecoveryTask = nil
        lanRecoveryPending = false
    }

    private func handleWiFiPathUpdate(_ available: Bool) {
        didReceiveWiFiPathUpdate = true
        isWiFiPathAvailable = available
        publishPathAvailability()
        if available {
            guard role == .mac, activeInterface == nil else { return }
            let command = routeMachine.wifiPathChanged(
                isAvailable: true,
                lanAvailable: pathAvailable(.wiredEthernet)
            )
            apply(command, reason: command == .startWiFi(fallback: true) ? "LAN unavailable" : nil)
            return
        }
        guard activeInterface == .wifi else { return }

        if role == .iPad {
            startRouteDiscovery()
            return
        }

        let command = routeMachine.wifiPathChanged(
            isAvailable: false,
            lanAvailable: pathAvailable(.wiredEthernet)
        )
        apply(command, reason: command == .startLAN ? "Wi-Fi unavailable" : nil)
    }

    private func apply(_ command: BoothNetworkRouteCommand, reason: String?) {
        switch command {
        case .startLAN:
            startTransport(using: .wiredEthernet, fallback: false, reason: reason)
        case .startWiFi(let fallback):
            startTransport(using: .wifi, fallback: fallback, reason: reason)
        case .unavailable:
            cancelRouteDiscovery()
            tearDownActiveTransport()
            fallbackActive = false
            fallbackReason = reason
            publishStatus()
            print("[NetworkRoute] No network connection")
        case .none:
            break
        }
    }

    private func activateWiFiFallback(reason: String) {
        guard activeInterface != .wifi else { return }
        let command = routeMachine.lanPathChanged(
            isAvailable: false,
            wifiAvailable: pathAvailable(.wifi)
        )
        guard command != .none else { return }
        print("[NetworkRoute] Falling back to Wi-Fi")
        apply(command, reason: reason)
    }

    private func handleLANHandshakeFailure(reason: String) {
        guard activeInterface == .wiredEthernet else { return }
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        lanHandshakeState = .timeout
        lastNetworkError = reason
        print("[NetworkRoute] LAN handshake timed out after \(Self.lanHandshakeTimeout)s")
        let command = routeMachine.lanHandshakeTimedOut(wifiAvailable: pathAvailable(.wifi))
        if command == .unavailable {
            apply(command, reason: reason)
        } else {
            print("[NetworkRoute] Falling back to Wi-Fi")
            apply(command, reason: reason)
        }
    }

    private func startTransport(
        using interface: BoothNetworkInterfacePolicy,
        fallback: Bool,
        reason: String?,
        discoveredControlBrowser: NWBrowser? = nil
    ) {
        guard shouldReconnect else { return }
        cancelRouteDiscovery(keeping: discoveredControlBrowser)
        tearDownActiveTransport()
        activeInterface = interface
        fallbackActive = fallback
        fallbackReason = fallback ? (reason ?? "LAN unavailable") : nil
        lanHandshakeState = interface == .wiredEthernet ? .waiting : .unknown
        lastNetworkError = nil
        connectionState = role == .mac ? .disconnected : .connecting
        publishStatus()

        if let discoveredControlBrowser {
            controlBrowser = discoveredControlBrowser
            configure(discoveredControlBrowser, channel: .control, interface: interface)
        }

        print("[NetworkRoute] Starting \(interface == .wiredEthernet ? "LAN" : "Wi-Fi") transport")
        switch role {
        case .mac:
            startListener(channel: .control)
            startListener(channel: .preview)
        case .iPad:
            if controlBrowser == nil { startBrowser(channel: .control) }
            startBrowser(channel: .preview)
        }

        if interface == .wiredEthernet {
            lanHandshakeTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.lanHandshakeTimeout))
                } catch {
                    return
                }
                guard let self,
                      self.activeInterface == .wiredEthernet,
                      self.shouldReconnect,
                      !self.peerAuthenticated else { return }
                self.handleLANHandshakeFailure(reason: "No valid iPad hello")
            }
        }
    }

    private func startRouteDiscovery() {
        guard role == .iPad, shouldReconnect else { return }
        cancelRouteDiscovery()
        tearDownActiveTransport()
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        connectionState = .connecting
        publishStatus()
        let generation = routeDiscoveryGate.begin()
        startRouteDiscoveryBrowser(on: .wifi, generation: generation)
        startRouteDiscoveryBrowser(on: .wiredEthernet, generation: generation)
    }

    private func startRouteDiscoveryBrowser(
        on interface: BoothNetworkInterfacePolicy,
        generation: Int
    ) {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.controlServiceType, domain: nil),
            using: makeParameters(for: interface)
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.routeDiscoveryGate.accepts(generation),
                      self.isCurrentRouteDiscoveryBrowser(browser, interface: interface) else { return }

                self.updateDiscoveredPeers(from: results, interface: interface)
                for result in results {
                    guard let peer = self.discoveredPeer(from: result, interface: interface),
                          peer.role == .mac,
                          let targetPeerID = self.targetPeerID,
                          peer.id == targetPeerID else { continue }
                    guard peer.protocolVersion == BoothTransportHello.currentProtocolVersion else {
                        self.connectionStatus.publishPairing(state: .failed(BoothPairingError.incompatibleProtocol.localizedDescription))
                        continue
                    }

                    let advertisedPreference = peer.networkPreference
                    if let advertisedPreference,
                       self.requestedPreference != advertisedPreference {
                        self.requestedPreference = advertisedPreference
                        self.routeMachine = BoothNetworkRouteMachine(preference: advertisedPreference)
                        self.publishStatus()
                    }
                    let decision = self.routeDiscoverySelection.consider(
                        interface,
                        preferredPreference: self.requestedPreference,
                        advertisedPreference: advertisedPreference
                    )
                    switch decision {
                    case .ignored:
                        continue
                    case .waitingForPreferredInterface:
                        self.storePendingRouteEndpoint(result.endpoint, for: interface)
                        self.scheduleRouteDiscoveryFallback()
                        continue
                    case .accepted:
                        if let advertisedPreference {
                            self.requestedPreference = advertisedPreference
                        }
                        self.connectDiscoveredRoute(
                            interface: interface,
                            endpoint: result.endpoint,
                            browser: browser
                        )
                        return
                    }
                }
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed(let error) = state else { return }
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.routeDiscoveryGate.accepts(generation),
                      self.isCurrentRouteDiscoveryBrowser(browser, interface: interface) else { return }
                print("[NetworkRoute] \(interface.rawValue) discovery failed: \(error.localizedDescription)")
                if interface == .wifi {
                    self.wifiRouteDiscoveryBrowser = nil
                } else {
                    self.lanRouteDiscoveryBrowser = nil
                }
                self.scheduleReconnect()
            }
        }
        browser.start(queue: .main)
        if interface == .wifi {
            wifiRouteDiscoveryBrowser = browser
        } else {
            lanRouteDiscoveryBrowser = browser
        }
    }

    private func storePendingRouteEndpoint(_ endpoint: NWEndpoint, for interface: BoothNetworkInterfacePolicy) {
        switch interface {
        case .wifi:
            pendingWiFiRouteEndpoint = endpoint
        case .wiredEthernet:
            pendingLANRouteEndpoint = endpoint
        }
    }

    private func scheduleRouteDiscoveryFallback() {
        guard routeDiscoveryFallbackTask == nil else { return }
        routeDiscoveryFallbackTask = Task { @MainActor [weak self] in
            defer { self?.routeDiscoveryFallbackTask = nil }
            do {
                try await Task.sleep(for: .seconds(Self.routeDiscoveryGracePeriod))
            } catch {
                return
            }
            guard let self,
                  self.shouldReconnect,
                  self.activeInterface == nil,
                  let pendingInterface = self.routeDiscoverySelection.promotePending() else { return }

            guard self.requestedPreference == .lan else {
                self.routeDiscoverySelection.reset()
                self.scheduleReconnect()
                return
            }
            let endpoint = pendingInterface == .wifi
                ? self.pendingWiFiRouteEndpoint
                : self.pendingLANRouteEndpoint
            guard let endpoint else { return }
            self.connectDiscoveredRoute(
                interface: pendingInterface,
                endpoint: endpoint,
                browser: pendingInterface == .wifi
                    ? self.wifiRouteDiscoveryBrowser
                    : self.lanRouteDiscoveryBrowser
            )
        }
    }

    private func connectDiscoveredRoute(
        interface: BoothNetworkInterfacePolicy,
        endpoint: NWEndpoint,
        browser: NWBrowser?
    ) {
        routeDiscoveryFallbackTask?.cancel()
        routeDiscoveryFallbackTask = nil
        if interface == .wiredEthernet {
            _ = routeMachine.beginLANAttempt()
        } else {
            _ = routeMachine.startWiFiAttempt(
                wifiAvailable: true,
                fallback: requestedPreference == .lan
            )
        }
        startTransport(
            using: interface,
            fallback: interface == .wifi && requestedPreference == .lan,
            reason: interface == .wifi && requestedPreference == .lan ? "LAN unavailable" : nil,
            discoveredControlBrowser: browser
        )
        connect(to: endpoint, channel: .control)
    }

    private func cancelRouteDiscovery(keeping browser: NWBrowser? = nil) {
        if wifiRouteDiscoveryBrowser !== browser { wifiRouteDiscoveryBrowser?.cancel() }
        if lanRouteDiscoveryBrowser !== browser { lanRouteDiscoveryBrowser?.cancel() }
        routeDiscoveryGate.invalidate()
        routeDiscoveryFallbackTask?.cancel()
        routeDiscoveryFallbackTask = nil
        wifiRouteDiscoveryBrowser = nil
        lanRouteDiscoveryBrowser = nil
        pendingWiFiRouteEndpoint = nil
        pendingLANRouteEndpoint = nil
        routeDiscoverySelection.reset()
    }

    private func isCurrentRouteDiscoveryBrowser(
        _ browser: NWBrowser,
        interface: BoothNetworkInterfacePolicy
    ) -> Bool {
        interface == .wifi
            ? browser === wifiRouteDiscoveryBrowser
            : browser === lanRouteDiscoveryBrowser
    }

    private func tearDownActiveTransport() {
        activeInterface = nil
        callbackGate.invalidate()
        reconnectTask?.cancel()
        reconnectTask = nil
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        cancelTransportObjects()
        peerName = ""
        connectedPeerNames = []
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        connectionState = .disconnected
    }

    private func cancelTransportObjects() {
        controlBrowser?.cancel()
        previewBrowser?.cancel()
        controlBrowser = nil
        previewBrowser = nil
        controlListener?.cancel()
        previewListener?.cancel()
        controlListener = nil
        previewListener = nil
        controlConnection?.cancel()
        previewConnection?.cancel()
        controlConnection = nil
        previewConnection = nil
        controlEndpointDescription = nil
        previewEndpointDescription = nil
        controlParser = BoothFrameParser()
        previewParser = BoothFrameParser()
        previewFrames.reset()
        didReceiveHello = false
        peerAuthenticated = false
        didInitiateAuthentication = false
        peerHello = nil
        pendingAuthChallenge = nil
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        let pairingState: BoothPairingState
        if let session = currentPairingSession, session.isActive() {
            pairingState = .pairing(expiresAt: session.info.expiresAt)
        } else if let pendingPairingRequest {
            pairingState = .pairing(
                expiresAt: discoveredPeersByID[pendingPairingRequest.targetMacDeviceID]?.pairingExpiresAt
                    ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
            )
        } else {
            pairingState = .idle
        }
        connectionStatus.publishPairing(authenticated: false, state: pairingState)
        resetPreviewIdentity()
    }

    private func advertisedService(for channel: BoothTransportChannel) -> NWListener.Service {
        var metadata = [
            "network": requestedPreference.rawValue,
            "deviceID": localIdentity.id,
            "deviceName": localIdentity.displayName,
            "role": role.rawValue,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            "protocolVersion": String(BoothTransportHello.currentProtocolVersion)
        ]
        if role == .mac, let session = currentPairingSession, session.isActive() {
            metadata["pairingSessionID"] = session.info.sessionID
            metadata["pairingExpiresAt"] = String(session.info.expiresAt.timeIntervalSince1970)
        }
        return NWListener.Service(
            name: "PRC PhotoBooth \(channel == .control ? "Control" : "Preview") \(localIdentity.id)",
            type: channel == .control ? Self.controlServiceType : Self.previewServiceType,
            txtRecord: NWTXTRecord(metadata)
        )
    }

    private func refreshAdvertisedServices() {
        if let controlListener { controlListener.service = advertisedService(for: .control) }
        if let previewListener { previewListener.service = advertisedService(for: .preview) }
    }

    private func discoveredPeer(
        from result: NWBrowser.Result,
        interface: BoothNetworkInterfacePolicy
    ) -> BoothDiscoveredPeer? {
        guard case .bonjour(let txtRecord) = result.metadata,
              let id = txtRecord["deviceID"], !id.isEmpty,
              let roleRaw = txtRecord["role"],
              let peerRole = DeviceRole(rawValue: roleRaw) else { return nil }
        let preferred = trustedStore.preferredPeerID
        let expiresAt = txtRecord["pairingExpiresAt"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        return BoothDiscoveredPeer(
            id: id,
            displayName: txtRecord["deviceName"] ?? id,
            role: peerRole,
            appVersion: txtRecord["appVersion"] ?? "unknown",
            protocolVersion: Int(txtRecord["protocolVersion"] ?? "0") ?? 0,
            networkPreference: txtRecord["network"].flatMap(BoothNetworkPreference.init(rawValue:)),
            availableInterfaces: [interface],
            pairingSessionID: txtRecord["pairingSessionID"],
            pairingExpiresAt: expiresAt,
            isTrusted: trustedStore.trustedPeerIDs.contains(id),
            isPreferred: preferred == id
        )
    }

    private func updateDiscoveredPeers(
        from results: Set<NWBrowser.Result>,
        interface: BoothNetworkInterfacePolicy
    ) {
        for id in Array(discoveredPeersByID.keys) {
            guard var peer = discoveredPeersByID[id] else { continue }
            peer.availableInterfaces.remove(interface)
            if peer.availableInterfaces.isEmpty { discoveredPeersByID.removeValue(forKey: id) }
            else { discoveredPeersByID[id] = peer }
        }

        for result in results {
            guard var peer = discoveredPeer(from: result, interface: interface) else { continue }
            if var existing = discoveredPeersByID[peer.id] {
                existing.availableInterfaces.insert(interface)
                existing.displayName = peer.displayName
                existing.appVersion = peer.appVersion
                existing.protocolVersion = peer.protocolVersion
                existing.networkPreference = peer.networkPreference
                existing.pairingSessionID = peer.pairingSessionID ?? existing.pairingSessionID
                existing.pairingExpiresAt = peer.pairingExpiresAt ?? existing.pairingExpiresAt
                existing.isTrusted = peer.isTrusted
                existing.isPreferred = peer.isPreferred
                peer = existing
            }
            discoveredPeersByID[peer.id] = peer
        }
        publishPairingStatus()
    }

    private func startListener(channel: BoothTransportChannel) {
        guard let activeInterface else { return }
        if channel == .control, controlListener != nil { return }
        if channel == .preview, previewListener != nil { return }
        let listener: NWListener
        do {
            listener = try NWListener(using: makeParameters(for: activeInterface))
        } catch {
            print("[Network] listener creation failed: \(error.localizedDescription)")
            if activeInterface == .wiredEthernet { handleLANHandshakeFailure(reason: error.localizedDescription) }
            return
        }
        let interfaceAtStart = activeInterface
        listener.service = advertisedService(for: channel)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .failed(let error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self, weak listener] in
                guard let self, let listener,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(listener, channel: channel) else { return }
                print("[Network] listener failed: \(message)")
                if channel == .control { self.controlListener = nil } else { self.previewListener = nil }
                if interfaceAtStart == .wiredEthernet {
                    self.handleLANHandshakeFailure(reason: message)
                } else if !message.contains("NoAuth") {
                    self.scheduleReconnect()
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor [weak self, weak listener] in
                guard let self, let listener,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(listener, channel: channel) else {
                    connection.cancel()
                    return
                }
                self.accept(connection, channel: channel)
            }
        }
        listener.start(queue: .main)
        if channel == .control { controlListener = listener } else { previewListener = listener }
    }

    private func startBrowser(channel: BoothTransportChannel) {
        guard let activeInterface else { return }
        if channel == .control, controlBrowser != nil { return }
        if channel == .preview, previewBrowser != nil { return }
        let serviceType = channel == .control ? Self.controlServiceType : Self.previewServiceType
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: makeParameters(for: activeInterface)
        )
        configure(browser, channel: channel, interface: activeInterface)
        browser.start(queue: .main)
        if channel == .control { controlBrowser = browser } else { previewBrowser = browser }
    }

    private func configure(
        _ browser: NWBrowser,
        channel: BoothTransportChannel,
        interface interfaceAtStart: BoothNetworkInterfacePolicy
    ) {
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(browser, channel: channel),
                      let endpoint = self.endpointToConnect(from: results, channel: channel) else { return }
                self.connect(to: endpoint, channel: channel)
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard case .failed(let error) = state else { return }
            let message = error.localizedDescription
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.activeInterface == interfaceAtStart,
                      self.isCurrent(browser, channel: channel) else { return }
                print("[Network] browser failed: \(message)")
                if channel == .control { self.controlBrowser = nil } else { self.previewBrowser = nil }
                if interfaceAtStart == .wiredEthernet {
                    self.handleLANHandshakeFailure(reason: message)
                } else if !message.contains("NoAuth") {
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func endpointToConnect(
        from results: Set<NWBrowser.Result>,
        channel: BoothTransportChannel
    ) -> NWEndpoint? {
        let endpoints = results.map(\.endpoint)
        guard !endpoints.isEmpty else { return nil }
        if channel == .preview {
            guard let expectedPeerDeviceID else { return nil }
            return endpoints.first { serviceName(from: $0)?.contains(expectedPeerDeviceID) == true }
        }
        if let selectedPeerID = expectedPeerDeviceID ?? targetPeerID {
            return endpoints.first { serviceName(from: $0)?.contains(selectedPeerID) == true }
        }
        return role == .iPad ? nil : endpoints[0]
    }

    private func serviceName(from endpoint: NWEndpoint) -> String? {
        guard case let .service(name, _, _, _) = endpoint else { return nil }
        return name
    }

    private func accept(_ connection: NWConnection, channel: BoothTransportChannel) {
        if role == .mac, channel == .control, controlConnection != nil {
            connection.cancel()
            return
        }
        guard activeInterface != nil else {
            connection.cancel()
            return
        }
        if channel == .control {
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnection = connection
            controlEndpointDescription = connection.endpoint.debugDescription
            resetControlAuthentication()
            controlParser = BoothFrameParser()
        } else {
            previewFrames.reset()
            previewConnection?.cancel()
            previewConnection = connection
            previewEndpointDescription = connection.endpoint.debugDescription
            previewParser = BoothFrameParser()
            resetPreviewIdentity()
        }
        configure(connection, channel: channel)
    }

    private func connect(to endpoint: NWEndpoint, channel: BoothTransportChannel) {
        guard let activeInterface else { return }
        if channel == .preview, expectedPeerDeviceID == nil { return }
        let description = endpoint.debugDescription
        if channel == .control {
            guard controlConnection == nil || controlEndpointDescription != description else { return }
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnection = NWConnection(to: endpoint, using: makeParameters(for: activeInterface))
            controlEndpointDescription = description
            resetControlAuthentication()
            controlParser = BoothFrameParser()
            if let connection = controlConnection { configure(connection, channel: channel) }
        } else {
            guard previewConnection == nil || previewEndpointDescription != description else { return }
            previewFrames.reset()
            previewConnection?.cancel()
            previewConnection = NWConnection(to: endpoint, using: makeParameters(for: activeInterface))
            previewEndpointDescription = description
            previewParser = BoothFrameParser()
            resetPreviewIdentity()
            if let connection = previewConnection { configure(connection, channel: channel) }
        }
    }

    private func configure(_ connection: NWConnection, channel: BoothTransportChannel) {
        let generationAtStart = callbackGate.generation
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self] in
                guard let self, let connection else { return }
                guard self.callbackGate.accepts(generationAtStart),
                      self.isCurrent(connection, channel: channel) else { return }
                switch state {
                case .ready:
                    if self.activeInterface == .wiredEthernet,
                       let path = connection.currentPath,
                       !path.usesInterfaceType(.wiredEthernet) {
                        self.connectionDidClose(connection, channel: channel, reason: "Transport became ready on a non-Ethernet path")
                        return
                    }
                    if channel == .control {
                        if self.activeInterface == .wiredEthernet {
                            self.lanHandshakeState = .waiting
                        }
                        self.connectionState = .connecting
                        self.publishStatus()
                        self.receive(on: connection, channel: channel)
                        self.sendTransportHello()
                    } else {
                        self.connectionStatus.publishPreviewChannel(connected: true)
                        self.receive(on: connection, channel: channel)
                        self.sendPreviewHello(on: connection)
                    }
                case .failed, .cancelled:
                    if channel == .preview {
                        self.connectionStatus.publishPreviewChannel(connected: false)
                    }
                    self.connectionDidClose(connection, channel: channel)
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    private func receive(on connection: NWConnection, channel: BoothTransportChannel) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            let errorMessage = error?.localizedDescription
            let didFail = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(connection, channel: channel) else { return }
                if let data, !data.isEmpty { self.receiveData(data, channel: channel) }
                if isComplete || didFail {
                    self.connectionDidClose(connection, channel: channel, reason: errorMessage)
                } else {
                    self.receive(on: connection, channel: channel)
                }
            }
        }
    }

    private func receiveData(_ data: Data, channel: BoothTransportChannel) {
        do {
            let frames = try channel == .control
                ? controlParser.append(data)
                : previewParser.append(data)
            if channel == .control { lastControlMessageAt = Date() }
            for frame in frames {
                guard frame.channel == channel || frame.channel == .heartbeat else { continue }
                switch frame.channel {
                case .control:
                    guard let message = try? Message.decoded(from: frame.payload) else { continue }
                    handleControl(message)
                case .heartbeat:
                    if channel == .preview { handlePreviewHello(frame.payload) }
                case .preview:
                    guard previewIdentityVerified else { continue }
                    onPreviewFrame?(frame.payload)
                case .asset:
                    break
                }
            }
        } catch {
            print("[Network] invalid frame: \(error)")
            connectionDidClose(channel == .control ? controlConnection : previewConnection, channel: channel)
        }
    }

    private func handleControl(_ message: Message) {
        switch message {
        case .helloDetails(let hello):
            handleHello(hello)
        case .pairingRequest(let request):
            handlePairingRequest(request)
        case .pairingResult(let result):
            handlePairingResult(result)
        case .authChallenge(let challenge):
            handleAuthChallenge(challenge)
        case .authProof(let proof):
            handleAuthProof(proof)
        case .connectionRejected(let reason):
            lastNetworkError = reason
            connectionStatus.publishPairing(authenticated: false, state: .failed(reason))
            connectionDidClose(controlConnection, channel: .control, reason: reason)
        case .heartbeat:
            guard peerAuthenticated else { return }
            lastControlMessageAt = Date()
        default:
            guard peerAuthenticated else { return }
            onControlMessage?(message)
        }
    }

    private func handleHello(_ hello: BoothTransportHello) {
        let expectedRole: DeviceRole = role == .mac ? .iPad : .mac
        guard !hello.deviceID.isEmpty, !hello.deviceName.isEmpty else {
            rejectControlConnection("Invalid device identity.")
            return
        }
        guard hello.protocolVersion == BoothTransportHello.currentProtocolVersion else {
            rejectControlConnection(BoothPairingError.incompatibleProtocol.localizedDescription)
            return
        }
        guard hello.role == expectedRole else {
            rejectControlConnection(BoothPairingError.wrongRole.localizedDescription)
            return
        }
        guard hello.capabilities.contains(Self.pairingCapability) else {
            rejectControlConnection(BoothPairingError.incompatibleProtocol.localizedDescription)
            return
        }

        didReceiveHello = true
        peerHello = hello
        peerDeviceID = hello.deviceID
        peerName = hello.deviceName.isEmpty ? hello.deviceID : hello.deviceName
        previewPeerSupportsIdentity = hello.capabilities.contains(Self.previewIdentityCapability)
        connectionState = .connecting
        if role == .iPad, let peerPreference = hello.networkPreference {
            requestedPreference = peerPreference
        }
        publishStatus()

        if role == .mac {
            switch BoothPeerSelectionPolicy.admission(
                peerID: hello.deviceID,
                preferredPeerID: trustedStore.preferredPeerID,
                trustedPeerIDs: trustedStore.trustedPeerIDs
            ) {
            case .allowed:
                beginAuthentication(with: hello.deviceID)
            case .unpaired:
                if let session = currentPairingSession, session.isActive() {
                    connectionStatus.publishPairing(state: .pairing(expiresAt: session.info.expiresAt))
                } else {
                    rejectControlConnection("This iPad is not paired with this Mac.")
                }
            case .notSelected:
                rejectControlConnection("This Mac is configured for another iPad. Select this iPad in Mac Settings first.")
            }
            return
        }

        guard targetPeerID == hello.deviceID else {
            rejectControlConnection("This Mac was not selected on this iPad.")
            return
        }
        if let pendingPairingRequest {
            send(.pairingRequest(request: pendingPairingRequest), on: controlConnection, channel: .control)
            if let expiresAt = discoveredPeersByID[hello.deviceID]?.pairingExpiresAt {
                connectionStatus.publishPairing(state: .pairing(expiresAt: expiresAt))
            }
            return
        }
        guard BoothPeerSelectionPolicy.canAutomaticallyConnect(
            peerID: hello.deviceID,
            preferredPeerID: trustedStore.preferredPeerID,
            trustedPeerIDs: trustedStore.trustedPeerIDs,
            autoReconnect: true
        ) else {
            rejectControlConnection("This Mac is not paired with this iPad.")
            return
        }
        beginAuthentication(with: hello.deviceID)
    }

    private func beginPairing(peerID: String, sessionID: String, method: BoothPairingMethod) {
        let expiresAt = discoveredPeersByID[peerID]?.pairingExpiresAt ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
        pendingPairingRequest = BoothPairingRequest(
            sessionID: sessionID,
            targetMacDeviceID: peerID,
            iPadIdentity: localIdentity,
            method: method
        )
        targetPeerID = peerID
        connectionStatus.publishPairing(state: .pairing(expiresAt: expiresAt))
        restartDiscoveryForPeerSelection()
    }

    private func handlePairingRequest(_ request: BoothPairingRequest) {
        guard role == .mac,
              let hello = peerHello,
              hello.role == .iPad,
              request.iPadIdentity.id == hello.deviceID,
              request.iPadIdentity.role == .iPad,
              !request.iPadIdentity.displayName.isEmpty,
              request.targetMacDeviceID == localIdentity.id else {
            rejectControlConnection("Pairing request does not match this connection.")
            return
        }
        guard var session = currentPairingSession else {
            sendPairingFailure("Pairing mode is not active.")
            return
        }
        guard request.sessionID == session.info.sessionID else {
            sendPairingFailure("Pairing session does not match.")
            return
        }

        let validation: BoothPairingAttemptResult
        switch request.method {
        case .pin(let pin):
            validation = session.validatePIN(pin)
        case .qrToken(let token):
            guard request.sessionID == session.info.sessionID else {
                sendPairingFailure("Pairing QR code is invalid.")
                return
            }
            validation = session.validateQRToken(token)
        }
        currentPairingSession = session

        switch validation {
        case .accepted:
            do {
                let secret = try BoothPairingCrypto.makeSharedSecret()
                let peer = TrustedBoothPeer(
                    id: request.iPadIdentity.id,
                    displayName: request.iPadIdentity.displayName,
                    role: .iPad,
                    lastSeenAt: Date()
                )
                try trustedStore.trust(peer, secret: secret)
                trustedStore.preferredPeerID = peer.id
                trustedStore.autoReconnect = true
                currentPairingSession = nil
                refreshAdvertisedServices()
                publishPairingStatus()
                send(
                    .pairingResult(result: BoothPairingResult(
                        accepted: true,
                        macIdentity: localIdentity,
                        sharedSecret: secret
                    )),
                    on: controlConnection,
                    channel: .control
                )
                beginAuthentication(with: peer.id)
            } catch {
                currentPairingSession = nil
                refreshAdvertisedServices()
                sendPairingFailure(error.localizedDescription)
            }
        case .rejected(let remainingAttempts):
            let reason: String
            switch request.method {
            case .pin:
                reason = "Pairing PIN is invalid. \(remainingAttempts) attempts remaining."
            case .qrToken:
                reason = "Pairing QR code is invalid."
            }
            sendPairingFailure(reason)
        case .expired:
            currentPairingSession = nil
            refreshAdvertisedServices()
            connectionStatus.publishPairing(state: .failed("Pairing code expired"))
            sendPairingFailure("Pairing code expired.")
            rejectControlConnection("Pairing code expired.")
        case .locked:
            currentPairingSession = nil
            refreshAdvertisedServices()
            connectionStatus.publishPairing(state: .failed("Too many incorrect pairing PIN attempts."))
            sendPairingFailure("Too many incorrect pairing PIN attempts.")
            rejectControlConnection("Too many incorrect pairing PIN attempts.")
        }
    }

    private func sendPairingFailure(_ reason: String) {
        send(
            .pairingResult(result: BoothPairingResult(accepted: false, reason: reason)),
            on: controlConnection,
            channel: .control
        )
    }

    private func handlePairingResult(_ result: BoothPairingResult) {
        guard role == .iPad else { return }
        guard result.accepted,
              let macIdentity = result.macIdentity,
              macIdentity.role == .mac,
              let secret = result.sharedSecret,
              secret.count == 32,
              !macIdentity.displayName.isEmpty,
              macIdentity.id == targetPeerID else {
            let reason = result.reason ?? "Pairing rejected."
            pendingPairingRequest = nil
            connectionStatus.publishPairing(state: .failed(reason))
            return
        }
        do {
            try trustedStore.trust(
                TrustedBoothPeer(
                    id: macIdentity.id,
                    displayName: macIdentity.displayName,
                    role: .mac,
                    lastSeenAt: Date()
                ),
                secret: secret
            )
            trustedStore.preferredPeerID = macIdentity.id
            trustedStore.autoReconnect = true
            pendingPairingRequest = nil
            targetPeerID = macIdentity.id
            publishPairingStatus()
            beginAuthentication(with: macIdentity.id)
        } catch {
            connectionStatus.publishPairing(state: .failed(error.localizedDescription))
        }
    }

    private func beginAuthentication(with peerID: String) {
        guard !didInitiateAuthentication else { return }
        guard trustedStore.secret(for: peerID) != nil else {
            rejectControlConnection("Authentication failed: pairing secret is unavailable.")
            return
        }
        do {
            let challenge = try BoothAuthChallenge.make(
                challengerDeviceID: localIdentity.id,
                responderDeviceID: peerID
            )
            didInitiateAuthentication = true
            pendingAuthChallenge = challenge
            connectionStatus.publishPairing(authenticated: false, state: .authenticating(peerID: peerID))
            send(.authChallenge(challenge: challenge), on: controlConnection, channel: .control)
        } catch {
            rejectControlConnection(error.localizedDescription)
        }
    }

    private func handleAuthChallenge(_ challenge: BoothAuthChallenge) {
        guard let hello = peerHello,
              challenge.challengerDeviceID == hello.deviceID,
              challenge.responderDeviceID == localIdentity.id,
              challenge.isFresh(),
              let secret = trustedStore.secret(for: hello.deviceID) else {
            rejectControlConnection("Authentication failed.")
            return
        }
        let proof = BoothPairingCrypto.makeProof(
            for: challenge,
            responderDeviceID: localIdentity.id,
            secret: secret
        )
        send(.authProof(proof: proof), on: controlConnection, channel: .control)
        if !didInitiateAuthentication { beginAuthentication(with: hello.deviceID) }
    }

    private func handleAuthProof(_ proof: BoothAuthProof) {
        guard let hello = peerHello,
              let challenge = pendingAuthChallenge,
              let secret = trustedStore.secret(for: hello.deviceID),
              BoothPairingCrypto.verify(
                proof,
                for: challenge,
                expectedResponderDeviceID: hello.deviceID,
                secret: secret
              ) else {
            rejectControlConnection("Authentication failed.")
            return
        }
        pendingAuthChallenge = nil
        completeAuthentication(with: hello)
    }

    private func completeAuthentication(with hello: BoothTransportHello) {
        peerAuthenticated = true
        expectedPeerDeviceID = hello.deviceID
        peerDeviceID = hello.deviceID
        peerName = hello.deviceName.isEmpty ? hello.deviceID : hello.deviceName
        connectedPeerNames = [peerName]
        connectionState = .connected(peerName: peerName)
        reconnectAttempt = 0
        lastControlMessageAt = Date()
        lastNetworkError = nil
        trustedStore.updateLastSeen(peerID: hello.deviceID, name: peerName)
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        if activeInterface == .wiredEthernet {
            lanHandshakeState = .ready
            _ = routeMachine.lanHandshakeSucceeded(peer: peerName)
        } else {
            _ = routeMachine.wifiConnected(peer: peerName, fallback: fallbackActive)
        }
        publishStatus()
        publishPairingStatus(state: .authenticated(peerID: hello.deviceID))
        startHeartbeat()
        validatePreviewIdentity()
        if role == .iPad, previewConnection == nil {
            previewBrowser?.cancel()
            previewBrowser = nil
            startBrowser(channel: .preview)
        }
        onControlMessage?(.hello(role: hello.role))
    }

    private func rejectControlConnection(_ reason: String) {
        lastNetworkError = reason
        connectionStatus.publishPairing(authenticated: false, state: .failed(reason))
        send(.connectionRejected(reason: reason), on: controlConnection, channel: .control)
        let connection = controlConnection
        Task { @MainActor [weak self, weak connection] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, let connection, self.isCurrent(connection, channel: .control) else { return }
            self.connectionDidClose(connection, channel: .control, reason: reason)
        }
    }

    private func restartDiscoveryForPeerSelection() {
        guard role == .iPad, shouldReconnect else { return }
        startRouteDiscovery()
    }

    private func publishPairingStatus(state: BoothPairingState? = nil) {
        let preferred = trustedStore.preferredPeerID
        var peers = discoveredPeersByID.values.map { peer in
            var updated = peer
            updated.isTrusted = trustedStore.trustedPeerIDs.contains(peer.id)
            updated.isPreferred = peer.id == preferred
            return updated
        }
        peers.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        connectionStatus.publishPairing(
            discoveredPeers: peers,
            trustedPeerIDs: trustedStore.trustedPeerIDs,
            preferredPeerID: preferred,
            updatePreferredPeer: true,
            authenticated: peerAuthenticated,
            state: state
        )
    }

    private func sendTransportHello() {
        send(
            .helloDetails(hello: BoothTransportHello(
                role: role,
                deviceID: localIdentity.id,
                deviceName: localIdentity.displayName,
                networkPreference: requestedPreference
            )),
            on: controlConnection,
            channel: .control
        )
    }

    private func sendPreviewHello(on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(
            BoothTransportHello(
                role: role,
                deviceID: localIdentity.id,
                deviceName: localIdentity.displayName,
                networkPreference: requestedPreference
            )
        ), let frame = try? BoothFrameEncoder.encode(channel: .heartbeat, payload: payload) else {
            connectionDidClose(connection, channel: .preview, reason: "preview hello encoding failed")
            return
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            Task { @MainActor [weak self] in
                guard let self, let connection,
                      self.isCurrent(connection, channel: .preview) else { return }
                if let error {
                    self.connectionDidClose(connection, channel: .preview, reason: error.localizedDescription)
                    return
                }
                self.didSendPreviewHello = true
                self.flushPreviewFrame()
            }
        })
    }

    private func handlePreviewHello(_ payload: Data) {
        guard let hello = try? JSONDecoder().decode(BoothTransportHello.self, from: payload) else {
            connectionDidClose(previewConnection, channel: .preview, reason: "invalid preview hello")
            return
        }
        let expectedRole: DeviceRole = role == .mac ? .iPad : .mac
        guard hello.protocolVersion == BoothTransportHello.currentProtocolVersion,
              hello.role == expectedRole else {
            connectionDidClose(previewConnection, channel: .preview, reason: "incompatible preview hello")
            return
        }
        if role == .iPad, let peerPreference = hello.networkPreference {
            requestedPreference = peerPreference
        }
        previewPeerID = hello.deviceID
        validatePreviewIdentity()
    }

    private func validatePreviewIdentity() {
        guard peerAuthenticated else { return }
        if !previewPeerSupportsIdentity {
            previewIdentityVerified = true
            flushPreviewFrame()
            return
        }
        guard previewPeerMatchesControlPeer(
            previewPeerID: previewPeerID,
            controlPeerID: expectedPeerDeviceID,
            identityRequired: previewPeerSupportsIdentity
        ) else {
            connectionDidClose(previewConnection, channel: .preview, reason: "preview peer does not match control peer")
            return
        }
        previewIdentityVerified = true
        flushPreviewFrame()
    }

    private func send(_ message: Message, on connection: NWConnection?, channel: BoothTransportChannel) {
        guard let connection else { return }
        guard let payload = try? message.encoded(),
              let frame = try? BoothFrameEncoder.encode(channel: channel, payload: payload) else { return }
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error { print("[Network] send failed: \(error.localizedDescription)") }
        })
    }

    private func flushPreviewFrame() {
        guard didSendPreviewHello,
              previewIdentityVerified,
              let connection = previewConnection,
              let jpeg = previewFrames.startNext() else { return }
        sendPreviewFrame(jpeg, on: connection)
    }

    private func sendPreviewFrame(_ jpeg: Data, on connection: NWConnection) {
        guard let frame = try? BoothFrameEncoder.encode(channel: .preview, payload: jpeg) else {
            let next = previewFrames.completeWrite()
            if let next { sendPreviewFrame(next, on: connection) }
            return
        }
        previewFramesSent += 1
        previewBytesSent += jpeg.count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(connection, channel: .preview) else { return }
                if let error {
                    print("[Network] preview send failed: \(error.localizedDescription)")
                    self.previewFrames.resetWriteState()
                    self.connectionDidClose(connection, channel: .preview, reason: error.localizedDescription)
                    return
                }
                if let next = self.previewFrames.completeWrite() {
                    self.sendPreviewFrame(next, on: connection)
                }
                self.publishPreviewMetricsIfNeeded()
            }
        })
    }

    private func publishPreviewMetricsIfNeeded() {
        let now = Date()
        let elapsed = now.timeIntervalSince(previewMetricsStartedAt)
        guard elapsed >= 1 else { return }
        var diagnostics = BoothPreviewDiagnostics()
        diagnostics.fps = Double(previewFramesSent) / elapsed
        diagnostics.bytesPerSecond = Double(previewBytesSent) / elapsed
        diagnostics.framesSubmitted = previewFramesSubmitted
        diagnostics.framesSent = previewFramesSent
        diagnostics.framesCoalesced = previewFrames.coalescedFrameCount
        connectionStatus.publishPreviewDiagnostics(diagnostics)
#if DEBUG
        let state = previewIdentityVerified ? "ready" : "waiting"
        NSLog(
            "[Network] Preview state=%@ submitted=%d sent=%d coalesced=%d control=%@",
            state,
            previewFramesSubmitted,
            previewFramesSent,
            previewFrames.coalescedFrameCount,
            connectionStateLabel
        )
#endif
        previewMetricsStartedAt = now
        previewFramesSubmitted = 0
        previewFramesSent = 0
        previewBytesSent = 0
    }

    private var connectionStateLabel: String {
        switch connectionState {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.peerAuthenticated else { return }
                if Date().timeIntervalSince(self.lastControlMessageAt) > Self.heartbeatTimeout {
                    self.connectionDidClose(self.controlConnection, channel: .control, reason: "heartbeat timeout")
                } else {
                    self.sendControl(.heartbeat)
                }
            }
        }
    }

    private func connectionDidClose(_ connection: NWConnection?, channel: BoothTransportChannel, reason: String? = nil) {
        if let reason { print("[Network] \(channel) disconnected: \(reason)") }
        if let reason { lastNetworkError = reason }
        if channel == .control {
            guard let connection, connection === controlConnection else { return }
            if role == .iPad {
                startRouteDiscovery()
                return
            }
            let command = routeMachine.transportDisconnected(
                lanAvailable: pathAvailable(.wiredEthernet),
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: command == .startWiFi(fallback: true) ? "LAN unavailable" : nil)
        } else {
            guard let connection, connection === previewConnection else { return }
            previewConnection?.cancel()
            previewConnection = nil
            previewEndpointDescription = nil
            previewFrames.reset()
            resetPreviewIdentity()
            connectionStatus.publishPreviewChannel(connected: false)
            if role == .iPad {
                previewBrowser?.cancel()
                previewBrowser = nil
            }
            scheduleReconnect()
        }
    }

    private func isCurrent(_ connection: NWConnection, channel: BoothTransportChannel) -> Bool {
        channel == .control ? connection === controlConnection : connection === previewConnection
    }

    private func isCurrent(_ listener: NWListener, channel: BoothTransportChannel) -> Bool {
        channel == .control ? listener === controlListener : listener === previewListener
    }

    private func isCurrent(_ browser: NWBrowser, channel: BoothTransportChannel) -> Bool {
        channel == .control ? browser === controlBrowser : browser === previewBrowser
    }

    private func publishStatus() {
        connectionStatus.publish(
            requestedNetwork: requestedPreference,
            state: connectionState,
            peerID: peerDeviceID,
            peerDisplayName: peerName.isEmpty ? nil : peerName,
            routeState: routeMachine.state,
            effectiveNetwork: routeMachine.effectiveTransport,
            fallbackReason: fallbackActive ? fallbackReason : nil,
            isLANPathAvailable: isLANPathAvailable,
            isWiFiPathAvailable: isWiFiPathAvailable,
            lanPathObservation: didReceiveLANPathUpdate
                ? (isLANPathAvailable ? .available : .unavailable) : .unknown,
            wifiPathObservation: didReceiveWiFiPathUpdate
                ? (isWiFiPathAvailable ? .available : .unavailable) : .unknown,
            lanHandshake: lanHandshakeState,
            lastNetworkError: lastNetworkError,
            isPreviewChannelConnected: previewConnection != nil
        )
    }

    private func publishPathAvailability() {
        connectionStatus.publishPathAvailability(
            lan: isLANPathAvailable,
            wifi: isWiFiPathAvailable,
            lanObserved: didReceiveLANPathUpdate,
            wifiObserved: didReceiveWiFiPathUpdate
        )
    }

    private func resetPreviewConnection() {
        previewConnection?.cancel()
        previewConnection = nil
        previewEndpointDescription = nil
        previewFrames.reset()
        resetPreviewIdentity()
        if role == .iPad {
            previewBrowser?.cancel()
            previewBrowser = nil
        }
    }

    private func resetPreviewIdentity() {
        previewPeerID = nil
        previewPeerSupportsIdentity = false
        didSendPreviewHello = false
        previewIdentityVerified = false
    }

    private func resetControlAuthentication() {
        didReceiveHello = false
        peerAuthenticated = false
        didInitiateAuthentication = false
        pendingAuthChallenge = nil
        peerHello = nil
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        peerName = ""
        connectedPeerNames = []
        connectionStatus.publishPairing(authenticated: false)
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            if self.role == .iPad, self.activeInterface == nil {
                self.startRouteDiscovery()
                return
            }
            if self.activeInterface == nil {
                let command = self.routeMachine.start(
                    lanAvailable: self.pathAvailable(.wiredEthernet),
                    wifiAvailable: self.pathAvailable(.wifi)
                )
                self.apply(command, reason: nil)
                return
            }
            if self.role == .mac {
                if self.controlListener == nil { self.startListener(channel: .control) }
                if self.previewListener == nil { self.startListener(channel: .preview) }
            } else {
                if self.controlBrowser == nil { self.startBrowser(channel: .control) }
                if self.previewBrowser == nil { self.startBrowser(channel: .preview) }
            }
        }
    }

    private static func localDeviceName(for role: DeviceRole) -> String {
#if os(iOS)
        let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "PRC Booth iPad" : name
#else
        let name = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name! : (role == .mac ? "PRC Booth Mac" : "PRC Booth iPad")
#endif
    }
}
