import Foundation
import Network

/// Queue-owned transport authority. Every mutable field, Network object, and
/// protocol candidate is accessed only on `queue`; public methods synchronously
/// enter that queue and callbacks re-enter it before changing state. The
/// `@unchecked Sendable` conformance is limited to this explicit serialization
/// boundary. MainActor consumes immutable events and owns presentation only.
final class BoothNetworkTransportRuntime: @unchecked Sendable {
    /// Trusted connection events carry a generation and values only. The
    /// pairingCandidate case is a separate legacy handoff for an untrusted
    /// pairing flow; that socket/decoder transfer remains a migration gap.
    enum ControlCoreEvent: Sendable {
        case pairingCandidate(
            connection: NWConnection,
            admission: InboundControlAdmission,
            hello: BoothTransportHello,
            decoder: BoothTransportFrameDecoder,
            bufferedFrames: [BoothDecodedTransportFrame]
        )
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
        case disconnected(generation: Int, reason: String?)
        case rejected(generation: Int, reason: String)
        case listenerReady(generation: Int, port: NWEndpoint.Port?)
        case listenerFailed(generation: Int, reason: String)
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
        var secureNegotiator: BoothSecureChannelNegotiator
        var localSecureHello: BoothSecureChannelHello?
        var peerSecureHello: BoothSecureChannelHello?
        var readySent = false
        var readyReceived = false
        var isTrusted = false
        var isIdentityProbeCoolingDown = false
        var authenticated = false
        var claimedTrustedPeerID: String?

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

    /// A single FIFO waiter protects a trusted reconnect from one socket that
    /// currently occupies the probe lane. It remains queue-owned and does not
    /// start receiving until promoted.
    private final class QueuedIdentityProbe {
        let connection: NWConnection
        let admission: InboundControlAdmission
        var timeout: DispatchSourceTimer?

        init(connection: NWConnection, admission: InboundControlAdmission) {
            self.connection = connection
            self.admission = admission
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
        let isQueuedProbe: Bool

        init(
            admission: InboundControlAdmission?,
            rejectionReason: String?,
            isQueuedProbe: Bool = false
        ) {
            self.admission = admission
            self.rejectionReason = rejectionReason
            self.isQueuedProbe = isQueuedProbe
        }
    }

    struct AdmissionLaneSnapshot: Sendable, Equatable {
        let normalCandidatePresent: Bool
        let identityProbePresent: Bool
        let queuedIdentityProbePresent: Bool
    }

    private struct ControlReconnectRoute {
        let endpoint: NWEndpoint
        let parameters: NWParameters
        let interface: BoothNetworkInterfacePolicy
        let provenance: BoothRouteCandidateProvenance
        let generation: Int
    }

    private let queue: DispatchQueue
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
    private var queuedIdentityProbe: QueuedIdentityProbe?
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
    private var localIdentity: BoothDeviceIdentity?
    private var localNetworkPreference: BoothNetworkPreference = .wifi
    private var trustedSecrets: [String: Data] = [:]
    private var selectedPeerID: String?
    private var sharedSecureChannel: BoothSecureChannel?
    private var controlWriter: BoothControlWritePump?
    private var controlCoreEvent: (@Sendable (ControlCoreEvent) -> Void)?
    private var protocolCandidates: [ObjectIdentifier: TrustedHandshake] = [:]
    private var identityProbeConnection: NWConnection?
    private var coreControlListener: NWListener?
    private var coreControlListenerGeneration = 0
    private var coreRouteBrowsers: [String: NWBrowser] = [:]
    private var coreRouteGeneration = 0
    private var coreRouteSelection = BoothRouteDiscoverySelection()
    private var corePendingRoute: ControlReconnectRoute?
    private var coreRouteFallbackSource: DispatchSourceTimer?
    private var coreRouteRetrySource: DispatchSourceTimer?
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
        admissionLimiter: BoothPreAuthAdmissionLimiter = BoothPreAuthAdmissionLimiter()
    ) {
        self.queue = queue
        self.admissionLimiter = admissionLimiter
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

    func startControlListener(
        using parameters: NWParameters,
        port: NWEndpoint.Port?,
        service: NWListener.Service,
        generation: Int
    ) {
        onQueue {
            guard self.coreControlListener == nil else { return }
            self.coreControlListenerGeneration = generation
            let listener: NWListener
            do {
                if let port {
                    listener = try NWListener(using: parameters, on: port)
                } else {
                    listener = try NWListener(using: parameters)
                }
            } catch {
                self.controlCoreEvent?(.listenerFailed(generation: generation, reason: error.localizedDescription))
                return
            }
            listener.service = service
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    self.onQueue {
                        guard self.coreControlListener === listener,
                              self.coreControlListenerGeneration == generation else { return }
                        self.controlCoreEvent?(.listenerReady(generation: generation, port: listener.port))
                    }
                case .failed(let error):
                    self.onQueue {
                        guard self.coreControlListener === listener,
                              self.coreControlListenerGeneration == generation else { return }
                        self.coreControlListener = nil
                        self.controlCoreEvent?(.listenerFailed(generation: generation, reason: error.localizedDescription))
                    }
                case .cancelled:
                    self.onQueue {
                        if self.coreControlListener === listener { self.coreControlListener = nil }
                    }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                _ = self.startInboundControlConnection(connection)
            }
            self.coreControlListener = listener
            listener.start(queue: self.queue)
        }
    }

    func updateControlListenerService(_ service: NWListener.Service) {
        onQueue { self.coreControlListener?.service = service }
    }

    func stopControlListener() {
        onQueue {
            self.coreControlListenerGeneration &+= 1
            self.coreControlListener?.cancel()
            self.coreControlListener = nil
        }
    }

    /// Invalidates every core-owned callback before releasing sockets, so a
    /// stale listener or reconnect cannot affect a later route generation.
    func stopControlCore() {
        onQueue {
            self.nextControlGeneration &+= 1
            self.coreRouteGeneration &+= 1
            self.stopTrustedRouteDiscoveryOnQueue()
            self.coreControlListenerGeneration &+= 1
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
            self.cancelQueuedIdentityProbeOnQueue(recordFailure: false)
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
        }
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
            let browserParameters = parameters
            let key = "\(generation):\(interface.rawValue):\(compatibility)"
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: "_prc-control._tcp", domain: nil),
                using: browserParameters
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
                        parameters: browserParameters,
                        generation: generation
                    )
                }
            }
            browser.stateUpdateHandler = { [weak self, weak browser] state in
                guard let self, let browser, case .failed = state else { return }
                self.onQueue {
                    guard self.coreRouteBrowsers[key] === browser else { return }
                    self.coreRouteBrowsers.removeValue(forKey: key)
                    if self.coreRouteBrowsers.isEmpty {
                        self.scheduleCoreRouteRetryOnQueue(generation: generation)
                    }
                }
            }
            coreRouteBrowsers[key] = browser
            browser.start(queue: queue)
        }
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

    private func scheduleCoreRouteRetryOnQueue(generation: Int) {
        guard coreRouteRetrySource == nil,
              !activeControlAuthenticated,
              selectedPeerID.flatMap({ trustedSecrets[$0] }) != nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1.0)
        source.setEventHandler { [weak self] in
            guard let self, self.coreRouteGeneration == generation,
                  !self.activeControlAuthenticated else { return }
            self.coreRouteRetrySource?.cancel()
            self.coreRouteRetrySource = nil
            self.coreRouteSelection.reset()
            self.startTrustedRouteBrowsersOnQueue(
                preference: self.localNetworkPreference,
                generation: generation
            )
        }
        coreRouteRetrySource = source
        source.resume()
    }

    private func stopTrustedRouteBrowsersOnQueue() {
        coreRouteBrowsers.values.forEach { $0.cancel() }
        coreRouteBrowsers.removeAll()
    }

    private func stopTrustedRouteDiscoveryOnQueue() {
        stopTrustedRouteBrowsersOnQueue()
        coreRouteFallbackSource?.cancel()
        coreRouteFallbackSource = nil
        coreRouteRetrySource?.cancel()
        coreRouteRetrySource = nil
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
                        let frames = try candidate.decoder.decode(
                            data,
                            channel: .control,
                            secureChannel: candidate.secureChannel
                        )
                        for (index, frame) in frames.enumerated() {
                            switch frame {
                            case .control(let message):
                                self.handleCoreMessageOnQueue(message, candidate: candidate)
                                if candidate.peerHello != nil, !candidate.isTrusted {
                                    guard let admission = candidate.admission else { return }
                                    let buffered = Array(frames.dropFirst(index + 1))
                                    candidate.timeout?.cancel()
                                    candidate.timeout = nil
                                    self.protocolCandidates.removeValue(forKey: ObjectIdentifier(connection))
                                    self.controlCoreEvent?(.pairingCandidate(
                                        connection: connection,
                                        admission: admission,
                                        hello: candidate.peerHello!,
                                        decoder: candidate.decoder,
                                        bufferedFrames: buffered
                                    ))
                                    return
                                }
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
                        self.rejectTrustedCandidateOnQueue(
                            connection,
                            generation: candidate.generation,
                            reason: "Invalid control frame: \(error.localizedDescription)"
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
        guard let secret = trustedSecrets[hello.deviceID] else {
            guard candidate.lane == .normal,
                  let admission = candidate.admission else {
                rejectTrustedCandidateOnQueue(
                    candidate.connection,
                    generation: candidate.generation,
                    reason: "Identity probe did not claim a trusted peer."
                )
                return
            }
            candidate.peerHello = hello
            candidate.timeout?.cancel()
            candidate.timeout = nil
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
              let secret = trustedSecrets[peer.deviceID] else {
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
              let secret = trustedSecrets[peer.deviceID],
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
              let peer = candidate.peerHello,
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
        guard let localHello = candidate.secureNegotiator.localHello,
              let peerHello = candidate.secureNegotiator.peerHello,
              let peerID = candidate.peerHello?.deviceID,
              let secret = trustedSecrets[peerID] else { throw BoothSecureChannelError.invalidHello }
        try candidate.secureChannel.configure(secret: secret, localHello: localHello, peerHello: peerHello)
        let macHello = localHello.senderRole == .mac ? localHello : peerHello
        let iPadHello = localHello.senderRole == .iPad ? localHello : peerHello
        let proof = BoothSecureChannel.readyProof(
            secret: secret,
            macHello: macHello,
            iPadHello: iPadHello,
            senderRole: localHello.senderRole
        )
        sendCoreMessageOnQueue(
            .secureChannelReady(sessionID: localHello.sessionID, proof: proof),
            candidate: candidate
        )
        try candidate.secureNegotiator.markReadySent(generation: candidate.generation)
        candidate.readySent = true
    }

    private func handleCoreSecureReadyOnQueue(
        sessionID: String,
        proof: Data,
        candidate: TrustedHandshake
    ) {
        guard let localHello = candidate.secureNegotiator.localHello,
              let peerHello = candidate.secureNegotiator.peerHello,
              sessionID == localHello.sessionID,
              sessionID == peerHello.sessionID,
              let peerID = candidate.peerHello?.deviceID,
              let secret = trustedSecrets[peerID] else {
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
            _ = try candidate.secureNegotiator.receiveReady(
                sessionID: sessionID,
                generation: candidate.generation
            )
            candidate.readyReceived = true
            guard candidate.readySent,
              candidate.secureChannel.isConfigured else { return }
            try candidate.secureNegotiator.markEstablished(generation: candidate.generation)
            candidate.decoder.setHandshakeComplete(true, channel: .control)
            promoteCoreCandidateOnQueue(candidate)
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Secure-channel confirmation was invalid."
            )
        }
    }

    private func promoteCoreCandidateOnQueue(_ candidate: TrustedHandshake) {
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
            cancelQueuedIdentityProbeOnQueue(recordFailure: false)
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
        guard let secret = trustedSecrets[peer.deviceID],
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
            cancelQueuedIdentityProbeOnQueue(recordFailure: false)
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

    private func sendCoreMessageOnQueue(_ message: Message, candidate: TrustedHandshake) {
        do {
            let payload = try message.encoded()
            let frame = try BoothFrameEncoder.encode(channel: .control, payload: payload)
            let generation = candidate.generation
            candidate.connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection = candidate.connection] error in
                guard let self, let connection, let error else { return }
                self.onQueue {
                    guard self.isCurrentCandidateOnQueue(connection, generation: generation) else { return }
                    self.rejectTrustedCandidateOnQueue(
                        connection,
                        generation: generation,
                        reason: "Control handshake send failed: \(error.localizedDescription)"
                    )
                }
            })
        } catch {
            rejectTrustedCandidateOnQueue(
                candidate.connection,
                generation: candidate.generation,
                reason: "Control handshake encoding failed."
            )
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

    private func isCurrentCandidateOnQueue(_ connection: NWConnection, generation: Int) -> Bool {
        guard let candidate = protocolCandidates[ObjectIdentifier(connection)],
              candidate.generation == generation else { return false }
        return true
    }

    private func candidateOnQueue(_ connection: NWConnection, generation: Int) -> TrustedHandshake? {
        guard let candidate = protocolCandidates[ObjectIdentifier(connection)],
              candidate.generation == generation else { return nil }
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
            if let peerID = candidate.claimedTrustedPeerID {
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
            clearProbeOnQueue(connection: candidate.connection)
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

    private func clearProbeOnQueue(connection: NWConnection) {
        guard identityProbeConnection === connection else { return }
        stopIdentityProbeAdmissionTimeoutOnQueue()
        identityProbeAdmission = nil
        identityProbeConnection = nil
        if let candidate = protocolCandidates.removeValue(forKey: ObjectIdentifier(connection)) {
            candidate.timeout?.cancel()
        }
        if let peerID = activeIdentityProbePeerID {
            admissionLimiter.recordIdentityProbeFailure(peerID: peerID, trustedPeerIDs: trustedPeerIDs)
        }
        activeIdentityProbePeerID = nil
        promoteQueuedIdentityProbeOnQueue()
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
            // The claimed ID only selects its own retry budget. The transport
            // still requires the existing stored-secret HMAC before trust.
            activeIdentityProbePeerID = peerID
            return admissionLimiter.shouldAdmitIdentityProbe(
                peerID: peerID,
                trustedPeerIDs: trustedPeerIDs
            ).admitted
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
                        guard check.admitted || check.globalLimitReached else {
                            connection.cancel()
                            return InboundControlAdmissionResult(
                                admission: nil,
                                rejectionReason: check.reason ?? "Pre-authentication candidate was throttled."
                            )
                        }
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
            let isIdentityProbe = !check.admitted && !isPreferred && check.globalLimitReached
            guard check.admitted || isIdentityProbe else {
                connection.cancel()
                return InboundControlAdmissionResult(admission: nil, rejectionReason: check.reason)
            }
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
                identityProbePresent: identityProbeConnection != nil,
                queuedIdentityProbePresent: queuedIdentityProbe != nil
            )
        }
    }

    private func makeInboundAdmissionOnQueue(
        _ connection: NWConnection,
        endpointKey: String,
        preferred: Bool,
        identityProbe: Bool,
        adoptionTimeout: TimeInterval
    ) -> InboundControlAdmissionResult {
        nextInboundAdmissionGeneration = max(nextInboundAdmissionGeneration, nextControlGeneration) &+ 1
        nextControlGeneration = nextInboundAdmissionGeneration
        let admission = InboundControlAdmission(
            token: UUID(),
            generation: nextInboundAdmissionGeneration,
            endpointKey: endpointKey,
            isPreferredCandidate: preferred,
            isIdentityProbe: identityProbe
        )
        let isQueuedProbe = identityProbe
            && (identityProbeConnection != nil || identityProbeAdmission != nil)
        if identityProbe {
            if isQueuedProbe {
                guard queuedIdentityProbe == nil else {
                    connection.cancel()
                    admissionLimiter.recordFailure(endpointKey: endpointKey)
                    admissionLimiter.recordIdentityProbeAttemptFailure()
                    return InboundControlAdmissionResult(
                        admission: nil,
                        rejectionReason: "The trusted-identity probe waiter is occupied."
                    )
                }
                let queued = QueuedIdentityProbe(connection: connection, admission: admission)
                queuedIdentityProbe = queued
                startQueuedIdentityProbeTimeoutOnQueue(queued, timeout: min(10, max(1, adoptionTimeout)))
            } else {
                identityProbeAdmission = admission
                identityProbeConnection = connection
                startIdentityProbeAdmissionTimeoutOnQueue(
                    connection: connection,
                    admission: admission,
                    timeout: min(5, max(1, adoptionTimeout))
                )
            }
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
            rejectionReason: nil,
            isQueuedProbe: isQueuedProbe
        )
    }

    func startInboundControlConnection(
        _ connection: NWConnection,
        preferredCandidateHint: Bool = false,
        adoptionTimeout: TimeInterval = 10
    ) -> InboundControlAdmissionResult {
        onQueue {
            let result = admitInboundControlConnection(
                connection,
                preferredCandidateHint: preferredCandidateHint,
                adoptionTimeout: adoptionTimeout
            )
            guard let admission = result.admission else { return result }
            guard !result.isQueuedProbe else { return result }
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
                if queuedIdentityProbe?.admission.token == admission.token,
                   queuedIdentityProbe?.connection === connection {
                    cancelQueuedIdentityProbeOnQueue(recordFailure: true)
                    return
                }
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

    private func startQueuedIdentityProbeTimeoutOnQueue(
        _ queued: QueuedIdentityProbe,
        timeout: TimeInterval
    ) {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler { [weak self, weak queued] in
            guard let self, let queued,
                  self.queuedIdentityProbe === queued else { return }
            self.cancelQueuedIdentityProbeOnQueue(recordFailure: true)
        }
        queued.timeout = source
        source.resume()
    }

    private func cancelQueuedIdentityProbeOnQueue(recordFailure: Bool) {
        guard let queued = queuedIdentityProbe else { return }
        queuedIdentityProbe = nil
        queued.timeout?.cancel()
        queued.timeout = nil
        if recordFailure {
            admissionLimiter.recordFailure(endpointKey: queued.admission.endpointKey)
            admissionLimiter.recordIdentityProbeAttemptFailure()
        }
        queued.connection.cancel()
    }

    private func promoteQueuedIdentityProbeOnQueue() {
        guard identityProbeConnection == nil,
              identityProbeAdmission == nil,
              !activeControlAuthenticated,
              let queued = queuedIdentityProbe else { return }
        queuedIdentityProbe = nil
        queued.timeout?.cancel()
        queued.timeout = nil
        identityProbeAdmission = queued.admission
        identityProbeConnection = queued.connection
        startIdentityProbeAdmissionTimeoutOnQueue(
            connection: queued.connection,
            admission: queued.admission,
            timeout: 5
        )
        if localIdentity != nil {
            startAdmittedInboundConnectionOnQueue(queued.connection, admission: queued.admission)
        } else {
            queued.connection.stateUpdateHandler = { [weak self, weak connection = queued.connection] state in
                guard let self, let connection else { return }
                switch state {
                case .failed, .cancelled:
                    self.controlConnectionEnded(connection)
                default:
                    break
                }
            }
            queued.connection.start(queue: queue)
        }
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
        guard let route = reconnectRoute,
              route.generation == reconnectGeneration,
              reconnectAttempt <= 5 else {
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
            if let peerID = selectedPeerID,
               trustedSecrets[peerID] != nil,
               localIdentity?.role == .iPad {
                reconnectAttempt = 0
                coreRouteSelection.reset()
                startTrustedRouteBrowsersOnQueue(
                    preference: localNetworkPreference,
                    generation: coreRouteGeneration
                )
            } else {
                onReconnectDue?(attempt, generation)
            }
        }
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
