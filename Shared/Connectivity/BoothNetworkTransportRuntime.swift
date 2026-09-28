import Foundation
import Network

/// Queue-owned transport authority. Every mutable field, Network object, and
/// protocol candidate is accessed only on `queue`; public methods synchronously
/// enter that queue and callbacks re-enter it before changing state. The
/// `@unchecked Sendable` conformance is limited to this explicit serialization
/// boundary. MainActor consumes immutable events and owns presentation only.
final class BoothNetworkTransportRuntime: @unchecked Sendable {
    typealias ControlListenerFactory = (NWParameters, NWEndpoint.Port?) throws -> NWListener

    /// Transport events carry immutable values only. Live connections and
    /// decoders remain owned by this runtime's serial queue.
    enum ControlCoreEvent: Sendable {
        case pairingIntentCandidate(PairingCandidate, BoothPairingIntent)
        case pairingSessionConsumed(PairingSessionConsumption)
        case pairingVerificationRequired(PairingVerificationSnapshot)
        case pairingTrustRequired(PairingTrustSnapshot)
        case trustedAuthenticated(
            generation: Int,
            endpointDescription: String,
            hello: BoothTransportHello,
            localSecureHello: BoothSecureChannelHello,
            peerSecureHello: BoothSecureChannelHello,
            interface: BoothNetworkInterfacePolicy?,
            provenance: BoothRouteCandidateProvenance?,
            routeGeneration: Int?
        )
        case controlFrames(generation: Int, frames: [BoothDecodedTransportFrame])
        /// Frames from the facade-owned direct receive path. They are emitted
        /// only after its decoder has completed the secure handshake.
        case directControlFrames(generation: Int, frames: [BoothDecodedTransportFrame])
        case controlFrameDecodeFailed(
            generation: Int,
            routeGeneration: Int?,
            byteCount: Int,
            summary: String
        )
        case disconnected(generation: Int, reason: String?)
        case rejected(generation: Int, reason: String)
        case listenerReady(
            generation: Int,
            port: NWEndpoint.Port?,
            interface: BoothNetworkInterfacePolicy
        )
        case listenerFailed(generation: Int, reason: String)

        var controlGeneration: Int? {
            switch self {
            case .pairingIntentCandidate(let candidate, _):
                candidate.generation
            case .pairingSessionConsumed(let consumption):
                consumption.candidate.generation
            case .pairingVerificationRequired(let snapshot):
                snapshot.candidate.generation
            case .pairingTrustRequired(let snapshot):
                snapshot.candidate.generation
            case .trustedAuthenticated(let generation, _, _, _, _, _, _, _),
                 .controlFrames(let generation, _),
                 .directControlFrames(let generation, _),
                 .controlFrameDecodeFailed(let generation, _, _, _),
                 .disconnected(let generation, _),
                 .rejected(let generation, _):
                generation
            case .listenerReady, .listenerFailed:
                nil
            }
        }
    }

    struct PairingCandidate: Sendable, Equatable {
        let token: UUID
        let generation: Int
        let hello: BoothTransportHello
    }

    struct PairingVerificationSnapshot: Sendable, Equatable {
        let candidate: PairingCandidate
        let sessionID: String
        let peer: TrustedBoothPeer
        let verificationCode: String
        let expiresAt: Date
    }

    struct PairingSessionConsumption: Sendable, Equatable {
        let candidate: PairingCandidate
        let sessionID: String
        let outcome: Outcome

        enum Outcome: Sendable, Equatable {
            case proofAccepted(method: BoothPairingMethod)
            case expired
            case locked
        }
    }

    struct PairingTrustSnapshot: Sendable, Equatable {
        let candidate: PairingCandidate
        let sessionID: String
        let peer: TrustedBoothPeer
        let secret: Data
        let expiresAt: Date
    }

    private enum AdmissionLane: Sendable, Equatable {
        case normal
        case identityProbe
    }

    /// Every field in this object is read or written only on `queue`.
    /// It represents one pre-auth control candidate and never escapes except
    /// as immutable protocol events.
    private final class TrustedHandshake {
        let connection: NWConnection
        let generation: Int
        var routeGeneration: Int?
        let admission: InboundControlAdmission?
        let lane: AdmissionLane
        let decoder = BoothTransportFrameDecoder()
        let secureChannel = BoothSecureChannel()
        var timeout: DispatchSourceTimer?
        var localHello: BoothTransportHello?
        var peerHello: BoothTransportHello?
        var localChallenge: BoothAuthChallenge?
        var peerProofVerified = false
        var peerProofSent = false
        var mutualAuthenticationComplete: Bool { peerProofSent && peerProofVerified }
        var secureNegotiator: BoothSecureChannelNegotiator
        var localSecureHello: BoothSecureChannelHello?
        var peerSecureHello: BoothSecureChannelHello?
        var readySent = false
        var readyReceived = false
        var secureHandshakeEstablished = false
        var isTrusted = false
        var isIdentityProbeCoolingDown = false
        var authenticated = false
        var claimedTrustedPeerID: String?
        var isPairingCandidate = false
        var receivedPairingIntent: BoothPairingIntent?
        var pairingSessionID: String?
        var pairingExpiresAt: Date?
        var pairingSecret: Data?
        var pairingTranscript: Data?
        var pairingPeer: TrustedBoothPeer?
        var pairingMethod: BoothPairingMethod?
        var pairingVerificationCode: String?
        var pairingTrustRequested = false
        var pairingTrustCommitClaimed = false

        init(
            connection: NWConnection,
            generation: Int,
            admission: InboundControlAdmission?,
            lane: AdmissionLane,
            role: DeviceRole,
            localDeviceID: String
        ) {
            self.connection = connection
            self.generation = generation
            self.admission = admission
            self.lane = lane
            self.secureNegotiator = BoothSecureChannelNegotiator(
                role: role,
                localDeviceID: localDeviceID,
                connectionGeneration: generation
            )
            decoder.reset(.control)
        }
    }

    struct InboundControlAdmission: Sendable {
        let token: UUID
        let generation: Int
        let endpointKey: String
        let isPreferredCandidate: Bool
        let isIdentityProbe: Bool
    }

    struct InboundControlAdmissionResult: Sendable {
        let admission: InboundControlAdmission?
        let rejectionReason: String?
    }

    struct AdmissionLaneSnapshot: Sendable, Equatable {
        let normalCandidatePresent: Bool
        let identityProbePresent: Bool
    }

    struct RouteBrowserRetryBackoff: Sendable, Equatable {
        private(set) var attempt = 0

        mutating func nextDelay() -> TimeInterval {
            defer { attempt += 1 }
            return BoothNetworkTransportRuntime.coreRouteBrowserRetryDelay(attempt: attempt)
        }

        mutating func browserRecovered() {
            attempt = 0
        }
    }

    private struct ControlReconnectRoute {
        let endpoint: NWEndpoint
        let parameters: NWParameters
        let interface: BoothNetworkInterfacePolicy
        let provenance: BoothRouteCandidateProvenance
        let generation: Int
    }

    private struct ControlListenerConfiguration {
        var parameters: NWParameters
        var port: NWEndpoint.Port?
        var interface: BoothNetworkInterfacePolicy
        let fallback: (
            interface: BoothNetworkInterfacePolicy,
            parameters: NWParameters,
            port: NWEndpoint.Port?
        )?
        var didUseFallback = false
        var service: NWListener.Service
        let generation: Int
    }

    private static let controlListenerRetryDelays: [TimeInterval] = [0.25, 0.5, 1, 2, 4, 8]
    private static let coreRouteBrowserRetryDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

    static func coreRouteBrowserRetryDelay(attempt: Int) -> TimeInterval {
        coreRouteBrowserRetryDelays[min(max(0, attempt), coreRouteBrowserRetryDelays.count - 1)]
    }

    private let queue: DispatchQueue
    private let controlListenerFactory: ControlListenerFactory
    private let queueKey = DispatchSpecificKey<Void>()
    private let heartbeatState = BoothTransportHeartbeatState()
    private var heartbeatSource: DispatchSourceTimer?
    private var heartbeatConnection: NWConnection?
    private var heartbeatGeneration = 0
    private var controlTrafficAdmitted = false
    private var reconnectSource: DispatchSourceTimer?
    private var reconnectAttempt = 0
    private var reconnectGeneration = 0
    private var reconnectRoute: ControlReconnectRoute?
    private var pendingReconnectConnection: NWConnection?
    private var pendingReconnectTimeoutSource: DispatchSourceTimer?
    private var nextInboundAdmissionGeneration = 0
    private var inboundAdmission: InboundControlAdmission?
    private var inboundAdmissionSource: DispatchSourceTimer?
    private var identityProbeAdmission: InboundControlAdmission?
    private var identityProbeAdmissionSource: DispatchSourceTimer?
    private var admissionLimiter: BoothPreAuthAdmissionLimiter
    private var trustedPeerIDs = Set<String>()
    private var authenticatedEndpointsByPeerID: [String: Set<String>] = [:]

    // Pre-Auth Watchdog state (Finding A03)
    private var preAuthWatchdog: BoothPreAuthWatchdog?
    private var preAuthSource: DispatchSourceTimer?
    private var preAuthConnection: NWConnection?
    private var preAuthGeneration = 0

    // Control connection slot authority (Finding A03)
    private var activeControlConnection: NWConnection?
    private var activeControlGeneration = 0
    private var activeControlAuthenticated = false
    private var activeControlIsIdentityProbe = false
    private var activeIdentityProbePeerID: String?
    private var inboundControlConnectionsSeen = 0
    private var localIdentity: BoothDeviceIdentity?
    private var localNetworkPreference: BoothNetworkPreference = .wifi
    private var trustedSecrets: [String: Data] = [:]
    private var inboundPairingSession: BoothPairingSession?
    private var selectedPeerID: String?
    private var sharedSecureChannel: BoothSecureChannel?
    private var controlWriter: BoothControlWritePump?
    private var controlCoreEvent: (@Sendable (ControlCoreEvent) -> Void)?
    private var protocolCandidates: [ObjectIdentifier: TrustedHandshake] = [:]
    private var identityProbeConnection: NWConnection?
    private var coreControlListener: NWListener?
    private var coreControlListenerGeneration = 0
    private var coreControlListenerConfiguration: ControlListenerConfiguration?
    private var coreControlListenerRetrySource: DispatchSourceTimer?
    private var coreControlListenerRetryAttempt = 0
    private var coreRouteBrowsers: [String: NWBrowser] = [:]
    private var coreRouteBrowserRetrySources: [String: DispatchSourceTimer] = [:]
    private var coreRouteBrowserRetryTokens: [String: UUID] = [:]
    private var coreRouteBrowserRetryBackoffs: [String: RouteBrowserRetryBackoff] = [:]
    private var coreRouteGeneration = 0
    private var coreRouteSelection = BoothRouteDiscoverySelection()
    private var corePendingRoute: ControlReconnectRoute?
    private var coreRouteFallbackSource: DispatchSourceTimer?
    private var nextControlGeneration = 0

    private var heartbeatTimeoutHandler: (@Sendable (Int) -> Void)?
    private var reconnectDueHandler: (@Sendable (Int, Int) -> Void)?
    private var reconnectConnectionStartedHandler: (@Sendable (
        NWConnection,
        NWEndpoint,
        NWParameters,
        BoothNetworkInterfacePolicy,
        BoothRouteCandidateProvenance,
        Int,
        Int
    ) -> Void)?
    private var preAuthTimeoutHandler: (@Sendable (NWConnection, Int, String) -> Void)?

    var onHeartbeatTimeout: (@Sendable (Int) -> Void)? {
        get { onQueue { heartbeatTimeoutHandler } }
        set { onQueue { heartbeatTimeoutHandler = newValue } }
    }

    var onReconnectDue: (@Sendable (Int, Int) -> Void)? {
        get { onQueue { reconnectDueHandler } }
        set { onQueue { reconnectDueHandler = newValue } }
    }

    var onReconnectConnectionStarted: (@Sendable (
        NWConnection,
        NWEndpoint,
        NWParameters,
        BoothNetworkInterfacePolicy,
        BoothRouteCandidateProvenance,
        Int,
        Int
    ) -> Void)? {
        get { onQueue { reconnectConnectionStartedHandler } }
        set { onQueue { reconnectConnectionStartedHandler = newValue } }
    }

    var onPreAuthTimeout: (@Sendable (NWConnection, Int, String) -> Void)? {
        get { onQueue { preAuthTimeoutHandler } }
        set { onQueue { preAuthTimeoutHandler = newValue } }
    }

    init(
        queue: DispatchQueue,
        admissionLimiter: BoothPreAuthAdmissionLimiter = BoothPreAuthAdmissionLimiter(),
        controlListenerFactory: @escaping ControlListenerFactory = { parameters, port in
            if let port {
                return try NWListener(using: parameters, on: port)
            }
            return try NWListener(using: parameters)
        }
    ) {
        self.queue = queue
        self.admissionLimiter = admissionLimiter
        self.controlListenerFactory = controlListenerFactory
        queue.setSpecific(key: queueKey, value: ())
    }

    func configureControlCore(
        localIdentity: BoothDeviceIdentity,
        networkPreference: BoothNetworkPreference,
        trustedSecrets: [String: Data],
        selectedPeerID: String?,
        secureChannel: BoothSecureChannel,
        writer: BoothControlWritePump,
        onEvent: @escaping @Sendable (ControlCoreEvent) -> Void
    ) {
        onQueue {
            self.localIdentity = localIdentity
            self.localNetworkPreference = networkPreference
            self.trustedSecrets = trustedSecrets.filter { !$0.key.isEmpty && $0.value.count == 32 }
            self.trustedPeerIDs = Set(self.trustedSecrets.keys)
            self.selectedPeerID = selectedPeerID
            self.sharedSecureChannel = secureChannel
            self.controlWriter = writer
            self.controlCoreEvent = onEvent
        }
    }

    /// Installs the locally displayed pairing session into the transport
    /// authority. The returned UI values remain a presentation copy; proof
    /// validation and attempt accounting use only this queue-owned value.
    func installInboundPairingSession(_ session: BoothPairingSession?) {
        onQueue {
            if let session {
                for candidate in Array(protocolCandidates.values) where
                    candidate.isPairingCandidate
                        && candidate.pairingSessionID != nil
                        && candidate.pairingSessionID != session.info.sessionID {
                    rejectTrustedCandidateOnQueue(
                        candidate.connection,
                        generation: candidate.generation,
                        reason: "Pairing session was replaced."
                    )
                }
            }
            inboundPairingSession = session
            guard let session else { return }
            for candidate in protocolCandidates.values where candidate.isPairingCandidate {
                guard candidate.pairingSessionID == nil,
                      candidate.peerHello?.role == .iPad else { continue }
                candidate.pairingSessionID = session.info.sessionID
                candidate.pairingExpiresAt = session.info.expiresAt
                startCoreTimeoutOnQueue(
                    candidate,
                    after: max(1, session.info.expiresAt.timeIntervalSinceNow),
                    reason: "Pairing session expired."
                )
            }
        }
    }

    func clearInboundPairingSession(sessionID: String?) {
        onQueue {
            if let sessionID {
                guard inboundPairingSession?.info.sessionID == sessionID
                        || protocolCandidates.values.contains(where: { $0.pairingSessionID == sessionID }) else { return }
                if inboundPairingSession?.info.sessionID == sessionID {
                    inboundPairingSession = nil
                }
                for candidate in Array(protocolCandidates.values) where candidate.pairingSessionID == sessionID {
                    rejectTrustedCandidateOnQueue(
                        candidate.connection,
                        generation: candidate.generation,
                        reason: "Pairing session was cancelled."
                    )
                }
            } else {
                inboundPairingSession = nil
            }
        }
    }

    func respondToInboundPairingIntent(
        token: UUID,
        generation: Int,
        session: BoothPairingSessionInfo
    ) -> Bool {
        onQueue {
            guard let candidate = pairingCandidateOnQueue(token: token, generation: generation),
                  let identity = localIdentity,
                  candidate.receivedPairingIntent != nil,
                  session.macDeviceID == identity.id,
                  inboundPairingSession?.info.sessionID == session.sessionID,
                  session.expiresAt > Date() else { return false }
            candidate.pairingSessionID = session.sessionID
            candidate.pairingExpiresAt = session.expiresAt
            startCoreTimeoutOnQueue(
                candidate,
                after: max(1, session.expiresAt.timeIntervalSinceNow),
                reason: "Pairing session expired."
            )
            sendCoreMessageOnQueue(.pairingSessionAvailable(session: session), candidate: candidate)
            return true
        }
    }

    func rejectInboundPairingCandidate(token: UUID, generation: Int, reason: String) {
        onQueue {
            guard let candidate = pairingCandidateOnQueue(token: token, generation: generation) else { return }
            let result = BoothPairingResult(
                accepted: false,
                reason: reason,
                pairingSessionID: candidate.pairingSessionID
            )
            sendCoreMessageOnQueue(.pairingResult(result: result), candidate: candidate) { [weak self] _ in
                guard let self,
                      let current = self.pairingCandidateOnQueue(token: token, generation: generation) else { return }
                self.rejectTrustedCandidateOnQueue(
                    current.connection,
                    generation: generation,
                    reason: reason
                )
            }
        }
    }

    @discardableResult
    func confirmPairingVerification(token: UUID, generation: Int) -> Bool {
        onQueue {
            guard let candidate = pairingCandidateOnQueue(token: token, generation: generation),
                  candidate.pairingMethod == .pin,
                  let sessionID = candidate.pairingSessionID,
                  let secret = candidate.pairingSecret,
                  let transcript = candidate.pairingTranscript,
                  candidate.pairingVerificationCode != nil,
                  !candidate.pairingTrustRequested,
                  Date() < (candidate.pairingExpiresAt ?? .distantPast) else { return false }
            let proof = BoothPairingCrypto.makeVerificationConfirmationProof(
                secret: secret,
                transcript: transcript,
                role: .mac
            )
            candidate.pairingVerificationCode = nil
            candidate.isTrusted = true
            sendCoreMessageOnQueue(
                .pairingVerificationConfirmed(sessionID: sessionID, proof: proof),
                candidate: candidate
            ) { [weak self] sent in
                guard let self,
                      let current = self.pairingCandidateOnQueue(token: token, generation: generation) else { return }
                guard sent, let secret = current.pairingSecret else {
                    self.rejectTrustedCandidateOnQueue(
                        current.connection,
                        generation: generation,
                        reason: "Pairing verification could not be delivered."
                    )
                    return
                }
                self.beginCoreAuthenticationOnQueue(current, secret: secret)
            }
            return true
        }
    }

    func beginPairingTrustCommit(token: UUID, generation: Int) -> Bool {
        onQueue {
            guard let candidate = pairingCandidateOnQueue(token: token, generation: generation),
                  candidate.pairingTrustRequested,
                  !candidate.pairingTrustCommitClaimed else { return false }
            candidate.pairingTrustCommitClaimed = true
            candidate.timeout?.cancel()
            candidate.timeout = nil
            return true
        }
    }

    func finishPairingTrustCommit(token: UUID, generation: Int, succeeded: Bool) -> Bool {
        onQueue {
            guard let candidate = pairingCandidateOnQueue(token: token, generation: generation),
                  candidate.pairingTrustRequested,
                  candidate.pairingTrustCommitClaimed,
                  let peer = candidate.pairingPeer,
                  let secret = candidate.pairingSecret else { return false }
            guard succeeded else {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: generation,
                    reason: "Pairing trust could not be saved."
                )
                return true
            }
            trustedSecrets[peer.id] = secret
            trustedPeerIDs.insert(peer.id)
            candidate.isTrusted = true
            promoteCoreCandidateOnQueue(candidate)
            return true
        }
    }

    func cancelInboundPairingCandidate(token: UUID, generation: Int, reason: String) {
        onQueue {
            guard let candidate = pairingCandidateOnQueue(token: token, generation: generation) else { return }
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: generation,
                reason: reason
            )
        }
    }

    func isInboundPairingCandidateCurrent(token: UUID, generation: Int) -> Bool {
        onQueue {
            pairingCandidateOnQueue(token: token, generation: generation) != nil
        }
    }

    func updateControlCredentials(
        trustedSecrets: [String: Data],
        selectedPeerID: String?,
        localIdentity: BoothDeviceIdentity? = nil,
        networkPreference: BoothNetworkPreference? = nil
    ) {
        onQueue {
            self.trustedSecrets = trustedSecrets.filter { !$0.key.isEmpty && $0.value.count == 32 }
            self.trustedPeerIDs = Set(self.trustedSecrets.keys)
            self.selectedPeerID = selectedPeerID
            if let localIdentity { self.localIdentity = localIdentity }
            if let networkPreference { self.localNetworkPreference = networkPreference }
        }
    }

    /// Starts one logical listener lifecycle. Repeated calls refresh its
    /// advertised service and return its generation; changing listener
    /// parameters requires stopping the control core first.
    func startControlListener(
        using parameters: NWParameters,
        port: NWEndpoint.Port?,
        service: NWListener.Service,
        interface: BoothNetworkInterfacePolicy = .wifi,
        fallback: (
            interface: BoothNetworkInterfacePolicy,
            parameters: NWParameters,
            port: NWEndpoint.Port?
        )? = nil
    ) -> Int {
        onQueue {
            if var configuration = self.coreControlListenerConfiguration {
                configuration.service = service
                self.coreControlListenerConfiguration = configuration
                self.coreControlListener?.service = service
                if self.coreControlListener == nil,
                   self.coreControlListenerRetrySource == nil {
                    self.scheduleControlListenerRetryOnQueue(generation: configuration.generation, immediate: true)
                }
                return configuration.generation
            }

            self.coreControlListenerGeneration &+= 1
            let generation = self.coreControlListenerGeneration
            self.coreControlListenerConfiguration = ControlListenerConfiguration(
                parameters: parameters,
                port: port,
                interface: interface,
                fallback: fallback,
                service: service,
                generation: generation
            )
            self.coreControlListenerRetryAttempt = 0
            self.startControlListenerOnQueue(generation: generation)
            return generation
        }
    }

    func updateControlListenerService(_ service: NWListener.Service) {
        onQueue {
            if var configuration = self.coreControlListenerConfiguration {
                configuration.service = service
                self.coreControlListenerConfiguration = configuration
            }
            self.coreControlListener?.service = service
        }
    }

    func stopControlListener() {
        onQueue {
            self.coreControlListenerGeneration &+= 1
            self.coreControlListenerConfiguration = nil
            self.cancelControlListenerRetryOnQueue()
            self.coreControlListener?.cancel()
            self.coreControlListener = nil
        }
    }

    /// Invalidates every core-owned callback before releasing sockets, so a
    /// stale listener or reconnect cannot affect a later route generation.
    @discardableResult
    func stopControlCore() -> Int {
        onQueue {
            self.nextControlGeneration &+= 1
            self.coreRouteGeneration &+= 1
            self.stopTrustedRouteDiscoveryOnQueue()
            self.coreControlListenerGeneration &+= 1
            self.coreControlListenerConfiguration = nil
            self.cancelControlListenerRetryOnQueue()
            self.coreControlListener?.cancel()
            self.coreControlListener = nil
            self.cancelReconnectOnQueue()
            let candidates = Array(self.protocolCandidates.values)
            self.protocolCandidates.removeAll()
            for candidate in candidates {
                candidate.timeout?.cancel()
                candidate.connection.stateUpdateHandler = nil
                candidate.connection.cancel()
            }
            self.identityProbeConnection?.cancel()
            self.identityProbeConnection = nil
            self.identityProbeAdmission = nil
            self.stopIdentityProbeAdmissionTimeoutOnQueue()
            self.inboundAdmission = nil
            self.stopInboundAdmissionTimeoutOnQueue()
            self.activeControlConnection?.cancel()
            self.activeControlConnection = nil
            self.activeControlAuthenticated = false
            self.activeControlIsIdentityProbe = false
            self.activeIdentityProbePeerID = nil
            self.stopHeartbeatOnQueue()
            self.stopPreAuthWatchdogOnQueue()
            self.sharedSecureChannel?.reset()
            return self.coreControlListenerGeneration
        }
    }

    private func startControlListenerOnQueue(generation: Int) {
        guard let configuration = coreControlListenerConfiguration,
              configuration.generation == generation,
              coreControlListener == nil else { return }

        let listener: NWListener
        do {
            listener = try controlListenerFactory(configuration.parameters, configuration.port)
        } catch {
            reportControlListenerFailureOnQueue(
                error.localizedDescription,
                generation: generation,
                listener: nil
            )
            return
        }

        listener.service = configuration.service
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                self.onQueue {
                    guard self.coreControlListener === listener,
                          self.coreControlListenerGeneration == generation,
                          self.coreControlListenerConfiguration?.generation == generation else { return }
                    self.coreControlListenerRetryAttempt = 0
                    self.controlCoreEvent?(.listenerReady(
                        generation: generation,
                        port: listener.port,
                        interface: self.coreControlListenerConfiguration?.interface ?? .wifi
                    ))
                }
            case .failed(let error):
                self.onQueue {
                    self.reportControlListenerFailureOnQueue(
                        error.localizedDescription,
                        generation: generation,
                        listener: listener
                    )
                }
            case .cancelled:
                self.onQueue {
                    guard self.coreControlListener === listener else { return }
                    self.reportControlListenerFailureOnQueue(
                        "The control listener was cancelled unexpectedly.",
                        generation: generation,
                        listener: listener
                    )
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else { connection.cancel(); return }
            self.onQueue {
                guard self.coreControlListener === listener,
                      self.coreControlListenerGeneration == generation,
                      self.coreControlListenerConfiguration?.generation == generation else {
                    connection.cancel()
                    return
                }
                _ = self.startInboundControlConnection(connection)
            }
        }
        coreControlListener = listener
        listener.start(queue: queue)
    }

    private func reportControlListenerFailureOnQueue(
        _ reason: String,
        generation: Int,
        listener: NWListener?
    ) {
        guard coreControlListenerGeneration == generation,
              coreControlListenerConfiguration?.generation == generation else { return }
        if let listener {
            guard coreControlListener === listener else { return }
            coreControlListener = nil
            listener.cancel()
        } else {
            guard coreControlListener == nil else { return }
        }
        controlCoreEvent?(.listenerFailed(generation: generation, reason: reason))
        guard switchControlListenerToFallbackOnQueue(generation: generation) else {
            scheduleControlListenerRetryOnQueue(generation: generation)
            return
        }
        coreControlListenerRetryAttempt = 0
        scheduleControlListenerRetryOnQueue(generation: generation, immediate: true)
    }

    private func switchControlListenerToFallbackOnQueue(generation: Int) -> Bool {
        guard var configuration = coreControlListenerConfiguration,
              configuration.generation == generation,
              !configuration.didUseFallback,
              let fallback = configuration.fallback else { return false }
        configuration.parameters = fallback.parameters
        configuration.port = fallback.port
        configuration.interface = fallback.interface
        configuration.didUseFallback = true
        coreControlListenerConfiguration = configuration
        return true
    }

    private func scheduleControlListenerRetryOnQueue(generation: Int, immediate: Bool = false) {
        guard coreControlListenerRetrySource == nil,
              coreControlListener == nil,
              coreControlListenerConfiguration?.generation == generation else { return }
        let attempt = coreControlListenerRetryAttempt
        coreControlListenerRetryAttempt += 1
        let delay = immediate ? 0 : Self.controlListenerRetryDelays[
            min(attempt, Self.controlListenerRetryDelays.count - 1)
        ]
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.coreControlListenerConfiguration?.generation == generation,
                  self.coreControlListenerGeneration == generation,
                  self.coreControlListener == nil else {
                self.cancelControlListenerRetryOnQueue()
                return
            }
            self.coreControlListenerRetrySource?.cancel()
            self.coreControlListenerRetrySource = nil
            self.startControlListenerOnQueue(generation: generation)
        }
        coreControlListenerRetrySource = source
        source.resume()
    }

    private func cancelControlListenerRetryOnQueue() {
        coreControlListenerRetrySource?.cancel()
        coreControlListenerRetrySource = nil
    }

    func startTrustedRouteDiscovery(
        targetPeerID: String,
        preference: BoothNetworkPreference,
        generation: Int,
        directLANEndpoint: NWEndpoint?,
        directLANParameters: NWParameters?
    ) {
        onQueue {
            guard self.trustedSecrets[targetPeerID] != nil,
                  self.localIdentity?.role == .iPad else { return }
            self.stopTrustedRouteDiscoveryOnQueue()
            self.selectedPeerID = targetPeerID
            self.localNetworkPreference = preference
            self.coreRouteGeneration = generation
            self.reconnectAttempt = 0
            self.coreRouteSelection.reset()
            self.corePendingRoute = nil
            if preference == .lan,
               let directLANEndpoint,
               let directLANParameters {
                self.beginTrustedConnectionOnQueue(
                    endpoint: directLANEndpoint,
                    parameters: directLANParameters,
                    interface: .wiredEthernet,
                    provenance: .directStaticLAN,
                    routeGeneration: generation
                )
                return
            }
            self.startTrustedRouteBrowsersOnQueue(preference: preference, generation: generation)
        }
    }

    func stopTrustedRouteDiscovery() {
        onQueue { stopTrustedRouteDiscoveryOnQueue() }
    }

    private func startTrustedRouteBrowsersOnQueue(
        preference: BoothNetworkPreference,
        generation: Int
    ) {
        for mechanism in BoothRouteDiscoveryPlan(preference: preference).mechanisms {
            let interface: BoothNetworkInterfacePolicy
            let compatibility: Bool
            var parameters: NWParameters
            switch mechanism {
            case .wifiBonjour:
                interface = .wifi
                compatibility = false
                parameters = .tcp
                parameters.includePeerToPeer = true
            case .wiredEthernetBonjour:
                interface = .wiredEthernet
                compatibility = false
                parameters = .tcp
                parameters.requiredInterfaceType = .wiredEthernet
            case .wiredEthernetCompatibilityBonjour:
                interface = .wiredEthernet
                compatibility = true
                parameters = .tcp
            }
            startTrustedRouteBrowserOnQueue(
                preference: preference,
                interface: interface,
                compatibility: compatibility,
                parameters: parameters,
                generation: generation
            )
        }
    }

    private func startTrustedRouteBrowserOnQueue(
        preference: BoothNetworkPreference,
        interface: BoothNetworkInterfacePolicy,
        compatibility: Bool,
        parameters: NWParameters,
        generation: Int
    ) {
        let key = "\(generation):\(interface.rawValue):\(compatibility)"
        guard coreRouteGeneration == generation,
              coreRouteBrowsers[key] == nil,
              let targetPeerID = selectedPeerID,
              trustedSecrets[targetPeerID] != nil else { return }
        coreRouteBrowserRetryTokens.removeValue(forKey: key)
        coreRouteBrowserRetrySources.removeValue(forKey: key)?.cancel()
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_prc-control._tcp", domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser else { return }
            self.onQueue {
                guard self.coreRouteBrowsers[key] === browser,
                      self.coreRouteGeneration == generation,
                      let targetPeerID = self.selectedPeerID else { return }
                self.consumeTrustedRouteResultsOnQueue(
                    results,
                    targetPeerID: targetPeerID,
                    preference: preference,
                    interface: interface,
                    compatibility: compatibility,
                    parameters: parameters,
                    generation: generation
                )
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser else { return }
            self.onQueue {
                guard self.coreRouteBrowsers[key] === browser,
                      self.coreRouteGeneration == generation else { return }
                switch state {
                case .ready:
                    var backoff = self.coreRouteBrowserRetryBackoffs[key, default: .init()]
                    backoff.browserRecovered()
                    self.coreRouteBrowserRetryBackoffs[key] = backoff
                case .failed:
                    self.coreRouteBrowsers.removeValue(forKey: key)
                    self.scheduleCoreRouteBrowserRetryOnQueue(
                        key: key,
                        preference: preference,
                        interface: interface,
                        compatibility: compatibility,
                        parameters: parameters,
                        generation: generation
                    )
                default:
                    break
                }
            }
        }
        coreRouteBrowsers[key] = browser
        browser.start(queue: queue)
    }

    private func scheduleCoreRouteBrowserRetryOnQueue(
        key: String,
        preference: BoothNetworkPreference,
        interface: BoothNetworkInterfacePolicy,
        compatibility: Bool,
        parameters: NWParameters,
        generation: Int
    ) {
        guard coreRouteBrowserRetrySources[key] == nil,
              !activeControlAuthenticated,
              selectedPeerID.flatMap({ trustedSecrets[$0] }) != nil else { return }
        let retryToken = UUID()
        var backoff = coreRouteBrowserRetryBackoffs[key, default: .init()]
        let delay = backoff.nextDelay()
        coreRouteBrowserRetryBackoffs[key] = backoff
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.coreRouteBrowserRetryTokens[key] == retryToken else { return }
            self.coreRouteBrowserRetryTokens.removeValue(forKey: key)
            self.coreRouteBrowserRetrySources.removeValue(forKey: key)?.cancel()
            guard self.coreRouteGeneration == generation,
                  !self.activeControlAuthenticated,
                  self.coreRouteBrowsers[key] == nil else {
                return
            }
            self.startTrustedRouteBrowserOnQueue(
                preference: preference,
                interface: interface,
                compatibility: compatibility,
                parameters: parameters,
                generation: generation
            )
        }
        coreRouteBrowserRetrySources[key] = source
        coreRouteBrowserRetryTokens[key] = retryToken
        source.resume()
    }

    private func consumeTrustedRouteResultsOnQueue(
        _ results: Set<NWBrowser.Result>,
        targetPeerID: String,
        preference: BoothNetworkPreference,
        interface: BoothNetworkInterfacePolicy,
        compatibility: Bool,
        parameters: NWParameters,
        generation: Int
    ) {
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint,
                  let service = BoothBonjourServiceIdentity.parse(name),
                  service.channel == .control,
                  service.deviceID == targetPeerID,
                  case let .bonjour(record) = result.metadata else { continue }
            let advertisedID = record["deviceID"]
            guard advertisedID == nil || advertisedID == targetPeerID else { continue }
            let advertisedPreference = record["network"].flatMap(BoothNetworkPreference.init(rawValue:))
            guard !compatibility || advertisedPreference == .lan else { continue }
            let route = ControlReconnectRoute(
                endpoint: result.endpoint,
                parameters: parameters,
                interface: interface,
                provenance: BoothRouteCandidatePolicy.discoveryProvenance(
                    interface: interface,
                    isLANCompatibilityFallback: compatibility
                ),
                generation: generation
            )
            switch coreRouteSelection.consider(
                interface,
                preferredPreference: preference,
                advertisedPreference: advertisedPreference
            ) {
            case .accepted:
                corePendingRoute = nil
                coreRouteFallbackSource?.cancel()
                coreRouteFallbackSource = nil
                stopTrustedRouteBrowsersOnQueue()
                beginTrustedConnectionOnQueue(
                    endpoint: route.endpoint,
                    parameters: route.parameters,
                    interface: route.interface,
                    provenance: route.provenance,
                    routeGeneration: route.generation
                )
                return
            case .waitingForPreferredInterface:
                corePendingRoute = route
                scheduleCoreRouteFallbackOnQueue(generation: generation)
            case .ignored:
                break
            }
        }
    }

    private func scheduleCoreRouteFallbackOnQueue(generation: Int) {
        guard coreRouteFallbackSource == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 2.0)
        source.setEventHandler { [weak self] in
            guard let self,
                  self.coreRouteGeneration == generation,
                  let route = self.corePendingRoute,
                  self.coreRouteSelection.promotePending() != nil else { return }
            self.coreRouteFallbackSource?.cancel()
            self.coreRouteFallbackSource = nil
            self.corePendingRoute = nil
            self.stopTrustedRouteBrowsersOnQueue()
            self.beginTrustedConnectionOnQueue(
                endpoint: route.endpoint,
                parameters: route.parameters,
                interface: route.interface,
                provenance: route.provenance,
                routeGeneration: route.generation
            )
        }
        coreRouteFallbackSource = source
        source.resume()
    }

    private func stopTrustedRouteBrowsersOnQueue() {
        coreRouteBrowsers.values.forEach { $0.cancel() }
        coreRouteBrowsers.removeAll()
        coreRouteBrowserRetryTokens.removeAll()
        coreRouteBrowserRetrySources.values.forEach { $0.cancel() }
        coreRouteBrowserRetrySources.removeAll()
        coreRouteBrowserRetryBackoffs.removeAll()
    }

    private func stopTrustedRouteDiscoveryOnQueue() {
        stopTrustedRouteBrowsersOnQueue()
        coreRouteFallbackSource?.cancel()
        coreRouteFallbackSource = nil
        corePendingRoute = nil
        coreRouteSelection.reset()
    }

    func startTrustedControlConnection(
        endpoint: NWEndpoint,
        parameters: NWParameters,
        interface: BoothNetworkInterfacePolicy,
        provenance: BoothRouteCandidateProvenance,
        generation: Int
    ) {
        onQueue {
            self.coreRouteGeneration = generation
            self.beginTrustedConnectionOnQueue(
                endpoint: endpoint,
                parameters: parameters,
                interface: interface,
                provenance: provenance,
                routeGeneration: generation
            )
        }
    }

    private func beginTrustedConnectionOnQueue(
        endpoint: NWEndpoint,
        parameters: NWParameters,
        interface: BoothNetworkInterfacePolicy,
        provenance: BoothRouteCandidateProvenance,
        routeGeneration: Int
    ) {
        guard let identity = localIdentity,
              let peerID = selectedPeerID,
              trustedSecrets[peerID] != nil,
              identity.role == .iPad else { return }
        let hasDifferentRoute = reconnectRoute?.endpoint != endpoint
            || reconnectRoute?.generation != routeGeneration
        if hasDifferentRoute { reconnectAttempt = 0 }
        if activeControlAuthenticated,
           activeControlConnection?.endpoint == endpoint { return }
        if let activeControlConnection {
            activeControlConnection.cancel()
            clearControlSlotOnQueue(connection: activeControlConnection)
        }
        if let identityProbeConnection {
            identityProbeConnection.cancel()
            clearProbeOnQueue(connection: identityProbeConnection)
        }
        nextControlGeneration = max(nextControlGeneration, nextInboundAdmissionGeneration) &+ 1
        nextInboundAdmissionGeneration = nextControlGeneration
        let controlGeneration = nextControlGeneration
        let connection = NWConnection(to: endpoint, using: parameters)
        let route = ControlReconnectRoute(
            endpoint: endpoint,
            parameters: parameters,
            interface: interface,
            provenance: provenance,
            generation: routeGeneration
        )
        reconnectRoute = route
        reconnectGeneration = routeGeneration
        reconnectAttempt = max(1, reconnectAttempt)
        activeControlConnection = connection
        activeControlGeneration = controlGeneration
        activeControlAuthenticated = false
        activeControlIsIdentityProbe = false
        let candidate = TrustedHandshake(
            connection: connection,
            generation: controlGeneration,
            admission: nil,
            lane: .normal,
            role: identity.role,
            localDeviceID: identity.id
        )
        candidate.routeGeneration = routeGeneration
        candidate.isTrusted = true
        candidate.localHello = BoothTransportHello(
            role: identity.role,
            deviceID: identity.id,
            deviceName: identity.displayName,
            networkPreference: localNetworkPreference
        )
        protocolCandidates[ObjectIdentifier(connection)] = candidate
        pendingReconnectConnection = connection
        let connectTimeout = DispatchSource.makeTimerSource(queue: queue)
        connectTimeout.schedule(deadline: .now() + 10)
        connectTimeout.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.isCurrentCandidateOnQueue(connection, generation: controlGeneration) else { return }
            self.rejectTrustedCandidateOnQueue(
                connection,
                generation: controlGeneration,
                reason: "Control connection deadline expired."
            )
        }
        candidate.timeout = connectTimeout
        connectTimeout.resume()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.onQueue {
                guard let current = self.candidateOnQueue(connection, generation: controlGeneration) else { return }
                switch state {
                case .ready:
                    guard let hello = current.localHello else { return }
                    self.stopPendingReconnectTimeoutOnQueue()
                    self.pendingReconnectConnection = nil
                    self.startCoreTimeoutOnQueue(
                        current,
                        after: 5,
                        reason: "Transport Hello deadline expired."
                    )
                    self.sendCoreMessageOnQueue(.helloDetails(hello: hello), candidate: current)
                    self.receiveCoreFramesOnQueue(current)
                case .failed(let error):
                    self.finishTrustedCandidateOnQueue(
                        current,
                        reason: error.localizedDescription,
                        rejected: false
                    )
                case .cancelled:
                    self.finishTrustedCandidateOnQueue(current, reason: nil, rejected: false)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        if routeGeneration > 0 {
            reconnectRoute = route
        }
    }

    private func startTrustedHandshakeOnQueue(
        connection: NWConnection,
        admission: InboundControlAdmission,
        lane: AdmissionLane
    ) {
        guard let identity = localIdentity else {
            connection.cancel()
            return
        }
        let candidate = TrustedHandshake(
            connection: connection,
            generation: admission.generation,
            admission: admission,
            lane: lane,
            role: identity.role,
            localDeviceID: identity.id
        )
        protocolCandidates[ObjectIdentifier(connection)] = candidate
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        let helloDeadline: TimeInterval = lane == .identityProbe
            && admissionLimiter.isIdentityProbeCoolingDown() ? 1 : 5
        timeout.schedule(deadline: .now() + helloDeadline)
        timeout.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.isCurrentCandidateOnQueue(connection, generation: admission.generation) else { return }
            self.rejectTrustedCandidateOnQueue(
                connection,
                generation: admission.generation,
                reason: "Bootstrap Hello deadline expired."
            )
        }
        candidate.timeout = timeout
        timeout.resume()
        candidate.localHello = BoothTransportHello(
            role: identity.role,
            deviceID: identity.id,
            deviceName: identity.displayName,
            networkPreference: localNetworkPreference
        )
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.onQueue {
                guard let current = self.candidateOnQueue(connection, generation: admission.generation) else { return }
                switch state {
                case .ready:
                    self.receiveCoreFramesOnQueue(current)
                case .failed(let error):
                    self.finishTrustedCandidateOnQueue(
                        current,
                        reason: error.localizedDescription,
                        rejected: false
                    )
                case .cancelled:
                    self.finishTrustedCandidateOnQueue(current, reason: nil, rejected: false)
                default:
                    break
                }
            }
        }
    }

    private func receiveCoreFramesOnQueue(_ candidate: TrustedHandshake) {
        let connection = candidate.connection
        let generation = candidate.generation
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }
            self.onQueue {
                guard let candidate = self.candidateOnQueue(connection, generation: generation) else { return }
                if let data, !data.isEmpty {
                    do {
                        var pendingData = data
                        while let frame = try candidate.decoder.decodeNextControl(
                            pendingData,
                            secureChannel: candidate.secureChannel
                        ) {
                            pendingData = Data()
                            switch frame {
                            case .control(let message):
                                self.handleCoreMessageOnQueue(message, candidate: candidate)
                                guard self.candidateOnQueue(connection, generation: generation) === candidate else { return }
                            case .heartbeat:
                                guard self.activeControlConnection === connection,
                                      self.activeControlAuthenticated else { continue }
                                self.markControlActivityOnQueue()
                                self.controlCoreEvent?(.controlFrames(
                                    generation: candidate.generation,
                                    frames: [frame]
                                ))
                            default:
                                self.rejectTrustedCandidateOnQueue(
                                    connection,
                                    generation: candidate.generation,
                                    reason: "Unexpected frame on control channel."
                                )
                                return
                            }
                        }
                    } catch {
                        if let failure = error as? BoothControlFrameDecodeFailure {
                            self.controlCoreEvent?(.controlFrameDecodeFailed(
                                generation: candidate.generation,
                                routeGeneration: candidate.routeGeneration,
                                byteCount: failure.payloadByteCount,
                                summary: self.controlFrameFailureSummary(failure, candidate: candidate)
                            ))
                        }
                        self.rejectTrustedCandidateOnQueue(
                            connection,
                            generation: candidate.generation,
                            reason: error is BoothControlFrameDecodeFailure
                                ? String(localized: "Secure connection failed. Reconnecting…")
                                : String(localized: "Invalid control frame. Reconnecting…")
                        )
                        return
                    }
                }
                if let error {
                    self.finishTrustedCandidateOnQueue(
                        candidate,
                        reason: error.localizedDescription,
                        rejected: false
                    )
                } else if isComplete {
                    self.finishTrustedCandidateOnQueue(candidate, reason: nil, rejected: false)
                } else {
                    self.receiveCoreFramesOnQueue(candidate)
                }
            }
        }
    }

    private func controlFrameFailureSummary(
        _ failure: BoothControlFrameDecodeFailure,
        candidate: TrustedHandshake
    ) -> String {
        let role: String
        switch localIdentity?.role {
        case .mac: role = "Mac"
        case .iPad: role = "iPad"
        case nil: role = "unknown"
        }
        let routeGeneration = candidate.routeGeneration.map(String.init) ?? "none"
        let prepared = candidate.secureChannel.hasPreparedKeys ? "yes" : "no"
        let established = candidate.secureHandshakeEstablished ? "yes" : "no"
        let endpoint = Self.sanitizedEndpoint(candidate.connection.endpoint)
        return [
            failure.diagnosticDescription,
            "role=\(role)",
            "generation=\(candidate.generation)",
            "routeGeneration=\(routeGeneration)",
            "endpoint=\(endpoint)",
            "authenticated=\(candidate.authenticated ? "yes" : "no")",
            "peerProofSent=\(candidate.peerProofSent ? "yes" : "no")",
            "peerProofVerified=\(candidate.peerProofVerified ? "yes" : "no")",
            "readySent=\(candidate.readySent ? "yes" : "no")",
            "readyReceived=\(candidate.readyReceived ? "yes" : "no")",
            "keysPrepared=\(prepared)",
            "secureOperational=\(established)"
        ].joined(separator: " ")
    }

    private static func sanitizedEndpoint(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(_, let port): return "tcp-port:\(port.rawValue)"
        case .service: return "bonjour-service"
        case .url: return "url-endpoint"
        case .unix: return "unix-endpoint"
        case .opaque: return "opaque-endpoint"
        @unknown default: return "unknown-endpoint"
        }
    }

    private func handleCoreMessageOnQueue(_ message: Message, candidate: TrustedHandshake) {
        if candidate.peerHello == nil {
            guard case .helloDetails(let hello) = message else {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Control Hello must be the first protocol message."
                )
                return
            }
            handleCoreHelloOnQueue(hello, candidate: candidate)
            return
        }
        switch message {
        case .pairingIntent(let intent) where candidate.isPairingCandidate:
            guard let hello = candidate.peerHello,
                  let identity = localIdentity else { return }
            do {
                try intent.validate(peerHello: hello, localMacDeviceID: identity.id)
                if let previous = candidate.receivedPairingIntent {
                    guard previous == intent else {
                        rejectTrustedCandidateOnQueue(
                            candidate.connection,
                            generation: candidate.generation,
                            reason: "Pairing intent changed during an active candidate."
                        )
                        return
                    }
                    return
                }
                candidate.receivedPairingIntent = intent
                guard let pairing = pairingCandidateValueOnQueue(candidate) else { return }
                controlCoreEvent?(.pairingIntentCandidate(pairing, intent))
            } catch {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: error.localizedDescription
                )
            }
        case .pairingRequest(let request) where candidate.isPairingCandidate:
            handleCorePairingRequestOnQueue(request, candidate: candidate)
        case .authChallenge(let challenge):
            handleCoreAuthChallengeOnQueue(challenge, candidate: candidate)
        case .authProof(let proof):
            handleCoreAuthProofOnQueue(proof, candidate: candidate)
        case .secureChannelHello(let hello):
            handleCoreSecureHelloOnQueue(hello, candidate: candidate)
        case .secureChannelReady(let sessionID, let proof):
            handleCoreSecureReadyOnQueue(sessionID: sessionID, proof: proof, candidate: candidate)
        case .connectionRejected(let reason):
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: reason
            )
        case .heartbeat:
            guard candidate === activeProtocolCandidateOnQueue,
                  activeControlAuthenticated else { return }
            markControlActivityOnQueue()
            controlCoreEvent?(.controlFrames(
                generation: candidate.generation,
                frames: [.heartbeat]
            ))
        default:
            guard candidate === activeProtocolCandidateOnQueue,
                  activeControlAuthenticated else {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Application control message arrived before secure-channel readiness."
                )
                return
            }
            controlCoreEvent?(.controlFrames(
                generation: candidate.generation,
                frames: [.control(message)]
            ))
        }
    }

    private var activeProtocolCandidateOnQueue: TrustedHandshake? {
        guard let connection = activeControlConnection else { return nil }
        return protocolCandidates[ObjectIdentifier(connection)]
    }

    private func pairingCandidateOnQueue(token: UUID, generation: Int) -> TrustedHandshake? {
        guard let candidate = protocolCandidates.values.first(where: {
            $0.admission?.token == token && $0.generation == generation && $0.isPairingCandidate
        }),
              activeControlConnection === candidate.connection,
              activeControlGeneration == generation else { return nil }
        return candidate
    }

    private func pairingCandidateValueOnQueue(_ candidate: TrustedHandshake) -> PairingCandidate? {
        guard candidate.isPairingCandidate,
              let admission = candidate.admission,
              let hello = candidate.peerHello else { return nil }
        return PairingCandidate(token: admission.token, generation: candidate.generation, hello: hello)
    }

    private func handleCorePairingRequestOnQueue(
        _ request: BoothPairingRequest,
        candidate: TrustedHandshake
    ) {
        guard candidateOnQueue(candidate.connection, generation: candidate.generation) === candidate,
              candidate.isPairingCandidate,
              let hello = candidate.peerHello,
              let identity = localIdentity,
              identity.role == .mac,
              hello.role == .iPad,
              request.iPadIdentity.id == hello.deviceID,
              request.iPadIdentity.role == .iPad,
              !request.iPadIdentity.displayName.isEmpty,
              request.targetMacDeviceID == identity.id else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Pairing request does not match this connection."
            )
            return
        }
        guard var session = inboundPairingSession,
              session.isActive(),
              request.sessionID == session.info.sessionID,
              request.sessionID == candidate.pairingSessionID,
              request.iPadEphemeralPublicKey.count == 32,
              request.admissionProof.count == 32 else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Pairing session is unavailable or request proof is malformed."
            )
            return
        }

        let transcript = BoothPairingCrypto.pairingTranscript(
            sessionID: request.sessionID,
            macDeviceID: identity.id,
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
        inboundPairingSession = session
        switch validation {
        case .rejected(let remainingAttempts):
            sendCoreMessageOnQueue(
                .pairingResult(result: BoothPairingResult(
                    accepted: false,
                    reason: request.method == .pin
                        ? "Pairing PIN is invalid. \(remainingAttempts) attempts remaining."
                        : "Pairing QR code is invalid.",
                    retryable: remainingAttempts > 0,
                    pairingSessionID: request.sessionID
                )),
                candidate: candidate
            )
        case .expired:
            inboundPairingSession = nil
            emitPairingSessionConsumedOnQueue(
                sessionID: request.sessionID,
                outcome: .expired,
                candidate: candidate
            )
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Pairing session expired."
            )
        case .locked:
            inboundPairingSession = nil
            emitPairingSessionConsumedOnQueue(
                sessionID: request.sessionID,
                outcome: .locked,
                candidate: candidate
            )
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Too many incorrect pairing PIN attempts."
            )
        case .accepted:
            inboundPairingSession = nil
            emitPairingSessionConsumedOnQueue(
                sessionID: request.sessionID,
                outcome: .proofAccepted(method: request.method),
                candidate: candidate
            )
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
                candidate.pairingSessionID = request.sessionID
                candidate.pairingExpiresAt = session.info.expiresAt
                candidate.pairingSecret = secret
                candidate.pairingTranscript = transcript
                candidate.pairingPeer = peer
                candidate.pairingMethod = request.method
                candidate.pairingVerificationCode = request.method == .pin
                    ? BoothPairingCrypto.makeVerificationCode(secret: secret, transcript: transcript)
                    : nil
                candidate.isTrusted = true
                candidate.secureNegotiator.setExpectedPeerDeviceID(peer.id)
                startCoreTimeoutOnQueue(
                    candidate,
                    after: max(1, session.info.expiresAt.timeIntervalSinceNow),
                    reason: "Pairing session expired."
                )
                let result = BoothPairingResult(
                    accepted: true,
                    macIdentity: identity,
                    pairingSessionID: request.sessionID,
                    macEphemeralPublicKey: session.info.macEphemeralPublicKey,
                    keyAgreementProof: BoothPairingCrypto.makeKeyAgreementProof(
                        secret: secret,
                        transcript: transcript,
                        role: .mac
                    )
                )
                let token = candidate.admission?.token
                let generation = candidate.generation
                sendCoreMessageOnQueue(.pairingResult(result: result), candidate: candidate) { [weak self] sent in
                    guard let self,
                          let token,
                          let current = self.pairingCandidateOnQueue(token: token, generation: generation) else { return }
                    guard sent,
                          let currentPeer = current.pairingPeer,
                          let expiresAt = current.pairingExpiresAt else {
                        self.rejectTrustedCandidateOnQueue(
                            current.connection,
                            generation: generation,
                            reason: "Pairing result could not be delivered."
                        )
                        return
                    }
                    if let code = current.pairingVerificationCode {
                        guard let snapshotCandidate = self.pairingCandidateValueOnQueue(current) else { return }
                        self.controlCoreEvent?(.pairingVerificationRequired(PairingVerificationSnapshot(
                            candidate: snapshotCandidate,
                            sessionID: request.sessionID,
                            peer: currentPeer,
                            verificationCode: code,
                            expiresAt: expiresAt
                        )))
                    } else if let secret = current.pairingSecret {
                        self.beginCoreAuthenticationOnQueue(current, secret: secret)
                    }
                }
            } catch {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Pairing key agreement failed."
                )
            }
        }
    }

    private func emitPairingSessionConsumedOnQueue(
        sessionID: String,
        outcome: PairingSessionConsumption.Outcome,
        candidate: TrustedHandshake
    ) {
        guard let candidateValue = pairingCandidateValueOnQueue(candidate) else { return }
        controlCoreEvent?(.pairingSessionConsumed(PairingSessionConsumption(
            candidate: candidateValue,
            sessionID: sessionID,
            outcome: outcome
        )))
    }

    private func handleCoreHelloOnQueue(_ hello: BoothTransportHello, candidate: TrustedHandshake) {
        guard let identity = localIdentity,
              hello.deviceID.isEmpty == false,
              hello.deviceName.isEmpty == false,
              hello.protocolVersion == BoothTransportHello.currentProtocolVersion,
              hello.role == (identity.role == .mac ? .iPad : .mac),
              hello.capabilities.contains("pairing-v2"),
              hello.capabilities.contains("secure-channel-v1"),
              hello.capabilities.contains("asset-channel-v2"),
              hello.capabilities.contains("preview-identity") else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Control Hello is invalid or incompatible."
            )
            return
        }
        if let selectedPeerID, identity.role == .iPad, hello.deviceID != selectedPeerID {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "The connected Mac does not match the selected peer."
            )
            return
        }
        if identity.role == .mac,
           let selectedPeerID,
           hello.deviceID != selectedPeerID {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "This Mac is configured for another iPad."
            )
            return
        }
        guard let secret = trustedSecrets[hello.deviceID] else {
            guard candidate.lane == .normal,
                  let admission = candidate.admission,
                  identity.role == .mac else {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Identity probe did not claim a trusted peer."
                )
                return
            }
            candidate.peerHello = hello
            candidate.isPairingCandidate = true
            candidate.pairingSessionID = inboundPairingSession?.info.sessionID
            candidate.pairingExpiresAt = inboundPairingSession?.info.expiresAt
            candidate.timeout?.cancel()
            candidate.timeout = nil
            // Hello has been consumed by the core; MainActor adoption is no
            // longer part of the admission deadline or socket ownership.
            if inboundAdmission?.token == admission.token {
                stopInboundAdmissionTimeoutOnQueue()
                inboundAdmission = nil
            }
            if let pairingSession = inboundPairingSession,
               pairingSession.isActive(),
               let localHello = candidate.localHello {
                candidate.pairingSessionID = pairingSession.info.sessionID
                candidate.pairingExpiresAt = pairingSession.info.expiresAt
                sendCoreMessageOnQueue(.helloDetails(hello: localHello), candidate: candidate)
                startCoreTimeoutOnQueue(
                    candidate,
                    after: max(1, pairingSession.info.expiresAt.timeIntervalSinceNow),
                    reason: "Pairing session expired."
                )
            } else {
                if let localHello = candidate.localHello {
                    sendCoreMessageOnQueue(.helloDetails(hello: localHello), candidate: candidate)
                }
                startCoreTimeoutOnQueue(
                    candidate,
                    after: 30,
                    reason: "Pairing intent deadline expired."
                )
            }
            return
        }
        if identity.role == .mac, selectedPeerID != hello.deviceID {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "This Mac is configured for another iPad."
            )
            return
        }
        if candidate.admission != nil {
            let probeDecision = admissionLimiter.shouldAdmitIdentityProbe(
                peerID: hello.deviceID,
                trustedPeerIDs: trustedPeerIDs
            )
            // A claimed ID shares its failure history with the real device.
            // Do not let that shared cooldown deny a valid HMAC proof; keep
            // the candidate bounded and shorten its authentication deadline.
            candidate.isIdentityProbeCoolingDown = !probeDecision.admitted
                || admissionLimiter.isIdentityProbeCoolingDown()
            candidate.claimedTrustedPeerID = hello.deviceID
        }
        candidate.peerHello = hello
        candidate.isTrusted = true
        candidate.secureNegotiator.setExpectedPeerDeviceID(hello.deviceID)
        if let admission = candidate.admission {
            if admission.isIdentityProbe {
                stopIdentityProbeAdmissionTimeoutOnQueue()
            } else {
                stopInboundAdmissionTimeoutOnQueue()
            }
        }
        startCoreTimeoutOnQueue(
            candidate,
            after: candidate.admission == nil
                ? 25
                : candidate.isIdentityProbeCoolingDown ? 2 : 5,
            reason: "Trusted authentication deadline expired."
        )
        if identity.role == .mac, let localHello = candidate.localHello {
            sendCoreMessageOnQueue(.helloDetails(hello: localHello), candidate: candidate)
        }
        beginCoreAuthenticationOnQueue(candidate, secret: secret)
    }

    private func beginCoreAuthenticationOnQueue(_ candidate: TrustedHandshake, secret: Data) {
        guard let identity = localIdentity, let peer = candidate.peerHello else { return }
        do {
            let challenge = try BoothAuthChallenge.make(
                challengerDeviceID: identity.id,
                responderDeviceID: peer.deviceID
            )
            candidate.localChallenge = challenge
            sendCoreMessageOnQueue(.authChallenge(challenge: challenge), candidate: candidate)
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Authentication challenge could not be created."
            )
        }
    }

    private func handleCoreAuthChallengeOnQueue(_ challenge: BoothAuthChallenge, candidate: TrustedHandshake) {
        guard let identity = localIdentity,
              let peer = candidate.peerHello,
              challenge.challengerDeviceID == peer.deviceID,
              challenge.responderDeviceID == identity.id,
              challenge.isWellFormed,
              let secret = authenticationSecretOnQueue(candidate) else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Authentication challenge was invalid."
            )
            return
        }
        let proof = BoothPairingCrypto.makeProof(
            for: challenge,
            responderDeviceID: identity.id,
            secret: secret
        )
        candidate.peerProofSent = true
        sendCoreMessageOnQueue(.authProof(proof: proof), candidate: candidate)
        finishCoreAuthenticationIfReadyOnQueue(candidate)
    }

    private func handleCoreAuthProofOnQueue(_ proof: BoothAuthProof, candidate: TrustedHandshake) {
        guard let peer = candidate.peerHello,
              let challenge = candidate.localChallenge,
              let secret = authenticationSecretOnQueue(candidate),
              BoothPairingCrypto.verificationFailure(
                proof,
                for: challenge,
                expectedResponderDeviceID: peer.deviceID,
                secret: secret
              ) == nil else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Stored-secret authentication failed."
            )
            return
        }
        candidate.peerProofVerified = true
        finishCoreAuthenticationIfReadyOnQueue(candidate)
    }

    private func finishCoreAuthenticationIfReadyOnQueue(_ candidate: TrustedHandshake) {
        guard candidate.peerProofVerified,
              candidate.peerProofSent,
              candidate.peerHello != nil,
              let identity = localIdentity else { return }
        candidate.timeout?.cancel()
        candidate.timeout = nil
        if identity.role == .mac {
            do {
                guard case .sendHello(let hello) = try candidate.secureNegotiator.begin(
                    generation: candidate.generation
                ) else { return }
                candidate.localSecureHello = hello
                sendCoreMessageOnQueue(.secureChannelHello(hello: hello), candidate: candidate)
                startCoreTimeoutOnQueue(candidate, after: 25, reason: "Secure-channel negotiation deadline expired.")
            } catch {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Secure-channel setup failed."
                )
            }
        } else if candidate.localSecureHello == nil {
            startCoreTimeoutOnQueue(candidate, after: 25, reason: "Secure-channel negotiation deadline expired.")
        }
    }

    private func handleCoreSecureHelloOnQueue(_ hello: BoothSecureChannelHello, candidate: TrustedHandshake) {
        guard candidate.mutualAuthenticationComplete else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel Hello arrived before mutual authentication."
            )
            return
        }
        do {
            let actions = try candidate.secureNegotiator.receiveHello(
                hello,
                generation: candidate.generation
            )
            candidate.localSecureHello = candidate.secureNegotiator.localHello
            candidate.peerSecureHello = candidate.secureNegotiator.peerHello
            for action in actions {
                switch action {
                case .sendHello(let response):
                    candidate.localSecureHello = response
                    sendCoreMessageOnQueue(.secureChannelHello(hello: response), candidate: candidate)
                    try configureCoreSecureChannelOnQueue(candidate)
                case .configure:
                    try configureCoreSecureChannelOnQueue(candidate)
                case .established, .ignored:
                    break
                }
            }
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel Hello was invalid."
            )
        }
    }

    private func configureCoreSecureChannelOnQueue(_ candidate: TrustedHandshake) throws {
        guard !candidate.readySent, !candidate.secureHandshakeEstablished else { return }
        guard let localHello = candidate.secureNegotiator.localHello,
              let peerHello = candidate.secureNegotiator.peerHello,
              candidate.peerHello != nil,
              let secret = authenticationSecretOnQueue(candidate) else { throw BoothSecureChannelError.invalidHello }
        try candidate.secureChannel.configure(secret: secret, localHello: localHello, peerHello: peerHello)
        let macHello = localHello.senderRole == .mac ? localHello : peerHello
        let iPadHello = localHello.senderRole == .iPad ? localHello : peerHello
        let proof = BoothSecureChannel.readyProof(
            secret: secret,
            macHello: macHello,
            iPadHello: iPadHello,
            senderRole: localHello.senderRole
        )
        try candidate.secureNegotiator.markReadySent(generation: candidate.generation)
        candidate.readySent = true
        sendCoreMessageOnQueue(
            .secureChannelReady(sessionID: localHello.sessionID, proof: proof),
            candidate: candidate
        )
        finishCoreSecureChannelIfReadyOnQueue(candidate)
    }

    private func handleCoreSecureReadyOnQueue(
        sessionID: String,
        proof: Data,
        candidate: TrustedHandshake
    ) {
        guard candidate.mutualAuthenticationComplete else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel confirmation arrived before mutual authentication."
            )
            return
        }
        guard !candidate.readyReceived else { return }
        guard let localHello = candidate.secureNegotiator.localHello,
              let peerHello = candidate.secureNegotiator.peerHello,
              sessionID == localHello.sessionID,
              sessionID == peerHello.sessionID,
              candidate.peerHello != nil,
              let secret = authenticationSecretOnQueue(candidate) else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel confirmation was invalid."
            )
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
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel confirmation failed."
            )
            return
        }
        do {
            let action = try candidate.secureNegotiator.receiveReady(
                sessionID: sessionID,
                generation: candidate.generation
            )
            guard action == .established || !candidate.readySent else { return }
            candidate.readyReceived = true
            finishCoreSecureChannelIfReadyOnQueue(candidate)
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel confirmation was invalid."
            )
        }
    }

    private func finishCoreSecureChannelIfReadyOnQueue(_ candidate: TrustedHandshake) {
        guard candidate.mutualAuthenticationComplete,
              candidate.readySent,
              candidate.readyReceived,
              candidate.secureChannel.isConfigured,
              !candidate.secureHandshakeEstablished else { return }
        do {
            try candidate.secureNegotiator.markEstablished(generation: candidate.generation)
            candidate.secureHandshakeEstablished = true
            candidate.decoder.setHandshakeComplete(true, channel: .control)
            if let peer = candidate.pairingPeer,
               let secret = candidate.pairingSecret,
               let admission = candidate.admission,
               let hello = candidate.peerHello {
                guard !candidate.pairingTrustRequested else { return }
                candidate.pairingTrustRequested = true
                startCoreTimeoutOnQueue(
                    candidate,
                    after: 60,
                    reason: "Pairing trust persistence deadline expired."
                )
                controlCoreEvent?(.pairingTrustRequired(PairingTrustSnapshot(
                    candidate: PairingCandidate(
                        token: admission.token,
                        generation: candidate.generation,
                        hello: hello
                    ),
                    sessionID: candidate.pairingSessionID ?? "",
                    peer: peer,
                    secret: secret,
                    expiresAt: candidate.pairingExpiresAt ?? .distantPast
                )))
            } else {
                promoteCoreCandidateOnQueue(candidate)
            }
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel confirmation was invalid."
            )
        }
    }

    private func promoteCoreCandidateOnQueue(_ candidate: TrustedHandshake) {
        guard !candidate.authenticated,
              candidate.mutualAuthenticationComplete,
              candidate.secureHandshakeEstablished else { return }
        guard let peer = candidate.peerHello,
              let localHello = candidate.secureNegotiator.localHello,
              let peerSecureHello = candidate.secureNegotiator.peerHello else { return }
        if candidate.lane == .identityProbe {
            guard identityProbeConnection === candidate.connection,
                  identityProbeAdmission?.generation == candidate.generation,
                  !activeControlAuthenticated else {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Authenticated control connection is already active."
                )
                return
            }
            if let activeControlConnection, activeControlConnection !== candidate.connection {
                activeControlConnection.cancel()
                clearControlSlotOnQueue(connection: activeControlConnection)
            }
        } else if activeControlConnection !== candidate.connection {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Control candidate lost the active slot."
            )
            return
        }
        candidate.timeout?.cancel()
        candidate.timeout = nil
        guard let secret = authenticationSecretOnQueue(candidate),
              let sharedSecureChannel,
              let writer = controlWriter else {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Trusted credentials changed before secure-channel activation."
            )
            return
        }
        do {
            try sharedSecureChannel.configure(
                secret: secret,
                localHello: localHello,
                peerHello: peerSecureHello
            )
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Control secure-channel activation failed."
            )
            return
        }
        writer.bind(candidate.connection, generation: candidate.generation)
        candidate.authenticated = true
        if candidate.lane == .identityProbe {
            identityProbeAdmission = nil
            stopIdentityProbeAdmissionTimeoutOnQueue()
            identityProbeConnection = nil
            activeControlConnection = candidate.connection
            activeControlGeneration = candidate.generation
        }
        activeControlAuthenticated = true
        activeControlIsIdentityProbe = false
        activeIdentityProbePeerID = nil
        if let admission = candidate.admission {
            if admission.isIdentityProbe {
                identityProbeAdmission = nil
                stopIdentityProbeAdmissionTimeoutOnQueue()
                identityProbeConnection = nil
            } else {
                inboundAdmission = nil
                stopInboundAdmissionTimeoutOnQueue()
            }
            admissionLimiter.recordSuccess(endpointKey: admission.endpointKey)
            admissionLimiter.recordIdentityProbeSuccess(peerID: peer.deviceID)
            var endpoints = authenticatedEndpointsByPeerID[peer.deviceID, default: []]
            endpoints.insert(admission.endpointKey)
            authenticatedEndpointsByPeerID[peer.deviceID] = Set(endpoints.sorted().suffix(8))
        }
        onPreAuthAuthenticated()
        startHeartbeatOnQueue(
            connection: candidate.connection,
            generation: candidate.generation,
            writer: writer,
            interval: 2,
            timeout: 8
        )
        controlCoreEvent?(.trustedAuthenticated(
            generation: candidate.generation,
            endpointDescription: candidate.connection.endpoint.debugDescription,
            hello: peer,
            localSecureHello: localHello,
            peerSecureHello: peerSecureHello,
            interface: reconnectRoute?.interface,
            provenance: reconnectRoute?.provenance,
            routeGeneration: candidate.routeGeneration
        ))
    }

    private func authenticationSecretOnQueue(_ candidate: TrustedHandshake) -> Data? {
        if let pairingSecret = candidate.pairingSecret { return pairingSecret }
        guard let peerID = candidate.peerHello?.deviceID else { return nil }
        return trustedSecrets[peerID]
    }

    private func sendCoreMessageOnQueue(
        _ message: Message,
        candidate: TrustedHandshake,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        do {
            let payload = try message.encoded()
            let frame = try BoothFrameEncoder.encode(channel: .control, payload: payload)
            let generation = candidate.generation
            candidate.connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection = candidate.connection] error in
                guard let self, let connection else { return }
                self.onQueue {
                    guard self.isCurrentCandidateOnQueue(connection, generation: generation) else { return }
                    if let error {
                        self.rejectTrustedCandidateOnQueue(
                            connection,
                            generation: generation,
                            reason: "Control handshake send failed: \(error.localizedDescription)"
                        )
                        completion?(false)
                    } else {
                        completion?(true)
                    }
                }
            })
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Control handshake encoding failed."
            )
            completion?(false)
        }
    }

    private func startCoreTimeoutOnQueue(
        _ candidate: TrustedHandshake,
        after timeout: TimeInterval,
        reason: String
    ) {
        let generation = candidate.generation
        let connection = candidate.connection
        candidate.timeout?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.isCurrentCandidateOnQueue(connection, generation: generation) else { return }
            self.rejectTrustedCandidateOnQueue(
                connection,
                generation: generation,
                reason: reason
            )
        }
        candidate.timeout = source
        source.resume()
    }

    private func shortenAnonymousIdentityProbeHelloDeadlineOnQueueIfCoolingDown() {
        guard admissionLimiter.isIdentityProbeCoolingDown(),
              let connection = identityProbeConnection,
              let candidate = protocolCandidates[ObjectIdentifier(connection)],
              candidate.peerHello == nil,
              !candidate.isIdentityProbeCoolingDown else { return }

        // Once a hostile flood trips global cooldown, release an anonymous
        // no-Hello probe quickly so cached trusted reconnects can use the lane.
        // Marking the candidate also makes this deadline adjustment one-shot.
        candidate.isIdentityProbeCoolingDown = true
        startCoreTimeoutOnQueue(
            candidate,
            after: 1,
            reason: "Bootstrap Hello deadline expired."
        )
    }

    private func isCurrentCandidateOnQueue(_ connection: NWConnection, generation: Int) -> Bool {
        candidateOnQueue(connection, generation: generation) != nil
    }

    private func candidateOnQueue(_ connection: NWConnection, generation: Int) -> TrustedHandshake? {
        guard let candidate = protocolCandidates[ObjectIdentifier(connection)],
              candidate.generation == generation,
              activeControlConnection === connection || identityProbeConnection === connection else { return nil }
        return candidate
    }

    private func rejectTrustedCandidateOnQueue(
        _ connection: NWConnection,
        generation: Int,
        reason: String
    ) {
        guard let candidate = protocolCandidates[ObjectIdentifier(connection)],
              candidate.generation == generation else { return }
        connection.cancel()
        finishTrustedCandidateOnQueue(candidate, reason: reason, rejected: true)
    }

    private func finishTrustedCandidateOnQueue(
        _ candidate: TrustedHandshake,
        reason: String?,
        rejected: Bool
    ) {
        candidate.timeout?.cancel()
        candidate.timeout = nil
        protocolCandidates.removeValue(forKey: ObjectIdentifier(candidate.connection))
        if !candidate.authenticated {
            let claimedPeerID = candidate.claimedTrustedPeerID
                ?? (identityProbeConnection === candidate.connection ? activeIdentityProbePeerID : nil)
            if let peerID = claimedPeerID {
                admissionLimiter.recordIdentityProbeFailure(peerID: peerID, trustedPeerIDs: trustedPeerIDs)
            } else if candidate.lane == .identityProbe {
                admissionLimiter.recordIdentityProbeAttemptFailure()
            }
        }
        if !candidate.authenticated, let admission = candidate.admission {
            admissionLimiter.recordFailure(
                endpointKey: admission.endpointKey,
                isPreferredCandidate: admission.isPreferredCandidate
            )
        }
        if identityProbeConnection === candidate.connection {
            clearProbeOnQueue(connection: candidate.connection, recordFailure: false)
        } else if activeControlConnection === candidate.connection {
            stopHeartbeatOnQueue()
            clearControlSlotOnQueue(connection: candidate.connection)
        }
        if let reason {
            controlCoreEvent?(rejected
                ? .rejected(generation: candidate.generation, reason: reason)
                : .disconnected(generation: candidate.generation, reason: reason))
        } else {
            controlCoreEvent?(.disconnected(generation: candidate.generation, reason: nil))
        }
        if candidate.connection === pendingReconnectConnection {
            pendingReconnectConnection = nil
            stopPendingReconnectTimeoutOnQueue()
        }
        let routeIsCurrent = candidate.routeGeneration == coreRouteGeneration
        if routeIsCurrent,
           reconnectRoute?.provenance == .directStaticLAN,
           localIdentity?.role == .iPad,
           !activeControlAuthenticated {
            startTrustedRouteBrowsersOnQueue(
                preference: localNetworkPreference,
                generation: coreRouteGeneration
            )
        } else if routeIsCurrent, !activeControlAuthenticated, reconnectRoute != nil {
            _ = scheduleRecoveryReconnectOnQueue(after: 0.5, generation: reconnectRoute?.generation ?? reconnectGeneration)
        }
    }

    private func clearProbeOnQueue(connection: NWConnection, recordFailure: Bool = true) {
        guard identityProbeConnection === connection else { return }
        stopIdentityProbeAdmissionTimeoutOnQueue()
        identityProbeAdmission = nil
        identityProbeConnection = nil
        if let candidate = protocolCandidates.removeValue(forKey: ObjectIdentifier(connection)) {
            candidate.timeout?.cancel()
        }
        if recordFailure, let peerID = activeIdentityProbePeerID {
            admissionLimiter.recordIdentityProbeFailure(peerID: peerID, trustedPeerIDs: trustedPeerIDs)
        }
        activeIdentityProbePeerID = nil
    }


    func startHeartbeat(
        connection: NWConnection,
        generation: Int,
        writer: BoothControlWritePump,
        interval: TimeInterval,
        timeout: TimeInterval
    ) {
        onQueue {
            startHeartbeatOnQueue(
                connection: connection,
                generation: generation,
                writer: writer,
                interval: interval,
                timeout: timeout
            )
        }
    }

    func startHeartbeatOnQueue(
        connection: NWConnection,
        generation: Int,
        writer: BoothControlWritePump,
        interval: TimeInterval,
        timeout: TimeInterval
    ) {
        heartbeatSource?.cancel()
        heartbeatConnection = connection
        heartbeatGeneration = generation
        controlTrafficAdmitted = true
        heartbeatState.markActivity()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.heartbeatConnection === connection,
                  self.heartbeatGeneration == generation else { return }
            if self.heartbeatState.shouldReportTimeout(after: timeout) {
                connection.cancel()
                self.stopHeartbeatOnQueue()
                if let candidate = self.protocolCandidates[ObjectIdentifier(connection)] {
                    self.finishTrustedCandidateOnQueue(
                        candidate,
                        reason: "heartbeat timeout",
                        rejected: false
                    )
                    return
                }
                _ = self.scheduleRecoveryReconnectOnQueue(
                    after: 0,
                    generation: self.reconnectRoute?.generation ?? generation
                )
                self.onHeartbeatTimeout?(generation)
                return
            }
            if writer.enqueueOnQueue(
                .heartbeat,
                connection: connection,
                generation: generation,
                secure: true,
                completion: nil
            ) != .sent {
                connection.cancel()
                self.stopHeartbeatOnQueue()
            }
        }
        source.resume()
        heartbeatSource = source
    }

    func markControlActivityOnQueue() {
        guard controlTrafficAdmitted, heartbeatConnection != nil else { return }
        heartbeatState.markActivity()
    }

    /// Refresh liveness only for the exact connection and generation that
    /// owns the active heartbeat. A delayed callback from a replaced socket
    /// cannot extend its successor's timeout.
    func markControlActivityOnQueue(connection: NWConnection, generation: Int) {
        guard controlTrafficAdmitted,
              activeControlConnection === connection,
              activeControlGeneration == generation,
              heartbeatConnection === connection,
              heartbeatGeneration == generation else { return }
        heartbeatState.markActivity()
    }

    func isControlConnectionCurrent(connection: NWConnection, generation: Int) -> Bool {
        onQueue {
            activeControlConnection === connection && activeControlGeneration == generation
        }
    }

    func stopHeartbeat() {
        onQueue {
            stopHeartbeatOnQueue()
        }
    }

    func stopHeartbeatOnQueue() {
        heartbeatSource?.cancel()
        heartbeatSource = nil
        heartbeatConnection = nil
        controlTrafficAdmitted = false
        heartbeatState.reset()
    }

    @discardableResult
    func scheduleReconnect(after delay: TimeInterval, attempt: Int, generation: Int = 0) -> Bool {
        onQueue {
            scheduleReconnectOnQueue(after: delay, attempt: attempt, generation: generation)
        }
    }

    /// Schedules recovery from a Network.framework callback without asking the
    /// MainActor to make the timing decision first.
    @discardableResult
    func scheduleRecoveryReconnect(after delay: TimeInterval, generation: Int) -> Int? {
        onQueue {
            scheduleRecoveryReconnectOnQueue(after: delay, generation: generation)
        }
    }

    func cancelReconnect() {
        onQueue {
            reconnectSource?.cancel()
            reconnectSource = nil
            stopPendingReconnectTimeoutOnQueue()
            reconnectAttempt = 0
            reconnectGeneration = 0
            pendingReconnectConnection?.cancel()
            pendingReconnectConnection = nil
        }
    }

    func setControlReconnectRoute(
        endpoint: NWEndpoint,
        parameters: NWParameters,
        interface: BoothNetworkInterfacePolicy,
        provenance: BoothRouteCandidateProvenance,
        generation: Int
    ) {
        onQueue {
            if reconnectRoute?.endpoint != endpoint || reconnectRoute?.generation != generation {
                cancelReconnectOnQueue()
            }
            reconnectRoute = ControlReconnectRoute(
                endpoint: endpoint,
                parameters: parameters,
                interface: interface,
                provenance: provenance,
                generation: generation
            )
        }
    }

    func clearControlReconnectRoute() {
        onQueue {
            stopTrustedRouteDiscoveryOnQueue()
            cancelReconnectOnQueue()
            reconnectRoute = nil
        }
    }

    func updateTrustedPeerIDs(_ peerIDs: Set<String>) {
        onQueue {
            trustedPeerIDs = peerIDs
        }
    }

    func recordAuthenticatedPeer(_ peerID: String, endpoint: NWEndpoint) {
        onQueue {
            let key = Self.endpointKey(for: endpoint)
            var endpoints = authenticatedEndpointsByPeerID[peerID, default: []]
            endpoints.insert(key)
            authenticatedEndpointsByPeerID[peerID] = Set(endpoints.sorted().suffix(8))
            admissionLimiter.recordSuccess(endpointKey: key)
            admissionLimiter.recordIdentityProbeSuccess(peerID: peerID)
            if activeControlConnection?.endpoint == endpoint {
                activeControlIsIdentityProbe = false
                activeIdentityProbePeerID = nil
            }
        }
    }

    func acceptIdentityProbeClaim(
        _ peerID: String,
        connection: NWConnection,
        generation: Int
    ) -> Bool {
        onQueue {
            let candidate = protocolCandidates[ObjectIdentifier(connection)]
            let isProbe: Bool
            if identityProbeConnection === connection,
               identityProbeAdmission?.generation == generation {
                isProbe = true
            } else if activeControlConnection === connection,
                      activeControlGeneration == generation {
                isProbe = activeControlIsIdentityProbe
            } else {
                return false
            }
            guard candidate == nil || candidate?.generation == generation else { return false }
            guard isProbe || candidate?.admission?.isPreferredCandidate == true else { return true }
            // A claimed ID may select its failure budget, but cannot veto its
            // own HMAC attempt: an attacker could otherwise cooldown a real
            // peer by repeatedly spoofing its identifier.
            activeIdentityProbePeerID = peerID
            let decision = admissionLimiter.shouldAdmitIdentityProbe(
                peerID: peerID,
                trustedPeerIDs: trustedPeerIDs
            )
            candidate?.isIdentityProbeCoolingDown = !decision.admitted
                || admissionLimiter.isIdentityProbeCoolingDown()
            return true
        }
    }

    func admitInboundControlConnection(
        _ connection: NWConnection,
        preferredCandidateHint: Bool = false,
        adoptionTimeout: TimeInterval = 10
    ) -> InboundControlAdmissionResult {
        onQueue {
            let key = Self.endpointKey(for: connection.endpoint)
            let isPreferred = isPreferredEndpoint(key) || preferredCandidateHint
            let check = admissionLimiter.shouldAdmit(
                endpointKey: key,
                isPreferredCandidate: isPreferred
            )
            // Cooldown rejects must fall through the separately bounded
            // proof lane so a trusted device is never identified by IP alone.
            let requiresIdentityProbe = !check.admitted
            if let active = activeControlConnection {
                switch active.state {
                case .cancelled, .failed:
                    clearControlSlotOnQueue(connection: active)
                default:
                    if activeControlAuthenticated {
                        connection.cancel()
                        return InboundControlAdmissionResult(
                            admission: nil,
                            rejectionReason: "An authenticated control connection is already active."
                        )
                    }
                    if isPreferred {
                        recordAdmissionFailureOnQueue(active.endpoint)
                        active.cancel()
                        clearControlSlotOnQueue(connection: active)
                    } else {
                        return makeInboundAdmissionOnQueue(
                            connection,
                            endpointKey: key,
                            preferred: false,
                            identityProbe: true,
                            adoptionTimeout: adoptionTimeout
                        )
                    }
                }
            }
            // A source or claimed-endpoint cooldown must not close the only
            // path for a trusted device whose DHCP address is new to this
            // process. Keep it in the bounded probe lane, where the stored
            // secret HMAC remains the only authority that can grant trust.
            let isIdentityProbe = requiresIdentityProbe
            return makeInboundAdmissionOnQueue(
                connection,
                endpointKey: key,
                preferred: isPreferred,
                identityProbe: isIdentityProbe,
                adoptionTimeout: adoptionTimeout
            )
        }
    }

    func admissionLaneSnapshot() -> AdmissionLaneSnapshot {
        onQueue {
            AdmissionLaneSnapshot(
                normalCandidatePresent: activeControlConnection != nil,
                identityProbePresent: identityProbeConnection != nil
            )
        }
    }

    func identityProbeCooldownIsActive() -> Bool {
        onQueue { admissionLimiter.isIdentityProbeCoolingDown() }
    }

    private func makeInboundAdmissionOnQueue(
        _ connection: NWConnection,
        endpointKey: String,
        preferred: Bool,
        identityProbe: Bool,
        adoptionTimeout: TimeInterval
    ) -> InboundControlAdmissionResult {
        if identityProbe && (identityProbeConnection != nil || identityProbeAdmission != nil) {
            connection.cancel()
            admissionLimiter.recordFailure(endpointKey: endpointKey)
            admissionLimiter.recordIdentityProbeAttemptFailure()
            shortenAnonymousIdentityProbeHelloDeadlineOnQueueIfCoolingDown()
            return InboundControlAdmissionResult(
                admission: nil,
                rejectionReason: "The trusted-identity probe slot is occupied."
            )
        }

        nextInboundAdmissionGeneration = max(nextInboundAdmissionGeneration, nextControlGeneration) &+ 1
        nextControlGeneration = nextInboundAdmissionGeneration
        let admission = InboundControlAdmission(
            token: UUID(),
            generation: nextInboundAdmissionGeneration,
            endpointKey: endpointKey,
            isPreferredCandidate: preferred,
            isIdentityProbe: identityProbe
        )
        if identityProbe {
            identityProbeAdmission = admission
            identityProbeConnection = connection
            startIdentityProbeAdmissionTimeoutOnQueue(
                connection: connection,
                admission: admission,
                timeout: min(5, max(1, adoptionTimeout))
            )
        } else {
            inboundAdmission = admission
            activeControlConnection = connection
            activeControlGeneration = admission.generation
            activeControlAuthenticated = false
            activeControlIsIdentityProbe = false
            activeIdentityProbePeerID = nil
            startInboundAdmissionTimeoutOnQueue(
                connection: connection,
                admission: admission,
                timeout: max(1, adoptionTimeout)
            )
        }
        return InboundControlAdmissionResult(
            admission: admission,
            rejectionReason: nil
        )
    }

    func startInboundControlConnection(
        _ connection: NWConnection,
        preferredCandidateHint: Bool = false,
        adoptionTimeout: TimeInterval = 10
    ) -> InboundControlAdmissionResult {
        onQueue {
            inboundControlConnectionsSeen &+= 1
            let result = admitInboundControlConnection(
                connection,
                preferredCandidateHint: preferredCandidateHint,
                adoptionTimeout: adoptionTimeout
            )
            guard let admission = result.admission else { return result }
            if localIdentity != nil {
                startAdmittedInboundConnectionOnQueue(connection, admission: admission)
            } else {
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    switch state {
                    case .failed, .cancelled:
                        self.controlConnectionEnded(connection)
                    default:
                        break
                    }
                }
            }
            if localIdentity == nil { connection.start(queue: queue) }
            return result
        }
    }

    func inboundControlConnectionCount() -> Int {
        onQueue { inboundControlConnectionsSeen }
    }

    func confirmInboundControlAdmission(
        _ admission: InboundControlAdmission,
        connection: NWConnection,
        generation: Int
    ) -> Bool {
        onQueue {
            if admission.isIdentityProbe {
                guard identityProbeAdmission?.token == admission.token,
                      identityProbeConnection === connection else { return false }
                stopIdentityProbeAdmissionTimeoutOnQueue()
                identityProbeAdmission = nil
                identityProbeConnection = nil
                // Pairing candidates never use the reserved lane.
                return false
            }
            guard inboundAdmission?.token == admission.token,
                  activeControlConnection === connection else { return false }
            stopInboundAdmissionTimeoutOnQueue()
            inboundAdmission = nil
            activeControlGeneration = generation
            return true
        }
    }

    func abandonInboundControlAdmission(_ admission: InboundControlAdmission, connection: NWConnection) {
        onQueue {
            if admission.isIdentityProbe {
                guard identityProbeAdmission?.token == admission.token,
                      identityProbeConnection === connection else { return }
                stopIdentityProbeAdmissionTimeoutOnQueue()
                identityProbeAdmission = nil
                admissionLimiter.recordFailure(endpointKey: admission.endpointKey)
                connection.cancel()
                clearProbeOnQueue(connection: connection)
                return
            }
            guard inboundAdmission?.token == admission.token,
                  activeControlConnection === connection else { return }
            stopInboundAdmissionTimeoutOnQueue()
            inboundAdmission = nil
            admissionLimiter.recordFailure(
                endpointKey: admission.endpointKey,
                isPreferredCandidate: admission.isPreferredCandidate
            )
            connection.cancel()
            clearControlSlotOnQueue(connection: connection)
        }
    }

    private func startAdmittedInboundConnectionOnQueue(
        _ connection: NWConnection,
        admission: InboundControlAdmission
    ) {
        let lane: AdmissionLane = admission.isIdentityProbe ? .identityProbe : .normal
        startTrustedHandshakeOnQueue(connection: connection, admission: admission, lane: lane)
        connection.start(queue: queue)
    }

    func controlConnectionEnded(_ connection: NWConnection, generation: Int? = nil) {
        onQueue {
            if identityProbeConnection === connection,
               generation == nil || protocolCandidates[ObjectIdentifier(connection)]?.generation == generation {
                if let candidate = protocolCandidates[ObjectIdentifier(connection)] {
                    self.finishTrustedCandidateOnQueue(candidate, reason: nil, rejected: false)
                } else {
                    self.clearProbeOnQueue(connection: connection)
                }
                return
            }
            guard activeControlConnection === connection,
                  generation == nil || activeControlGeneration == generation else { return }
            if !activeControlAuthenticated {
                if let admission = inboundAdmission,
                   admission.generation == generation {
                    admissionLimiter.recordFailure(
                        endpointKey: admission.endpointKey,
                        isPreferredCandidate: admission.isPreferredCandidate
                    )
                } else {
                    recordAdmissionFailureOnQueue(connection.endpoint)
                }
            }
            clearControlSlotOnQueue(connection: connection)
        }
    }

    func isReconnectConnectionCurrent(_ connection: NWConnection, generation: Int) -> Bool {
        onQueue {
            guard reconnectGeneration == generation,
                  pendingReconnectConnection === connection else { return false }
            return true
        }
    }

    private func cancelReconnectOnQueue() {
        reconnectSource?.cancel()
        reconnectSource = nil
        stopPendingReconnectTimeoutOnQueue()
        reconnectAttempt = 0
        reconnectGeneration = 0
        pendingReconnectConnection?.cancel()
        pendingReconnectConnection = nil
    }

    private func stopPendingReconnectTimeoutOnQueue() {
        pendingReconnectTimeoutSource?.cancel()
        pendingReconnectTimeoutSource = nil
    }

    private func startInboundAdmissionTimeoutOnQueue(
        connection: NWConnection,
        admission: InboundControlAdmission,
        timeout: TimeInterval
    ) {
        stopInboundAdmissionTimeoutOnQueue()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.inboundAdmission?.token == admission.token,
                  self.activeControlConnection === connection else { return }
            self.admissionLimiter.recordFailure(
                endpointKey: admission.endpointKey,
                isPreferredCandidate: admission.isPreferredCandidate
            )
            connection.cancel()
            self.inboundAdmission = nil
            self.clearControlSlotOnQueue(connection: connection)
            self.onPreAuthTimeout?(connection, admission.generation, "Control connection was not adopted before its admission deadline.")
        }
        inboundAdmissionSource = source
        source.resume()
    }

    private func startIdentityProbeAdmissionTimeoutOnQueue(
        connection: NWConnection,
        admission: InboundControlAdmission,
        timeout: TimeInterval
    ) {
        stopIdentityProbeAdmissionTimeoutOnQueue()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.identityProbeAdmission?.token == admission.token,
                  self.identityProbeConnection === connection else { return }
            self.admissionLimiter.recordFailure(endpointKey: admission.endpointKey)
            self.admissionLimiter.recordIdentityProbeAttemptFailure()
            connection.cancel()
            self.controlCoreEvent?(.rejected(
                generation: admission.generation,
                reason: "Trusted-identity probe admission deadline expired."
            ))
            self.clearProbeOnQueue(connection: connection)
        }
        identityProbeAdmissionSource = source
        source.resume()
    }

    private func stopInboundAdmissionTimeoutOnQueue() {
        inboundAdmissionSource?.cancel()
        inboundAdmissionSource = nil
    }

    private func stopIdentityProbeAdmissionTimeoutOnQueue() {
        identityProbeAdmissionSource?.cancel()
        identityProbeAdmissionSource = nil
    }

    private func clearControlSlotOnQueue(connection: NWConnection) {
        guard activeControlConnection === connection else { return }
        if let candidate = protocolCandidates.removeValue(forKey: ObjectIdentifier(connection)) {
            candidate.timeout?.cancel()
            candidate.timeout = nil
        }
        if heartbeatConnection === connection { stopHeartbeatOnQueue() }
        if activeControlIsIdentityProbe { recordIdentityProbeFailureOnQueue() }
        stopInboundAdmissionTimeoutOnQueue()
        if inboundAdmission?.token != nil,
           inboundAdmission?.generation == activeControlGeneration {
            inboundAdmission = nil
        }
        activeControlConnection = nil
        activeControlAuthenticated = false
        activeControlIsIdentityProbe = false
        activeIdentityProbePeerID = nil
        controlWriter?.invalidate(generation: activeControlGeneration)
        stopPreAuthWatchdogOnQueue()
        if pendingReconnectConnection === connection {
            pendingReconnectConnection = nil
            stopPendingReconnectTimeoutOnQueue()
        }
    }

    private func recordIdentityProbeFailureOnQueue() {
        guard !activeControlAuthenticated,
              let peerID = activeIdentityProbePeerID else { return }
        admissionLimiter.recordIdentityProbeFailure(
            peerID: peerID,
            trustedPeerIDs: trustedPeerIDs
        )
    }

    private func recordAdmissionFailureOnQueue(_ endpoint: NWEndpoint) {
        let key = Self.endpointKey(for: endpoint)
        admissionLimiter.recordFailure(
            endpointKey: key,
            isPreferredCandidate: isPreferredEndpoint(key)
        )
    }

    private func isPreferredEndpoint(_ key: String) -> Bool {
        trustedPeerIDs.contains { authenticatedEndpointsByPeerID[$0]?.contains(key) == true }
    }

    private static func endpointKey(for endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return endpoint.debugDescription
        }
    }

    private func onQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return operation()
        }
        return queue.sync(execute: operation)
    }

    @discardableResult
    private func scheduleRecoveryReconnectOnQueue(
        after delay: TimeInterval,
        generation: Int
    ) -> Int? {
        let attempt = reconnectAttempt + 1
        guard scheduleReconnectOnQueue(
            after: delay,
            attempt: attempt,
            generation: generation
        ) else { return nil }
        return attempt
    }

    @discardableResult
    private func scheduleReconnectOnQueue(
        after delay: TimeInterval,
        attempt: Int,
        generation: Int
    ) -> Bool {
        guard reconnectSource == nil, pendingReconnectConnection == nil else { return false }
        reconnectAttempt = attempt
        reconnectGeneration = generation
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.reconnectSource = nil
            self.beginReconnectOnQueue()
        }
        reconnectSource = source
        source.resume()
        return true
    }

    private func beginReconnectOnQueue() {
        guard reconnectAttempt <= 5 else {
            if restartTrustedRouteDiscoveryAfterCachedRetriesOnQueue() { return }
            onReconnectDue?(reconnectAttempt, reconnectGeneration)
            return
        }
        guard let route = reconnectRoute,
              route.generation == reconnectGeneration else {
            if restartTrustedRouteDiscoveryAfterCachedRetriesOnQueue() { return }
            onReconnectDue?(reconnectAttempt, reconnectGeneration)
            return
        }

        if let peerID = selectedPeerID,
           trustedSecrets[peerID] != nil,
           localIdentity?.role == .iPad {
            beginTrustedConnectionOnQueue(
                endpoint: route.endpoint,
                parameters: route.parameters,
                interface: route.interface,
                provenance: route.provenance,
                routeGeneration: route.generation
            )
            return
        }

        let connection = NWConnection(to: route.endpoint, using: route.parameters)
        pendingReconnectConnection = connection
        let attempt = reconnectAttempt
        let generation = reconnectGeneration
        let timeoutSource = DispatchSource.makeTimerSource(queue: queue)
        timeoutSource.schedule(deadline: .now() + 10)
        timeoutSource.setEventHandler { [weak self, weak connection] in
            guard let self, let connection,
                  self.pendingReconnectConnection === connection,
                  self.reconnectGeneration == generation else { return }
            self.pendingReconnectConnection = nil
            self.stopPendingReconnectTimeoutOnQueue()
            connection.cancel()
            self.retryOrFinishReconnectOnQueue(attempt: attempt, generation: generation)
        }
        pendingReconnectTimeoutSource = timeoutSource
        timeoutSource.resume()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                break
            default:
                return
            }
            self.onQueue {
                guard self.pendingReconnectConnection === connection,
                      self.reconnectGeneration == generation else { return }
                self.pendingReconnectConnection = nil
                self.stopPendingReconnectTimeoutOnQueue()
                connection.cancel()
                self.retryOrFinishReconnectOnQueue(attempt: attempt, generation: generation)
            }
        }
        connection.start(queue: queue)
        onReconnectConnectionStarted?(
            connection,
            route.endpoint,
            route.parameters,
            route.interface,
            route.provenance,
            attempt,
            generation
        )
    }

    private func retryOrFinishReconnectOnQueue(attempt: Int, generation: Int) {
        if attempt < 5 {
            _ = scheduleReconnectOnQueue(
                after: [0.5, 1, 2, 4, 5][min(attempt, 4)],
                attempt: attempt + 1,
                generation: generation
            )
        } else {
            reconnectAttempt = attempt
            reconnectGeneration = generation
            if !restartTrustedRouteDiscoveryAfterCachedRetriesOnQueue() {
                onReconnectDue?(attempt, generation)
            }
        }
    }

    /// A trusted iPad owns its reconnect discovery. Once the cached Bonjour
    /// endpoint stops working, refresh discovery on this queue so a blocked
    /// MainActor cannot transfer socket ownership back to the facade.
    private func restartTrustedRouteDiscoveryAfterCachedRetriesOnQueue() -> Bool {
        guard localIdentity?.role == .iPad,
              let peerID = selectedPeerID,
              trustedSecrets[peerID] != nil,
              coreRouteGeneration == reconnectGeneration else { return false }
        reconnectAttempt = 0
        corePendingRoute = nil
        coreRouteSelection.reset()
        coreRouteFallbackSource?.cancel()
        coreRouteFallbackSource = nil
        stopTrustedRouteBrowsersOnQueue()
        startTrustedRouteBrowsersOnQueue(
            preference: localNetworkPreference,
            generation: coreRouteGeneration
        )
        return true
    }


    // MARK: - Control Connection Slot Ownership (Finding A03)

    func bindControlConnection(
        _ connection: NWConnection,
        generation: Int,
        authenticated: Bool = false
    ) {
        onQueue {
            if pendingReconnectConnection === connection {
                pendingReconnectConnection = nil
                stopPendingReconnectTimeoutOnQueue()
            }
            if activeControlConnection !== connection {
                activeControlIsIdentityProbe = false
                activeIdentityProbePeerID = nil
            }
            activeControlConnection = connection
            activeControlGeneration = generation
            activeControlAuthenticated = authenticated
        }
    }

    func invalidateControlConnection(generation: Int) {
        onQueue {
            if activeControlGeneration == generation {
                if let connection = activeControlConnection {
                    connection.cancel()
                    clearControlSlotOnQueue(connection: connection)
                    if let route = reconnectRoute,
                       localIdentity?.role == .iPad,
                       selectedPeerID.flatMap({ trustedSecrets[$0] }) != nil {
                        _ = scheduleRecoveryReconnectOnQueue(
                            after: 0.5,
                            generation: route.generation
                        )
                    }
                } else {
                    recordIdentityProbeFailureOnQueue()
                    activeControlAuthenticated = false
                    activeControlIsIdentityProbe = false
                    activeIdentityProbePeerID = nil
                    stopInboundAdmissionTimeoutOnQueue()
                    inboundAdmission = nil
                    stopPreAuthWatchdogOnQueue()
                    stopHeartbeatOnQueue()
                    controlWriter?.invalidate(generation: generation)
                }
            }
        }
    }

    /// Fails the queue-owned connection for this generation when UI event
    /// delivery overflows. Stale overflow notifications cannot affect a newer
    /// generation.
    func failControlCoreConnection(generation: Int, reason: String) {
        onQueue {
            if let candidate = protocolCandidates.values.first(where: { $0.generation == generation }) {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: generation,
                    reason: reason
                )
                return
            }
            guard activeControlGeneration == generation,
                  let connection = activeControlConnection else { return }
            connection.cancel()
            stopHeartbeatOnQueue()
            clearControlSlotOnQueue(connection: connection)
            controlCoreEvent?(.disconnected(generation: generation, reason: reason))
        }
    }

    /// Queues output through the writer already bound by the core. The
    /// MainActor caller supplies only a generation; the socket reference
    /// remains inside this queue-owned runtime.
    @discardableResult
    func enqueueAuthenticatedControl(
        _ message: Message,
        generation: Int,
        secure: Bool,
        completion: (@MainActor (BoothControlSendOutcome) -> Void)?
    ) -> BoothControlSendOutcome {
        onQueue {
            guard activeControlGeneration == generation,
                  activeControlAuthenticated,
                  let connection = activeControlConnection,
                  let controlWriter else {
                if let completion {
                    Task { @MainActor in completion(.noConnection) }
                }
                return .noConnection
            }
            return controlWriter.enqueueOnQueue(
                message,
                connection: connection,
                generation: generation,
                secure: secure,
                completion: completion
            )
        }
    }

    func isControlConnectionAuthenticated(generation: Int) -> Bool {
        onQueue {
            activeControlGeneration == generation
                && activeControlAuthenticated
                && activeControlConnection != nil
        }
    }

    func isControlConnectionActive(generation: Int) -> Bool {
        onQueue {
            guard activeControlGeneration == generation,
                  let connection = activeControlConnection else { return false }
            switch connection.state {
            case .cancelled, .failed:
                return false
            default:
                return true
            }
        }
    }

    func isControlSlotAvailable() -> Bool {
        onQueue {
            guard let active = activeControlConnection else { return true }
            switch active.state {
            case .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Pre-Auth Watchdog Ownership (Finding A03)

    func startPreAuthWatchdog(
        connection: NWConnection,
        generation: Int,
        watchdog: BoothPreAuthWatchdog
    ) {
        onQueue {
            startPreAuthWatchdogOnQueue(
                connection: connection,
                generation: generation,
                watchdog: watchdog
            )
        }
    }

    func startPreAuthWatchdogOnQueue(
        connection: NWConnection,
        generation: Int,
        watchdog: BoothPreAuthWatchdog
    ) {
        stopPreAuthWatchdogOnQueue()
        preAuthConnection = connection
        preAuthGeneration = generation
        preAuthWatchdog = watchdog
        schedulePreAuthWatchdogTickOnQueue(connection: connection, generation: generation, watchdog: watchdog)
    }

    func reschedulePreAuthWatchdog() {
        onQueue {
            guard let connection = preAuthConnection,
                  let watchdog = preAuthWatchdog else { return }
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
        }
    }

    private func schedulePreAuthWatchdogTickOnQueue(
        connection: NWConnection,
        generation: Int,
        watchdog: BoothPreAuthWatchdog
    ) {
        preAuthSource?.cancel()
        preAuthSource = nil
        guard preAuthConnection === connection,
              preAuthGeneration == generation,
              let nextDeadline = watchdog.nextDeadline() else { return }

        let delay = max(0.05, nextDeadline.timeIntervalSinceNow)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + delay)
        source.setEventHandler { [weak self, weak connection] in
            guard let self, let connection else { return }
            guard self.preAuthConnection === connection,
                  self.preAuthGeneration == generation,
                  let watchdog = self.preAuthWatchdog else { return }

            if let reason = watchdog.checkTimeout() {
                // Immediate cancellation directly on transport queue!
                // Does NOT require MainActor progress!
                connection.cancel()
                self.stopPreAuthWatchdogOnQueue()
                if self.activeControlConnection === connection {
                    self.recordAdmissionFailureOnQueue(connection.endpoint)
                    self.activeControlConnection = nil
                    self.activeControlAuthenticated = false
                }
                self.onPreAuthTimeout?(connection, generation, reason)
            } else {
                self.schedulePreAuthWatchdogTickOnQueue(
                    connection: connection,
                    generation: generation,
                    watchdog: watchdog
                )
            }
        }
        source.resume()
        preAuthSource = source
    }

    func stopPreAuthWatchdog() {
        onQueue {
            stopPreAuthWatchdogOnQueue()
        }
    }

    func stopPreAuthWatchdogOnQueue() {
        preAuthSource?.cancel()
        preAuthSource = nil
        preAuthConnection = nil
        preAuthWatchdog = nil
    }

    @discardableResult
    func advancePreAuthWatchdog(
        after decision: BoothPairingIntentPolicy.Decision,
        now: Date = Date()
    ) -> Bool {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return false }
            guard BoothPreAuthProgressPolicy.advance(watchdog, after: decision, now: now) else {
                return false
            }
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
            return true
        }
    }

    @discardableResult
    func advancePreAuthWatchdog(
        after result: BoothPairingAttemptResult,
        now: Date = Date()
    ) -> Bool {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return false }
            guard BoothPreAuthProgressPolicy.advance(watchdog, after: result, now: now) else {
                return false
            }
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
            return true
        }
    }

    func onPreAuthPairingStarted(absoluteExpiry: Date, now: Date = Date()) -> Bool {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return false }
            let success = watchdog.onPairingSessionStarted(absoluteExpiry: absoluteExpiry, now: now)
            if success {
                schedulePreAuthWatchdogTickOnQueue(
                    connection: connection,
                    generation: preAuthGeneration,
                    watchdog: watchdog
                )
            }
            return success
        }
    }

    func onPreAuthAuthenticationStarted(now: Date = Date()) {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return }
            watchdog.onAuthenticationStarted(now: now)
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
        }
    }

    func onPreAuthSecureNegotiationStarted(now: Date = Date()) {
        onQueue {
            guard let watchdog = preAuthWatchdog,
                  let connection = preAuthConnection else { return }
            watchdog.onSecureNegotiationStarted(now: now)
            schedulePreAuthWatchdogTickOnQueue(
                connection: connection,
                generation: preAuthGeneration,
                watchdog: watchdog
            )
        }
    }

    func onPreAuthAuthenticated() {
        onQueue {
            preAuthWatchdog?.onAuthenticated()
            stopPreAuthWatchdogOnQueue()
            activeControlAuthenticated = true
            reconnectAttempt = 0
            pendingReconnectConnection = nil
        }
    }
}
