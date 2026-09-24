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
    public let generation: Int
    public private(set) var phase: BoothPreAuthPhase

    public var helloTimeout: TimeInterval = 5.0
    public var interactiveInactivityTimeout: TimeInterval = 45.0
    public var authenticatingTimeout: TimeInterval = 25.0
    public var negotiatingTimeout: TimeInterval = 25.0

    public init(generation: Int, startTime: Date = Date()) {
        self.generation = generation
        self.phase = .awaitingHello(deadline: startTime.addingTimeInterval(helloTimeout))
    }

    public func onValidHello(now: Date = Date(), isPairing: Bool, pairingExpiry: Date? = nil) {
        guard case .awaitingHello = phase else { return }
        if isPairing, let pairingExpiry {
            let inactivity = now.addingTimeInterval(interactiveInactivityTimeout)
            phase = .interactivePairing(inactivityDeadline: inactivity, absoluteExpiry: pairingExpiry)
        } else {
            phase = .authenticating(deadline: now.addingTimeInterval(authenticatingTimeout))
        }
    }

    public func onPairingSessionStarted(absoluteExpiry: Date, now: Date = Date()) {
        guard !phase.isTerminal else { return }
        let inactivity = now.addingTimeInterval(interactiveInactivityTimeout)
        phase = .interactivePairing(inactivityDeadline: inactivity, absoluteExpiry: absoluteExpiry)
    }

    public func onInteractiveProgress(now: Date = Date()) {
        guard case .interactivePairing(_, let absoluteExpiry) = phase else { return }
        guard now < absoluteExpiry else {
            phase = .expired(reason: "Pairing session expired.")
            return
        }
        let inactivity = now.addingTimeInterval(interactiveInactivityTimeout)
        phase = .interactivePairing(inactivityDeadline: inactivity, absoluteExpiry: absoluteExpiry)
    }

    public func onAuthenticationStarted(now: Date = Date()) {
        guard !phase.isTerminal else { return }
        phase = .authenticating(deadline: now.addingTimeInterval(authenticatingTimeout))
    }

    public func onSecureNegotiationStarted(now: Date = Date()) {
        guard !phase.isTerminal else { return }
        phase = .secureChannelNegotiating(deadline: now.addingTimeInterval(negotiatingTimeout))
    }

    public func onAuthenticated() {
        phase = .authenticated
    }

    public func checkTimeout(now: Date = Date()) -> String? {
        switch phase {
        case .awaitingHello(let deadline):
            if now >= deadline {
                let reason = "Bootstrap Hello deadline expired (no protocol hello received within \(Int(helloTimeout))s)."
                phase = .expired(reason: reason)
                return reason
            }
        case .interactivePairing(let inactivityDeadline, let absoluteExpiry):
            if now >= absoluteExpiry {
                let reason = "Pairing session absolute deadline expired."
                phase = .expired(reason: reason)
                return reason
            }
            if now >= inactivityDeadline {
                let reason = "Pairing interactive inactivity deadline expired."
                phase = .expired(reason: reason)
                return reason
            }
        case .authenticating(let deadline):
            if now >= deadline {
                let reason = "Authentication deadline expired."
                phase = .expired(reason: reason)
                return reason
            }
        case .secureChannelNegotiating(let deadline):
            if now >= deadline {
                let reason = "Secure channel negotiation deadline expired."
                phase = .expired(reason: reason)
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
        switch phase {
        case .awaitingHello(let deadline):
            return deadline
        case .interactivePairing(let inactivityDeadline, let absoluteExpiry):
            return min(inactivityDeadline, absoluteExpiry)
        case .authenticating(let deadline):
            return deadline
        case .secureChannelNegotiating(let deadline):
            return deadline
        case .authenticated, .expired:
            return nil
        }
    }
}

// MARK: - Pre-Auth Admission Limiter (Finding F26)

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

    private var records: [String: EndpointRecord] = [:]
    private var globalFailureTimestamps: [Date] = []

    public let maxTrackedEndpoints: Int
    public let failureWindow: TimeInterval
    public let recordExpiry: TimeInterval
    public let failureThreshold: Int
    public let baseCooldown: TimeInterval
    public let maxCooldown: TimeInterval
    public let globalFailureThreshold: Int

    public init(
        maxTrackedEndpoints: Int = defaultMaxTrackedEndpoints,
        failureWindow: TimeInterval = defaultFailureWindow,
        recordExpiry: TimeInterval = defaultRecordExpiry,
        failureThreshold: Int = defaultFailureThreshold,
        baseCooldown: TimeInterval = defaultBaseCooldown,
        maxCooldown: TimeInterval = defaultMaxCooldown,
        globalFailureThreshold: Int = defaultGlobalFailureThreshold
    ) {
        self.maxTrackedEndpoints = maxTrackedEndpoints
        self.failureWindow = failureWindow
        self.recordExpiry = recordExpiry
        self.failureThreshold = failureThreshold
        self.baseCooldown = baseCooldown
        self.maxCooldown = maxCooldown
        self.globalFailureThreshold = globalFailureThreshold
    }

    public var trackedEndpointCount: Int { records.count }

    public func shouldAdmit(endpointKey: String, now: Date = Date()) -> (admitted: Bool, reason: String?) {
        // Check global abuse threshold
        let recentGlobal = globalFailureTimestamps.filter { now.timeIntervalSince($0) <= failureWindow }
        if recentGlobal.count >= globalFailureThreshold {
            return (false, "Global pre-auth failure rate limit exceeded.")
        }

        guard let record = records[endpointKey] else {
            return (true, nil)
        }

        if let cooldownUntil = record.cooldownUntil, now < cooldownUntil {
            let remaining = Int(ceil(cooldownUntil.timeIntervalSince(now)))
            return (false, "Pre-authentication throttled due to repeated failures. Cooldown: \(remaining)s remaining.")
        }

        return (true, nil)
    }

    public mutating func recordFailure(endpointKey: String, now: Date = Date()) {
        purgeExpired(now: now)

        globalFailureTimestamps.append(now)

        var record = records[endpointKey] ?? EndpointRecord()
        record.failureTimestamps = record.failureTimestamps.filter { now.timeIntervalSince($0) <= failureWindow }
        record.failureTimestamps.append(now)

        if record.failureTimestamps.count >= failureThreshold {
            let excess = record.failureTimestamps.count - failureThreshold
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
        records = records.filter { _, record in
            if let cooldown = record.cooldownUntil, now < cooldown { return true }
            guard let last = record.failureTimestamps.last else { return false }
            return now.timeIntervalSince(last) <= recordExpiry
        }
    }
}
