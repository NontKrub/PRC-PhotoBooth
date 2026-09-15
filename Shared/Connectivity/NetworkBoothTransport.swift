import Foundation
import CryptoKit
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
    private static let assetServiceType = "_prc-asset._tcp"
    // The documented direct Ethernet setup uses these addresses. Bonjour is
    // still preferred, but iPadOS 16 Lightning adapters can have a working
    // IP path without returning a constrained Bonjour result.
    private static let directLANHost = NWEndpoint.Host("10.0.0.1")
    private static let directLANControlPort = NWEndpoint.Port(rawValue: 58_500)!
    private static let directLANPreviewPort = NWEndpoint.Port(rawValue: 58_501)!
    private static let directLANAssetPort = NWEndpoint.Port(rawValue: 58_502)!
    static let routeDiscoveryGracePeriod: TimeInterval = 2.0
    private static let lanRecoveryStabilityPeriod: TimeInterval = 2
    private static let lanRecoveryCooldown: TimeInterval = 5
    private static let pairingCapability = "pairing-v2"
    private static let previewIdentityCapability = "preview-identity"
    private static let heartbeatInterval: TimeInterval = 2
    private static let heartbeatTimeout: TimeInterval = 8
    private static let transportQueueLabel = "PRC-PhotoBooth.Transport"

    private struct PendingPairingCommit: Equatable, Sendable {
        let sessionID: String
        let method: BoothPairingMethod
        let peer: TrustedBoothPeer
        let macIdentity: BoothDeviceIdentity
        let secret: Data
        let expiresAt: Date
        let transcript: Data
        let macEphemeralPublicKey: Data
        let keyAgreementProof: Data

        var result: BoothPairingResult {
            BoothPairingResult(
                accepted: true,
                macIdentity: macIdentity,
                pairingSessionID: sessionID,
                macEphemeralPublicKey: macEphemeralPublicKey,
                keyAgreementProof: keyAgreementProof
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
    public var onAssetChunk: (@MainActor (BoothAssetChunk) -> Void)?
    public var onTransportEvent: (@MainActor (BoothTransportDiagnosticEvent) -> Void)?
    public var onTransportReady: (@MainActor (BoothDeviceIdentity) -> Void)?

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
            if role == .iPad {
                routeMachine = BoothNetworkRouteMachine(preference: newValue)
                restartDiscoveryForPeerSelection()
                publishStatus()
                return
            }
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
    private var pendingPairingPrivateKeyData: Data?
    private var pendingPairingCode: String?
    private var pendingPairingVerificationCode: String?
    private var didConfirmPairingVerification = false
    private var deferredAuthChallenge: BoothAuthChallenge?
    private var peerHello: BoothTransportHello?
    private var peerAuthenticated = false
    private let secureChannel = BoothSecureChannel()
    private var secureNegotiator = BoothSecureChannelNegotiator(role: .mac, localDeviceID: "")
    private var localSecureChannelHello: BoothSecureChannelHello?
    private var peerSecureChannelHello: BoothSecureChannelHello?
    private var deferredSecureChannelHello: (hello: BoothSecureChannelHello, generation: Int)?
    private var secureChannelSessionID: String?
    private var secureChannelReadySent = false
    private var secureChannelReadyReceived = false
    private var secureChannelEstablished = false
    private var secureNegotiationTimeoutSource: DispatchSourceTimer?
    private var pendingAuthChallenge: BoothAuthChallenge?
    private var didInitiateAuthentication = false
    private var discoveredPeersByID: [String: BoothDiscoveredPeer] = [:]
    private var controlListener: NWListener?
    private var previewListener: NWListener?
    private var assetListener: NWListener?
    private var controlBrowser: NWBrowser?
    private var previewBrowser: NWBrowser?
    private var assetBrowser: NWBrowser?
    private var wifiRouteDiscoveryBrowser: NWBrowser?
    private var lanRouteDiscoveryBrowser: NWBrowser?
    // Some iPadOS 16 Lightning Ethernet adapters expose a usable IP path but
    // do not return Bonjour results to a browser constrained to
    // `.wiredEthernet`. This browser only discovers a LAN-advertised peer.
    private var lanCompatibilityRouteDiscoveryBrowser: NWBrowser?
    private var discoveredPeerProvenanceByID: [String: Set<BoothRouteCandidateProvenance>] = [:]
    private var routeDiscoverySelection = BoothRouteDiscoverySelection()
    private var routeDiscoveryTargetPeerID: String?
    private var routeDiscoveryPreference: BoothNetworkPreference?
    private var directLANAttemptedRouteGeneration: Int?
    private var directLANControlAttemptInFlight = false
    private var pendingWiFiRouteEndpoint: NWEndpoint?
    private var pendingLANRouteEndpoint: NWEndpoint?
    private var pendingLANRouteProvenance: BoothRouteCandidateProvenance?
    private var routeDiscoveryFallbackTask: Task<Void, Never>?
    private var routeDiscoveryFallbackToken = 0
    private var routeDiscoveryGate = BoothRouteDiscoveryGenerationGate()
    private var callbackGate = BoothTransportCallbackGate()
    private var controlConnection: NWConnection?
    private var controlConnectionGeneration = 0
    private var pairingGeneration = 0
    private var pairingRequestSubmission = BoothPairingRequestSubmissionGate()
    private var previewConnection: NWConnection?
    private var previewConnectionGeneration = 0
    private var assetConnection: NWConnection?
    private var assetConnectionGeneration = 0
    private var controlReceiveToken: BoothTransportReceiveToken?
    private var previewReceiveToken: BoothTransportReceiveToken?
    private var assetReceiveToken: BoothTransportReceiveToken?
    private let previewWritePump: BoothPreviewWritePump
    private let previewDeliveryPump: BoothLatestPreviewDeliveryPump
    private let transportRuntime: BoothNetworkTransportRuntime
    private var lanHandshakeTask: Task<Void, Never>?
    private let waitingRecoveryScheduler: BoothConnectionRecoveryScheduler
    private var waitingRecoveryChannels = Set<UInt8>()
    private var lastControlMessageAt = Date.distantPast
    private var lanRecoverySource: DispatchSourceTimer?
    private var lanRecoveryToken = 0
    private var lanRecoveryPending = false
    private var lastLANRecoveryAttemptAt: Date?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private var controlEndpointDescription: String?
    private var previewEndpointDescription: String?
    private var assetEndpointDescription: String?
    private var assetIdentityVerified = false
    private var assetBindingSent = false
    private var deferredAssetRequests: [BoothAssetReference] = []
    private var didReceiveHello = false
    private var peerDeviceID: String?
    private var expectedPeerDeviceID: String?
    private var previewPeerID: String?
    private var previewPeerSupportsIdentity = false
    private var didSendPreviewHello = false
    private var previewIdentityVerified = false
    private var lanPathMonitor: NWPathMonitor?
    private var wifiPathMonitor: NWPathMonitor?
    private var pathMonitorGeneration = 0
    private var didReceiveLANPathUpdate = false
    private var didReceiveWiFiPathUpdate = false
    private var isLANPathAvailable = false
    private var isWiFiPathAvailable = false
    private var lanHandshakeState: BoothLANHandshakeState = .unknown
    private var controlConnectionIsViable = false
    private var lastNetworkError: String?
    private var pairingStageValue: BoothPairingStage = .idle
    private let controlWritePump: BoothControlWritePump
    private let assetWritePump: BoothAssetWritePump
    private var assetReconnectSource: DispatchSourceTimer?
    private var assetReconnectToken = 0
    private let transportQueue = DispatchQueue(
        label: "PRC-PhotoBooth.Transport",
        qos: .userInitiated
    )

    private func replaceReceiveToken(for channel: BoothTransportChannel) -> BoothTransportReceiveToken {
        invalidateReceiveToken(for: channel)
        let token = BoothTransportReceiveToken()
        switch channel {
        case .control: controlReceiveToken = token
        case .preview: previewReceiveToken = token
        case .asset: assetReceiveToken = token
        case .heartbeat: break
        }
        return token
    }

    private func invalidateReceiveToken(for channel: BoothTransportChannel) {
        switch channel {
        case .control:
            controlReceiveToken?.invalidate()
            controlReceiveToken = nil
        case .preview:
            previewReceiveToken?.invalidate()
            previewReceiveToken = nil
        case .asset:
            assetReceiveToken?.invalidate()
            assetReceiveToken = nil
        case .heartbeat: break
        }
    }

    private func emitTransportEvent(
        _ kind: BoothTransportDiagnosticKind,
        channel: BoothTransportChannel? = nil,
        route: String? = nil,
        attempt: Int? = nil,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil,
        reason: String? = nil,
        routeGeneration: Int? = nil,
        candidateSource: String? = nil
    ) {
        onTransportEvent?(BoothTransportDiagnosticEvent(
            kind: kind,
            channel: channel.map { String(describing: $0) },
            generation: channel.map { connectionGeneration(for: $0) },
            route: route ?? activeInterface?.rawValue,
            attempt: attempt,
            byteCount: byteCount,
            duration: duration,
            reason: reason,
            targetPeerID: diagnosticTargetPeerID,
            routeGeneration: routeGeneration ?? routeDiscoveryGate.generation,
            networkPreference: requestedPreference,
            candidateSource: candidateSource
        ))
    }

    private var diagnosticTargetPeerID: String? {
        if role == .iPad {
            return targetPeerID ?? peerDeviceID
        }
        return peerDeviceID
            ?? pendingPairingCommit?.peer.id
            ?? incomingPairingRequest?.iPadIdentity.id
    }

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
        self.secureNegotiator = BoothSecureChannelNegotiator(
            role: role,
            localDeviceID: self.localIdentity.id
        )
        self.controlWritePump = BoothControlWritePump(
            queue: self.transportQueue,
            secureChannel: self.secureChannel
        )
        self.assetWritePump = BoothAssetWritePump(
            queue: self.transportQueue,
            secureChannel: self.secureChannel
        )
        self.previewWritePump = BoothPreviewWritePump(
            queue: self.transportQueue,
            secureChannel: self.secureChannel
        )
        self.previewDeliveryPump = BoothLatestPreviewDeliveryPump(queue: self.transportQueue)
        self.transportRuntime = BoothNetworkTransportRuntime(queue: self.transportQueue)
        self.waitingRecoveryScheduler = BoothConnectionRecoveryScheduler(queue: self.transportQueue)
        if role == .iPad, trustedStore.autoReconnect {
            self.targetPeerID = trustedStore.preferredPeerID
        }
        self.controlWritePump.onFailure = { [weak self] outcome, reason, generation in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.controlConnectionGeneration,
                      let connection = self.controlConnection else { return }
                self.recordControlSendFailure(outcome)
                self.connectionDidClose(connection, channel: .control, reason: reason)
            }
        }
        self.assetWritePump.onFailure = { [weak self] outcome, reason, generation in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.assetConnectionGeneration,
                      let connection = self.assetConnection else { return }
                self.emitTransportEvent(.assetRejected, channel: .asset, reason: reason)
                self.connectionDidClose(connection, channel: .asset, reason: reason)
                if outcome == .rejectedOversize { self.lastNetworkError = reason }
            }
        }
        self.previewWritePump.onFailure = { [weak self] reason, generation in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.previewConnectionGeneration,
                      let connection = self.previewConnection else { return }
                self.connectionDidClose(connection, channel: .preview, reason: reason)
            }
        }
        self.previewWritePump.onMetrics = { [weak self] diagnostics in
            Task { @MainActor [weak self] in
                self?.connectionStatus.publishPreviewWriteDiagnostics(diagnostics)
            }
        }
        self.previewDeliveryPump.onDeliver = { [weak self] data, generation, diagnostics in
            guard let self,
                  generation == self.previewConnectionGeneration,
                  self.previewIdentityVerified,
                  let connection = self.previewConnection,
                  self.isCurrent(connection, channel: .preview) else { return }
            self.connectionStatus.publishPreviewDeliveryDiagnostics(
                framesReceived: diagnostics.framesReceived,
                framesDelivered: diagnostics.framesDelivered,
                framesCoalesced: diagnostics.framesCoalesced,
                pendingFrames: diagnostics.pendingFrames
            )
            self.onPreviewFrame?(data)
        }
        self.transportRuntime.onHeartbeatTimeout = { [weak self] connection, generation in
            Task { @MainActor [weak self] in
                guard let self,
                      self.isCurrent(connection, channel: .control),
                      self.controlConnectionGeneration == generation,
                      self.peerAuthenticated,
                      self.secureChannelEstablished else { return }
                self.emitTransportEvent(
                    .heartbeatTimedOut,
                    channel: .control,
                    reason: "No valid control traffic within heartbeat timeout"
                )
                self.connectionDidClose(
                    connection,
                    channel: .control,
                    reason: "heartbeat timeout"
                )
            }
        }
        self.transportRuntime.onReconnectDue = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleReconnectDue()
            }
        }
        publishPairingStatus()
    }

    public var deviceIdentity: BoothDeviceIdentity { localIdentity }
    public var trustedPeers: [TrustedBoothPeer] { trustedStore.trustedPeers }
    public var preferredPeerID: String? { trustedStore.preferredPeerID }
    public var currentPairingSessionInfo: BoothPairingSessionInfo? { currentPairingSession?.info }
    public var pairingPINForDisplay: String? { currentPairingSession?.pin }
    public var pairingQRCodePayload: BoothPairingQRCodePayload? { currentPairingSession?.qrPayload }
    public var pairingVerificationCodeForDisplay: String? { pendingPairingVerificationCode }
    public var isPairingVerificationConfirmed: Bool { didConfirmPairingVerification }
    public var pairingStage: BoothPairingStage { pairingStageValue }
    public var pairingExpiresAt: Date? {
        currentPairingSession?.info.expiresAt
            ?? pendingPairingCommit?.expiresAt
            ?? pairingExpiryAt
    }
    private var pairingDiagnosticPeer: BoothPairingDiagnosticPeer {
        let connectedPeer = peerDeviceID.map {
            BoothDeviceIdentity(
                id: $0,
                displayName: peerName.isEmpty ? $0 : peerName,
                role: role == .mac ? .iPad : .mac
            )
        }
        let targetMacID = targetPeerID ?? receivedPairingSession?.macDeviceID
        let targetMacPeer = targetMacID.map { id in
            BoothDeviceIdentity(
                id: id,
                displayName: discoveredPeersByID[id]?.displayName
                    ?? receivedPairingSession?.macDeviceName
                    ?? id,
                role: .mac
            )
        }
        let pendingIPadPeer = pendingPairingRequest?.iPadIdentity
            ?? pendingPairingIntent?.iPadIdentity
            ?? incomingPairingRequest?.iPadIdentity
        return BoothPairingDiagnosticPeer.resolve(
            role: role,
            connectedPeer: connectedPeer,
            targetMacPeer: targetMacPeer,
            pendingIPadPeer: pendingIPadPeer,
            fallbackPeer: pendingPairingCommit?.peer
        )
    }
    public var pairingPeerID: String? {
        pairingDiagnosticPeer.id
    }
    public var pairingPeerDisplayName: String? {
        pairingDiagnosticPeer.displayName
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
                assetConnectionGeneration &+= 1
                controlWritePump.invalidate(generation: controlConnectionGeneration)
                assetWritePump.invalidate(generation: assetConnectionGeneration)
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

    /// Recycles only the asset channel after its bounded per-generation
    /// recovery attempts are exhausted. Control authentication and preview
    /// remain intact so Review recovery cannot restart the customer session.
    public func recycleAssetChannel() {
        guard role == .iPad,
              shouldReconnect,
              peerAuthenticated,
              secureChannelEstablished else { return }
        if let connection = assetConnection {
            connectionDidClose(
                connection,
                channel: .asset,
                reason: "Asset recovery requested a fresh channel generation"
            )
            return
        }
        assetBrowser?.cancel()
        assetBrowser = nil
        scheduleAssetReconnect()
    }

    /// Confirms the locally displayed SAS before PIN pairing can authenticate.
    /// The code itself is derived independently on both devices and is never
    /// transmitted.
    public func confirmPairingVerification() {
        guard role == .mac,
              let commit = pendingPairingCommit,
              commit.method == .pin,
              pendingPairingVerificationCode != nil,
              !didConfirmPairingVerification else { return }
        didConfirmPairingVerification = true
        guard pairingStageValue != .resultSending else { return }
        sendPairingVerificationConfirmation(commit, on: controlConnection)
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
        pairingRequestSubmission.reset()
        pendingPairingPrivateKeyData = nil
        pendingPairingCode = nil
        deferredAuthChallenge = nil
        if !peerAuthenticated {
            pendingAuthChallenge = nil
            didInitiateAuthentication = false
        }
        if clearPendingCommit {
            pendingPairingCommit = nil
            pendingPairingVerificationCode = nil
            didConfirmPairingVerification = false
        }
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
        requestPairing(with: peerID, restartDiscovery: false)
    }

    public func retryPairing(with peerID: String) {
        requestPairing(with: peerID, restartDiscovery: true)
    }

    private func requestPairing(with peerID: String, restartDiscovery: Bool) {
        guard role == .iPad, !trustedStore.trustedPeerIDs.contains(peerID) else { return }
        if let peer = discoveredPeersByID[peerID] {
            guard peer.role == .mac else {
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
        } else if !restartDiscovery {
            let reason = "The selected Mac was not found."
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
        if restartDiscovery {
            restartDiscoveryForPeerSelection()
        } else {
            ensureDiscoveryForPeerSelection()
        }
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
            method: .pin,
            code: pin,
            macEphemeralPublicKey: discoveredPeer?.pairingMacEphemeralPublicKey
                ?? verifiedSession?.macEphemeralPublicKey,
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
                method: .qrToken,
                code: payload.oneTimeToken,
                macEphemeralPublicKey: payload.macEphemeralPublicKey,
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
        connectionStatus.publishReconnectState(inProgress: false)
        emitTransportEvent(.transportDiscoveryStarted, attempt: reconnectAttempt)
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
        connectionStatus.publishReconnectState(inProgress: false)
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

    @discardableResult
    public func sendControl(_ message: Message) -> BoothControlSendOutcome {
        send(message, on: controlConnection, channel: .control)
    }

    public func sendControl(
        _ message: Message,
        completion: @escaping @MainActor (BoothControlSendOutcome) -> Void
    ) {
        _ = send(message, on: controlConnection, channel: .control, completion: completion)
    }

    @discardableResult
    public func sendAsset(_ chunk: BoothAssetChunk) -> BoothControlSendOutcome {
        guard peerAuthenticated,
              secureChannelEstablished,
              assetIdentityVerified else {
            emitTransportEvent(.assetRejected, channel: .asset, reason: "Secure asset channel is not ready")
            return .noConnection
        }
        let outcome = assetWritePump.enqueue(
            chunk,
            connection: assetConnection,
            generation: assetConnectionGeneration,
            completion: { @MainActor [weak self] outcome in
                guard let self else { return }
                if outcome == .sent {
                    self.emitTransportEvent(.assetSent, channel: .asset, byteCount: chunk.data.count)
                } else {
                    self.emitTransportEvent(
                        .assetRejected,
                        channel: .asset,
                        byteCount: chunk.data.count,
                        reason: String(describing: outcome)
                    )
                }
            }
        )
        if outcome != .sent {
            emitTransportEvent(.assetRejected, channel: .asset, reason: String(describing: outcome))
        }
        return outcome
    }

    public func sendPreviewFrame(_ jpegData: Data) {
        previewWritePump.enqueue(
            jpegData,
            connection: previewConnection,
            generation: previewConnectionGeneration
        )
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
        switch interface {
        case .wifi:
            // "Wi-Fi" is the local-network preference, not a physical
            // interface requirement. This allows router LAN, hotspot, and
            // peer-to-peer paths to remain eligible.
            parameters.includePeerToPeer = true
        case .wiredEthernet:
            parameters.requiredInterfaceType = .wiredEthernet
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
        pathMonitorGeneration &+= 1
        let generation = pathMonitorGeneration
        didReceiveLANPathUpdate = false
        didReceiveWiFiPathUpdate = false

        let lanMonitor = NWPathMonitor(requiredInterfaceType: .wiredEthernet)
        lanMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.pathMonitorGeneration == generation else { return }
                self.handleLANPathUpdate(path.status == .satisfied)
            }
        }
        lanMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.WiredEthernetPath"))
        lanPathMonitor = lanMonitor

        // The Wi-Fi preference represents any usable local path. The
        // connection's Bonjour/TCP result remains authoritative for the
        // actual route; this monitor is only an availability hint.
        let wifiMonitor = NWPathMonitor()
        wifiMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, self.pathMonitorGeneration == generation else { return }
                self.handleWiFiPathUpdate(path.status == .satisfied)
            }
        }
        wifiMonitor.start(queue: DispatchQueue(label: "PRC-PhotoBooth.WiFiPath"))
        wifiPathMonitor = wifiMonitor
    }

    private func stopPathMonitors() {
        pathMonitorGeneration &+= 1
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
        if shouldIgnoreUnavailablePathHint {
            emitTransportEvent(
                .pathHintUnavailableIgnored,
                channel: .control,
                route: "Wired Ethernet",
                reason: "Wired Ethernet path hint ignored while authenticated control remains active."
            )
            return
        }
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
        guard lanRecoverySource == nil,
              shouldReconnect,
              activeInterface == .wifi,
              requestedPreference == .lan,
              fallbackActive,
              isLANPathAvailable else { return }

        lanRecoveryPending = true
        lanRecoveryToken &+= 1
        let token = lanRecoveryToken
        let source = DispatchSource.makeTimerSource(queue: transportQueue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.lanRecoveryToken == token else { return }
                self.lanRecoverySource = nil
                guard self.isLANPathAvailable,
                      self.shouldReconnect,
                      self.activeInterface == .wifi,
                      self.requestedPreference == .lan,
                      self.fallbackActive else { return }
                self.attemptPendingLANRecoveryIfIdle()
            }
        }
        lanRecoverySource = source
        source.resume()
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
        lanRecoveryToken &+= 1
        lanRecoverySource?.cancel()
        lanRecoverySource = nil
        lanRecoveryPending = false
    }

    private func handleWiFiPathUpdate(_ available: Bool) {
        didReceiveWiFiPathUpdate = true
        isWiFiPathAvailable = available
        publishPathAvailability()
        if !available, shouldIgnoreUnavailablePathHint {
            emitTransportEvent(
                .pathHintUnavailableIgnored,
                channel: .control,
                reason: "Generic Wi-Fi path hint ignored while authenticated control remains active."
            )
            return
        }
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
            ensureDiscoveryForPeerSelection()
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

    private func handleLANHandshakeFailure(
        reason: String,
        retainManualListener: Bool = true
    ) {
        guard activeInterface == .wiredEthernet else { return }
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        lanHandshakeState = .timeout
        lastNetworkError = reason
        if retainManualListener, retainsManualLANListener {
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
        reason: String?
    ) {
        guard shouldReconnect else { return }
        // The selected route-discovery browser has already started. Cancel it
        // before opening the connection; Network.framework does not support
        // replacing browse handlers after start().
        cancelRouteDiscovery()
        tearDownActiveTransport()
        if role == .iPad {
            routeDiscoveryTargetPeerID = targetPeerID
            routeDiscoveryPreference = requestedPreference
        }
        activeInterface = interface
        fallbackActive = fallback
        fallbackReason = fallback ? (reason ?? "LAN unavailable") : nil
        lanHandshakeState = interface == .wiredEthernet ? .waiting : .unknown
        lastNetworkError = nil
        connectionState = role == .mac ? .disconnected : .connecting
        publishStatus()

        print("[NetworkRoute] Starting \(interface == .wiredEthernet ? "LAN" : "Wi-Fi") transport")
        emitTransportEvent(
            .transportConnecting,
            route: interface.rawValue,
            attempt: reconnectAttempt,
            reason: reason
        )
        switch role {
        case .mac:
            startListener(channel: .control)
            startListener(channel: .preview)
            startListener(channel: .asset)
        case .iPad:
            if !directLANControlAttemptInFlight {
                if controlBrowser == nil { startBrowser(channel: .control) }
                startBrowser(channel: .preview)
            }
        }

        // A Mac must keep its LAN listeners alive while waiting for an iPad.
        // The handshake timeout belongs to the initiating iPad connection;
        // applying it to an idle Mac made direct Ethernet fall back to Wi-Fi
        // after five seconds, before pairing could begin.
        if interface == .wiredEthernet, role == .iPad {
            let callbackGenerationAtStart = callbackGate.generation
            lanHandshakeTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(Self.lanHandshakeTimeout))
                } catch {
                    return
                }
                guard let self,
                      self.callbackGate.accepts(callbackGenerationAtStart),
                      self.activeInterface == .wiredEthernet,
                      self.shouldReconnect,
                      !self.peerAuthenticated else { return }
                self.handleLANHandshakeFailure(reason: "No valid iPad hello")
            }
        }
    }

    private func startRouteDiscovery() {
        startRouteDiscovery(skipDirectLANFallback: false)
    }

    private func startRouteDiscovery(skipDirectLANFallback: Bool) {
        guard role == .iPad, shouldReconnect else { return }
        directLANControlAttemptInFlight = false
        discoveredPeersByID.removeAll()
        discoveredPeerProvenanceByID.removeAll()
        publishPairingStatus()
        cancelRouteDiscovery()
        tearDownActiveTransport()
        routeMachine = BoothNetworkRouteMachine(preference: requestedPreference)
        connectionState = .connecting
        publishStatus()
        let generation = routeDiscoveryGate.begin()
        routeDiscoveryTargetPeerID = targetPeerID
        routeDiscoveryPreference = requestedPreference
        emitTransportEvent(
            .routeDiscoveryStarted,
            reason: skipDirectLANFallback
                ? "Route discovery started after direct LAN attempt failed."
                : "Route discovery started for the selected peer.",
            routeGeneration: generation
        )
        if !skipDirectLANFallback,
           startDirectLANPairingFallbackIfNeeded(routeGeneration: generation) { return }
        startRouteDiscoveryBrowser(on: .wifi, generation: generation)
        startRouteDiscoveryBrowser(on: .wiredEthernet, generation: generation)
        startRouteDiscoveryBrowser(
            on: .wiredEthernet,
            generation: generation,
            parameters: .tcp,
            isLANCompatibilityFallback: true
        )
    }

    private func startDirectLANPairingFallbackIfNeeded(routeGeneration: Int) -> Bool {
        guard requestedPreference == .lan,
              let targetPeerID,
              directLANAttemptedRouteGeneration != routeGeneration,
              trustedStore.trustedPeerIDs.contains(targetPeerID) || hasEphemeralPairingState else {
            return false
        }
        // On iPadOS 16 with a direct Lightning Ethernet adapter, the link can
        // pass IP traffic while Bonjour never returns a wired result. Do not
        // make the fixed-address recovery path depend on that missing
        // advertisement. The first hello and the pairing target ID still
        // reject any endpoint that is not the selected Mac.
        directLANAttemptedRouteGeneration = routeGeneration
        directLANControlAttemptInFlight = true
        emitTransportEvent(
            .routeCandidateDiscovered,
            route: BoothNetworkInterfacePolicy.wiredEthernet.rawValue,
            routeGeneration: routeGeneration,
            candidateSource: "Direct static LAN endpoint"
        )
        print("[NetworkRoute] Starting direct LAN control fallback")
        connectDiscoveredRoute(
            interface: .wiredEthernet,
            endpoint: directLANEndpoint(for: .control),
            connectionParameters: makeParameters(for: .wiredEthernet),
            provenance: .directStaticLAN
        )
        return true
    }

    private func directLANEndpoint(for channel: BoothTransportChannel) -> NWEndpoint {
        let port: NWEndpoint.Port
        switch channel {
        case .control: port = Self.directLANControlPort
        case .preview: port = Self.directLANPreviewPort
        case .asset: port = Self.directLANAssetPort
        case .heartbeat: port = Self.directLANControlPort
        }
        return .hostPort(
            host: Self.directLANHost,
            port: port
        )
    }

    private func startRouteDiscoveryBrowser(
        on interface: BoothNetworkInterfacePolicy,
        generation: Int,
        parameters: NWParameters? = nil,
        isLANCompatibilityFallback: Bool = false
    ) {
        let candidateProvenance = BoothRouteCandidatePolicy.discoveryProvenance(
            interface: interface,
            isLANCompatibilityFallback: isLANCompatibilityFallback
        )
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

                self.updateDiscoveredPeers(from: results, provenance: candidateProvenance)
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
                    let decision = self.routeDiscoverySelection.consider(
                        interface,
                        preferredPreference: self.requestedPreference,
                        advertisedPreference: advertisedPreference
                    )
                    switch decision {
                    case .ignored:
                        continue
                    case .waitingForPreferredInterface:
                        self.emitTransportEvent(
                            .routeCandidateDiscovered,
                            route: interface.rawValue,
                            reason: advertisedPreference.map { "Bonjour network hint=\($0.rawValue)" },
                            routeGeneration: generation,
                            candidateSource: candidateProvenance.rawValue
                        )
                        self.storePendingRouteEndpoint(
                            result.endpoint,
                            for: interface,
                            provenance: candidateProvenance
                        )
                        self.scheduleRouteDiscoveryFallback()
                        continue
                    case .accepted:
                        self.emitTransportEvent(
                            .routeCandidateDiscovered,
                            route: interface.rawValue,
                            reason: advertisedPreference.map { "Bonjour network hint=\($0.rawValue)" },
                            routeGeneration: generation,
                            candidateSource: candidateProvenance.rawValue
                        )
                        self.connectDiscoveredRoute(
                            interface: interface,
                            endpoint: result.endpoint,
                            connectionParameters: isLANCompatibilityFallback ? .tcp : nil,
                            provenance: candidateProvenance
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
                    return
                } else if interface == .wifi {
                    self.wifiRouteDiscoveryBrowser = nil
                } else {
                    self.lanRouteDiscoveryBrowser = nil
                }
                self.scheduleReconnect()
            }
        }
        browser.start(queue: transportQueue)
        if isLANCompatibilityFallback {
            lanCompatibilityRouteDiscoveryBrowser = browser
        } else if interface == .wifi {
            wifiRouteDiscoveryBrowser = browser
        } else {
            lanRouteDiscoveryBrowser = browser
        }
    }

    private func storePendingRouteEndpoint(
        _ endpoint: NWEndpoint,
        for interface: BoothNetworkInterfacePolicy,
        provenance: BoothRouteCandidateProvenance
    ) {
        switch interface {
        case .wifi:
            pendingWiFiRouteEndpoint = endpoint
        case .wiredEthernet:
            pendingLANRouteEndpoint = endpoint
            pendingLANRouteProvenance = provenance
        }
    }

    private func scheduleRouteDiscoveryFallback() {
        guard routeDiscoveryFallbackTask == nil else { return }
        routeDiscoveryFallbackToken &+= 1
        let token = routeDiscoveryFallbackToken
        routeDiscoveryFallbackTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.routeDiscoveryFallbackToken == token {
                    self.routeDiscoveryFallbackTask = nil
                }
            }
            do {
                try await Task.sleep(for: .seconds(Self.routeDiscoveryGracePeriod))
            } catch {
                return
            }
            guard let self,
                  self.routeDiscoveryFallbackToken == token,
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
                provenance: pendingInterface == .wiredEthernet
                    ? self.pendingLANRouteProvenance ?? .ethernetConstrainedBonjour
                    : .localNetworkBonjour
            )
        }
    }

    private func connectDiscoveredRoute(
        interface: BoothNetworkInterfacePolicy,
        endpoint: NWEndpoint,
        connectionParameters: NWParameters? = nil,
        provenance: BoothRouteCandidateProvenance? = nil
    ) {
        routeDiscoveryFallbackTask?.cancel()
        routeDiscoveryFallbackToken &+= 1
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
            reason: interface == .wifi && requestedPreference == .lan ? "LAN unavailable" : nil
        )
        connect(
            to: endpoint,
            channel: .control,
            parameters: connectionParameters,
            provenance: provenance ?? (interface == .wiredEthernet
                ? .ethernetConstrainedBonjour
                : .localNetworkBonjour)
        )
    }

    private func cancelRouteDiscovery() {
        wifiRouteDiscoveryBrowser?.cancel()
        lanRouteDiscoveryBrowser?.cancel()
        lanCompatibilityRouteDiscoveryBrowser?.cancel()
        routeDiscoveryGate.invalidate()
        routeDiscoveryFallbackToken &+= 1
        routeDiscoveryFallbackTask?.cancel()
        routeDiscoveryFallbackTask = nil
        wifiRouteDiscoveryBrowser = nil
        lanRouteDiscoveryBrowser = nil
        lanCompatibilityRouteDiscoveryBrowser = nil
        pendingWiFiRouteEndpoint = nil
        pendingLANRouteEndpoint = nil
        pendingLANRouteProvenance = nil
        routeDiscoverySelection.reset()
        routeDiscoveryTargetPeerID = nil
        routeDiscoveryPreference = nil
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

    private func ensureDiscoveryForPeerSelection() {
        guard role == .iPad, shouldReconnect else { return }

        let hasActiveDiscovery = wifiRouteDiscoveryBrowser != nil
            || lanRouteDiscoveryBrowser != nil
            || lanCompatibilityRouteDiscoveryBrowser != nil
            || routeDiscoveryFallbackTask != nil
        let hasActiveControlAttempt = controlConnection != nil
            || controlBrowser != nil
            || directLANControlAttemptInFlight
        let decision = BoothRouteDiscoveryPolicy.decision(
            targetPeerID: targetPeerID,
            requestedPreference: requestedPreference,
            activeTargetPeerID: routeDiscoveryTargetPeerID,
            activePreference: routeDiscoveryPreference,
            hasActiveDiscovery: hasActiveDiscovery,
            hasActiveControlAttempt: hasActiveControlAttempt
        )
        guard decision == .restart else {
            emitTransportEvent(
                .routeDiscoveryReused,
                reason: "Existing discovery or control attempt retained for the selected peer."
            )
            return
        }
        startRouteDiscovery()
    }

    private func tearDownActiveTransport() {
        activeInterface = nil
        callbackGate.invalidate()
        transportRuntime.cancelReconnect()
        assetReconnectSource?.cancel()
        assetReconnectToken &+= 1
        assetReconnectSource = nil
        lanHandshakeTask?.cancel()
        lanHandshakeTask = nil
        waitingRecoveryScheduler.cancelAll()
        waitingRecoveryChannels.removeAll()
        stopHeartbeat()
        cancelTransportObjects()
        peerName = ""
        connectedPeerNames = []
        peerDeviceID = nil
        expectedPeerDeviceID = nil
        connectionState = .disconnected
    }

    private func cancelTransportObjects() {
        invalidateReceiveToken(for: .control)
        invalidateReceiveToken(for: .preview)
        invalidateReceiveToken(for: .asset)
        controlConnectionGeneration &+= 1
        assetConnectionGeneration &+= 1
        controlWritePump.invalidate(generation: controlConnectionGeneration)
        assetWritePump.invalidate(generation: assetConnectionGeneration)
        controlBrowser?.cancel()
        previewBrowser?.cancel()
        assetBrowser?.cancel()
        controlBrowser = nil
        previewBrowser = nil
        assetBrowser = nil
        controlListener?.cancel()
        previewListener?.cancel()
        assetListener?.cancel()
        controlListener = nil
        previewListener = nil
        assetListener = nil
        controlConnection?.cancel()
        previewConnection?.cancel()
        assetConnection?.cancel()
        controlConnection = nil
        previewConnection = nil
        assetConnection = nil
        controlConnectionIsViable = false
        controlEndpointDescription = nil
        previewEndpointDescription = nil
        assetEndpointDescription = nil
        resetAssetBinding()
        deferredAssetRequests.removeAll()
        previewConnectionGeneration &+= 1
        previewWritePump.invalidate(generation: previewConnectionGeneration)
        previewDeliveryPump.reset(generation: previewConnectionGeneration)
        didReceiveHello = false
        peerAuthenticated = false
        secureChannel.reset()
        secureNegotiationTimeoutSource?.cancel()
        secureNegotiationTimeoutSource = nil
        secureNegotiator.reset(connectionGeneration: controlConnectionGeneration)
        localSecureChannelHello = nil
        peerSecureChannelHello = nil
        deferredSecureChannelHello = nil
        secureChannelSessionID = nil
        secureChannelReadySent = false
        secureChannelReadyReceived = false
        secureChannelEstablished = false
        connectionStatus.publishSecureChannel(ready: false)
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
            metadata["pairingMacKey"] = session.info.macEphemeralPublicKey.base64URLEncodedString()
        }
        let serviceType: String
        switch channel {
        case .control: serviceType = Self.controlServiceType
        case .preview: serviceType = Self.previewServiceType
        case .asset: serviceType = Self.assetServiceType
        case .heartbeat: serviceType = Self.controlServiceType
        }
        return NWListener.Service(
            name: "PRC PhotoBooth \(channel == .control ? "Control" : channel == .preview ? "Preview" : "Asset") \(localIdentity.id)",
            type: serviceType,
            txtRecord: NWTXTRecord(metadata)
        )
    }

    private func refreshAdvertisedServices() {
        if let controlListener { controlListener.service = advertisedService(for: .control) }
        if let previewListener { previewListener.service = advertisedService(for: .preview) }
        if let assetListener { assetListener.service = advertisedService(for: .asset) }
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
        let macEphemeralPublicKey = txtRecord["pairingMacKey"].flatMap(Data.init(base64URLString:))
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
            pairingMacEphemeralPublicKey: macEphemeralPublicKey,
            isTrusted: trustedStore.trustedPeerIDs.contains(id),
            isPreferred: preferred == id
        )
    }

    private func updateDiscoveredPeers(
        from results: Set<NWBrowser.Result>,
        provenance: BoothRouteCandidateProvenance
    ) {
        for id in Array(discoveredPeerProvenanceByID.keys) {
            guard var provenances = discoveredPeerProvenanceByID[id] else { continue }
            provenances.remove(provenance)
            if provenances.isEmpty {
                discoveredPeerProvenanceByID.removeValue(forKey: id)
                discoveredPeersByID.removeValue(forKey: id)
            } else {
                discoveredPeerProvenanceByID[id] = provenances
                if var peer = discoveredPeersByID[id] {
                    peer.availableInterfaces = Set(provenances.map(\.interface))
                    discoveredPeersByID[id] = peer
                }
            }
        }

        for result in results {
            guard var peer = discoveredPeer(from: result, interface: provenance.interface) else { continue }
            var provenances = discoveredPeerProvenanceByID[peer.id, default: []]
            provenances.insert(provenance)
            discoveredPeerProvenanceByID[peer.id] = provenances
            peer.availableInterfaces = Set(provenances.map(\.interface))
            if var existing = discoveredPeersByID[peer.id] {
                existing.availableInterfaces = peer.availableInterfaces
                existing.displayName = peer.displayName
                existing.appVersion = peer.appVersion
                existing.protocolVersion = peer.protocolVersion
                existing.networkPreference = peer.networkPreference
                existing.pairingSessionID = peer.pairingSessionID ?? existing.pairingSessionID
                existing.pairingExpiresAt = peer.pairingExpiresAt ?? existing.pairingExpiresAt
                existing.pairingMacEphemeralPublicKey = peer.pairingMacEphemeralPublicKey ?? existing.pairingMacEphemeralPublicKey
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
        if channel == .asset, assetListener != nil { return }
        let listener: NWListener
        do {
            if activeInterface == .wiredEthernet {
                let port: NWEndpoint.Port
                switch channel {
                case .control: port = Self.directLANControlPort
                case .preview: port = Self.directLANPreviewPort
                case .asset: port = Self.directLANAssetPort
                case .heartbeat: port = Self.directLANControlPort
                }
                listener = try NWListener(using: makeParameters(for: activeInterface), on: port)
            } else {
                listener = try NWListener(using: makeParameters(for: activeInterface))
            }
        } catch {
            print("[Network] listener creation failed: \(error.localizedDescription)")
            if channel == .asset {
                scheduleAssetReconnect()
            } else if activeInterface == .wiredEthernet {
                handleLANHandshakeFailure(
                    reason: error.localizedDescription,
                    retainManualListener: false
                )
            }
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
                switch channel {
                case .control: self.controlListener = nil
                case .preview: self.previewListener = nil
                case .asset: self.assetListener = nil
                case .heartbeat: break
                }
                if channel == .asset {
                    self.scheduleAssetReconnect()
                } else if interfaceAtStart == .wiredEthernet {
                    self.handleLANHandshakeFailure(reason: message, retainManualListener: false)
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
        listener.start(queue: transportQueue)
        switch channel {
        case .control: controlListener = listener
        case .preview: previewListener = listener
        case .asset: assetListener = listener
        case .heartbeat: break
        }
    }

    private func startBrowser(channel: BoothTransportChannel) {
        guard let activeInterface else { return }
        if channel == .control, controlBrowser != nil { return }
        if channel == .preview, previewBrowser != nil { return }
        if channel == .asset, assetBrowser != nil { return }
        let serviceType: String
        switch channel {
        case .control: serviceType = Self.controlServiceType
        case .preview: serviceType = Self.previewServiceType
        case .asset: serviceType = Self.assetServiceType
        case .heartbeat: return
        }
        let browser = NWBrowser(
            for: .bonjour(type: serviceType, domain: nil),
            using: makeParameters(for: activeInterface)
        )
        configure(browser, channel: channel, interface: activeInterface)
        browser.start(queue: transportQueue)
        switch channel {
        case .control: controlBrowser = browser
        case .preview: previewBrowser = browser
        case .asset: assetBrowser = browser
        case .heartbeat: break
        }
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
                switch channel {
                case .control: self.controlBrowser = nil
                case .preview: self.previewBrowser = nil
                case .asset: self.assetBrowser = nil
                case .heartbeat: break
                }
                if channel == .asset {
                    self.scheduleAssetReconnect()
                } else if interfaceAtStart == .wiredEthernet {
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
        if channel == .preview || channel == .asset {
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
        if channel == .asset, !peerAuthenticated || !secureChannelEstablished {
            connection.cancel()
            return
        }
        if channel == .preview,
           BoothSecondaryChannelAdmissionPolicy.decision(existingVerified: previewIdentityVerified)
                == .rejectCandidate {
            connection.cancel()
            emitTransportEvent(
                .secondaryCandidateRejected,
                channel: .preview,
                reason: "Verified preview channel is already active."
            )
            return
        }
        if channel == .asset,
           BoothSecondaryChannelAdmissionPolicy.decision(existingVerified: assetIdentityVerified)
                == .rejectCandidate {
            connection.cancel()
            emitTransportEvent(
                .secondaryCandidateRejected,
                channel: .asset,
                reason: "Verified asset channel is already active."
            )
            return
        }
        invalidateReceiveToken(for: channel)
        if channel == .control {
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnectionGeneration &+= 1
            assetConnectionGeneration &+= 1
            controlWritePump.invalidate(generation: controlConnectionGeneration)
            assetWritePump.invalidate(generation: assetConnectionGeneration)
            assetConnection?.cancel()
            assetConnection = nil
            assetEndpointDescription = nil
            resetAssetBinding()
            deferredAssetRequests.removeAll()
            controlConnection = connection
            controlEndpointDescription = connection.endpoint.debugDescription
            resetControlAuthentication()
            emitTransportEvent(
                .controlConnectionCreated,
                channel: .control,
                route: activeInterface?.rawValue,
                reason: "Accepted control connection."
            )
            controlWritePump.bind(connection, generation: controlConnectionGeneration)
        } else if channel == .preview {
            previewConnectionGeneration &+= 1
            previewWritePump.invalidate(generation: previewConnectionGeneration)
            previewDeliveryPump.reset(generation: previewConnectionGeneration)
            previewConnection?.cancel()
            previewConnection = connection
            previewEndpointDescription = connection.endpoint.debugDescription
            resetPreviewIdentity()
            previewWritePump.bind(connection, generation: previewConnectionGeneration)
        } else {
            assetConnectionGeneration &+= 1
            assetConnection?.cancel()
            assetWritePump.invalidate(generation: assetConnectionGeneration)
            assetConnection = connection
            assetEndpointDescription = connection.endpoint.debugDescription
            resetAssetBinding()
            assetWritePump.bind(connection, generation: assetConnectionGeneration)
        }
        configure(
            connection,
            channel: channel,
            provenance: activeInterface == .wiredEthernet ? .directStaticLAN : .localNetworkBonjour
        )
    }

    private func connect(
        to endpoint: NWEndpoint,
        channel: BoothTransportChannel,
        parameters: NWParameters? = nil,
        provenance: BoothRouteCandidateProvenance? = nil
    ) {
        guard let activeInterface else { return }
        if channel == .preview, expectedPeerDeviceID == nil { return }
        if channel == .asset, expectedPeerDeviceID == nil { return }
        let description = endpoint.debugDescription
        if channel == .control {
            guard controlConnection == nil || controlEndpointDescription != description else { return }
            invalidateReceiveToken(for: .control)
            resetPreviewConnection()
            controlConnection?.cancel()
            controlConnectionGeneration &+= 1
            assetConnectionGeneration &+= 1
            controlWritePump.invalidate(generation: controlConnectionGeneration)
            assetWritePump.invalidate(generation: assetConnectionGeneration)
            assetConnection?.cancel()
            assetConnection = nil
            assetEndpointDescription = nil
            controlConnection = NWConnection(
                to: endpoint,
                using: parameters ?? makeParameters(for: activeInterface)
            )
            controlEndpointDescription = description
            resetControlAuthentication()
            if let connection = controlConnection {
                emitTransportEvent(
                    .controlConnectionCreated,
                    channel: .control,
                    route: activeInterface.rawValue,
                    reason: "Created control connection for selected route."
                )
                controlWritePump.bind(connection, generation: controlConnectionGeneration)
                configure(connection, channel: channel, provenance: provenance)
            }
        } else if channel == .preview {
            guard previewConnection == nil || previewEndpointDescription != description else { return }
            if BoothSecondaryChannelAdmissionPolicy.decision(existingVerified: previewIdentityVerified)
                    == .rejectCandidate {
                emitTransportEvent(
                    .secondaryCandidateRejected,
                    channel: .preview,
                    reason: "Verified preview channel is already active."
                )
                return
            }
            invalidateReceiveToken(for: .preview)
            previewConnectionGeneration &+= 1
            previewWritePump.invalidate(generation: previewConnectionGeneration)
            previewDeliveryPump.reset(generation: previewConnectionGeneration)
            previewConnection?.cancel()
            previewConnection = NWConnection(
                to: endpoint,
                using: parameters ?? makeParameters(for: activeInterface)
            )
            previewEndpointDescription = description
            resetPreviewIdentity()
            if let connection = previewConnection {
                previewWritePump.bind(connection, generation: previewConnectionGeneration)
                configure(connection, channel: channel, provenance: provenance)
            }
        } else {
            guard assetConnection == nil || assetEndpointDescription != description else { return }
            if BoothSecondaryChannelAdmissionPolicy.decision(existingVerified: assetIdentityVerified)
                    == .rejectCandidate {
                emitTransportEvent(
                    .secondaryCandidateRejected,
                    channel: .asset,
                    reason: "Verified asset channel is already active."
                )
                return
            }
            invalidateReceiveToken(for: .asset)
            assetConnectionGeneration &+= 1
            assetConnection?.cancel()
            assetWritePump.invalidate(generation: assetConnectionGeneration)
            assetConnection = NWConnection(
                to: endpoint,
                using: parameters ?? makeParameters(for: activeInterface)
            )
            assetEndpointDescription = description
            resetAssetBinding()
            if let connection = assetConnection {
                assetWritePump.bind(connection, generation: assetConnectionGeneration)
                configure(connection, channel: channel, provenance: provenance)
            }
        }
    }

    private func configure(
        _ connection: NWConnection,
        channel: BoothTransportChannel,
        provenance: BoothRouteCandidateProvenance? = nil
    ) {
        let resolvedProvenance = provenance ?? {
            guard let activeInterface else { return .localNetworkBonjour }
            if role == .mac, activeInterface == .wiredEthernet { return .directStaticLAN }
            return activeInterface == .wiredEthernet
                ? .ethernetConstrainedBonjour
                : .localNetworkBonjour
        }()
        let generationAtStart = callbackGate.generation
        let connectionGenerationAtStart = connectionGeneration(for: channel)
        let recoveryScheduler = waitingRecoveryScheduler
        let receiveToken = replaceReceiveToken(for: channel)
        connection.viabilityUpdateHandler = { [weak self, weak connection, recoveryScheduler] isViable in
            let reason = isViable ? nil : "Network path is not viable."
            if let connection {
                if isViable {
                    recoveryScheduler.cancel(
                        connection: connection,
                        channel: channel,
                        generation: connectionGenerationAtStart
                    )
                } else {
                    recoveryScheduler.schedule(
                        connection: connection,
                        channel: channel,
                        generation: connectionGenerationAtStart,
                        after: 2
                    )
                }
            }
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection,
                      self.isCurrent(connection, channel: channel) else { return }
                if channel == .control { self.controlConnectionIsViable = isViable }
                self.emitTransportEvent(
                    .routeViabilityChanged,
                    channel: channel,
                    reason: isViable ? "Network path is viable." : reason
                )
                if let reason {
                    self.publishWaitingRecovery(for: connection, channel: channel, reason: reason)
                } else {
                    self.cancelWaitingRecovery(for: channel)
                }
            }
        }
        connection.pathUpdateHandler = { [weak self, weak connection] path in
            let route = Self.pathDescription(path)
            print("[Network] \(channel) path=\(route)")
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection,
                      self.callbackGate.accepts(generationAtStart),
                      self.isCurrent(connection, channel: channel),
                      self.connectionGeneration(for: channel) == connectionGenerationAtStart else { return }
                self.emitTransportEvent(.routeChanged, channel: channel, route: route)
            }
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] hasBetterPath in
            guard hasBetterPath else { return }
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection,
                      self.isCurrent(connection, channel: channel) else { return }
                print("[Network] \(channel) better path available; keeping current connection")
            }
        }
        connection.stateUpdateHandler = { [weak self, weak connection, recoveryScheduler] state in
            switch state {
            case .waiting:
                if let connection {
                    recoveryScheduler.schedule(
                        connection: connection,
                        channel: channel,
                        generation: connectionGenerationAtStart,
                        after: 2
                    )
                }
            case .ready, .failed, .cancelled:
                if let connection {
                    recoveryScheduler.cancel(
                        connection: connection,
                        channel: channel,
                        generation: connectionGenerationAtStart
                    )
                }
            default:
                break
            }
            Task { @MainActor [weak self] in
                guard let self, let connection else { return }
                guard self.callbackGate.accepts(generationAtStart),
                      self.isCurrent(connection, channel: channel),
                      self.connectionGeneration(for: channel) == connectionGenerationAtStart else { return }
                switch state {
                case .waiting(let error):
                    if channel == .control { self.controlConnectionIsViable = false }
                    self.emitTransportEvent(
                        .transportWaiting,
                        channel: channel,
                        attempt: self.reconnectAttempt,
                        reason: error.localizedDescription
                    )
                    self.publishWaitingRecovery(
                        for: connection,
                        channel: channel,
                        reason: error.localizedDescription
                    )
                case .ready:
                    if channel == .control { self.controlConnectionIsViable = true }
                    self.cancelWaitingRecovery(for: channel)
                    if channel != .asset {
                        self.emitTransportEvent(.transportReady, channel: channel)
                    }
                    if self.activeInterface == .wiredEthernet,
                       let path = connection.currentPath,
                       !path.usesInterfaceType(.wiredEthernet) {
                        if BoothRouteCandidatePolicy.shouldRejectNonEthernetPath(
                            provenance: resolvedProvenance
                        ) {
                            self.connectionDidClose(
                                connection,
                                channel: channel,
                                reason: "Transport became ready on a non-Ethernet path"
                            )
                            return
                        }
                        self.emitTransportEvent(
                            .pathHintUnavailableIgnored,
                            channel: channel,
                            route: "Wired Ethernet",
                            reason: "Non-Ethernet path hint ignored for \(resolvedProvenance.rawValue); hello/authentication remains required.",
                            candidateSource: resolvedProvenance.rawValue
                        )
                    }
                    if channel == .control {
                        if self.activeInterface == .wiredEthernet {
                            self.lanHandshakeState = .waiting
                        }
                        self.connectionState = .connecting
                        self.publishStatus()
                        guard self.receive(on: connection, channel: channel, token: receiveToken) else { return }
                        self.sendTransportHello()
                    } else if channel == .preview {
                        self.emitTransportEvent(.previewReconnected, channel: channel)
                        guard self.receive(on: connection, channel: channel, token: receiveToken) else { return }
                        self.sendPreviewHello(on: connection)
                    } else {
                        self.connectionStatus.publishAssetChannel(connected: true, verified: false)
                        self.emitTransportEvent(.assetChannelConnected, channel: channel)
                        guard self.receive(on: connection, channel: .asset, token: receiveToken) else { return }
                        self.sendAssetBinding(on: connection)
                    }
                case .failed, .cancelled:
                    if channel == .control { self.controlConnectionIsViable = false }
                    self.cancelWaitingRecovery(for: channel)
                    if channel == .preview {
                        self.connectionStatus.publishPreviewChannel(connected: false)
                    } else if channel == .asset {
                        self.connectionStatus.publishAssetChannel(connected: false)
                        self.emitTransportEvent(.assetChannelDisconnected, channel: channel)
                    }
                    self.connectionDidClose(connection, channel: channel)
                default:
                    break
                }
            }
        }
        if channel == .control {
            emitTransportEvent(
                .controlConnectionPreparing,
                channel: .control,
                reason: "Preparing control callbacks and receive loop."
            )
        }
        connection.start(queue: transportQueue)
    }

    private func publishWaitingRecovery(
        for connection: NWConnection,
        channel: BoothTransportChannel,
        reason: String
    ) {
        guard isCurrent(connection, channel: channel), shouldReconnect else { return }
        let key = channel.rawValue
        guard waitingRecoveryChannels.insert(key).inserted else { return }
        lastNetworkError = reason
        connectionStatus.publishNetworkError(reason)
        if channel == .control {
            connectionState = .connecting
            publishStatus()
        } else if channel == .preview {
            connectionStatus.publishPreviewChannel(connected: false)
        } else if channel == .asset {
            connectionStatus.publishAssetChannel(connected: false)
        }

        emitTransportEvent(
            .waitingRecoveryScheduled,
            channel: channel,
            duration: 2,
            reason: reason
        )
    }

    private func cancelWaitingRecovery(for channel: BoothTransportChannel) {
        let key = channel.rawValue
        waitingRecoveryScheduler.cancel(channel: channel)
        guard waitingRecoveryChannels.remove(key) != nil else { return }
        emitTransportEvent(.waitingRecoveryCancelled, channel: channel)
    }

    private func connectionGeneration(for channel: BoothTransportChannel) -> Int {
        switch channel {
        case .control: return controlConnectionGeneration
        case .preview: return previewConnectionGeneration
        case .asset: return assetConnectionGeneration
        case .heartbeat: return controlConnectionGeneration
        }
    }

    private nonisolated static func pathDescription(_ path: NWPath) -> String {
        if path.usesInterfaceType(.wiredEthernet) { return "Wired Ethernet" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi or local wireless" }
        if path.usesInterfaceType(.other) { return "Other / peer-to-peer" }
        return "Unknown"
    }

    private func receive(
        on connection: NWConnection,
        channel: BoothTransportChannel,
        token: BoothTransportReceiveToken
    ) -> Bool {
        guard token.begin() else { return false }
        Self.receive(
            on: connection,
            channel: channel,
            decoder: BoothTransportFrameDecoder(),
            token: token,
            secureChannel: secureChannel,
            activity: { [transportRuntime, secureChannel] in
                guard secureChannel.isConfigured else { return }
                transportRuntime.markControlActivityOnQueue()
            },
            deliver: { [weak self, weak connection] frames in
                guard let self, let connection,
                      token.isValid,
                      self.isCurrent(connection, channel: channel) else { return }
                self.handleDecodedFrames(frames)
            },
            deliverPreview: { [previewDeliveryPump, previewConnectionGeneration] data in
                previewDeliveryPump.enqueueOnQueue(data, generation: previewConnectionGeneration)
            },
            close: { [weak self, weak connection] reason in
                guard let self, let connection,
                      token.isValid,
                      self.isCurrent(connection, channel: channel) else { return }
                self.connectionDidClose(connection, channel: channel, reason: reason)
            }
        )
        return true
    }

    nonisolated static func receive(
        on connection: NWConnection,
        channel: BoothTransportChannel,
        decoder: BoothTransportFrameDecoder,
        token: BoothTransportReceiveToken,
        secureChannel: BoothSecureChannel,
        activity: @escaping @Sendable () -> Void,
        deliver: @escaping @MainActor ([BoothDecodedTransportFrame]) -> Void,
        deliverPreview: @escaping @Sendable (Data) -> Void,
        close: @escaping @MainActor (String?) -> Void
    ) {
        guard token.isValid else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            guard token.isValid else { return }
            var shouldContinue = !isComplete && error == nil
            if let data, !data.isEmpty {
                do {
                    let frames = try decoder.decode(
                        data,
                        channel: channel,
                        secureChannel: secureChannel
                    )
                    if !frames.isEmpty {
                        if channel == .control, token.isValid { activity() }
                        var mainActorFrames: [BoothDecodedTransportFrame] = []
                        for frame in frames {
                            if case .preview(let payload) = frame, channel == .preview {
                                deliverPreview(payload)
                            } else {
                                mainActorFrames.append(frame)
                            }
                        }
                        if !mainActorFrames.isEmpty {
                            Task { @MainActor in deliver(mainActorFrames) }
                        }
                    }
                } catch {
                    shouldContinue = false
                    Task { @MainActor in close("Invalid \(channel) frame: \(error)") }
                }
            }

            if isComplete || error != nil {
                Task { @MainActor in close(error?.localizedDescription) }
            } else if shouldContinue {
                Self.receive(
                    on: connection,
                    channel: channel,
                    decoder: decoder,
                    token: token,
                    secureChannel: secureChannel,
                    activity: activity,
                    deliver: deliver,
                    deliverPreview: deliverPreview,
                    close: close
                )
            }
        }
    }

    private func handleDecodedFrames(_ frames: [BoothDecodedTransportFrame]) {
        for frame in frames {
            switch frame {
            case .control(let message):
                if peerAuthenticated, secureChannelEstablished {
                    lastControlMessageAt = Date()
                    connectionStatus.publishControlActivity(at: lastControlMessageAt)
                }
                handleControl(message)
            case .heartbeat:
                guard peerAuthenticated, secureChannelEstablished else { continue }
                lastControlMessageAt = Date()
                connectionStatus.publishControlActivity(at: lastControlMessageAt)
            case .assetBinding(let binding):
                handleAssetBinding(binding)
            case .asset(let chunk):
                guard peerAuthenticated, secureChannelEstablished, assetIdentityVerified else { continue }
                onAssetChunk?(chunk)
            case .previewHello(let payload):
                handlePreviewHello(payload)
            case .preview(let payload):
                if previewPeerID == nil,
                   (try? JSONDecoder().decode(BoothTransportHello.self, from: payload)) != nil {
                    handlePreviewHello(payload)
                } else if previewIdentityVerified {
                    onPreviewFrame?(payload)
                }
            }
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
        case .pairingVerificationConfirmed(let sessionID, let proof):
            handlePairingVerificationConfirmed(sessionID: sessionID, proof: proof)
        case .authChallenge(let challenge):
            handleAuthChallenge(challenge)
        case .authProof(let proof):
            handleAuthProof(proof)
        case .secureChannelHello(let hello):
            handleSecureChannelHello(hello)
        case .secureChannelReady(let sessionID, let proof):
            handleSecureChannelReady(sessionID: sessionID, proof: proof)
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
            guard peerAuthenticated, secureChannelEstablished else { return }
            lastControlMessageAt = Date()
            connectionStatus.publishControlActivity(at: lastControlMessageAt)
        case .assetRequest(let references) where role == .mac && !assetIdentityVerified:
            deferAssetRequests(references)
        default:
            guard peerAuthenticated, secureChannelEstablished else { return }
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
        guard hello.capabilities.contains("secure-channel-v1"),
              hello.capabilities.contains("asset-channel-v2"),
              hello.capabilities.contains(Self.previewIdentityCapability) else {
            rejectControlConnection(BoothPairingError.incompatibleProtocol.localizedDescription)
            return
        }
        if let peerDeviceID,
           peerDeviceID != hello.deviceID {
            rejectControlConnection("Control peer identity changed during this connection.")
            return
        }

        didReceiveHello = true
        peerHello = hello
        peerDeviceID = hello.deviceID
        secureNegotiator.setExpectedPeerDeviceID(hello.deviceID)
        peerName = hello.deviceName.isEmpty ? hello.deviceID : hello.deviceName
        previewPeerSupportsIdentity = hello.capabilities.contains(Self.previewIdentityCapability)
        connectionState = .connecting
        emitTransportEvent(
            .controlHelloReceived,
            channel: .control,
            reason: hello.networkPreference.map { "Peer advertised network hint=\($0.rawValue)" }
        )
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
            if pendingPairingCommit?.method == .pin,
               pendingPairingVerificationCode != nil {
                setPairingStage(.verificationPending, state: .authenticating(peerID: hello.deviceID))
            } else {
                beginAuthentication(with: hello.deviceID)
            }
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
        let pairingGenerationAtStart = pairingGeneration
        guard let connection,
              pairingRequestSubmission.claim(
                  sessionID: request.sessionID,
                  connectionGeneration: controlConnectionGeneration
              ) else { return }
        emitTransportEvent(
            .pairingRequestSubmitted,
            channel: .control,
            reason: "Pairing request submitted after matching control hello."
        )
        setPairingStage(.requestSending, state: .pairing(expiresAt: pendingPairingStateExpiry))
        sendCriticalControl(
            .pairingRequest(request: request),
            on: connection,
            sessionID: request.sessionID
        ) { [weak self] result in
            guard let self else { return }
            guard self.pairingGeneration == pairingGenerationAtStart,
                  self.pendingPairingRequest?.sessionID == request.sessionID else { return }
            switch result {
            case .success:
                self.setPairingStage(.requestSent, state: .pairing(expiresAt: self.pendingPairingStateExpiry))
            case .failure(let error):
                self.pairingRequestSubmission.resetIfMatches(
                    sessionID: request.sessionID,
                    connectionGeneration: self.controlConnectionGeneration
                )
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
                if commit.method == .pin {
                    self.setPairingStage(.verificationPending, state: .authenticating(peerID: commit.peer.id))
                    if self.didConfirmPairingVerification {
                        self.sendPairingVerificationConfirmation(commit, on: connection)
                    }
                } else {
                    self.setPairingStage(.authenticating, state: .authenticating(peerID: commit.peer.id))
                    self.beginAuthentication(with: commit.peer.id)
                }
            case .failure(let error):
                self.failPendingPairingDelivery("Pairing result could not be delivered: \(error.message)")
            }
        }
    }

    private func sendPairingVerificationConfirmation(
        _ commit: PendingPairingCommit,
        on connection: NWConnection?
    ) {
        guard pendingPairingCommit == commit,
              commit.method == .pin,
              pendingPairingVerificationCode != nil,
              didConfirmPairingVerification else { return }
        sendCriticalControl(
            .pairingVerificationConfirmed(
                sessionID: commit.sessionID,
                proof: BoothPairingCrypto.makeVerificationConfirmationProof(
                    secret: commit.secret,
                    transcript: commit.transcript,
                    role: .mac
                )
            ),
            on: connection,
            sessionID: commit.sessionID
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.setPairingStage(.authenticating, state: .authenticating(peerID: commit.peer.id))
                self.beginAuthentication(with: commit.peer.id)
            case .failure(let error):
                self.didConfirmPairingVerification = false
                self.failPendingPairingDelivery("Pairing verification could not be delivered: \(error.message)")
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
              session.macEphemeralPublicKey.count == 32,
              session.expiresAt > Date() else {
            if role == .iPad, pendingPairingIntent != nil {
                failPairing("The Mac returned an invalid pairing session.")
            }
            return
        }

        if var peer = discoveredPeersByID[session.macDeviceID] {
            peer.pairingSessionID = session.sessionID
            peer.pairingExpiresAt = session.expiresAt
            peer.pairingMacEphemeralPublicKey = session.macEphemeralPublicKey
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
        code: String,
        macEphemeralPublicKey: Data?,
        expiresAt: Date? = nil
    ) {
        pairingGeneration &+= 1
        cancelPairingExpiry()
        let expiry = expiresAt
            ?? discoveredPeersByID[peerID]?.pairingExpiresAt
            ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
        pendingPairingIntent = nil
        pendingPairingFailure = nil
        pairingRequestSubmission.reset()
        pendingPairingSessionID = sessionID
        guard let macEphemeralPublicKey, macEphemeralPublicKey.count == 32 else {
            failPairing("Pairing session is missing its secure key.")
            return
        }
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let iPadEphemeralPublicKey = ephemeralKey.publicKey.rawRepresentation
        let transcript = BoothPairingCrypto.pairingTranscript(
            sessionID: sessionID,
            macDeviceID: peerID,
            iPadDeviceID: localIdentity.id,
            method: method,
            macEphemeralPublicKey: macEphemeralPublicKey,
            iPadEphemeralPublicKey: iPadEphemeralPublicKey
        )
        pendingPairingRequest = BoothPairingRequest(
            sessionID: sessionID,
            targetMacDeviceID: peerID,
            iPadIdentity: localIdentity,
            method: method,
            iPadEphemeralPublicKey: iPadEphemeralPublicKey,
            admissionProof: BoothPairingCrypto.makeAdmissionProof(code: code, transcript: transcript)
        )
        pendingPairingPrivateKeyData = ephemeralKey.rawRepresentation
        pendingPairingCode = code
        receivedPairingSession = BoothPairingSessionInfo(
            sessionID: sessionID,
            macDeviceID: peerID,
            macDeviceName: discoveredPeersByID[peerID]?.displayName ?? peerID,
            expiresAt: expiresAt ?? Date().addingTimeInterval(BoothPairingSession.lifetime),
            macEphemeralPublicKey: macEphemeralPublicKey
        )
        targetPeerID = peerID
        schedulePairingExpiry(sessionID: sessionID, expiresAt: expiry)
        if didReceiveHello, peerDeviceID == peerID, !peerAuthenticated,
           let pendingPairingRequest,
           controlConnection != nil {
            sendPairingRequest(pendingPairingRequest, on: controlConnection)
            return
        }
        setPairingStage(.discovering, state: .pairing(expiresAt: expiry))
        ensureDiscoveryForPeerSelection()
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
        guard request.iPadEphemeralPublicKey.count == 32,
              request.admissionProof.count == SHA256.Digest.byteCount else {
            sendPairingFailure("Pairing request is missing secure proof material.")
            return
        }

        incomingPairingRequest = IncomingBoothPairingRequest(
            iPadIdentity: request.iPadIdentity
        )
        let transcript = BoothPairingCrypto.pairingTranscript(
            sessionID: request.sessionID,
            macDeviceID: localIdentity.id,
            iPadDeviceID: request.iPadIdentity.id,
            method: request.method,
            macEphemeralPublicKey: session.info.macEphemeralPublicKey,
            iPadEphemeralPublicKey: request.iPadEphemeralPublicKey
        )
        let validation = session.validateAdmissionProof(
            request.admissionProof,
            method: request.method,
            transcript: transcript
        )
        currentPairingSession = session

        switch validation {
        case .accepted:
            do {
                let secret = try session.deriveSecret(
                    iPadEphemeralPublicKey: request.iPadEphemeralPublicKey,
                    method: request.method,
                    transcript: transcript
                )
                let peer = TrustedBoothPeer(
                    id: request.iPadIdentity.id,
                    displayName: request.iPadIdentity.displayName,
                    role: .iPad,
                    lastSeenAt: Date()
                )
                pendingPairingCommit = PendingPairingCommit(
                    sessionID: request.sessionID,
                    method: request.method,
                    peer: peer,
                    macIdentity: localIdentity,
                    secret: secret,
                    expiresAt: session.info.expiresAt,
                    transcript: transcript,
                    macEphemeralPublicKey: session.info.macEphemeralPublicKey,
                    keyAgreementProof: BoothPairingCrypto.makeKeyAgreementProof(
                        secret: secret,
                        transcript: transcript,
                        role: .mac
                    )
                )
                pendingPairingRequest = nil
                clearActivePairingSession()
                pendingPairingVerificationCode = request.method == .pin
                    ? BoothPairingCrypto.makeVerificationCode(secret: secret, transcript: transcript)
                    : nil
                didConfirmPairingVerification = false
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
            reason = request.method == .pin
                ? "Pairing PIN is invalid. \(remainingAttempts) attempts remaining."
                : "Pairing QR code is invalid."
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
        let macEphemeralPublicKey = result.macEphemeralPublicKey,
        let keyAgreementProof = result.keyAgreementProof,
        let privateKeyData = pendingPairingPrivateKeyData,
        let code = pendingPairingCode else {
            failPairing("Pairing result was not valid for this request.")
            return
        }

        guard receivedPairingSession?.macEphemeralPublicKey == macEphemeralPublicKey else {
            failPairing("Pairing result used a different secure session key.")
            return
        }
        let transcript = BoothPairingCrypto.pairingTranscript(
            sessionID: request.sessionID,
            macDeviceID: macIdentity.id,
            iPadDeviceID: request.iPadIdentity.id,
            method: request.method,
            macEphemeralPublicKey: macEphemeralPublicKey,
            iPadEphemeralPublicKey: request.iPadEphemeralPublicKey
        )
        guard let secret = try? BoothPairingCrypto.derivePairingSecret(
            privateKeyData: privateKeyData,
            peerPublicKeyData: macEphemeralPublicKey,
            code: code,
            transcript: transcript
        ),
        BoothPairingCrypto.constantTimeEqual(
            keyAgreementProof,
            BoothPairingCrypto.makeKeyAgreementProof(secret: secret, transcript: transcript, role: .mac)
        ) else {
            failPairing("Pairing result proof could not be verified.")
            return
        }

        let expiry = pairingExpiresAt ?? Date().addingTimeInterval(BoothPairingSession.lifetime)
        pendingPairingCommit = PendingPairingCommit(
            sessionID: request.sessionID,
            method: request.method,
            peer: TrustedBoothPeer(
                id: macIdentity.id,
                displayName: macIdentity.displayName,
                role: .mac,
                lastSeenAt: Date()
            ),
            macIdentity: macIdentity,
            secret: secret,
            expiresAt: expiry,
            transcript: transcript,
            macEphemeralPublicKey: macEphemeralPublicKey,
            keyAgreementProof: keyAgreementProof
        )
        pendingPairingSessionID = request.sessionID
        pendingPairingFailure = nil
        targetPeerID = macIdentity.id
        pendingPairingRequest = nil
        pendingPairingPrivateKeyData = nil
        pendingPairingCode = nil
        pendingPairingVerificationCode = request.method == .pin
            ? BoothPairingCrypto.makeVerificationCode(secret: secret, transcript: transcript)
            : nil
        didConfirmPairingVerification = false
        schedulePairingExpiry(sessionID: request.sessionID, expiresAt: expiry)
        if request.method == .pin {
            setPairingStage(.verificationPending, state: .authenticating(peerID: macIdentity.id))
        } else {
            setPairingStage(.resultReceived, state: .authenticating(peerID: macIdentity.id))
            beginAuthentication(with: macIdentity.id)
            if let deferredAuthChallenge {
                self.deferredAuthChallenge = nil
                handleAuthChallenge(deferredAuthChallenge)
            }
        }
    }

    private func handlePairingVerificationConfirmed(sessionID: String, proof: Data) {
        guard role == .iPad,
              let commit = pendingPairingCommit,
              commit.method == .pin,
              commit.sessionID == sessionID,
              pendingPairingVerificationCode != nil,
              pairingStageValue == .verificationPending,
              proof.count == SHA256.Digest.byteCount,
              !peerAuthenticated else { return }
        let expectedProof = BoothPairingCrypto.makeVerificationConfirmationProof(
            secret: commit.secret,
            transcript: commit.transcript,
            role: .mac
        )
        guard BoothPairingCrypto.constantTimeEqual(proof, expectedProof) else {
            rejectControlConnection("Pairing verification proof is invalid.")
            return
        }
        setPairingStage(.authenticating, state: .authenticating(peerID: commit.peer.id))
        beginAuthentication(with: commit.peer.id)
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
        if pendingPairingCommit?.method == .pin,
           pendingPairingVerificationCode != nil,
           pairingStageValue == .verificationPending {
            deferredAuthChallenge = challenge
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
        if pendingPairingCommit?.method == .pin,
           pendingPairingVerificationCode != nil,
           pairingStageValue == .verificationPending {
            rejectControlConnection("Pairing verification is still pending.")
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
                pendingPairingVerificationCode = nil
                didConfirmPairingVerification = false
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
        directLANControlAttemptInFlight = false
        connectionState = .connected(peerName: peerName)
        let completedReconnectAttempt = reconnectAttempt
        reconnectAttempt = 0
        lastControlMessageAt = Date()
        connectionStatus.publishControlActivity(at: lastControlMessageAt)
        connectionStatus.publishReconnectState(inProgress: false)
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
        emitTransportEvent(.transportReconnectSucceeded, channel: .control, attempt: completedReconnectAttempt)
        if role == .mac {
            startSecureChannelHandshake()
        } else if let deferred = deferredSecureChannelHello,
                  deferred.generation == controlConnectionGeneration {
            deferredSecureChannelHello = nil
            handleSecureChannelHello(deferred.hello)
        }
    }

    private func startSecureChannelHandshake() {
        guard role == .mac,
              peerAuthenticated,
              localSecureChannelHello == nil,
              let peerDeviceID,
              authenticationSecret(peerID: peerDeviceID) != nil else {
            failSecureChannel("Secure channel secret is unavailable.")
            return
        }
        do {
            secureChannelReadySent = false
            secureChannelReadyReceived = false
            secureChannelEstablished = false
            connectionStatus.publishSecureChannel(ready: false)
            secureChannel.reset()
            secureNegotiator.setExpectedPeerDeviceID(peerDeviceID)
            let action = try secureNegotiator.begin(generation: controlConnectionGeneration)
            guard case .sendHello(let hello) = action,
                  send(.secureChannelHello(hello: hello), on: controlConnection, channel: .control) == .sent else {
                failSecureChannel("Secure channel hello could not be delivered.")
                return
            }
            localSecureChannelHello = hello
            secureChannelSessionID = hello.sessionID
            startSecureNegotiationTimeout()
        } catch {
            failSecureChannel("Secure channel setup failed.")
        }
    }

    private func handleSecureChannelHello(_ hello: BoothSecureChannelHello) {
        guard let peerDeviceID,
              hello.isWellFormed,
              hello.senderRole == (role == .mac ? .iPad : .mac),
              hello.senderDeviceID == peerDeviceID,
              hello.receiverDeviceID == localIdentity.id,
              secureNegotiator.connectionGeneration == controlConnectionGeneration else {
            failSecureChannel("Secure channel hello was invalid.")
            return
        }
        guard peerAuthenticated else {
            // The authenticated control hello identifies the selected peer,
            // but its reciprocal HMAC may still be completing. Keep exactly
            // one hello for this connection generation and process it after
            // authentication succeeds.
            if let deferred = deferredSecureChannelHello,
               deferred.generation == controlConnectionGeneration,
               deferred.hello != hello {
                failSecureChannel("Conflicting secure channel hello received.")
                return
            }
            deferredSecureChannelHello = (hello, controlConnectionGeneration)
            return
        }
        do {
            let actions = try secureNegotiator.receiveHello(
                hello,
                generation: controlConnectionGeneration
            )
            localSecureChannelHello = secureNegotiator.localHello
            peerSecureChannelHello = secureNegotiator.peerHello
            secureChannelSessionID = secureNegotiator.localHello?.sessionID
            for action in actions {
                switch action {
                case .sendHello(let responderHello):
                    guard send(
                        .secureChannelHello(hello: responderHello),
                        on: controlConnection,
                        channel: .control
                    ) == .sent else {
                        failSecureChannel("Secure channel hello could not be delivered.")
                        return
                    }
                    startSecureNegotiationTimeout()
                case .configure:
                    configureSecureChannelIfPossible()
                case .established, .ignored:
                    break
                }
            }
        } catch {
            failSecureChannel("Secure channel hello was invalid.")
        }
    }

    private func handleSecureChannelReady(sessionID: String, proof: Data) {
        guard peerAuthenticated,
              let localHello = secureNegotiator.localHello,
              let peerHello = secureNegotiator.peerHello,
              sessionID == localHello.sessionID,
              sessionID == peerHello.sessionID,
              let peerDeviceID,
              let secret = authenticationSecret(peerID: peerDeviceID)?.data,
              proof.count == SHA256.Digest.byteCount else {
            failSecureChannel("Secure channel confirmation was invalid.")
            return
        }
        let macHello = localHello.senderRole == .mac ? localHello : peerHello
        let iPadHello = localHello.senderRole == .iPad ? localHello : peerHello
        let expected = BoothSecureChannel.readyProof(
            secret: secret,
            macHello: macHello,
            iPadHello: iPadHello,
            senderRole: peerHello.senderRole
        )
        guard BoothPairingCrypto.constantTimeEqual(proof, expected) else {
            failSecureChannel("Secure channel confirmation failed.")
            return
        }
        do {
            _ = try secureNegotiator.receiveReady(
                sessionID: sessionID,
                generation: controlConnectionGeneration
            )
            secureChannelReadyReceived = true
            establishSecureChannelIfReady()
        } catch {
            failSecureChannel("Secure channel confirmation was invalid.")
        }
    }

    private func configureSecureChannelIfPossible() {
        guard let localHello = secureNegotiator.localHello,
              let peerHello = secureNegotiator.peerHello,
              let peerDeviceID,
              let secret = authenticationSecret(peerID: peerDeviceID)?.data else { return }
        localSecureChannelHello = localHello
        peerSecureChannelHello = peerHello
        do {
            try secureChannel.configure(secret: secret, localHello: localHello, peerHello: peerHello)
            let macHello = localHello.senderRole == .mac ? localHello : peerHello
            let iPadHello = localHello.senderRole == .iPad ? localHello : peerHello
            let proof = BoothSecureChannel.readyProof(
                secret: secret,
                macHello: macHello,
                iPadHello: iPadHello,
                senderRole: localHello.senderRole
            )
            let outcome = send(
                .secureChannelReady(sessionID: localHello.sessionID, proof: proof),
                on: controlConnection,
                channel: .control
            )
            guard outcome == .sent else {
                failSecureChannel("Secure channel confirmation could not be delivered.")
                return
            }
            try secureNegotiator.markReadySent(generation: controlConnectionGeneration)
            secureChannelReadySent = true
            establishSecureChannelIfReady()
        } catch {
            failSecureChannel("Secure channel key derivation failed.")
        }
    }

    private func establishSecureChannelIfReady() {
        guard !secureChannelEstablished,
              secureChannelReadySent,
              secureChannelReadyReceived,
              secureChannel.isConfigured else { return }
        secureNegotiationTimeoutSource?.cancel()
        secureNegotiationTimeoutSource = nil
        try? secureNegotiator.markEstablished(generation: controlConnectionGeneration)
        secureChannelEstablished = true
        connectionStatus.publishSecureChannel(ready: true)
        emitTransportEvent(.secureChannelEstablished, channel: .control)
        startHeartbeat()
        if role == .iPad, previewConnection == nil {
            previewBrowser?.cancel()
            previewBrowser = nil
            if activeInterface == .wiredEthernet {
                connect(
                    to: directLANEndpoint(for: .preview),
                    channel: .preview,
                    parameters: makeParameters(for: .wiredEthernet),
                    provenance: .directStaticLAN
                )
            } else {
                startBrowser(channel: .preview)
            }
        }
        startAssetChannelIfNeeded()
        validatePreviewIdentity()
        if let peerHello = peerSecureChannelHello {
            onTransportReady?(BoothDeviceIdentity(
                id: peerHello.senderDeviceID,
                displayName: self.peerName.isEmpty ? peerHello.senderDeviceID : self.peerName,
                role: peerHello.senderRole
            ))
        }
    }

    private func startAssetChannelIfNeeded() {
        guard activeInterface != nil else { return }
        if role == .mac {
            if assetListener == nil { startListener(channel: .asset) }
            return
        }
        guard peerAuthenticated, secureChannelEstablished else { return }
        if activeInterface == .wiredEthernet {
            connect(
                to: directLANEndpoint(for: .asset),
                channel: .asset,
                parameters: makeParameters(for: .wiredEthernet),
                provenance: .directStaticLAN
            )
        } else {
            startBrowser(channel: .asset)
        }
    }

    private func resetAssetBinding() {
        assetIdentityVerified = false
        assetBindingSent = false
        connectionStatus.publishAssetChannel(connected: assetConnection != nil, verified: false)
    }

    private func sendAssetBinding(on connection: NWConnection) {
        guard !assetBindingSent else { return }
        guard secureChannelEstablished,
              let secureSessionID = secureChannel.sessionID,
              let peerDeviceID else {
            connectionDidClose(connection, channel: .asset, reason: "Asset channel has no secure control session")
            return
        }
        let generation = assetConnectionGeneration
        let binding = BoothChannelBindingHello(
            secureSessionID: secureSessionID,
            channel: .asset,
            senderDeviceID: localIdentity.id,
            receiverDeviceID: peerDeviceID
        )
        assetBindingSent = true
        let outcome = assetWritePump.enqueueBinding(
            binding,
            connection: connection,
            generation: assetConnectionGeneration
        ) { @MainActor [weak self, weak connection] outcome in
            guard let self, let connection,
                  self.assetConnectionGeneration == generation,
                  self.isCurrent(connection, channel: .asset) else { return }
            guard outcome == .sent else {
                self.assetBindingSent = false
                self.connectionDidClose(connection, channel: .asset, reason: "Asset channel binding could not be delivered")
                return
            }
        }
        if outcome != .sent {
            assetBindingSent = false
            connectionDidClose(connection, channel: .asset, reason: "Asset channel binding could not be queued")
        }
    }

    private func handleAssetBinding(_ binding: BoothChannelBindingHello) {
        guard assetConnection != nil,
              peerAuthenticated,
              secureChannelEstablished,
              binding.isWellFormed,
              binding.secureSessionID == secureChannel.sessionID,
              binding.senderDeviceID == peerDeviceID,
              binding.receiverDeviceID == localIdentity.id else {
            connectionDidClose(assetConnection, channel: .asset, reason: "Asset channel identity did not match control")
            return
        }
        assetIdentityVerified = true
        connectionStatus.publishAssetChannel(connected: true, verified: true)
        emitTransportEvent(.assetChannelVerified, channel: .asset)
        emitTransportEvent(.transportReady, channel: .asset)
        if role == .mac, !deferredAssetRequests.isEmpty {
            let references = deferredAssetRequests
            deferredAssetRequests.removeAll()
            onControlMessage?(.assetRequest(references: references))
        }
    }

    private func deferAssetRequests(_ references: [BoothAssetReference]) {
        guard !references.isEmpty, references.count <= 16 else { return }
        var seen = Set(deferredAssetRequests)
        for reference in references where deferredAssetRequests.count < 16 {
            if seen.insert(reference).inserted {
                deferredAssetRequests.append(reference)
            }
        }
    }

    private func scheduleAssetReconnect() {
        guard shouldReconnect, assetReconnectSource == nil else { return }
        assetReconnectToken &+= 1
        let token = assetReconnectToken
        let source = DispatchSource.makeTimerSource(queue: transportQueue)
        source.schedule(deadline: .now() + 0.5)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.assetReconnectToken == token else { return }
                self.assetReconnectSource = nil
                self.startAssetChannelIfNeeded()
            }
        }
        assetReconnectSource = source
        source.resume()
    }

    private func startSecureNegotiationTimeout() {
        secureNegotiationTimeoutSource?.cancel()
        secureNegotiationTimeoutSource = nil
        let generation = controlConnectionGeneration
        guard let connection = controlConnection else { return }
        let source = DispatchSource.makeTimerSource(queue: transportQueue)
        source.schedule(deadline: .now() + Self.lanHandshakeTimeout)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection,
                      self.controlConnectionGeneration == generation,
                      self.isCurrent(connection, channel: .control),
                      !self.secureChannelEstablished else { return }
                self.failSecureChannel("Secure channel negotiation timed out.")
            }
        }
        source.resume()
        secureNegotiationTimeoutSource = source
    }

    private func failSecureChannel(_ reason: String) {
        secureChannelEstablished = false
        connectionStatus.publishSecureChannel(ready: false)
        secureNegotiationTimeoutSource?.cancel()
        secureNegotiationTimeoutSource = nil
        emitTransportEvent(.secureChannelFailed, channel: .control, reason: reason)
        rejectControlConnection(reason)
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
        connection.start(queue: transportQueue)
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
        emitTransportEvent(
            .routeDiscoveryRestarted,
            reason: "Destructive discovery restart requested for peer selection."
        )
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
        case .pairingVerificationConfirmed: return "pairingVerificationConfirmed"
        case .authChallenge: return "authChallenge"
        case .authProof: return "authProof"
        case .secureChannelHello: return "secureChannelHello"
        case .secureChannelReady: return "secureChannelReady"
        case .connectionRejected: return "connectionRejected"
        case .sessionSync: return "sessionSync"
        case .assetRequest: return "assetRequest"
        case .assetUnavailable: return "assetUnavailable"
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
        case .shotCapturedAsset: return "shotCapturedAsset"
        case .captureRecovery: return "captureRecovery"
        case .captureRecoveryAction: return "captureRecoveryAction"
        case .reviewDecision: return "reviewDecision"
        case .sessionFinished: return "sessionFinished"
        case .sessionFinishedAssets: return "sessionFinishedAssets"
        case .customerFinished: return "customerFinished"
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

    private func requiresSecureChannel(_ message: Message) -> Bool {
        switch message {
        case .helloDetails,
             .pairingIntent,
             .pairingSessionAvailable,
             .pairingRequest,
             .pairingResult,
             .pairingVerificationConfirmed,
             .authChallenge,
             .authProof,
             .secureChannelHello,
             .secureChannelReady,
             .connectionRejected:
            return false
        default:
            return true
        }
    }

    private func sendPreviewHello(on connection: NWConnection) {
        guard let payload = try? JSONEncoder().encode(
            BoothTransportHello(
                role: role,
                deviceID: localIdentity.id,
                deviceName: localIdentity.displayName,
                networkPreference: requestedPreference
            )
        ), secureChannelEstablished,
        let protectedPayload = try? secureChannel.protect(payload, channel: .preview),
        let frame = try? BoothFrameEncoder.encode(channel: .preview, payload: protectedPayload) else {
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
                if self.previewIdentityVerified {
                    self.previewWritePump.markReady(
                        connection,
                        generation: self.previewConnectionGeneration
                    )
                }
            }
        })
    }

    private func handlePreviewHello(_ payload: Data) {
        guard secureChannelEstablished else {
            connectionDidClose(previewConnection, channel: .preview, reason: "preview arrived before secure channel")
            return
        }
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
        previewPeerID = hello.deviceID
        validatePreviewIdentity()
    }

    private func validatePreviewIdentity() {
        guard peerAuthenticated, previewPeerSupportsIdentity else {
            if peerAuthenticated {
                connectionDidClose(previewConnection, channel: .preview, reason: "preview identity capability is required")
            }
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
        connectionStatus.publishPreviewChannel(connected: true)
        if didSendPreviewHello, let connection = previewConnection {
            previewWritePump.markReady(connection, generation: previewConnectionGeneration)
        }
    }

    @discardableResult
    private func send(
        _ message: Message,
        on connection: NWConnection?,
        channel: BoothTransportChannel,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)? = nil
    ) -> BoothControlSendOutcome {
        guard channel == .control else {
            completion?(.networkSendFailed)
            return .networkSendFailed
        }
        if peerAuthenticated,
           requiresSecureChannel(message),
           !secureChannelEstablished {
            recordControlSendFailure(.networkSendFailed)
            completion?(.networkSendFailed)
            return .networkSendFailed
        }

        let queuedAt = Date()
        let wrappedCompletion: (@MainActor (BoothControlSendOutcome) -> Void)?
        if let completion {
            wrappedCompletion = { @MainActor [weak self] (outcome: BoothControlSendOutcome) in
                guard let self else {
                    completion(outcome)
                    return
                }
                self.emitTransportEvent(
                    .criticalSendCompleted,
                    channel: .control,
                    duration: Date().timeIntervalSince(queuedAt),
                    reason: outcome == .sent ? nil : String(describing: outcome)
                )
                completion(outcome)
            }
        } else {
            wrappedCompletion = nil
        }
        let outcome = controlWritePump.enqueue(
            message,
            connection: connection,
            generation: controlConnectionGeneration,
            secure: requiresSecureChannel(message),
            completion: wrappedCompletion
        )
        if outcome == .sent {
            if completion != nil {
                emitTransportEvent(.criticalSendQueued, channel: .control)
            }
            logPairingMessage(message, sent: true)
        } else {
            recordControlSendFailure(outcome)
        }
        return outcome
    }

    private func recordControlSendFailure(_ outcome: BoothControlSendOutcome) {
        guard outcome != .sent else { return }
        let message: String
        switch outcome {
        case .noConnection: message = "No active control connection."
        case .rejectedOversize: message = "Control payload exceeded the transport limit."
        case .encodingFailed: message = "Control payload encoding failed."
        case .networkSendFailed: message = "Control payload could not be sent."
        case .sent: return
        }
        lastNetworkError = message
        connectionStatus.publishNetworkError(message)
        emitTransportEvent(
            outcome == .rejectedOversize ? .controlPayloadRejected : .controlSendFailed,
            channel: .control,
            byteCount: nil,
            reason: message
        )
        print("[Network] \(message)")
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

        let context = BoothPairingControlSendContext(
            connectionGeneration: controlConnectionGeneration,
            pairingGeneration: pairingGeneration,
            sessionID: sessionID
        )
        if case .sessionSync = message {
            emitTransportEvent(.sessionSyncSent, channel: .control)
        }
        _ = send(message, on: connection, channel: .control) { [weak self] outcome in
            guard let self else { return }
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
            switch outcome {
            case .sent:
                self.logPairing(stage: self.pairingStageValue, message: "send complete \(self.messageType(message))", sessionID: context.sessionID)
                completion(.success(()))
            case .noConnection:
                completion(.failure(.failed("No active control connection.")))
            case .rejectedOversize:
                completion(.failure(.failed("Pairing message exceeded the transport limit.")))
            case .encodingFailed:
                completion(.failure(.failed("Pairing message encoding failed.")))
            case .networkSendFailed:
                completion(.failure(.failed("Pairing message could not be delivered.")))
            }
        }
    }

    private func sendThenClose(_ message: Message, connection: NWConnection, reason: String?) {
        let connectionGenerationAtStart = controlConnectionGeneration
        _ = send(message, on: connection, channel: .control) { [weak self] outcome in
            guard let self else {
                connection.cancel()
                return
            }
            let closeReason = outcome == .sent ? reason : String(describing: outcome)
            guard self.isCurrent(connection, channel: .control),
                  self.controlConnectionGeneration == connectionGenerationAtStart else {
                connection.cancel()
                return
            }
            connection.cancel()
            self.connectionDidClose(connection, channel: .control, reason: closeReason)
        }
    }

    private func startHeartbeat() {
        guard let connection = controlConnection else { return }
        let generation = controlConnectionGeneration
        transportRuntime.startHeartbeat(
            connection: connection,
            generation: generation,
            writer: controlWritePump,
            interval: Self.heartbeatInterval,
            timeout: Self.heartbeatTimeout
        )
    }

    private func stopHeartbeat() {
        transportRuntime.stopHeartbeat()
    }

    private func connectionDidClose(_ connection: NWConnection?, channel: BoothTransportChannel, reason: String? = nil) {
        if let reason { print("[Network] \(channel) disconnected: \(reason)") }
        if let reason { lastNetworkError = reason }
        if channel == .control {
            guard let connection, connection === controlConnection else { return }
            invalidateReceiveToken(for: .control)
            controlConnectionIsViable = false
            cancelWaitingRecovery(for: channel)
            stopHeartbeat()
            emitTransportEvent(.transportDisconnected, channel: channel, reason: reason)
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
                if directLANControlAttemptInFlight {
                    directLANControlAttemptInFlight = false
                    startRouteDiscovery(skipDirectLANFallback: true)
                } else {
                    startRouteDiscovery()
                }
                return
            }
            if retainsManualLANListener {
                // Do not use the path monitor to choose a new route here.
                // Static iPad Ethernet often remains "unsatisfied" despite
                // the control socket having just been usable. Clear only the
                // closed connection so the still-running fixed listener can
                // accept the retry/reconnect for this pairing session.
                resetPreviewConnection()
                invalidateReceiveToken(for: .control)
                invalidateReceiveToken(for: .asset)
                assetConnection?.cancel()
                assetConnection = nil
                assetEndpointDescription = nil
                controlConnection?.cancel()
                controlConnectionGeneration &+= 1
                assetConnectionGeneration &+= 1
                controlWritePump.invalidate(generation: controlConnectionGeneration)
                assetWritePump.invalidate(generation: assetConnectionGeneration)
                controlConnection = nil
                controlEndpointDescription = nil
                resetControlAuthentication()
                connectionState = .disconnected
                lanHandshakeState = .waiting
                if controlListener == nil { startListener(channel: .control) }
                if previewListener == nil { startListener(channel: .preview) }
                if assetListener == nil { startListener(channel: .asset) }
                publishStatus()
                return
            }
            let command = routeMachine.transportDisconnected(
                lanAvailable: pathAvailable(.wiredEthernet),
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: command == .startWiFi(fallback: true) ? "LAN unavailable" : nil)
        } else if channel == .preview {
            guard let connection, connection === previewConnection else { return }
            invalidateReceiveToken(for: .preview)
            cancelWaitingRecovery(for: channel)
            emitTransportEvent(.previewDisconnected, channel: channel, reason: reason)
            previewConnection?.cancel()
            previewConnection = nil
            previewEndpointDescription = nil
            previewConnectionGeneration &+= 1
            previewWritePump.invalidate(generation: previewConnectionGeneration)
            previewDeliveryPump.reset(generation: previewConnectionGeneration)
            resetPreviewIdentity()
            connectionStatus.publishPreviewChannel(connected: false)
            if role == .iPad {
                previewBrowser?.cancel()
                previewBrowser = nil
            }
            scheduleReconnect()
        } else {
            guard let connection, connection === assetConnection else { return }
            invalidateReceiveToken(for: .asset)
            cancelWaitingRecovery(for: channel)
            emitTransportEvent(.transportDisconnected, channel: .asset, reason: reason)
            assetConnection?.cancel()
            assetConnection = nil
            assetEndpointDescription = nil
            resetAssetBinding()
            assetConnectionGeneration &+= 1
            assetWritePump.invalidate(generation: assetConnectionGeneration)
            connectionStatus.publishAssetChannel(connected: false)
            emitTransportEvent(.assetChannelDisconnected, channel: .asset, reason: reason)
            if role == .iPad {
                assetBrowser?.cancel()
                assetBrowser = nil
            }
            scheduleAssetReconnect()
        }
    }

    private func isCurrent(_ connection: NWConnection, channel: BoothTransportChannel) -> Bool {
        switch channel {
        case .control: return connection === controlConnection
        case .preview: return connection === previewConnection
        case .asset: return connection === assetConnection
        case .heartbeat: return false
        }
    }

    private func isCurrent(_ listener: NWListener, channel: BoothTransportChannel) -> Bool {
        switch channel {
        case .control: return listener === controlListener
        case .preview: return listener === previewListener
        case .asset: return listener === assetListener
        case .heartbeat: return false
        }
    }

    private func isCurrent(_ browser: NWBrowser, channel: BoothTransportChannel) -> Bool {
        switch channel {
        case .control: return browser === controlBrowser
        case .preview: return browser === previewBrowser
        case .asset: return browser === assetBrowser
        case .heartbeat: return false
        }
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
            isPreviewChannelConnected: previewIdentityVerified
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
        invalidateReceiveToken(for: .preview)
        previewConnectionGeneration &+= 1
        previewConnection?.cancel()
        previewConnection = nil
        previewEndpointDescription = nil
        previewWritePump.invalidate(generation: previewConnectionGeneration)
        previewDeliveryPump.reset(generation: previewConnectionGeneration)
        resetPreviewIdentity()
        connectionStatus.publishPreviewChannel(connected: false)
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

    private var hasAuthoritativeControl: Bool {
        guard let connection = controlConnection,
              controlConnectionIsViable else { return false }
        guard case .ready = connection.state else { return false }
        return peerAuthenticated && secureChannelEstablished
    }

    private var shouldDeferPathHintForAuthenticatedControl: Bool {
        guard let connection = controlConnection,
              peerAuthenticated,
              secureChannelEstablished else { return false }
        guard !hasAuthoritativeControl else { return false }
        if case .failed = connection.state { return false }
        if case .cancelled = connection.state { return false }
        return true
    }

    private var shouldIgnoreUnavailablePathHint: Bool {
        BoothPathAuthorityPolicy.action(hasAuthenticatedControl: hasAuthoritativeControl) == .observeOnly
            || shouldDeferPathHintForAuthenticatedControl
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
        secureChannel.reset()
        resetAssetBinding()
        deferredAssetRequests.removeAll()
        secureNegotiationTimeoutSource?.cancel()
        secureNegotiationTimeoutSource = nil
        secureNegotiator = BoothSecureChannelNegotiator(
            role: role,
            localDeviceID: localIdentity.id,
            connectionGeneration: controlConnectionGeneration
        )
        localSecureChannelHello = nil
        peerSecureChannelHello = nil
        deferredSecureChannelHello = nil
        secureChannelSessionID = nil
        secureChannelReadySent = false
        secureChannelReadyReceived = false
        secureChannelEstablished = false
        connectionStatus.publishSecureChannel(ready: false)
        didInitiateAuthentication = false
        pendingAuthChallenge = nil
        deferredAuthChallenge = nil
        peerHello = nil
        peerDeviceID = nil
        pairingRequestSubmission.reset()
        expectedPeerDeviceID = nil
        peerName = ""
        connectedPeerNames = []
        connectionStatus.publishPairing(authenticated: false, stage: pairingStageValue)
    }

    private func scheduleReconnect() {
        guard shouldReconnect else { return }
        let delay = Self.reconnectDelays[min(reconnectAttempt, Self.reconnectDelays.count - 1)]
        reconnectAttempt += 1
        connectionStatus.publishReconnectState(inProgress: true, attempt: reconnectAttempt)
        emitTransportEvent(
            .transportReconnectScheduled,
            attempt: reconnectAttempt,
            duration: delay
        )
        transportRuntime.scheduleReconnect(after: delay, attempt: reconnectAttempt)
    }

    private func handleReconnectDue() {
        if role == .iPad, activeInterface == nil {
            ensureDiscoveryForPeerSelection()
            return
        }
        if activeInterface == nil {
            let command = routeMachine.start(
                lanAvailable: pathAvailable(.wiredEthernet),
                wifiAvailable: pathAvailable(.wifi)
            )
            apply(command, reason: nil)
            return
        }
        if role == .mac {
            if controlListener == nil { startListener(channel: .control) }
            if previewListener == nil { startListener(channel: .preview) }
            if assetListener == nil { startListener(channel: .asset) }
        } else {
            if controlBrowser == nil { startBrowser(channel: .control) }
            if previewBrowser == nil { startBrowser(channel: .preview) }
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

final class BoothConnectionRecoveryScheduler: @unchecked Sendable {
    private struct Key: Hashable {
        let channel: UInt8
        let generation: Int
    }

    private struct PendingRecovery {
        let connection: NWConnection
        let timer: DispatchSourceTimer
    }

    private let queue: DispatchQueue
    private var pending: [Key: PendingRecovery] = [:]

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func schedule(
        connection: NWConnection,
        channel: BoothTransportChannel,
        generation: Int,
        after delay: TimeInterval,
        onDeadline: @escaping @Sendable () -> Void = {}
    ) {
        queue.async { [weak self, connection] in
            guard let self else { return }
            let key = Key(channel: channel.rawValue, generation: generation)
            guard self.pending[key] == nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + delay)
            timer.setEventHandler { [weak self, connection] in
                guard let self else { return }
                self.pending.removeValue(forKey: key)
                connection.cancel()
                onDeadline()
            }
            self.pending[key] = PendingRecovery(connection: connection, timer: timer)
            timer.resume()
        }
    }

    func cancel(
        connection: NWConnection,
        channel: BoothTransportChannel,
        generation: Int
    ) {
        queue.async { [weak self, connection] in
            guard let self else { return }
            let key = Key(channel: channel.rawValue, generation: generation)
            guard let pending = self.pending[key], pending.connection === connection else { return }
            self.pending.removeValue(forKey: key)
            pending.timer.cancel()
        }
    }

    func cancel(channel: BoothTransportChannel) {
        queue.async { [weak self] in
            guard let self else { return }
            let keys = self.pending.keys.filter { $0.channel == channel.rawValue }
            for key in keys {
                self.pending.removeValue(forKey: key)?.timer.cancel()
            }
        }
    }

    func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pending.values.forEach { $0.timer.cancel() }
            self.pending.removeAll()
        }
    }
}
