import Foundation

// MARK: - Pre-Auth Phases (Finding F23)

public enum BoothPreAuthPhase: Equatable, Sendable {
    case awaitingHello(deadline: Date)
    case interactivePairing(inactivityDeadline: Date, absoluteExpiry: Date)
    case authenticating(deadline: Date)
    case secureChannelNegotiating(deadline: Date)
    case authenticated
    case expired(reason: String)

    public var isTerminal: Bool {
        switch self {
        case .authenticated, .expired: return true
        default: return false
        }
    }
}

// MARK: - Pre-Auth Watchdog (Finding F23)

public final class BoothPreAuthWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    public let generation: Int
    private var _phase: BoothPreAuthPhase
    private var _pairingAbsoluteExpiry: Date?

    public var phase: BoothPreAuthPhase {
        lock.lock()
        defer { lock.unlock() }
        return _phase
    }

    public var helloTimeout: TimeInterval
    public var interactiveInactivityTimeout: TimeInterval
    public var authenticatingTimeout: TimeInterval
    public var negotiatingTimeout: TimeInterval

    public init(
        generation: Int,
        startTime: Date = Date(),
        helloTimeout: TimeInterval = 5.0,
        interactiveInactivityTimeout: TimeInterval = 45.0,
        authenticatingTimeout: TimeInterval = 25.0,
        negotiatingTimeout: TimeInterval = 25.0
    ) {
        self.generation = generation
        self.helloTimeout = helloTimeout
        self.interactiveInactivityTimeout = interactiveInactivityTimeout
        self.authenticatingTimeout = authenticatingTimeout
        self.negotiatingTimeout = negotiatingTimeout
        self._phase = .awaitingHello(deadline: startTime.addingTimeInterval(helloTimeout))
    }

    public func onValidHello(now: Date = Date(), isPairing: Bool, pairingExpiry: Date? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingHello = _phase else { return }
        if isPairing, let pairingExpiry {
            _pairingAbsoluteExpiry = pairingExpiry
            let inactivity = now.addingTimeInterval(interactiveInactivityTimeout)
            _phase = .interactivePairing(inactivityDeadline: inactivity, absoluteExpiry: pairingExpiry)
        } else {
            _pairingAbsoluteExpiry = nil
            _phase = .authenticating(deadline: now.addingTimeInterval(authenticatingTimeout))
        }
    }

    @discardableResult
    public func onPairingSessionStarted(absoluteExpiry: Date, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard checkTimeoutLocked(now: now) == nil, !_phase.isTerminal else { return false }
        let connectionExpiry = min(_pairingAbsoluteExpiry ?? absoluteExpiry, absoluteExpiry)
        _pairingAbsoluteExpiry = connectionExpiry
        let inactivity = now.addingTimeInterval(interactiveInactivityTimeout)
        _phase = .interactivePairing(inactivityDeadline: inactivity, absoluteExpiry: connectionExpiry)
        return true
    }

    public func onInteractiveProgress(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard case .interactivePairing(_, let absoluteExpiry) = _phase else { return }
        guard now < absoluteExpiry else {
            _phase = .expired(reason: "Pairing session expired.")
            return
        }
        let inactivity = now.addingTimeInterval(interactiveInactivityTimeout)
        _phase = .interactivePairing(inactivityDeadline: inactivity, absoluteExpiry: absoluteExpiry)
    }

    public func onAuthenticationStarted(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard !_phase.isTerminal else { return }
        _phase = .authenticating(deadline: now.addingTimeInterval(authenticatingTimeout))
    }

    public func onSecureNegotiationStarted(now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        guard !_phase.isTerminal else { return }
        _phase = .secureChannelNegotiating(deadline: now.addingTimeInterval(negotiatingTimeout))
    }

    public func onAuthenticated() {
        lock.lock()
        defer { lock.unlock() }
        _pairingAbsoluteExpiry = nil
        _phase = .authenticated
    }

    public func checkTimeout(now: Date = Date()) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return checkTimeoutLocked(now: now)
    }

    private func checkTimeoutLocked(now: Date) -> String? {
        switch _phase {
        case .interactivePairing, .authenticating, .secureChannelNegotiating:
            if let pairingAbsoluteExpiry = _pairingAbsoluteExpiry, now >= pairingAbsoluteExpiry {
                let reason = "Pairing session absolute deadline expired."
                _phase = .expired(reason: reason)
                return reason
            }
        case .awaitingHello, .authenticated, .expired:
            break
        }

        switch _phase {
        case .awaitingHello(let deadline):
            if now >= deadline {
                let reason = "Bootstrap Hello deadline expired (no protocol hello received within \(Int(helloTimeout))s)."
                _phase = .expired(reason: reason)
                return reason
            }
        case .interactivePairing(let inactivityDeadline, let absoluteExpiry):
            if now >= absoluteExpiry {
                let reason = "Pairing session absolute deadline expired."
                _phase = .expired(reason: reason)
                return reason
            }
            if now >= inactivityDeadline {
                let reason = "Pairing interactive inactivity deadline expired."
                _phase = .expired(reason: reason)
                return reason
            }
        case .authenticating(let deadline):
            if now >= deadline {
                let reason = "Authentication deadline expired."
                _phase = .expired(reason: reason)
                return reason
            }
        case .secureChannelNegotiating(let deadline):
            if now >= deadline {
                let reason = "Secure channel negotiation deadline expired."
                _phase = .expired(reason: reason)
                return reason
            }
        case .authenticated:
            return nil
        case .expired(let reason):
            return reason
        }
        return nil
    }

    public func nextDeadline() -> Date? {
        lock.lock()
        defer { lock.unlock() }
        switch _phase {
        case .awaitingHello(let deadline):
            return deadline
        case .interactivePairing(let inactivityDeadline, let absoluteExpiry):
            return min(inactivityDeadline, absoluteExpiry)
        case .authenticating(let deadline):
            return min(deadline, _pairingAbsoluteExpiry ?? deadline)
        case .secureChannelNegotiating(let deadline):
            return min(deadline, _pairingAbsoluteExpiry ?? deadline)
        case .authenticated, .expired:
            return nil
        }
    }
}

public enum BoothPreAuthProgressPolicy {
    @discardableResult
    public static func advance(
        _ watchdog: BoothPreAuthWatchdog,
        after decision: BoothPairingIntentPolicy.Decision,
        now: Date = Date()
    ) -> Bool {
        if case .reject = decision { return false }
        guard case .interactivePairing(let inactivityDeadline, let absoluteExpiry) = watchdog.phase,
              now < inactivityDeadline,
              now < absoluteExpiry else {
            _ = watchdog.checkTimeout(now: now)
            return false
        }
        watchdog.onInteractiveProgress(now: now)
        guard case .interactivePairing = watchdog.phase else { return false }
        return true
    }

    @discardableResult
    public static func advance(
        _ watchdog: BoothPreAuthWatchdog,
        after result: BoothPairingAttemptResult,
        now: Date = Date()
    ) -> Bool {
        guard result == .accepted,
              case .interactivePairing(let inactivityDeadline, let absoluteExpiry) = watchdog.phase,
              now < inactivityDeadline,
              now < absoluteExpiry else {
            _ = watchdog.checkTimeout(now: now)
            return false
        }
        watchdog.onInteractiveProgress(now: now)
        guard case .interactivePairing = watchdog.phase else { return false }
        return true
    }

    public static func shouldRunTimerTick(
        expectedGeneration: Int,
        currentGeneration: Int,
        connectionIsCurrent: Bool
    ) -> Bool {
        expectedGeneration == currentGeneration && connectionIsCurrent
    }

    public static func canProcessPairingTraffic(
        _ watchdog: BoothPreAuthWatchdog,
        now: Date = Date()
    ) -> Bool {
        guard watchdog.checkTimeout(now: now) == nil,
              case .interactivePairing = watchdog.phase else { return false }
        return true
    }
}

// MARK: - Pre-Auth Admission Limiter (Finding F26 & Finding A04)

public struct BoothPreAuthAdmissionLimiter: Sendable {
    public struct EndpointRecord: Sendable {
        public var failureTimestamps: [Date]
        public var cooldownUntil: Date?

        public init(failureTimestamps: [Date] = [], cooldownUntil: Date? = nil) {
            self.failureTimestamps = failureTimestamps
            self.cooldownUntil = cooldownUntil
        }
    }

    public static let defaultMaxTrackedEndpoints = 128
    public static let defaultFailureWindow: TimeInterval = 30.0
    public static let defaultRecordExpiry: TimeInterval = 300.0 // 5 minutes
    public static let defaultFailureThreshold = 3
    public static let defaultBaseCooldown: TimeInterval = 2.0
    public static let defaultMaxCooldown: TimeInterval = 10.0
    public static let defaultGlobalFailureThreshold = 30
    public static let defaultReservedFailureThreshold = 5
    public static let defaultIdentityProbeGlobalFailureThreshold = 30

    private var records: [String: EndpointRecord] = [:]
    private var globalFailureTimestamps: [Date] = []
    private var identityProbeGlobalFailureTimestamps: [Date] = []
    private var identityProbeGlobalCooldownUntil: Date?

    public let maxTrackedEndpoints: Int
    public let failureWindow: TimeInterval
    public let recordExpiry: TimeInterval
    public let failureThreshold: Int
    public let baseCooldown: TimeInterval
    public let maxCooldown: TimeInterval
    public let globalFailureThreshold: Int
    public let reservedFailureThreshold: Int
    public let identityProbeGlobalFailureThreshold: Int
    public let identityProbeGlobalCooldown: TimeInterval

    public init(
        maxTrackedEndpoints: Int = defaultMaxTrackedEndpoints,
        failureWindow: TimeInterval = defaultFailureWindow,
        recordExpiry: TimeInterval = defaultRecordExpiry,
        failureThreshold: Int = defaultFailureThreshold,
        baseCooldown: TimeInterval = defaultBaseCooldown,
        maxCooldown: TimeInterval = defaultMaxCooldown,
        globalFailureThreshold: Int = defaultGlobalFailureThreshold,
        reservedFailureThreshold: Int = defaultReservedFailureThreshold,
        identityProbeGlobalFailureThreshold: Int = defaultIdentityProbeGlobalFailureThreshold,
        identityProbeGlobalCooldown: TimeInterval? = nil
    ) {
        self.maxTrackedEndpoints = maxTrackedEndpoints
        self.failureWindow = failureWindow
        self.recordExpiry = recordExpiry
        self.failureThreshold = failureThreshold
        self.baseCooldown = baseCooldown
        self.maxCooldown = maxCooldown
        self.globalFailureThreshold = globalFailureThreshold
        self.reservedFailureThreshold = reservedFailureThreshold
        self.identityProbeGlobalFailureThreshold = max(1, identityProbeGlobalFailureThreshold)
        self.identityProbeGlobalCooldown = max(0, identityProbeGlobalCooldown ?? maxCooldown)
    }

    public var trackedEndpointCount: Int { records.count }

    public func isIdentityProbeCoolingDown(now: Date = Date()) -> Bool {
        identityProbeGlobalCooldownUntil.map { now < $0 } ?? false
    }

    public func shouldAdmit(
        endpointKey: String,
        isPreferredCandidate: Bool = false,
        now: Date = Date()
    ) -> (admitted: Bool, reason: String?, globalLimitReached: Bool) {
        if let record = records[endpointKey],
           let cooldownUntil = record.cooldownUntil,
           now < cooldownUntil {
            let remaining = Int(ceil(cooldownUntil.timeIntervalSince(now)))
            return (false, "Pre-authentication throttled due to repeated failures. Cooldown: \(remaining)s remaining.", false)
        }

        if isPreferredCandidate {
            // Preferred peer bypasses anonymous global ceiling, but still subject to candidate-lane quota
            if let record = records[endpointKey] {
                let recentFailures = record.failureTimestamps.filter { now.timeIntervalSince($0) <= failureWindow }
                if recentFailures.count >= reservedFailureThreshold {
                    return (false, "Reserved candidate pre-authentication throttled due to repeated failures.", false)
                }
            }
            return (true, nil, false)
        }

        // Check global abuse threshold for anonymous endpoints
        let recentGlobal = globalFailureTimestamps.filter { now.timeIntervalSince($0) <= failureWindow }
        if recentGlobal.count >= globalFailureThreshold {
            return (false, "Global pre-auth failure rate limit exceeded.", true)
        }

        return (true, nil, false)
    }

    public func shouldAdmitIdentityProbe(
        peerID: String,
        trustedPeerIDs: Set<String>,
        now: Date = Date()
    ) -> (admitted: Bool, reason: String?) {
        guard !peerID.isEmpty, trustedPeerIDs.contains(peerID) else {
            return (false, "Identity probe did not claim a trusted peer.")
        }
        let key = Self.identityProbeKey(for: peerID)
        if let record = records[key],
           let cooldownUntil = record.cooldownUntil,
           now >= cooldownUntil {
            return (true, nil)
        }
        let decision = shouldAdmit(endpointKey: key, isPreferredCandidate: true, now: now)
        return (decision.admitted, decision.reason)
    }

    public mutating func recordIdentityProbeFailure(
        peerID: String,
        trustedPeerIDs: Set<String>,
        now: Date = Date()
    ) {
        recordIdentityProbeAttemptFailure(now: now)
        guard !peerID.isEmpty, trustedPeerIDs.contains(peerID) else { return }
        recordFailure(endpointKey: Self.identityProbeKey(for: peerID), isPreferredCandidate: true, now: now)
    }

    /// Counts failures in the bounded probe lane even when a candidate never
    /// supplied a trusted claimed ID (for example, a slow or malformed Hello).
    public mutating func recordIdentityProbeAttemptFailure(now: Date = Date()) {
        if let cooldownUntil = identityProbeGlobalCooldownUntil {
            guard now >= cooldownUntil else { return }
            identityProbeGlobalCooldownUntil = nil
        }
        identityProbeGlobalFailureTimestamps = identityProbeGlobalFailureTimestamps.filter {
            now.timeIntervalSince($0) <= failureWindow
        }
        identityProbeGlobalFailureTimestamps.append(now)
        guard identityProbeGlobalFailureTimestamps.count >= identityProbeGlobalFailureThreshold else { return }
        identityProbeGlobalFailureTimestamps.removeAll(keepingCapacity: true)
        identityProbeGlobalCooldownUntil = now.addingTimeInterval(identityProbeGlobalCooldown)
    }

    public mutating func recordIdentityProbeSuccess(peerID: String) {
        records.removeValue(forKey: Self.identityProbeKey(for: peerID))
    }

    public mutating func recordFailure(
        endpointKey: String,
        isPreferredCandidate: Bool = false,
        now: Date = Date()
    ) {
        purgeExpired(now: now)

        if !isPreferredCandidate {
            globalFailureTimestamps.append(now)
        }

        var record = records[endpointKey] ?? EndpointRecord()
        record.failureTimestamps = record.failureTimestamps.filter { now.timeIntervalSince($0) <= failureWindow }
        record.failureTimestamps.append(now)

        let threshold = isPreferredCandidate ? reservedFailureThreshold : failureThreshold
        if record.failureTimestamps.count >= threshold {
            let excess = record.failureTimestamps.count - threshold
            let factor = pow(2.0, Double(min(excess, 4)))
            let cooldown = min(maxCooldown, baseCooldown * factor)
            record.cooldownUntil = now.addingTimeInterval(cooldown)
        }

        if records[endpointKey] == nil, records.count >= maxTrackedEndpoints {
            // Evict oldest record
            if let oldest = records.min(by: {
                ($0.value.failureTimestamps.last ?? .distantPast) < ($1.value.failureTimestamps.last ?? .distantPast)
            }) {
                records.removeValue(forKey: oldest.key)
            }
        }

        records[endpointKey] = record
    }

    public mutating func recordSuccess(endpointKey: String) {
        records.removeValue(forKey: endpointKey)
    }

    public mutating func purgeExpired(now: Date = Date()) {
        globalFailureTimestamps.removeAll { now.timeIntervalSince($0) > failureWindow }
        identityProbeGlobalFailureTimestamps.removeAll { now.timeIntervalSince($0) > failureWindow }
        if let cooldownUntil = identityProbeGlobalCooldownUntil, now >= cooldownUntil {
            identityProbeGlobalCooldownUntil = nil
        }
        records = records.filter { _, record in
            if let cooldown = record.cooldownUntil, now < cooldown { return true }
            guard let last = record.failureTimestamps.last else { return false }
            return now.timeIntervalSince(last) <= recordExpiry
        }
    }

    private static func identityProbeKey(for peerID: String) -> String {
        "identity-probe:\(peerID)"
    }
}
