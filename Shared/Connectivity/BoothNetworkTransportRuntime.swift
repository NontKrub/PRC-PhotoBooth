import Foundation
import Network

/// Owns transport-timer decisions on the Network.framework queue. The
/// MainActor facade remains responsible for user-facing state and route
/// policy; socket cancellation and timer expiry do not depend on it.
final class BoothNetworkTransportRuntime: @unchecked Sendable {
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
    private var admissionLimiter = BoothPreAuthAdmissionLimiter()
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

    var onHeartbeatTimeout: (@Sendable (NWConnection, Int) -> Void)?
    var onReconnectDue: (@Sendable (Int, Int) -> Void)?
    var onReconnectConnectionStarted: (@Sendable (
        NWConnection,
        NWEndpoint,
        NWParameters,
        BoothNetworkInterfacePolicy,
        BoothRouteCandidateProvenance,
        Int,
        Int
    ) -> Void)?
    var onPreAuthTimeout: (@Sendable (NWConnection, Int, String) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
        queue.setSpecific(key: queueKey, value: ())
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
                _ = self.scheduleRecoveryReconnectOnQueue(
                    after: 0,
                    generation: generation
                )
                self.onHeartbeatTimeout?(connection, generation)
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
            guard activeControlConnection === connection,
                  activeControlGeneration == generation else { return false }
            guard activeControlIsIdentityProbe else { return true }
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
            let isIdentityProbe = !check.admitted && !isPreferred && check.globalLimitReached
            guard check.admitted || isIdentityProbe else {
                connection.cancel()
                return InboundControlAdmissionResult(admission: nil, rejectionReason: check.reason)
            }

            if let active = activeControlConnection {
                switch active.state {
                case .cancelled, .failed:
                    clearControlSlotOnQueue(connection: active)
                default:
                    guard !activeControlAuthenticated, isPreferred,
                          !isPreferredEndpoint(Self.endpointKey(for: active.endpoint)) else {
                        connection.cancel()
                        return InboundControlAdmissionResult(
                            admission: nil,
                            rejectionReason: "Another control connection is already active."
                        )
                    }
                    recordAdmissionFailureOnQueue(active.endpoint)
                    active.cancel()
                    clearControlSlotOnQueue(connection: active)
                }
            }

            nextInboundAdmissionGeneration &+= 1
            let admission = InboundControlAdmission(
                token: UUID(),
                generation: nextInboundAdmissionGeneration,
                endpointKey: key,
                isPreferredCandidate: isPreferred,
                isIdentityProbe: isIdentityProbe
            )
            inboundAdmission = admission
            activeControlConnection = connection
            activeControlGeneration = admission.generation
            activeControlAuthenticated = false
            activeControlIsIdentityProbe = isIdentityProbe
            activeIdentityProbePeerID = nil
            startInboundAdmissionTimeoutOnQueue(
                connection: connection,
                admission: admission,
                timeout: max(1, adoptionTimeout)
            )
            return InboundControlAdmissionResult(admission: admission, rejectionReason: nil)
        }
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
            guard result.admission != nil else { return result }
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection else { return }
                switch state {
                case .failed, .cancelled:
                    self.controlConnectionEnded(connection)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            return result
        }
    }

    func confirmInboundControlAdmission(
        _ admission: InboundControlAdmission,
        connection: NWConnection,
        generation: Int
    ) -> Bool {
        onQueue {
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

    func controlConnectionEnded(_ connection: NWConnection, generation: Int? = nil) {
        onQueue {
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

    private func stopInboundAdmissionTimeoutOnQueue() {
        inboundAdmissionSource?.cancel()
        inboundAdmissionSource = nil
    }

    private func clearControlSlotOnQueue(connection: NWConnection) {
        guard activeControlConnection === connection else { return }
        recordIdentityProbeFailureOnQueue()
        stopInboundAdmissionTimeoutOnQueue()
        if inboundAdmission?.token != nil,
           inboundAdmission?.generation == activeControlGeneration {
            inboundAdmission = nil
        }
        activeControlConnection = nil
        activeControlAuthenticated = false
        activeControlIsIdentityProbe = false
        activeIdentityProbePeerID = nil
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
            onReconnectDue?(attempt, generation)
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
                recordIdentityProbeFailureOnQueue()
                activeControlConnection = nil
                activeControlAuthenticated = false
                activeControlIsIdentityProbe = false
                activeIdentityProbePeerID = nil
                stopInboundAdmissionTimeoutOnQueue()
                inboundAdmission = nil
                stopPreAuthWatchdogOnQueue()
                stopHeartbeatOnQueue()
            }
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
