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
    // The documented direct Ethernet setup uses these addresses. Bonjour is
    // still preferred, but iPadOS 16 Lightning adapters can have a working
    // IP path without returning a constrained Bonjour result.
    private static let directLANHost = NWEndpoint.Host("10.0.0.1")
    private static let directLANControlPort = NWEndpoint.Port(rawValue: 58_500)!
    private static let directLANPreviewPort = NWEndpoint.Port(rawValue: 58_501)!
    static let routeDiscoveryGracePeriod: TimeInterval = 2.0
    private static let lanRecoveryStabilityPeriod: TimeInterval = 2
    private static let lanRecoveryCooldown: TimeInterval = 5
    private static let pairingCapability = "pairing-v1"
    private static let previewIdentityCapability = "preview-identity"
    private static let heartbeatInterval: TimeInterval = 2
    private static let heartbeatTimeout: TimeInterval = 8

    private struct PendingPairingCommit: Equatable, Sendable {
        let sessionID: String
        let peer: TrustedBoothPeer
        let macIdentity: BoothDeviceIdentity
        let secret: Data
        let expiresAt: Date

        var result: BoothPairingResult {
            BoothPairingResult(
                accepted: true,
                macIdentity: macIdentity,
                sharedSecret: secret,
                pairingSessionID: sessionID
            )
        }
    }

    private enum PairingControlSendError: Error {
        case failed(String)

        var message: String {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    private struct AuthenticationSecret {
        let data: Data
        let source: String
    }

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
    private var pendingPairingIntent: BoothPairingIntent?
    private var pendingPairingSessionID: String?
    private var receivedPairingSession: BoothPairingSessionInfo?
    private var currentPairingSession: BoothPairingSession?
    private var pairingExpiryTask: Task<Void, Never>?
    private var pairingExpirySessionID: String?
    private var pairingExpiryAt: Date?
    private var incomingPairingRequest: IncomingBoothPairingRequest?
    private var lastPairingIntentAt: [String: Date] = [:]
    private var pendingPairingFailure: String?
    private var pendingPairingCommit: PendingPairingCommit?
    private var deferredAuthChallenge: BoothAuthChallenge?
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
    // Some iPadOS 16 Lightning Ethernet adapters expose a usable IP path but
    // do not return Bonjour results to a browser constrained to
    // `.wiredEthernet`. This browser only discovers a LAN-advertised peer.
    private var lanCompatibilityRouteDiscoveryBrowser: NWBrowser?
    private var routeDiscoverySelection = BoothRouteDiscoverySelection()
    private var directLANPairingAttemptedSessionID: String?
    private var pendingWiFiRouteEndpoint: NWEndpoint?
    private var pendingLANRouteEndpoint: NWEndpoint?
    private var routeDiscoveryFallbackTask: Task<Void, Never>?
    private var routeDiscoveryGate = BoothRouteDiscoveryGenerationGate()
    private var callbackGate = BoothTransportCallbackGate()
    private var controlConnection: NWConnection?
    private var controlConnectionGeneration = 0
    private var pairingGeneration = 0
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
    private var pairingStageValue: BoothPairingStage = .idle

    public var canAttemptPreferredLANRecovery: @MainActor () -> Bool = { true }
    public var canAcceptIncomingPairing: @MainActor () -> Bool = { true }

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
    public var pairingStage: BoothPairingStage { pairingStageValue }
    public var pairingExpiresAt: Date? {
        currentPairingSession?.info.expiresAt
            ?? pendingPairingCommit?.expiresAt
            ?? pairingExpiryAt
    }
    public var pairingPeerID: String? {
        pendingPairingRequest?.iPadIdentity.id
            ?? pendingPairingIntent?.iPadIdentity.id
            ?? incomingPairingRequest?.iPadIdentity.id
            ?? pendingPairingCommit?.peer.id
    }
    public var pairingPeerDisplayName: String? {
        pendingPairingRequest?.iPadIdentity.displayName
            ?? pendingPairingIntent?.iPadIdentity.displayName
            ?? incomingPairingRequest?.iPadIdentity.displayName
            ?? pendingPairingCommit?.peer.displayName
    }
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
        startPairingSession(keepingControlConnection: false)
    }

    @discardableResult
    private func startPairingSession(keepingControlConnection: Bool) -> Bool {
        guard role == .mac else { return false }
        do {
            if !keepingControlConnection, !peerAuthenticated {
                controlConnectionGeneration &+= 1
                controlConnection?.cancel()
                controlConnection = nil
                controlEndpointDescription = nil
                resetControlAuthentication()
            }
            resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
            let session = try BoothPairingSession.make(macIdentity: localIdentity)
            currentPairingSession = session
            schedulePairingExpiry(for: session)
            if let expiresAt = currentPairingSession?.info.expiresAt {
                setPairingStage(.discovering, state: .pairing(expiresAt: expiresAt))
            }
            refreshAdvertisedServices()
            return true
        } catch {
            lastNetworkError = error.localizedDescription
            pendingPairingFailure = error.localizedDescription
            setPairingStage(.failed, state: .failed(error.localizedDescription))
            return false
        }
    }

    public func cancelPairingSession() {
        let connection = !peerAuthenticated ? controlConnection : nil
        let pairingSessionID = activePairingControlSessionID
        resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
        setPairingStage(.idle, state: .idle)
        refreshAdvertisedServices()
        if let connection {
            let reason = role == .mac ? "Pairing cancelled on Mac." : "Pairing cancelled on iPad."
            sendThenClose(
                .pairingResult(result: BoothPairingResult(
                    accepted: false,
                    reason: reason,
                    pairingSessionID: pairingSessionID
                )),
                connection: connection,
                reason: reason
            )
        } else if !peerAuthenticated {
            controlConnection?.cancel()
        }
    }

    private func resetPairingState(
        clearTarget: Bool,
        clearPendingCommit: Bool,
        clearFailure: Bool
    ) {
        pairingGeneration &+= 1
        cancelPairingExpiry()
        currentPairingSession?.invalidate()
        currentPairingSession = nil
        incomingPairingRequest = nil
        pendingPairingRequest = nil
        pendingPairingIntent = nil
        pendingPairingSessionID = nil
        receivedPairingSession = nil
        deferredAuthChallenge = nil
        if !peerAuthenticated {
            pendingAuthChallenge = nil
            didInitiateAuthentication = false
        }
        if clearPendingCommit { pendingPairingCommit = nil }
        if clearFailure { pendingPairingFailure = nil }
        if clearTarget { targetPeerID = nil }
    }

    private func clearActivePairingSession() {
        // Keep a provisional commit, if one was just created, so the result
        // can be resent until reciprocal authentication succeeds.
        resetPairingState(
            clearTarget: false,
            clearPendingCommit: false,
            clearFailure: false
        )
    }

    private func cancelPairingExpiry() {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingExpirySessionID = nil
        pairingExpiryAt = nil
    }

    private func schedulePairingExpiry(for session: BoothPairingSession) {
        schedulePairingExpiry(sessionID: session.info.sessionID, expiresAt: session.info.expiresAt)
    }

    private func schedulePairingExpiry(sessionID: String, expiresAt: Date) {
        cancelPairingExpiry()
        pairingExpirySessionID = sessionID
        pairingExpiryAt = expiresAt
        let pairingGenerationAtStart = pairingGeneration
        pairingExpiryTask = Task { @MainActor [weak self] in
            do {
                while !Task.isCancelled {
                    let remaining = expiresAt.timeIntervalSinceNow
                    if remaining <= 0 { break }
                    try await Task.sleep(for: .seconds(remaining))
                }
            } catch {
                return
            }
            guard let self,
                  self.pairingExpirySessionID == sessionID,
                  BoothPairingExpiryGate.accepts(
                      sessionID: sessionID,
                      generation: pairingGenerationAtStart,
                      currentGeneration: self.pairingGeneration,
                      currentSessionID: self.currentPairingSession?.info.sessionID,
                      pendingSessionID: self.pendingPairingSessionID,
                      pendingResultSessionID: self.pendingPairingCommit?.sessionID
                  ) else { return }
            self.pairingExpiryTask = nil
            self.pairingExpirySessionID = nil
            self.pairingExpiryAt = nil
            if BoothPairingSession.isCurrentSession(
                sessionID,
                currentSessionID: self.currentPairingSession?.info.sessionID
            ) {
                self.expirePairingSession(sessionID: sessionID)
            } else if self.pendingPairingCommit?.sessionID == sessionID {
                self.expirePendingPairingCommit(sessionID: sessionID)
            } else if self.pendingPairingSessionID == sessionID {
                self.expirePendingPairingSession(sessionID: sessionID)
            }
        }
    }

    private func expirePairingSession(sessionID: String) {
        guard BoothPairingSession.isCurrentSession(
            sessionID,
            currentSessionID: currentPairingSession?.info.sessionID
        ) else { return }

        let reason = BoothPairingError.expired.localizedDescription
        let connection = peerAuthenticated ? nil : controlConnection
        resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
        pendingPairingFailure = reason
        setPairingStage(.failed, state: .failed(reason))
        refreshAdvertisedServices()
        if let connection {
            sendThenClose(
                .pairingResult(result: BoothPairingResult(
                    accepted: false,
                    reason: reason,
                    pairingSessionID: sessionID
                )),
                connection: connection,
                reason: reason
            )
        }
    }

    private func expirePendingPairingCommit(sessionID: String) {
        guard pendingPairingCommit?.sessionID == sessionID else { return }
        let reason = BoothPairingError.expired.localizedDescription
        let connection = peerAuthenticated ? nil : controlConnection
        resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
        pendingPairingFailure = reason
        setPairingStage(.failed, state: .failed(reason))
        if let connection { connection.cancel() }
    }

    private func expirePendingPairingSession(sessionID: String) {
        guard pendingPairingSessionID == sessionID else { return }
        let reason = "Pairing timed out. Please try again."
        let connection = peerAuthenticated ? nil : controlConnection
        resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
        pendingPairingFailure = reason
        setPairingStage(.failed, state: .failed(reason))
        if let connection { connection.cancel() }
    }

    private func failPairing(
        _ reason: String,
        clearTarget: Bool = true,
        clearPendingCommit: Bool = true,
        closeConnection: Bool = true
    ) {
        let connection = closeConnection && !peerAuthenticated ? controlConnection : nil
        resetPairingState(
            clearTarget: clearTarget,
            clearPendingCommit: clearPendingCommit,
            clearFailure: true
        )
        refreshAdvertisedServices()
        pendingPairingFailure = reason
        lastNetworkError = reason
        setPairingStage(.failed, state: .failed(reason))
        if let connection { connection.cancel() }
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
        resetPairingState(clearTarget: false, clearPendingCommit: true, clearFailure: true)
        pendingPairingIntent = nil
        trustedStore.preferredPeerID = peerID
        targetPeerID = peerID
        setPairingStage(.idle, state: .idle)
        restartDiscoveryForPeerSelection()
    }

    public func requestPairing(with peerID: String) {
        guard role == .iPad, !trustedStore.trustedPeerIDs.contains(peerID) else { return }
        guard let peer = discoveredPeersByID[peerID], peer.role == .mac else {
            let reason = "The selected Mac was not found."
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            return
        }
        guard peer.protocolVersion == BoothTransportHello.currentProtocolVersion else {
            let reason = BoothPairingError.incompatibleProtocol.localizedDescription
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            return
        }

        resetPairingState(clearTarget: false, clearPendingCommit: true, clearFailure: true)
        pendingPairingRequest = nil
        targetPeerID = peerID
        pendingPairingIntent = BoothPairingIntent(
            iPadIdentity: localIdentity,
            targetMacDeviceID: peerID
        )
        let intentSessionID = "intent-\(UUID().uuidString)"
        pendingPairingSessionID = intentSessionID
        schedulePairingExpiry(
            sessionID: intentSessionID,
            expiresAt: Date().addingTimeInterval(BoothPairingSession.lifetime)
        )
        setPairingStage(.discovering, state: .waitingForMac(peerID: peerID))
        restartDiscoveryForPeerSelection()
    }

    public func pairWithPIN(peerID: String, pin: String) {
        guard role == .iPad else { return }
        guard BoothPairingSession.isValidPIN(pin) else {
            let reason = BoothPairingError.invalidPIN.localizedDescription
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            return
        }
        let discoveredPeer = discoveredPeersByID[peerID]
        if let discoveredPeer, discoveredPeer.role != .mac {
            let reason = "The selected Mac was not found."
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            return
        }
        if let discoveredPeer,
           discoveredPeer.protocolVersion != BoothTransportHello.currentProtocolVersion {
            let reason = BoothPairingError.incompatibleProtocol.localizedDescription
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            return
        }
        let verifiedSession = receivedPairingSession.flatMap { session in
            session.macDeviceID == peerID && session.expiresAt > Date() ? session : nil
        }
        guard let sessionID = discoveredPeer?.pairingSessionID ?? verifiedSession?.sessionID,
              !sessionID.isEmpty else {
            let reason = "Pairing session unavailable."
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            return
        }
        beginPairing(
            peerID: peerID,
            sessionID: sessionID,
            method: .pin(pin),
            expiresAt: discoveredPeer?.pairingExpiresAt ?? verifiedSession?.expiresAt
        )
    }

    public func pairWithQRCode(_ payload: BoothPairingQRCodePayload) {
        guard role == .iPad else { return }
        do {
            try payload.validate()
            beginPairing(
                peerID: payload.macDeviceID,
                sessionID: payload.pairingSessionID,
                method: .qrToken(payload.oneTimeToken),
                expiresAt: payload.expiresAt
            )
        } catch {
            let reason = error.localizedDescription
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
        }
    }

    public func forgetPeer(_ peerID: String) {
        let wasCurrent = peerDeviceID == peerID
        trustedStore.forget(peerID: peerID)
        if targetPeerID == peerID {
            resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
        }
        if wasCurrent { controlConnection?.cancel() }
        setPairingStage(.idle, state: .idle)
        if role == .iPad { restartDiscoveryForPeerSelection() }
    }

    public func forgetAllPeers() {
        trustedStore.forgetAll()
        resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
        peerAuthenticated = false
        controlConnection?.cancel()
        setPairingStage(.idle, state: .idle)
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
        let keepingTrustedTarget = targetPeerID.map(trustedStore.trustedPeerIDs.contains) ?? false
        resetPairingState(
            clearTarget: !keepingTrustedTarget,
            clearPendingCommit: true,
            clearFailure: true
        )
        setPairingStage(.idle, state: .idle)
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
        // A direct, manually addressed Ethernet link commonly has no default
        // route or DNS server. NWPathMonitor therefore reports it as
        // unsatisfied even while 10.0.0.1 <-> 10.0.0.2 TCP is usable. The Mac
        // owns the fixed listener for that configuration, so keep it alive;
        // the accepted connection/hello remains the authoritative liveness
        // signal. Without this guard the Mac silently replaced ports 58500/1
        // with Wi-Fi listeners during physical iPad pairing.
        if retainsManualLANListener { return }
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
        if retainsManualLANListener {
            connectionState = .disconnected
            publishStatus()
            return
        }
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

        // A Mac must keep its LAN listeners alive while waiting for an iPad.
        // The handshake timeout belongs to the initiating iPad connection;
        // applying it to an idle Mac made direct Ethernet fall back to Wi-Fi
        // after five seconds, before pairing could begin.
        if interface == .wiredEthernet, role == .iPad {
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
        if startDirectLANPairingFallbackIfNeeded() { return }
        startRouteDiscoveryBrowser(on: .wifi, generation: generation)
        startRouteDiscoveryBrowser(on: .wiredEthernet, generation: generation)
        startRouteDiscoveryBrowser(
            on: .wiredEthernet,
            generation: generation,
            parameters: .tcp,
            isLANCompatibilityFallback: true
        )
    }

    private func startDirectLANPairingFallbackIfNeeded() -> Bool {
        guard let sessionID = activePairingControlSessionID,
              sessionID != directLANPairingAttemptedSessionID,
              targetPeerID != nil,
              pendingPairingRequest != nil || pendingPairingIntent != nil else {
            return false
        }
        // On iPadOS 16 with a direct Lightning Ethernet adapter, the link can
        // pass IP traffic while Bonjour never returns a wired result. Do not
        // make the fixed-address recovery path depend on that missing
        // advertisement. The first hello and the pairing target ID still
        // reject any endpoint that is not the selected Mac.
        directLANPairingAttemptedSessionID = sessionID
        print("[NetworkRoute] Starting direct LAN control fallback")
        connectDiscoveredRoute(
            interface: .wiredEthernet,
            endpoint: directLANEndpoint(for: .control),
            browser: nil,
            connectionParameters: .tcp
        )
        return true
    }

    private func directLANEndpoint(for channel: BoothTransportChannel) -> NWEndpoint {
        .hostPort(
            host: Self.directLANHost,
            port: channel == .control ? Self.directLANControlPort : Self.directLANPreviewPort
        )
    }

    private func startRouteDiscoveryBrowser(
        on interface: BoothNetworkInterfacePolicy,
        generation: Int,
        parameters: NWParameters? = nil,
        isLANCompatibilityFallback: Bool = false
    ) {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.controlServiceType, domain: nil),
            using: parameters ?? makeParameters(for: interface)
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            Task { @MainActor [weak self, weak browser] in
                guard let self, let browser,
                      self.routeDiscoveryGate.accepts(generation),
                      self.isCurrentRouteDiscoveryBrowser(
                        browser,
                        interface: interface,
                        isLANCompatibilityFallback: isLANCompatibilityFallback
                      ) else { return }

                self.updateDiscoveredPeers(from: results, interface: interface)
                for result in results {
                    guard let peer = self.discoveredPeer(from: result, interface: interface),
                          peer.role == .mac,
                          let targetPeerID = self.targetPeerID,
                          peer.id == targetPeerID else { continue }
                    guard peer.protocolVersion == BoothTransportHello.currentProtocolVersion else {
                        let reason = BoothPairingError.incompatibleProtocol.localizedDescription
                        self.pendingPairingFailure = reason
                        self.setPairingStage(.failed, state: .failed(reason))
                        continue
                    }

                    let advertisedPreference = peer.networkPreference
                    guard !isLANCompatibilityFallback || advertisedPreference == .lan else {
                        continue
                    }
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
                      self.isCurrentRouteDiscoveryBrowser(
                        browser,
                        interface: interface,
                        isLANCompatibilityFallback: isLANCompatibilityFallback
                      ) else { return }
                print("[NetworkRoute] \(interface.rawValue) discovery failed: \(error.localizedDescription)")
                if isLANCompatibilityFallback {
                    self.lanCompatibilityRouteDiscoveryBrowser = nil
                } else if interface == .wifi {
                    self.wifiRouteDiscoveryBrowser = nil
                } else {
                    self.lanRouteDiscoveryBrowser = nil
                }
                self.scheduleReconnect()
            }
        }
        browser.start(queue: .main)
        if isLANCompatibilityFallback {
            lanCompatibilityRouteDiscoveryBrowser = browser
        } else if interface == .wifi {
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
        browser: NWBrowser?,
        connectionParameters: NWParameters? = nil
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
        connect(to: endpoint, channel: .control, parameters: connectionParameters)
    }

    private func cancelRouteDiscovery(keeping browser: NWBrowser? = nil) {
        if wifiRouteDiscoveryBrowser !== browser { wifiRouteDiscoveryBrowser?.cancel() }
        if lanRouteDiscoveryBrowser !== browser { lanRouteDiscoveryBrowser?.cancel() }
        if lanCompatibilityRouteDiscoveryBrowser !== browser { lanCompatibilityRouteDiscoveryBrowser?.cancel() }
        routeDiscoveryGate.invalidate()
        routeDiscoveryFallbackTask?.cancel()
        routeDiscoveryFallbackTask = nil
        wifiRouteDiscoveryBrowser = nil
        lanRouteDiscoveryBrowser = nil
        lanCompatibilityRouteDiscoveryBrowser = nil
        pendingWiFiRouteEndpoint = nil
        pendingLANRouteEndpoint = nil
        routeDiscoverySelection.reset()
    }

    private func isCurrentRouteDiscoveryBrowser(
        _ browser: NWBrowser,
        interface: BoothNetworkInterfacePolicy,
        isLANCompatibilityFallback: Bool = false
    ) -> Bool {
        if isLANCompatibilityFallback {
            return browser === lanCompatibilityRouteDiscoveryBrowser
        }
        return interface == .wifi
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
        controlConnectionGeneration &+= 1
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
        deferredAuthChallenge = nil
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        let pairingState: BoothPairingState
        if let pendingPairingFailure {
            pairingState = .failed(pendingPairingFailure)
            pairingStageValue = .failed
        } else if let incomingPairingRequest,
           let session = currentPairingSession {
            pairingState = .incoming(
                request: incomingPairingRequest,
                expiresAt: session.info.expiresAt
            )
        } else if let session = currentPairingSession, session.isActive() {
            pairingState = .pairing(expiresAt: session.info.expiresAt)
        } else if let pendingPairingCommit {
            pairingState = .authenticating(peerID: pendingPairingCommit.peer.id)
        } else if let pendingPairingRequest {
            pairingState = .pairing(
                expiresAt: discoveredPeersByID[pendingPairingRequest.targetMacDeviceID]?.pairingExpiresAt
                    ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
            )
        } else if let pendingPairingIntent {
            pairingState = .waitingForMac(peerID: pendingPairingIntent.targetMacDeviceID)
        } else {
            pairingStageValue = .idle
            pairingState = .idle
        }
        publishPairingStatus(state: pairingState)
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
            if activeInterface == .wiredEthernet {
                let port = channel == .control
                    ? Self.directLANControlPort
                    : Self.directLANPreviewPort
                listener = try NWListener(using: makeParameters(for: activeInterface), on: port)
            } else {
                listener = try NWListener(using: makeParameters(for: activeInterface))
            }
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
            let reason: String
            if peerAuthenticated {
                reason = "Another iPad is currently connected."
            } else if currentPairingSession?.isActive() == true {
                reason = "Another iPad is currently being paired."
            } else {
                reason = "Another pairing request is already in progress."
            }
            rejectIncomingConnection(connection, reason: reason)
            return
        }
        guard activeInterface != nil else {
            connection.cancel()
            return
        }
        if channel == .control {
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnectionGeneration &+= 1
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

    private func connect(
        to endpoint: NWEndpoint,
        channel: BoothTransportChannel,
        parameters: NWParameters? = nil
    ) {
        guard let activeInterface else { return }
        if channel == .preview, expectedPeerDeviceID == nil { return }
        let description = endpoint.debugDescription
        if channel == .control {
            guard controlConnection == nil || controlEndpointDescription != description else { return }
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnectionGeneration &+= 1
            controlConnection = NWConnection(
                to: endpoint,
                using: parameters ?? makeParameters(for: activeInterface)
            )
            controlEndpointDescription = description
            resetControlAuthentication()
            controlParser = BoothFrameParser()
            if let connection = controlConnection { configure(connection, channel: channel) }
        } else {
            guard previewConnection == nil || previewEndpointDescription != description else { return }
            previewFrames.reset()
            previewConnection?.cancel()
            previewConnection = NWConnection(
                to: endpoint,
                using: parameters ?? makeParameters(for: activeInterface)
            )
            previewEndpointDescription = description
            previewParser = BoothFrameParser()
            resetPreviewIdentity()
            if let connection = previewConnection { configure(connection, channel: channel) }
        }
    }

    private func configure(_ connection: NWConnection, channel: BoothTransportChannel) {
        let generationAtStart = callbackGate.generation
        let connectionGenerationAtStart = channel == .control ? controlConnectionGeneration : nil
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor [weak self] in
                guard let self, let connection else { return }
                guard self.callbackGate.accepts(generationAtStart),
                      self.isCurrent(connection, channel: channel),
                      connectionGenerationAtStart == nil
                        || self.controlConnectionGeneration == connectionGenerationAtStart else { return }
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
        logPairingMessage(message, sent: false)
        switch message {
        case .helloDetails(let hello):
            handleHello(hello)
        case .pairingIntent(let intent):
            handlePairingIntent(intent)
        case .pairingSessionAvailable(let session):
            handlePairingSessionAvailable(session)
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
            if hasEphemeralPairingState {
                failPairing(reason)
            } else {
                pendingPairingFailure = reason
                setPairingStage(.failed, state: .failed(reason))
            }
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
            if let pendingPairingCommit {
                guard pendingPairingCommit.peer.id == hello.deviceID else {
                    rejectControlConnection("This Mac is waiting for a different iPad to finish pairing.")
                    return
                }
                sendPendingPairingResult(pendingPairingCommit, on: controlConnection)
                return
            }
            switch BoothPeerSelectionPolicy.admission(
                peerID: hello.deviceID,
                preferredPeerID: trustedStore.preferredPeerID,
                trustedPeerIDs: trustedStore.trustedPeerIDs
            ) {
            case .allowed:
                beginAuthentication(with: hello.deviceID)
            case .unpaired:
                if let session = currentPairingSession, session.isActive() {
                    let state: BoothPairingState
                    if let incomingPairingRequest {
                        state = .incoming(request: incomingPairingRequest, expiresAt: session.info.expiresAt)
                    } else {
                        state = .pairing(expiresAt: session.info.expiresAt)
                    }
                    setPairingStage(pairingStageValue == .failed ? .discovering : pairingStageValue, state: state)
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
        if pendingPairingCommit?.peer.id == hello.deviceID {
            beginAuthentication(with: hello.deviceID)
            return
        }
        if let pendingPairingRequest {
            sendPairingRequest(pendingPairingRequest, on: controlConnection)
            return
        }
        if let pendingPairingIntent {
            sendPairingIntent(pendingPairingIntent, on: controlConnection)
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

    private var hasEphemeralPairingState: Bool {
        currentPairingSession != nil
            || incomingPairingRequest != nil
            || pendingPairingRequest != nil
            || pendingPairingIntent != nil
            || pendingPairingCommit != nil
    }

    private var currentConnectionOwnsPairingState: Bool {
        guard let peerID = peerHello?.deviceID else { return false }
        if role == .mac {
            return incomingPairingRequest?.iPadIdentity.id == peerID
                || pendingPairingCommit?.peer.id == peerID
        }
        return targetPeerID == peerID
            && (pendingPairingIntent != nil
                || pendingPairingRequest != nil
                || pendingPairingCommit != nil)
    }

    private var activePairingControlSessionID: String? {
        currentPairingSession?.info.sessionID
            ?? pendingPairingRequest?.sessionID
            ?? pendingPairingSessionID
            ?? pendingPairingCommit?.sessionID
    }

    private var pendingPairingStateExpiry: Date {
        pairingExpiresAt ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
    }

    private func sendPairingIntent(_ intent: BoothPairingIntent, on connection: NWConnection?) {
        setPairingStage(.intentSent, state: .waitingForMac(peerID: intent.targetMacDeviceID))
        sendCriticalControl(
            .pairingIntent(intent: intent),
            on: connection,
            sessionID: pendingPairingSessionID
        ) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.failPairing("Pairing request could not be delivered: \(error.message)")
            }
        }
    }

    private func sendPairingSession(
        _ session: BoothPairingSessionInfo,
        request: IncomingBoothPairingRequest
    ) {
        pendingPairingFailure = nil
        setPairingStage(.sessionSending, state: .incoming(request: request, expiresAt: session.expiresAt))
        sendCriticalControl(
            .pairingSessionAvailable(session: session),
            on: controlConnection,
            sessionID: session.sessionID
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.setPairingStage(.sessionSent, state: .incoming(request: request, expiresAt: session.expiresAt))
            case .failure(let error):
                self.failPairing("Pairing session could not be delivered: \(error.message)")
            }
        }
    }

    private func sendPairingRequest(_ request: BoothPairingRequest, on connection: NWConnection?) {
        setPairingStage(.requestSending, state: .pairing(expiresAt: pendingPairingStateExpiry))
        sendCriticalControl(
            .pairingRequest(request: request),
            on: connection,
            sessionID: request.sessionID
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.setPairingStage(.requestSent, state: .pairing(expiresAt: self.pendingPairingStateExpiry))
            case .failure(let error):
                self.failPairing("Pairing request could not be delivered: \(error.message)")
            }
        }
    }

    private func sendPendingPairingResult(
        _ commit: PendingPairingCommit,
        on connection: NWConnection?
    ) {
        guard pendingPairingCommit == commit else { return }
        pendingPairingFailure = nil
        setPairingStage(.resultSending, state: .authenticating(peerID: commit.peer.id))
        sendCriticalControl(
            .pairingResult(result: commit.result),
            on: connection,
            sessionID: commit.sessionID
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.setPairingStage(.authenticating, state: .authenticating(peerID: commit.peer.id))
                self.beginAuthentication(with: commit.peer.id)
            case .failure(let error):
                self.failPendingPairingDelivery("Pairing result could not be delivered: \(error.message)")
            }
        }
    }

    private func sendPairingFailure(
        _ reason: String,
        retryable: Bool = false,
        preserveExistingPairing: Bool = false,
        completion: (@MainActor (Result<Void, PairingControlSendError>) -> Void)? = nil
    ) {
        let responseSessionID = preserveExistingPairing ? nil : activePairingControlSessionID
        if !preserveExistingPairing {
            setPairingStage(.resultSending, state: .failed(reason))
        }
        let result = BoothPairingResult(
            accepted: false,
            reason: reason,
            retryable: retryable,
            pairingSessionID: responseSessionID
        )
        sendCriticalControl(
            .pairingResult(result: result),
            on: controlConnection,
            sessionID: responseSessionID
        ) { [weak self] sendResult in
            guard let self else { return }
            switch sendResult {
            case .success:
                if !preserveExistingPairing {
                    self.setPairingStage(.failed, state: .failed(reason))
                }
            case .failure(let error):
                if preserveExistingPairing {
                    self.rejectControlConnection("Pairing response could not be delivered: \(error.message)")
                } else {
                    self.failPairing("Pairing response could not be delivered: \(error.message)")
                }
            }
            completion?(sendResult)
        }
    }

    private func failPendingPairingDelivery(_ reason: String) {
        let commit = pendingPairingCommit
        failPairing(
            reason,
            clearTarget: false,
            clearPendingCommit: false,
            closeConnection: true
        )
        guard let commit, pendingPairingCommit == commit else { return }
        pendingPairingSessionID = commit.sessionID
        schedulePairingExpiry(sessionID: commit.sessionID, expiresAt: commit.expiresAt)
    }

    private func handlePairingIntent(_ intent: BoothPairingIntent) {
        guard role == .mac, let hello = peerHello else {
            rejectControlConnection(BoothPairingError.invalidPairingIntent.localizedDescription)
            return
        }
        do {
            try intent.validate(peerHello: hello, localMacDeviceID: localIdentity.id)
        } catch {
            rejectControlConnection(error.localizedDescription)
            return
        }

        let now = Date()
        let decision = BoothPairingIntentPolicy.decide(
            iPadID: intent.iPadIdentity.id,
            activeRequestID: incomingPairingRequest?.iPadIdentity.id,
            hasActivePairingSession: currentPairingSession?.isActive(at: now) == true,
            boothIsIdle: canAcceptIncomingPairing(),
            hasAuthenticatedPeer: peerAuthenticated,
            lastRequestAt: lastPairingIntentAt[intent.iPadIdentity.id],
            now: now
        )

        switch decision {
        case .reject(let reason):
            sendPairingFailure(reason, preserveExistingPairing: true) { [weak self] _ in
                self?.rejectControlConnection(reason)
            }
        case .reuseSession:
            guard let session = currentPairingSession else {
                sendPairingFailure("Pairing session is unavailable.")
                return
            }
            let request = incomingPairingRequest ?? IncomingBoothPairingRequest(
                iPadIdentity: intent.iPadIdentity,
                receivedAt: now
            )
            incomingPairingRequest = request
            sendPairingSession(session.info, request: request)
        case .startSession:
            lastPairingIntentAt[intent.iPadIdentity.id] = now
            guard startPairingSession(keepingControlConnection: true),
                  let session = currentPairingSession else {
                sendPairingFailure("Pairing mode could not be started.")
                return
            }
            let request = IncomingBoothPairingRequest(
                iPadIdentity: intent.iPadIdentity,
                receivedAt: now
            )
            incomingPairingRequest = request
            sendPairingSession(session.info, request: request)
        }
    }

    private func handlePairingSessionAvailable(_ session: BoothPairingSessionInfo) {
        guard role == .iPad,
              let intent = pendingPairingIntent,
              intent.targetMacDeviceID == session.macDeviceID,
              let hello = peerHello,
              hello.role == .mac,
              hello.deviceID == session.macDeviceID,
              !session.sessionID.isEmpty,
              !session.macDeviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.expiresAt > Date() else {
            if role == .iPad, pendingPairingIntent != nil {
                failPairing("The Mac returned an invalid pairing session.")
            }
            return
        }

        if var peer = discoveredPeersByID[session.macDeviceID] {
            peer.pairingSessionID = session.sessionID
            peer.pairingExpiresAt = session.expiresAt
            discoveredPeersByID[session.macDeviceID] = peer
        }
        receivedPairingSession = session
        pendingPairingSessionID = session.sessionID
        schedulePairingExpiry(sessionID: session.sessionID, expiresAt: session.expiresAt)
        pendingPairingFailure = nil
        setPairingStage(.sessionReceived, state: .pairing(expiresAt: session.expiresAt))
        setPairingStage(.waitingForPIN, state: .pairing(expiresAt: session.expiresAt))
    }

    private func beginPairing(
        peerID: String,
        sessionID: String,
        method: BoothPairingMethod,
        expiresAt: Date? = nil
    ) {
        pairingGeneration &+= 1
        cancelPairingExpiry()
        let expiry = expiresAt
            ?? discoveredPeersByID[peerID]?.pairingExpiresAt
            ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
        pendingPairingIntent = nil
        pendingPairingFailure = nil
        pendingPairingSessionID = sessionID
        pendingPairingRequest = BoothPairingRequest(
            sessionID: sessionID,
            targetMacDeviceID: peerID,
            iPadIdentity: localIdentity,
            method: method
        )
        targetPeerID = peerID
        schedulePairingExpiry(sessionID: sessionID, expiresAt: expiry)
        setPairingStage(.requestSending, state: .pairing(expiresAt: expiry))
        if didReceiveHello, peerDeviceID == peerID, !peerAuthenticated,
           let pendingPairingRequest {
            sendPairingRequest(pendingPairingRequest, on: controlConnection)
            return
        }
        setPairingStage(.discovering, state: .pairing(expiresAt: expiry))
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

        incomingPairingRequest = IncomingBoothPairingRequest(
            iPadIdentity: request.iPadIdentity
        )
        let validation: BoothPairingAttemptResult
        switch request.method {
        case .pin(let pin):
            validation = session.validatePIN(pin)
        case .qrToken(let token):
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
                pendingPairingCommit = PendingPairingCommit(
                    sessionID: request.sessionID,
                    peer: peer,
                    macIdentity: localIdentity,
                    secret: secret,
                    expiresAt: session.info.expiresAt
                )
                pendingPairingRequest = nil
                clearActivePairingSession()
                pendingPairingFailure = nil
                pendingPairingSessionID = request.sessionID
                targetPeerID = peer.id
                schedulePairingExpiry(sessionID: request.sessionID, expiresAt: session.info.expiresAt)
                refreshAdvertisedServices()
                guard let commit = pendingPairingCommit else {
                    failPairing("Pairing result could not be prepared.")
                    return
                }
                sendPendingPairingResult(commit, on: controlConnection)
            } catch {
                failPairing(error.localizedDescription)
            }
        case .rejected(let remainingAttempts):
            let reason: String
            switch request.method {
            case .pin:
                reason = "Pairing PIN is invalid. \(remainingAttempts) attempts remaining."
            case .qrToken:
                reason = "Pairing QR code is invalid."
            }
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            sendPairingFailure(reason, retryable: remainingAttempts > 0)
        case .expired:
            expirePairingSession(sessionID: session.info.sessionID)
        case .locked:
            let reason = "Too many incorrect pairing PIN attempts."
            let connection = peerAuthenticated ? nil : controlConnection
            clearActivePairingSession()
            pendingPairingFailure = reason
            setPairingStage(.failed, state: .failed(reason))
            refreshAdvertisedServices()
            if let connection {
                sendThenClose(
                    .pairingResult(result: BoothPairingResult(
                        accepted: false,
                        reason: reason,
                        pairingSessionID: request.sessionID
                    )),
                    connection: connection,
                    reason: reason
                )
            }
        }
    }

    private func handlePairingResult(_ result: BoothPairingResult) {
        guard role == .iPad else { return }
        if !result.accepted, pendingPairingRequest == nil {
            // The Mac can cancel or expire after receiving an intent but before
            // the iPad has submitted its PIN. End that local intent immediately;
            // otherwise a closed connection would leave the iPad waiting until
            // its timer, or indefinitely after a route restart.
            guard let intent = pendingPairingIntent,
                  peerDeviceID == intent.targetMacDeviceID else { return }
            failPairing(result.reason ?? "Pairing rejected.")
            return
        }
        guard let pendingRequest = pendingPairingRequest else { return }
        if let resultSessionID = result.pairingSessionID,
           resultSessionID != pendingRequest.sessionID {
            return
        }
        if !result.accepted {
            let reason = result.reason ?? "Pairing rejected."
            pendingPairingFailure = reason
            if result.retryable {
                // Do not resend the same bad PIN automatically after a route
                // reconnect. Keep the selected peer visible and require a new
                // user-authored attempt.
                pendingPairingRequest = nil
                pendingPairingIntent = nil
                pendingPairingSessionID = nil
                deferredAuthChallenge = nil
                pendingAuthChallenge = nil
                didInitiateAuthentication = false
                cancelPairingExpiry()
                setPairingStage(.failed, state: .failed(reason))
            } else {
                let connection = controlConnection
                resetPairingState(clearTarget: true, clearPendingCommit: true, clearFailure: true)
                pendingPairingFailure = reason
                setPairingStage(.failed, state: .failed(reason))
                connection?.cancel()
            }
            return
        }

        guard BoothPairingTrustPolicy.accepts(
            result: result,
            pendingPairingRequest: pendingRequest,
            targetPeerID: targetPeerID,
            expectedSessionID: pendingPairingRequest?.sessionID
        ),
        let request = pendingPairingRequest,
        let macIdentity = result.macIdentity,
        let secret = result.sharedSecret else {
            failPairing("Pairing result was not valid for this request.")
            return
        }

        let expiry = pairingExpiresAt ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
        pendingPairingCommit = PendingPairingCommit(
            sessionID: request.sessionID,
            peer: TrustedBoothPeer(
                id: macIdentity.id,
                displayName: macIdentity.displayName,
                role: .mac,
                lastSeenAt: Date()
            ),
            macIdentity: macIdentity,
            secret: secret,
            expiresAt: expiry
        )
        pendingPairingSessionID = request.sessionID
        pendingPairingFailure = nil
        targetPeerID = macIdentity.id
        schedulePairingExpiry(sessionID: request.sessionID, expiresAt: expiry)
        setPairingStage(.resultReceived, state: .authenticating(peerID: macIdentity.id))
        beginAuthentication(with: macIdentity.id)
        if let deferredAuthChallenge {
            self.deferredAuthChallenge = nil
            handleAuthChallenge(deferredAuthChallenge)
        }
    }

    private func beginAuthentication(with peerID: String) {
        guard !didInitiateAuthentication else { return }
        guard secretForAuthentication(peerID: peerID) != nil else {
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
            setPairingStage(.authenticating, state: .authenticating(peerID: peerID))
            sendCriticalControl(
                .authChallenge(challenge: challenge),
                on: controlConnection,
                sessionID: activePairingControlSessionID
            ) { [weak self] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    self.handleAuthenticationSendFailure("Authentication challenge could not be delivered: \(error.message)")
                }
            }
        } catch {
            rejectControlConnection(error.localizedDescription)
        }
    }

    private func handleAuthChallenge(_ challenge: BoothAuthChallenge) {
        guard let hello = peerHello else {
            rejectControlConnection("Authentication failed: peer hello is unavailable for the challenge.")
            return
        }
        guard challenge.challengerDeviceID == hello.deviceID else {
            rejectControlConnection("Authentication failed: challenge sender does not match the connected peer.")
            return
        }
        guard challenge.responderDeviceID == localIdentity.id else {
            rejectControlConnection("Authentication failed: challenge targets a different device.")
            return
        }
        guard challenge.isWellFormed else {
            rejectControlConnection("Authentication failed: challenge format is invalid.")
            return
        }
        // The responder must not use its wall clock to reject a challenge.
        // Physical iPads on an isolated Ethernet link can differ from the Mac
        // by more than the challenge lifetime. The challenger verifies
        // freshness against its own locally retained issuedAt when the proof
        // returns, so replay protection stays authoritative without requiring
        // synchronized clocks.
        // Result delivery and the Mac's authentication challenge can arrive
        // back-to-back. Until the iPad has processed the accepted result, it
        // must not answer with a stale Keychain secret from an interrupted or
        // forgotten relationship.
        if role == .iPad,
           pendingPairingRequest != nil,
           pendingPairingCommit == nil {
            deferredAuthChallenge = challenge
            return
        }
        guard let authenticationSecret = authenticationSecret(peerID: hello.deviceID) else {
            rejectControlConnection("Authentication failed: pairing secret is unavailable.")
            return
        }
        let proof = BoothPairingCrypto.makeProof(
            for: challenge,
            responderDeviceID: localIdentity.id,
            secret: authenticationSecret.data
        )
        logPairing(
            stage: .authenticating,
            message: "auth proof source=\(authenticationSecret.source) transcript=\(BoothPairingCrypto.transcriptIdentifier(for: challenge, responderDeviceID: localIdentity.id))",
            sessionID: pairingSessionIDForDiagnostics
        )
        sendCriticalControl(
            .authProof(proof: proof),
            on: controlConnection,
            sessionID: activePairingControlSessionID
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if !self.didInitiateAuthentication { self.beginAuthentication(with: hello.deviceID) }
            case .failure(let error):
                self.handleAuthenticationSendFailure("Authentication proof could not be delivered: \(error.message)")
            }
        }
    }

    private func handleAuthProof(_ proof: BoothAuthProof) {
        guard let hello = peerHello else {
            rejectControlConnection("Authentication failed: peer hello is unavailable.")
            return
        }
        guard let challenge = pendingAuthChallenge else {
            rejectControlConnection("Authentication failed: challenge state is unavailable.")
            return
        }
        guard let authenticationSecret = authenticationSecret(peerID: hello.deviceID) else {
            rejectControlConnection("Authentication failed: pairing secret is unavailable.")
            return
        }
        let transcriptID = BoothPairingCrypto.transcriptIdentifier(
            for: challenge,
            responderDeviceID: hello.deviceID
        )
        let verificationFailure = BoothPairingCrypto.verificationFailure(
            proof,
            for: challenge,
            expectedResponderDeviceID: hello.deviceID,
            secret: authenticationSecret.data
        )
        guard let verificationFailure else {
            logPairing(
                stage: .authenticating,
                message: "auth verified source=\(authenticationSecret.source) transcript=\(transcriptID)",
                sessionID: pairingSessionIDForDiagnostics
            )
            pendingAuthChallenge = nil
            completeAuthentication(with: hello)
            return
        }
        logPairing(
            stage: .failed,
            message: "auth verify failed reason=\(verificationFailure.rawValue) source=\(authenticationSecret.source) transcript=\(transcriptID)",
            sessionID: pairingSessionIDForDiagnostics
        )
        rejectControlConnection("Authentication failed: \(verificationFailure.message).")
    }

    private func completeAuthentication(with hello: BoothTransportHello) {
        if let commit = pendingPairingCommit {
            guard commit.peer.id == hello.deviceID else {
                failPairing("Authentication peer does not match the pairing request.")
                return
            }
            setPairingStage(.trustSaving, state: .authenticating(peerID: hello.deviceID))
            do {
                try trustedStore.trust(commit.peer, secret: commit.secret)
                trustedStore.preferredPeerID = commit.peer.id
                trustedStore.autoReconnect = true
                pendingPairingCommit = nil
                cancelPairingExpiry()
                pairingGeneration &+= 1
            } catch {
                failPairing("Pairing trust could not be saved: \(error.localizedDescription)")
                return
            }
        }
        peerAuthenticated = true
        pendingPairingRequest = nil
        pendingPairingIntent = nil
        pendingPairingSessionID = nil
        pendingPairingFailure = nil
        incomingPairingRequest = nil
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
        setPairingStage(.authenticated, state: .authenticated(peerID: hello.deviceID))
        startHeartbeat()
        validatePreviewIdentity()
        if role == .iPad, previewConnection == nil {
            previewBrowser?.cancel()
            previewBrowser = nil
            if activeInterface == .wiredEthernet {
                connect(
                    to: directLANEndpoint(for: .preview),
                    channel: .preview,
                    parameters: .tcp
                )
            } else {
                startBrowser(channel: .preview)
            }
        }
        onControlMessage?(.hello(role: hello.role))
    }

    private func secretForAuthentication(peerID: String) -> Data? {
        authenticationSecret(peerID: peerID)?.data
    }

    private func authenticationSecret(peerID: String) -> AuthenticationSecret? {
        // A newly accepted pairing must authenticate with the provisional
        // secret delivered in its pairing result. A leftover Keychain entry
        // from a forgotten or interrupted prior relationship must not win
        // over that session and create an asymmetric HMAC failure.
        if let commit = pendingPairingCommit, commit.peer.id == peerID {
            return AuthenticationSecret(data: commit.secret, source: "provisional")
        }
        guard let secret = trustedStore.secret(for: peerID) else { return nil }
        return AuthenticationSecret(data: secret, source: "keychain")
    }

    private func handleAuthenticationSendFailure(_ reason: String) {
        if pendingPairingCommit != nil {
            failPendingPairingDelivery(reason)
        } else {
            rejectControlConnection(reason)
        }
    }

    private func rejectIncomingConnection(_ connection: NWConnection, reason: String) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .ready = state, let connection else { return }
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                self.sendThenClose(
                    .connectionRejected(reason: reason),
                    connection: connection,
                    reason: reason
                )
            }
        }
        connection.start(queue: .main)
    }

    private func rejectControlConnection(_ reason: String) {
        let connection = controlConnection
        if currentConnectionOwnsPairingState {
            failPairing(reason, closeConnection: false)
        } else if !hasEphemeralPairingState {
            lastNetworkError = reason
            setPairingStage(.failed, state: .failed(reason))
        }
        if let connection {
            sendThenClose(
                .connectionRejected(reason: reason),
                connection: connection,
                reason: reason
            )
        } else {
            connectionDidClose(nil, channel: .control, reason: reason)
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
            state: state,
            stage: pairingStageValue
        )
    }

    private func setPairingStage(_ stage: BoothPairingStage, state: BoothPairingState? = nil) {
        pairingStageValue = stage
        publishPairingStatus(state: state)
        logPairing(stage: stage, message: nil, sessionID: pairingSessionIDForDiagnostics)
    }

    private var pairingSessionIDForDiagnostics: String? {
        currentPairingSession?.info.sessionID
            ?? pendingPairingRequest?.sessionID
            ?? pendingPairingSessionID
            ?? pendingPairingCommit?.sessionID
    }

    private func logPairing(
        stage: BoothPairingStage,
        message: String?,
        sessionID: String?
    ) {
#if DEBUG
        // Once hello has arrived, the connected peer is more authoritative
        // than request-side presentation data (which is the local iPad identity
        // on the iPad role).
        let peerID = peerDeviceID ?? pairingPeerID ?? "none"
        let peerName = self.peerName.isEmpty ? (pairingPeerDisplayName ?? "none") : self.peerName
        let route = activeInterface?.rawValue ?? "none"
        NSLog(
            "[Pairing] role=%@ peerID=%@ peerName=%@ session=%@ stage=%@ route=%@%@",
            role.rawValue,
            peerID,
            peerName.isEmpty ? "none" : peerName,
            sessionID ?? "none",
            stage.rawValue,
            route,
            message.map { " message=\($0)" } ?? ""
        )
#else
        _ = (stage, message, sessionID)
#endif
    }

    private func logPairingMessage(_ message: Message, sent: Bool, error: Error? = nil) {
#if DEBUG
        let direction = sent ? "send" : "receive"
        logPairing(
            stage: pairingStageValue,
            message: "\(direction) \(messageType(message))\(error.map { " failed: \($0.localizedDescription)" } ?? "")",
            sessionID: pairingSessionIDForDiagnostics
        )
#else
        _ = (message, sent, error)
#endif
    }

    private func messageType(_ message: Message) -> String {
        switch message {
        case .hello: return "hello"
        case .helloDetails: return "helloDetails"
        case .pairingIntent: return "pairingIntent"
        case .pairingSessionAvailable: return "pairingSessionAvailable"
        case .pairingRequest: return "pairingRequest"
        case .pairingResult: return "pairingResult"
        case .authChallenge: return "authChallenge"
        case .authProof: return "authProof"
        case .connectionRejected: return "connectionRejected"
        case .sessionSync: return "sessionSync"
        case .boothPaused: return "boothPaused"
        case .eventConfig: return "eventConfig"
        case .eventExperienceCatalog: return "eventExperienceCatalog"
        case .eventExperienceAsset: return "eventExperienceAsset"
        case .setMirrored: return "setMirrored"
        case .sessionStart: return "sessionStart"
        case .customerSessionRequest: return "customerSessionRequest"
        case .sessionRequestRejected: return "sessionRequestRejected"
        case .sessionPrepared: return "sessionPrepared"
        case .beginCountdown: return "beginCountdown"
        case .shotCaptured: return "shotCaptured"
        case .captureRecovery: return "captureRecovery"
        case .captureRecoveryAction: return "captureRecoveryAction"
        case .reviewDecision: return "reviewDecision"
        case .sessionFinished: return "sessionFinished"
        case .operatorOverride: return "operatorOverride"
        case .heartbeat: return "heartbeat"
        }
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
        logPairingMessage(message, sent: true)
        connection.send(content: frame, completion: .contentProcessed { error in
            if let error { print("[Network] send failed: \(error.localizedDescription)") }
        })
    }

    private func sendCriticalControl(
        _ message: Message,
        on connection: NWConnection?,
        sessionID: String?,
        completion: @escaping @MainActor (Result<Void, PairingControlSendError>) -> Void
    ) {
        guard let connection else {
            completion(.failure(.failed("No active control connection.")))
            return
        }
        guard isCurrent(connection, channel: .control) else {
            completion(.failure(.failed("The control connection is no longer current.")))
            return
        }
        guard let payload = try? message.encoded() else {
            completion(.failure(.failed("Pairing message encoding failed.")))
            return
        }
        guard let frame = try? BoothFrameEncoder.encode(channel: .control, payload: payload) else {
            completion(.failure(.failed("Pairing message framing failed.")))
            return
        }

        let context = BoothPairingControlSendContext(
            connectionGeneration: controlConnectionGeneration,
            pairingGeneration: pairingGeneration,
            sessionID: sessionID
        )
        logPairingMessage(message, sent: true)
        connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection else { return }
                guard self.isCurrent(connection, channel: .control),
                      BoothPairingControlSendGate.accepts(
                          context,
                          currentConnectionGeneration: self.controlConnectionGeneration,
                          currentPairingGeneration: self.pairingGeneration,
                          currentSessionID: self.currentPairingSession?.info.sessionID,
                          pendingSessionID: self.pendingPairingSessionID,
                          pendingResultSessionID: self.pendingPairingCommit?.sessionID
                      ) else {
                    self.logPairing(stage: self.pairingStageValue, message: "stale send completion ignored", sessionID: context.sessionID)
                    return
                }

                if let error {
                    self.logPairingMessage(message, sent: true, error: error)
                    completion(.failure(.failed(error.localizedDescription)))
                } else {
                    self.logPairing(stage: self.pairingStageValue, message: "send complete \(self.messageType(message))", sessionID: context.sessionID)
                    completion(.success(()))
                }
            }
        })
    }

    private func sendThenClose(_ message: Message, connection: NWConnection, reason: String?) {
        let connectionGenerationAtStart = controlConnectionGeneration
        guard let payload = try? message.encoded(),
              let frame = try? BoothFrameEncoder.encode(channel: .control, payload: payload) else {
            connection.cancel()
            if isCurrent(connection, channel: .control) {
                connectionDidClose(connection, channel: .control, reason: reason)
            }
            return
        }

        logPairingMessage(message, sent: true)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }
                let closeReason = error?.localizedDescription ?? reason
                guard self.isCurrent(connection, channel: .control),
                      self.controlConnectionGeneration == connectionGenerationAtStart else {
                    connection.cancel()
                    return
                }
                connection.cancel()
                self.connectionDidClose(connection, channel: .control, reason: closeReason)
            }
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
            logPairing(
                stage: pairingStageValue,
                message: reason.map { "control connection closed: \($0)" } ?? "control connection closed",
                sessionID: pairingSessionIDForDiagnostics
            )
            if hasEphemeralPairingState, pendingPairingFailure == nil {
                let state: BoothPairingState
                let stage: BoothPairingStage
                if let commit = pendingPairingCommit {
                    state = .authenticating(peerID: commit.peer.id)
                    stage = .authenticating
                } else if let incomingPairingRequest,
                          let session = currentPairingSession {
                    state = .incoming(request: incomingPairingRequest, expiresAt: session.info.expiresAt)
                    stage = .discovering
                } else if let session = currentPairingSession {
                    state = .pairing(expiresAt: session.info.expiresAt)
                    stage = .discovering
                } else if pendingPairingRequest != nil {
                    state = .pairing(expiresAt: pendingPairingStateExpiry)
                    stage = .discovering
                } else if let pendingPairingIntent {
                    state = .waitingForMac(peerID: pendingPairingIntent.targetMacDeviceID)
                    stage = .discovering
                } else {
                    state = .failed("Pairing connection closed. Please try again.")
                    stage = .failed
                }
                setPairingStage(stage, state: state)
            } else if let pendingPairingFailure {
                setPairingStage(.failed, state: .failed(pendingPairingFailure))
            }
            if role == .iPad {
                startRouteDiscovery()
                return
            }
            if retainsManualLANListener {
                // Do not use the path monitor to choose a new route here.
                // Static iPad Ethernet often remains "unsatisfied" despite
                // the control socket having just been usable. Clear only the
                // closed connection so the still-running fixed listener can
                // accept the retry/reconnect for this pairing session.
                controlConnection?.cancel()
                controlConnectionGeneration &+= 1
                controlConnection = nil
                controlEndpointDescription = nil
                controlParser = BoothFrameParser()
                resetControlAuthentication()
                connectionState = .disconnected
                lanHandshakeState = .waiting
                if controlListener == nil { startListener(channel: .control) }
                if previewListener == nil { startListener(channel: .preview) }
                publishStatus()
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

    private var retainsManualLANListener: Bool {
        role == .mac
            && requestedPreference == .lan
            && activeInterface == .wiredEthernet
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
        deferredAuthChallenge = nil
        peerHello = nil
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        peerName = ""
        connectedPeerNames = []
        connectionStatus.publishPairing(authenticated: false, stage: pairingStageValue)
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
