import Foundation
import Network
#if os(macOS)
import Observation
#else
import Combine
#endif

public enum BoothConnectionState: Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected(peerName: String)
}

public enum BoothPathObservation: Equatable, Sendable {
    case unknown
    case unavailable
    case available
}

public enum BoothLANHandshakeState: Equatable, Sendable {
    case unknown
    case waiting
    case ready
    case timeout
    case failed
}

public struct BoothPreviewDiagnostics: Equatable, Sendable {
    public var fps: Double = 0
    public var bytesPerSecond: Double = 0
    public var framesSubmitted = 0
    public var framesSent = 0
    public var framesCoalesced = 0
    public var framesReceived = 0
    public var framesDelivered = 0
    public var framesCoalescedBeforeMainActor = 0
    public var pendingFrames = 0

    public init() {}
}

public struct EthernetProbeResult: Equatable, Sendable {
    public let interfaceAvailable: Bool
    public let peerDiscovered: Bool
    public let identityMatched: Bool
    public let trustedPairing: Bool
    public let authenticated: Bool
    public let controlConnected: Bool
    public let handshakeSucceeded: Bool
    public let previewConnected: Bool
    public let duration: TimeInterval
    public let error: String?
    public let roundTripLatency: TimeInterval?

    public init(
        interfaceAvailable: Bool,
        peerDiscovered: Bool,
        identityMatched: Bool = false,
        trustedPairing: Bool = false,
        authenticated: Bool = false,
        controlConnected: Bool,
        handshakeSucceeded: Bool,
        previewConnected: Bool,
        duration: TimeInterval,
        error: String?,
        roundTripLatency: TimeInterval? = nil
    ) {
        self.interfaceAvailable = interfaceAvailable
        self.peerDiscovered = peerDiscovered
        self.identityMatched = identityMatched
        self.trustedPairing = trustedPairing
        self.authenticated = authenticated
        self.controlConnected = controlConnected
        self.handshakeSucceeded = handshakeSucceeded
        self.previewConnected = previewConnected
        self.duration = duration
        self.error = error
        self.roundTripLatency = roundTripLatency
    }
}

#if os(macOS)
@Observable
#endif
@MainActor
public final class BoothConnectionStatus {
#if os(iOS)
    @Published
#endif
    public private(set) var state: BoothConnectionState = .disconnected
#if os(iOS)
    @Published
#endif
    public private(set) var peerID: String?
#if os(iOS)
    @Published
#endif
    public private(set) var peerDisplayName: String?
#if os(iOS)
    @Published
#endif
    public private(set) var connectedPeerNames: [String] = []
#if os(iOS)
    @Published
#endif
    public private(set) var requestedNetwork: BoothNetworkPreference
#if os(iOS)
    @Published
#endif
    public private(set) var effectiveNetwork: BoothEffectiveNetworkTransport = .unavailable
#if os(iOS)
    @Published
#endif
    public private(set) var routeState: BoothNetworkRouteState = .disconnected
#if os(iOS)
    @Published
#endif
    public private(set) var fallbackReason: String?
#if os(iOS)
    @Published
#endif
    public private(set) var isLANPathAvailable = false
#if os(iOS)
    @Published
#endif
    public private(set) var isWiFiPathAvailable = false
#if os(iOS)
    @Published
#endif
    public private(set) var lanPathObservation: BoothPathObservation = .unknown
#if os(iOS)
    @Published
#endif
    public private(set) var wifiPathObservation: BoothPathObservation = .unknown
#if os(iOS)
    @Published
#endif
    public private(set) var lanHandshake: BoothLANHandshakeState = .unknown
#if os(iOS)
    @Published
#endif
    public private(set) var lastNetworkError: String?
#if os(iOS)
    @Published
#endif
    public private(set) var isPreviewChannelConnected = false
#if os(iOS)
    @Published
#endif
    public private(set) var isSecureChannelEstablished = false
#if os(iOS)
    @Published
#endif
    public private(set) var isAssetChannelConnected = false
#if os(iOS)
    @Published
#endif
    public private(set) var isAssetChannelVerified = false
#if os(iOS)
    @Published
#endif
    public private(set) var previewDiagnostics = BoothPreviewDiagnostics()
#if os(iOS)
    @Published
#endif
    public private(set) var discoveredPeers: [BoothDiscoveredPeer] = []
#if os(iOS)
    @Published
#endif
    public private(set) var trustedPeerIDs: Set<String> = []
#if os(iOS)
    @Published
#endif
    public private(set) var preferredPeerID: String?
#if os(iOS)
    @Published
#endif
    public private(set) var isPeerAuthenticated = false
#if os(iOS)
    @Published
#endif
    public private(set) var pairingState: BoothPairingState = .idle
#if os(iOS)
    @Published
#endif
    public private(set) var pairingStage: BoothPairingStage = .idle
#if os(iOS)
    @Published
#endif
    public private(set) var roundTripLatency: TimeInterval?
#if os(iOS)
    @Published
#endif
    public private(set) var lastControlActivityAt: Date?
#if os(iOS)
    @Published
#endif
    public private(set) var isReconnectInProgress = false
#if os(iOS)
    @Published
#endif
    public private(set) var reconnectAttempt = 0

    public var isFallbackActive: Bool {
        if case .fallbackWiFi = routeState { return true }
        return fallbackReason != nil && requestedNetwork == .lan
    }

    public var isAssetChannelReady: Bool {
        isAssetChannelConnected && isAssetChannelVerified
    }

    public init(requestedNetwork: BoothNetworkPreference = .wifi) {
        self.requestedNetwork = requestedNetwork
    }

    public func publish(
        requestedNetwork: BoothNetworkPreference,
        state: BoothConnectionState,
        peerID: String?,
        peerDisplayName: String?,
        routeState: BoothNetworkRouteState,
        effectiveNetwork: BoothEffectiveNetworkTransport,
        fallbackReason: String? = nil,
        isLANPathAvailable: Bool = false,
        isWiFiPathAvailable: Bool = false,
        lanPathObservation: BoothPathObservation? = nil,
        wifiPathObservation: BoothPathObservation? = nil,
        lanHandshake: BoothLANHandshakeState? = nil,
        lastNetworkError: String? = nil,
        isPreviewChannelConnected: Bool? = nil
    ) {
        self.requestedNetwork = requestedNetwork
        self.state = state
        self.peerID = peerID
        self.peerDisplayName = peerDisplayName
        self.connectedPeerNames = peerDisplayName.map { [$0] } ?? []
        self.routeState = routeState
        self.effectiveNetwork = effectiveNetwork
        self.fallbackReason = fallbackReason
        self.isLANPathAvailable = isLANPathAvailable
        self.isWiFiPathAvailable = isWiFiPathAvailable
        if let lanPathObservation { self.lanPathObservation = lanPathObservation }
        if let wifiPathObservation { self.wifiPathObservation = wifiPathObservation }
        if let lanHandshake { self.lanHandshake = lanHandshake }
        self.lastNetworkError = lastNetworkError
        if let isPreviewChannelConnected { self.isPreviewChannelConnected = isPreviewChannelConnected }
    }

    public func publishPathAvailability(
        lan: Bool,
        wifi: Bool,
        lanObserved: Bool = true,
        wifiObserved: Bool = true
    ) {
        isLANPathAvailable = lan
        isWiFiPathAvailable = wifi
        lanPathObservation = lanObserved ? (lan ? .available : .unavailable) : .unknown
        wifiPathObservation = wifiObserved ? (wifi ? .available : .unavailable) : .unknown
    }

    public func publishHandshake(_ state: BoothLANHandshakeState) {
        lanHandshake = state
    }

    public func publishNetworkError(_ message: String?) {
        lastNetworkError = message
    }

    public func publishPreviewChannel(connected: Bool) {
        isPreviewChannelConnected = connected
    }

    public func publishSecureChannel(ready: Bool) {
        isSecureChannelEstablished = ready
        if !ready {
            isAssetChannelConnected = false
            isAssetChannelVerified = false
        }
    }

    public func publishAssetChannel(connected: Bool, verified: Bool = false) {
        isAssetChannelConnected = connected
        isAssetChannelVerified = connected && verified
    }

    public func publishPreviewDiagnostics(_ diagnostics: BoothPreviewDiagnostics) {
        previewDiagnostics = diagnostics
    }

    public func publishPreviewWriteDiagnostics(_ diagnostics: BoothPreviewDiagnostics) {
        previewDiagnostics.fps = diagnostics.fps
        previewDiagnostics.bytesPerSecond = diagnostics.bytesPerSecond
        previewDiagnostics.framesSubmitted = diagnostics.framesSubmitted
        previewDiagnostics.framesSent = diagnostics.framesSent
        previewDiagnostics.framesCoalesced = diagnostics.framesCoalesced
    }

    public func publishPreviewDeliveryDiagnostics(
        framesReceived: Int,
        framesDelivered: Int,
        framesCoalesced: Int,
        pendingFrames: Int
    ) {
        previewDiagnostics.framesReceived = framesReceived
        previewDiagnostics.framesDelivered = framesDelivered
        previewDiagnostics.framesCoalescedBeforeMainActor = framesCoalesced
        previewDiagnostics.pendingFrames = pendingFrames
    }

    public func publishControlActivity(at date: Date = Date()) {
        lastControlActivityAt = date
    }

    public func publishReconnectState(inProgress: Bool, attempt: Int = 0) {
        isReconnectInProgress = inProgress
        reconnectAttempt = max(0, attempt)
    }

    public func publishPairing(
        discoveredPeers: [BoothDiscoveredPeer]? = nil,
        trustedPeerIDs: Set<String>? = nil,
        preferredPeerID: String? = nil,
        updatePreferredPeer: Bool = false,
        authenticated: Bool? = nil,
        state: BoothPairingState? = nil,
        stage: BoothPairingStage? = nil,
        roundTripLatency: TimeInterval? = nil,
        updateLatency: Bool = false
    ) {
        if let discoveredPeers { self.discoveredPeers = discoveredPeers }
        if let trustedPeerIDs { self.trustedPeerIDs = trustedPeerIDs }
        if updatePreferredPeer { self.preferredPeerID = preferredPeerID }
        if let authenticated { isPeerAuthenticated = authenticated }
        if let state { pairingState = state }
        if let stage { pairingStage = stage }
        if updateLatency { self.roundTripLatency = roundTripLatency }
    }

    public func publishDisconnected() {
        isPeerAuthenticated = false
        roundTripLatency = nil
        lastControlActivityAt = nil
        isReconnectInProgress = false
        reconnectAttempt = 0
        lanHandshake = .unknown
        isPreviewChannelConnected = false
        publishSecureChannel(ready: false)
        publishAssetChannel(connected: false)
        publish(
            requestedNetwork: requestedNetwork,
            state: .disconnected,
            peerID: nil,
            peerDisplayName: nil,
            routeState: .disconnected,
            effectiveNetwork: .unavailable,
            fallbackReason: nil,
            isLANPathAvailable: isLANPathAvailable,
            isWiFiPathAvailable: isWiFiPathAvailable
        )
    }
}

#if os(iOS)
extension BoothConnectionStatus: ObservableObject {}
#endif

public enum BoothControlSendOutcome: Equatable, Sendable {
    case sent
    case noConnection
    case rejectedOversize
    case encodingFailed
    case networkSendFailed
}

public enum BoothTransportDiagnosticKind: String, Codable, Sendable {
    case routeDiscoveryStarted
    case routeDiscoveryRestarted
    case routeDiscoveryReused
    case routeDiscoveryResult
    case targetSelected
    case targetMatched
    case routeSelected
    case browserReady
    case browserFailed
    case browserCancelled
    case routeCandidateDiscovered
    case controlConnectionCreated
    case controlConnectionPreparing
    case helloSent
    case controlHelloReceived
    case authenticated
    case pairingIntentSent
    case pairingSessionReceived
    case pairingRequestSent
    case pairingResultReceived
    case pairingRequestSubmitted
    case transportDiscoveryStarted
    case transportConnecting
    case transportReady
    case transportWaiting
    case transportDisconnected
    case transportReconnectScheduled
    case transportReconnectSucceeded
    case heartbeatTimedOut
    case routeChanged
    case controlSendFailed
    case controlPayloadRejected
    case previewDisconnected
    case previewReconnected
    case sessionSyncSent
    case sessionSyncFailed
    case criticalSendQueued
    case criticalSendCompleted
    case assetSent
    case assetRejected
    case assetChannelConnected
    case assetChannelVerified
    case assetChannelDisconnected
    case secureChannelEstablished
    case secureChannelFailed
    case previewReady
    case assetReady
    case routeViabilityChanged
    case pathHintUnavailableIgnored
    case secondaryCandidateRejected
    case waitingRecoveryScheduled
    case waitingRecoveryCancelled
    case ipadAppForegrounded
    case ipadAppBackgrounded
}

public struct BoothDiscoveryDiagnostics: Codable, Sendable, Equatable {
    public let generation: Int
    public let activeBrowserCount: Int
    public let discoveredPeerCount: Int
    public let targetPeerID: String?
    public let targetCandidateAvailable: Bool
    public let targetCandidateSource: String?
    public let controlConnectionState: String
    public let controlConnectionGeneration: Int
    public let helloSent: Bool
    public let helloReceived: Bool
    public let authenticated: Bool
    public let secureChannelReady: Bool
    public let previewReady: Bool
    public let assetReady: Bool

    public init(
        generation: Int,
        activeBrowserCount: Int,
        discoveredPeerCount: Int,
        targetPeerID: String?,
        targetCandidateAvailable: Bool,
        targetCandidateSource: String?,
        controlConnectionState: String,
        controlConnectionGeneration: Int,
        helloSent: Bool,
        helloReceived: Bool,
        authenticated: Bool,
        secureChannelReady: Bool,
        previewReady: Bool,
        assetReady: Bool
    ) {
        self.generation = generation
        self.activeBrowserCount = activeBrowserCount
        self.discoveredPeerCount = discoveredPeerCount
        self.targetPeerID = targetPeerID
        self.targetCandidateAvailable = targetCandidateAvailable
        self.targetCandidateSource = targetCandidateSource
        self.controlConnectionState = controlConnectionState
        self.controlConnectionGeneration = controlConnectionGeneration
        self.helloSent = helloSent
        self.helloReceived = helloReceived
        self.authenticated = authenticated
        self.secureChannelReady = secureChannelReady
        self.previewReady = previewReady
        self.assetReady = assetReady
    }
}

public struct BoothTransportDiagnosticEvent: Codable, Sendable, Equatable {
    public let kind: BoothTransportDiagnosticKind
    public let timestamp: Date
    public let channel: String?
    public let generation: Int?
    public let route: String?
    public let attempt: Int?
    public let byteCount: Int?
    public let duration: TimeInterval?
    public let reason: String?
    public let targetPeerID: String?
    public let routeGeneration: Int?
    public let networkPreference: BoothNetworkPreference?
    public let candidateSource: String?

    public init(
        kind: BoothTransportDiagnosticKind,
        timestamp: Date = Date(),
        channel: String? = nil,
        generation: Int? = nil,
        route: String? = nil,
        attempt: Int? = nil,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil,
        reason: String? = nil,
        targetPeerID: String? = nil,
        routeGeneration: Int? = nil,
        networkPreference: BoothNetworkPreference? = nil,
        candidateSource: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.channel = channel
        self.generation = generation
        self.route = route
        self.attempt = attempt
        self.byteCount = byteCount
        self.duration = duration
        self.reason = reason
        self.targetPeerID = targetPeerID
        self.routeGeneration = routeGeneration
        self.networkPreference = networkPreference
        self.candidateSource = candidateSource
    }
}

public enum BoothConnectionDiagnosticsReport {
    @MainActor
    public static func make(
        appVersion: String,
        appBuild: String,
        operatingSystem: String,
        deviceName: String,
        status: BoothConnectionStatus,
        discoveryDiagnostics: BoothDiscoveryDiagnostics?,
        recentEvents: [BoothTransportDiagnosticEvent] = []
    ) -> String {
        let metrics = status.previewDiagnostics
        let version = safe(appVersion) ?? "Unknown"
        let build = safe(appBuild) ?? "Unknown"
        let os = safe(operatingSystem) ?? "Unknown"
        let device = safe(deviceName) ?? "Unknown"
        let peer = safe(status.peerDisplayName) ?? "None"
        let fallback = safe(status.fallbackReason) ?? "Inactive"
        let error = safe(status.lastNetworkError) ?? "None"
        let preferredPeer = safe(status.preferredPeerID) ?? "None"
        let authentication = status.isPeerAuthenticated ? "Authenticated" : "Not authenticated"
        let secureChannel = status.isSecureChannelEstablished ? "Ready" : "Not ready"
        let previewChannel = status.isPreviewChannelConnected ? "Ready" : "Not ready"
        let assetChannel = status.isAssetChannelReady ? "Ready" : "Not ready"
        let reconnect = status.isReconnectInProgress ? "In progress" : "Idle"

        return [
            "PRC PhotoBooth Connection Log",
            "",
            "App",
            "Version: \(version)",
            "Build: \(build)",
            "Operating system: \(os)",
            "Device: \(device)",
            "Generated: \(dateText(Date()))",
            "",
            "Connection",
            "Requested: \(networkText(status.requestedNetwork))",
            "Effective: \(networkText(status.effectiveNetwork))",
            "State: \(connectionText(status.state))",
            "Peer: \(peer)",
            "Fallback: \(fallback)",
            "Ethernet path: \(pathText(status.lanPathObservation))",
            "Wi-Fi path: \(pathText(status.wifiPathObservation))",
            "LAN handshake: \(handshakeText(status.lanHandshake))",
            "Authentication: \(authentication)",
            "Secure channel: \(secureChannel)",
            "Preview channel: \(previewChannel)",
            "Asset channel: \(assetChannel)",
            "Last network error: \(error)",
            "",
            "Pairing",
            "Pairing state: \(pairingStateText(status.pairingState))",
            "Pairing stage: \(status.pairingStage.rawValue)",
            "Preferred peer: \(preferredPeer)",
            "Trusted peers: \(status.trustedPeerIDs.count)",
            "Discovered peers: \(status.discoveredPeers.count)",
            "Reconnect: \(reconnect) (attempt \(status.reconnectAttempt))",
            "",
            "Discovery",
            discoveryText(discoveryDiagnostics),
            "",
            "Preview",
            "FPS: \(decimal(metrics.fps))",
            "Throughput: \(decimal(metrics.bytesPerSecond / 1_000_000)) MB/s",
            "Frames submitted: \(metrics.framesSubmitted)",
            "Frames sent: \(metrics.framesSent)",
            "Frames received: \(metrics.framesReceived)",
            "Frames delivered: \(metrics.framesDelivered)",
            "Frames coalesced: \(metrics.framesCoalesced + metrics.framesCoalescedBeforeMainActor)",
            "",
            "Recent transport events",
            recentEventsText(recentEvents)
        ].joined(separator: "\n")
    }

    static func redacted(_ event: BoothTransportDiagnosticEvent) -> BoothTransportDiagnosticEvent {
        BoothTransportDiagnosticEvent(
            kind: event.kind,
            timestamp: event.timestamp,
            channel: safe(event.channel),
            generation: event.generation,
            route: safe(event.route),
            attempt: event.attempt,
            byteCount: event.byteCount,
            duration: event.duration,
            reason: safe(event.reason),
            targetPeerID: safe(event.targetPeerID),
            routeGeneration: event.routeGeneration,
            networkPreference: event.networkPreference,
            candidateSource: safe(event.candidateSource)
        )
    }

    private static func networkText(_ network: BoothNetworkPreference) -> String {
        network == .lan ? "LAN" : "Wi-Fi"
    }

    private static func networkText(_ network: BoothEffectiveNetworkTransport) -> String {
        switch network {
        case .wifi: return "Wi-Fi"
        case .lan: return "LAN (Ethernet)"
        case .unavailable: return "Unavailable"
        }
    }

    private static func connectionText(_ state: BoothConnectionState) -> String {
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }

    private static func pathText(_ path: BoothPathObservation) -> String {
        switch path {
        case .unknown: return "Unknown"
        case .unavailable: return "Unavailable"
        case .available: return "Available"
        }
    }

    private static func handshakeText(_ state: BoothLANHandshakeState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .timeout: return "Timeout"
        case .failed: return "Failed"
        }
    }

    private static func pairingStateText(_ state: BoothPairingState) -> String {
        switch state {
        case .idle: return "Idle"
        case .waitingForMac: return "Waiting for Mac"
        case .pairing: return "Pairing"
        case .incoming: return "Incoming"
        case .authenticating: return "Authenticating"
        case .authenticated: return "Authenticated"
        case .failed(let reason): return "Failed: \(safe(reason) ?? "Unknown")"
        }
    }

    private static func discoveryText(_ diagnostics: BoothDiscoveryDiagnostics?) -> String {
        guard let diagnostics else { return "Snapshot: Unavailable" }
        let target = safe(diagnostics.targetPeerID) ?? "None"
        let source = safe(diagnostics.targetCandidateSource) ?? "None"
        let state = safe(diagnostics.controlConnectionState) ?? "Unknown"
        let candidate = diagnostics.targetCandidateAvailable ? "Available" : "Unavailable"
        let helloSent = diagnostics.helloSent ? "Yes" : "No"
        let helloReceived = diagnostics.helloReceived ? "Yes" : "No"
        let authenticated = diagnostics.authenticated ? "Yes" : "No"
        let secure = diagnostics.secureChannelReady ? "Ready" : "Not ready"
        let preview = diagnostics.previewReady ? "Yes" : "No"
        let asset = diagnostics.assetReady ? "Yes" : "No"

        return [
            "Generation: \(diagnostics.generation)",
            "Active browsers: \(diagnostics.activeBrowserCount)",
            "Discovered peers: \(diagnostics.discoveredPeerCount)",
            "Target: \(target)",
            "Candidate: \(candidate)",
            "Candidate source: \(source)",
            "Control state: \(state)",
            "Control generation: \(diagnostics.controlConnectionGeneration)",
            "Hello sent: \(helloSent)",
            "Hello received: \(helloReceived)",
            "Authenticated: \(authenticated)",
            "Secure channel: \(secure)",
            "Preview ready: \(preview)",
            "Asset ready: \(asset)"
        ].joined(separator: "\n")
    }

    private static func recentEventsText(_ events: [BoothTransportDiagnosticEvent]) -> String {
        guard !events.isEmpty else { return "None" }
        return events.suffix(50).map { event in
            let target = event.targetPeerID.flatMap { safe($0) }.map { "target=\($0)" }
            let details = [
                event.channel,
                event.route,
                target,
                event.routeGeneration.map { "routeGen=\($0)" },
                event.networkPreference.map { "preference=\($0.rawValue)" },
                event.candidateSource,
                event.reason
            ].compactMap { $0 }.joined(separator: " · ")
            let suffix = details.isEmpty ? "" : " — \(details)"
            return "\(dateText(event.timestamp)) \(event.kind.rawValue)\(suffix)"
        }.joined(separator: "\n")
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private static func safe(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let normalized = value.lowercased()
        let sensitiveWords = [
            "token", "password", "secret", "private key", "credential",
            "authorization", "bearer", "pin", "keychain", "access_token",
            "pairing-v2:"
        ]
        guard !sensitiveWords.contains(where: normalized.contains) else { return "[redacted]" }
        return value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

enum BoothPathHintAction: Equatable {
    case observeOnly
    case evaluateRoute
}

enum BoothPathAuthorityPolicy {
    static func action(hasAuthenticatedControl: Bool) -> BoothPathHintAction {
        hasAuthenticatedControl ? .observeOnly : .evaluateRoute
    }
}

enum BoothForegroundRecoveryAction: Equatable {
    case none
    case restartControl
    case waitForSecondaryChannels

    static func action(
        controlReady: Bool,
        previewReady: Bool,
        assetReady: Bool
    ) -> Self {
        guard controlReady else { return .restartControl }
        return previewReady && assetReady ? .none : .waitForSecondaryChannels
    }
}

enum BoothSecondaryChannelAdmissionDecision: Equatable {
    case acceptCandidate
    case rejectCandidate
}

enum BoothSecondaryChannelAdmissionPolicy {
    static func decision(existingVerified: Bool) -> BoothSecondaryChannelAdmissionDecision {
        existingVerified ? .rejectCandidate : .acceptCandidate
    }
}

struct BoothAssetRequestPump: Sendable {
    private(set) var inFlight: Set<BoothAssetReference> = []
    private(set) var unavailable: Set<BoothAssetReference> = []
    let maximumInFlight: Int

    init(maximumInFlight: Int = 8) {
        self.maximumInFlight = max(1, maximumInFlight)
    }

    mutating func nextBatch(
        expected: [BoothAssetReference],
        cached: Set<BoothAssetReference>
    ) -> [BoothAssetReference] {
        let capacity = maximumInFlight - inFlight.count
        guard capacity > 0 else { return [] }

        var selected: [BoothAssetReference] = []
        var seen = Set<BoothAssetReference>()
        for reference in expected where selected.count < capacity {
            guard seen.insert(reference).inserted,
                  !cached.contains(reference),
                  !inFlight.contains(reference),
                  !unavailable.contains(reference) else { continue }
            selected.append(reference)
            inFlight.insert(reference)
        }
        return selected
    }

    mutating func markCompleted(_ reference: BoothAssetReference) {
        inFlight.remove(reference)
        unavailable.remove(reference)
    }

    mutating func markUnavailable(_ reference: BoothAssetReference) {
        inFlight.remove(reference)
        unavailable.insert(reference)
    }

    mutating func markSendFailed(_ references: [BoothAssetReference]) {
        inFlight.subtract(references)
    }

    mutating func clearInFlight() {
        inFlight.removeAll()
    }

    mutating func reset() {
        inFlight.removeAll()
        unavailable.removeAll()
    }
}

@MainActor
public protocol BoothTransport: AnyObject {
    var connectionState: BoothConnectionState { get }
    var peerName: String { get }
    var connectedPeerNames: [String] { get }
    var connectionStatus: BoothConnectionStatus { get }
    var requestedNetworkPreference: BoothNetworkPreference { get set }
    var activePeerName: String? { get set }
    var role: DeviceRole { get }
    var onControlMessage: (@MainActor (Message) -> Void)? { get set }
    var onPreviewFrame: (@MainActor (Data) -> Void)? { get set }
    var onAssetChunk: (@MainActor (BoothAssetChunk) -> Void)? { get set }
    var onTransportEvent: (@MainActor (BoothTransportDiagnosticEvent) -> Void)? { get set }
    var onTransportReady: (@MainActor (BoothDeviceIdentity) -> Void)? { get set }

    func start()
    func restart()
    @discardableResult
    func sendControl(_ message: Message) -> BoothControlSendOutcome
    func sendControl(
        _ message: Message,
        completion: @escaping @MainActor (BoothControlSendOutcome) -> Void
    )
    @discardableResult
    func sendAsset(_ chunk: BoothAssetChunk) -> BoothControlSendOutcome
    func sendPreviewFrame(_ jpegData: Data)
    func recycleAssetChannel()
    func disconnect()
}

public extension BoothTransport {
    func sendControl(
        _ message: Message,
        completion: @escaping @MainActor (BoothControlSendOutcome) -> Void
    ) {
        completion(sendControl(message))
    }

    @discardableResult
    func sendAsset(_ chunk: BoothAssetChunk) -> BoothControlSendOutcome {
        .networkSendFailed
    }

    func recycleAssetChannel() {}

    func restart() {
        disconnect()
        start()
    }
}

public enum BoothTransportChannel: UInt8, Codable, Sendable {
    case control = 1
    case preview = 2
    case asset = 3
    case heartbeat = 4
}

struct LatestFrameCoalescer: Sendable {
    private(set) var writeInFlight = false
    private var pendingFrame: Data?
    private(set) var coalescedFrameCount = 0

    mutating func enqueue(_ frame: Data) {
        if writeInFlight { coalescedFrameCount += 1 }
        pendingFrame = frame
    }

    mutating func startNext() -> Data? {
        guard !writeInFlight, let pendingFrame else { return nil }
        self.pendingFrame = nil
        writeInFlight = true
        return pendingFrame
    }

    mutating func completeWrite() -> Data? {
        writeInFlight = false
        return startNext()
    }

    mutating func resetWriteState() {
        writeInFlight = false
    }

    mutating func reset() {
        writeInFlight = false
        pendingFrame = nil
        coalescedFrameCount = 0
    }
}

/// Queue-confined preview writer. Preview keeps only the newest pending frame;
/// control and asset writers remain independent of its backpressure.
final class BoothPreviewWritePump: @unchecked Sendable {
    private let queue: DispatchQueue
    private let secureChannel: BoothSecureChannel
    private var connection: NWConnection?
    private var connectionGeneration = 0
    private var ready = false
    private var pendingFrame: Data?
    private var inFlight = false
    private var framesSubmitted = 0
    private var framesSent = 0
    private var framesCoalesced = 0
    private var bytesSent = 0
    private var metricsStartedAt = Date()

    var onFailure: (@Sendable (String, Int) -> Void)?
    var onMetrics: (@Sendable (BoothPreviewDiagnostics) -> Void)?

    init(queue: DispatchQueue, secureChannel: BoothSecureChannel) {
        self.queue = queue
        self.secureChannel = secureChannel
    }

    func bind(_ connection: NWConnection, generation: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection = connection
            self.connectionGeneration = generation
            self.ready = false
            self.pendingFrame = nil
            self.inFlight = false
        }
    }

    func markReady(_ connection: NWConnection, generation: Int) {
        queue.async { [weak self, weak connection] in
            guard let self, let connection,
                  self.connection === connection,
                  self.connectionGeneration == generation else { return }
            self.ready = true
            self.flush()
        }
    }

    func enqueue(
        _ jpegData: Data,
        connection expectedConnection: NWConnection?,
        generation: Int
    ) {
        queue.async { [weak self, weak expectedConnection] in
            guard let self, let expectedConnection,
                  self.connection === expectedConnection,
                  self.connectionGeneration == generation else { return }
            if self.inFlight { self.framesCoalesced += 1 }
            self.framesSubmitted += 1
            self.pendingFrame = jpegData
            self.flush()
        }
    }

    func invalidate(generation: Int) {
        queue.sync { [weak self] in
            guard let self else { return }
            self.connection = nil
            self.connectionGeneration = generation
            self.ready = false
            self.pendingFrame = nil
            self.inFlight = false
        }
    }

    private func flush() {
        guard ready, !inFlight, let connection, let jpegData = pendingFrame else { return }
        pendingFrame = nil
        inFlight = true
        do {
            let payload = try secureChannel.protect(jpegData, channel: .preview)
            let frame = try BoothFrameEncoder.encode(channel: .preview, payload: payload)
            connection.send(content: frame, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection else { return }
                self.queue.async { self.complete(jpegData: jpegData, connection: connection, error: error) }
            })
        } catch {
            complete(jpegData: jpegData, connection: connection, error: error)
        }
    }

    private func complete(jpegData: Data, connection: NWConnection, error: Error?) {
        guard self.connection === connection else { return }
        inFlight = false
        if let error {
            ready = false
            onFailure?(error.localizedDescription, connectionGeneration)
            return
        }
        framesSent += 1
        bytesSent += jpegData.count
        flush()
        publishMetricsIfNeeded()
    }

    private func publishMetricsIfNeeded() {
        let now = Date()
        let elapsed = now.timeIntervalSince(metricsStartedAt)
        guard elapsed >= 1 else { return }
        var diagnostics = BoothPreviewDiagnostics()
        diagnostics.fps = Double(framesSent) / elapsed
        diagnostics.bytesPerSecond = Double(bytesSent) / elapsed
        diagnostics.framesSubmitted = framesSubmitted
        diagnostics.framesSent = framesSent
        diagnostics.framesCoalesced = framesCoalesced
        onMetrics?(diagnostics)
        metricsStartedAt = now
        framesSubmitted = 0
        framesSent = 0
        framesCoalesced = 0
        bytesSent = 0
    }
}

/// Queue-confined receiver-side preview pump. It deliberately schedules one
/// MainActor drain for a burst and replaces the pending frame while that drain
/// is waiting or decoding.
final class BoothLatestPreviewDeliveryPump: @unchecked Sendable {
    struct Snapshot: Equatable, Sendable {
        let framesReceived: Int
        let framesDelivered: Int
        let framesCoalesced: Int
        let pendingFrames: Int
    }

    private struct PendingFrame: Sendable {
        let data: Data
        let generation: Int
    }

    private let queue: DispatchQueue
    private var currentGeneration = 0
    private var pendingFrame: PendingFrame?
    private var drainScheduled = false
    private var framesReceived = 0
    private var framesDelivered = 0
    private var framesCoalesced = 0

    var onDeliver: (@MainActor @Sendable (Data, Int, Snapshot) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Call only from the transport queue. Keeping this method explicit avoids
    /// enqueueing one unbounded DispatchWorkItem per incoming preview frame.
    func enqueueOnQueue(_ data: Data, generation: Int) {
        guard generation == currentGeneration else { return }
        framesReceived += 1
        if pendingFrame != nil { framesCoalesced += 1 }
        pendingFrame = PendingFrame(data: data, generation: generation)
        scheduleDrainOnQueue()
    }

    func reset(generation: Int) {
        queue.sync {
            currentGeneration = generation
            pendingFrame = nil
        }
    }

    func resetOnQueue(generation: Int) {
        currentGeneration = generation
        pendingFrame = nil
    }

    func snapshot() -> Snapshot {
        queue.sync { snapshotOnQueue() }
    }

    private func snapshotOnQueue() -> Snapshot {
        Snapshot(
            framesReceived: framesReceived,
            framesDelivered: framesDelivered,
            framesCoalesced: framesCoalesced,
            pendingFrames: pendingFrame == nil ? 0 : 1
        )
    }

    private func scheduleDrainOnQueue() {
        guard !drainScheduled else { return }
        drainScheduled = true
        Task { @MainActor [weak self] in
            await self?.drainOnMainActor()
        }
    }

    @MainActor
    private func drainOnMainActor() async {
        while let next = await takeNextOnQueue() {
            onDeliver?(next.data, next.generation, next.snapshot)
        }
    }

    private func takeNextOnQueue() async -> (data: Data, generation: Int, snapshot: Snapshot)? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let pendingFrame = self.pendingFrame else {
                    self?.drainScheduled = false
                    continuation.resume(returning: nil)
                    return
                }
                self.pendingFrame = nil
                guard pendingFrame.generation == self.currentGeneration else {
                    self.drainScheduled = false
                    continuation.resume(returning: nil)
                    return
                }
                self.framesDelivered += 1
                continuation.resume(returning: (
                    pendingFrame.data,
                    pendingFrame.generation,
                    self.snapshotOnQueue()
                ))
            }
        }
    }
}

struct BoothTransportCallbackGate: Sendable {
    private(set) var generation = 0

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ generation: Int) -> Bool {
        generation == self.generation
    }
}

/// Invalidated with its owning connection so queued receive callbacks cannot
/// deliver frames or refresh liveness after that connection is replaced.
final class BoothTransportReceiveToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    private var didStart = false

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard valid, !didStart else { return false }
        didStart = true
        return true
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

/// Queue-confined monotonic heartbeat state. The unchecked marker is limited
/// to this small value object; callers must access it only on the transport
/// queue, where the timer and receive callback are serialized.
final class BoothTransportHeartbeatState: @unchecked Sendable {
    private var lastActivity = DispatchTime.now().uptimeNanoseconds
    private var timeoutReported = false

    func markActivity() {
        lastActivity = DispatchTime.now().uptimeNanoseconds
        timeoutReported = false
    }

    func shouldReportTimeout(after timeout: TimeInterval) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now >= lastActivity
            ? Double(now - lastActivity) / 1_000_000_000
            : 0
        guard elapsed >= timeout, !timeoutReported else { return false }
        timeoutReported = true
        return true
    }

    func reset() {
        lastActivity = DispatchTime.now().uptimeNanoseconds
        timeoutReported = false
    }
}

public struct BoothNetworkFrame: Equatable, Sendable {
    public let channel: BoothTransportChannel
    public let payload: Data

    public init(channel: BoothTransportChannel, payload: Data) {
        self.channel = channel
        self.payload = payload
    }
}

public enum BoothFrameError: Error, Equatable, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownChannel(UInt8)
    case oversizedPayload(Int)
    case invalidMessage
}

public struct BoothFrameParser: Sendable {
    public static let protocolVersion: UInt8 = 1
    public static let maximumPayloadLength = 2 * 1024 * 1024
    public static let targetControlPayloadLength = 128 * 1024
    public static let maximumControlPayloadLength = 256 * 1024

    private static let headerLength = 8
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [BoothNetworkFrame] {
        buffer.append(data)
        var frames: [BoothNetworkFrame] = []
        while buffer.count >= Self.headerLength {
            let start = buffer.startIndex
            guard buffer[start] == 0x50,
                  buffer[buffer.index(start, offsetBy: 1)] == 0x52 else {
                throw BoothFrameError.invalidMagic
            }
            let versionIndex = buffer.index(start, offsetBy: 2)
            guard buffer[versionIndex] == Self.protocolVersion else {
                throw BoothFrameError.unsupportedVersion(buffer[versionIndex])
            }
            let rawChannel = buffer[buffer.index(start, offsetBy: 3)]
            guard let channel = BoothTransportChannel(rawValue: rawChannel) else {
                throw BoothFrameError.unknownChannel(rawChannel)
            }
            let lengthStart = buffer.index(start, offsetBy: 4)
            let lengthByte0 = UInt32(buffer[lengthStart])
            let lengthByte1 = UInt32(buffer[buffer.index(lengthStart, offsetBy: 1)])
            let lengthByte2 = UInt32(buffer[buffer.index(lengthStart, offsetBy: 2)])
            let lengthByte3 = UInt32(buffer[buffer.index(lengthStart, offsetBy: 3)])
            let rawLength = (lengthByte0 << 24)
                | (lengthByte1 << 16)
                | (lengthByte2 << 8)
                | lengthByte3
            let length = Int(rawLength)
            guard length <= Self.maximumPayloadLength else {
                throw BoothFrameError.oversizedPayload(length)
            }
            guard buffer.count >= Self.headerLength + length else { break }
            let payloadStart = buffer.index(start, offsetBy: Self.headerLength)
            let payloadEnd = buffer.index(payloadStart, offsetBy: length)
            let payload = Data(buffer[payloadStart..<payloadEnd])
            frames.append(BoothNetworkFrame(channel: channel, payload: payload))
            buffer.removeSubrange(start..<payloadEnd)
        }
        return frames
    }

    public var bufferedByteCount: Int { buffer.count }
}

public enum BoothFrameEncoder {
    public static func encode(channel: BoothTransportChannel, payload: Data) throws -> Data {
        guard payload.count <= BoothFrameParser.maximumPayloadLength else {
            throw BoothFrameError.oversizedPayload(payload.count)
        }
        guard channel != .control || payload.count <= BoothFrameParser.maximumControlPayloadLength else {
            throw BoothFrameError.oversizedPayload(payload.count)
        }
        var frame = Data([0x50, 0x52, BoothFrameParser.protocolVersion, channel.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

enum BoothDecodedTransportFrame: Sendable {
    case control(Message)
    case assetBinding(BoothChannelBindingHello)
    case asset(BoothAssetChunk)
    case heartbeat
    case previewHello(Data)
    case preview(Data)
}

/// Network callbacks own this decoder on the transport serial queue. Keeping
/// framing and JSON decoding here prevents a burst of preview/control bytes
/// from making the MainActor do parser work before it can render UI.
final class BoothTransportFrameDecoder: @unchecked Sendable {
    private var controlParser = BoothFrameParser()
    private var previewParser = BoothFrameParser()
    private var assetParser = BoothFrameParser()

    func reset(_ channel: BoothTransportChannel) {
        switch channel {
        case .control: controlParser = BoothFrameParser()
        case .preview: previewParser = BoothFrameParser()
        case .asset: assetParser = BoothFrameParser()
        case .heartbeat: break
        }
    }

    func decode(
        _ data: Data,
        channel: BoothTransportChannel,
        secureChannel: BoothSecureChannel? = nil
    ) throws -> [BoothDecodedTransportFrame] {
        let parsed: [BoothNetworkFrame]
        switch channel {
        case .control: parsed = try controlParser.append(data)
        case .preview: parsed = try previewParser.append(data)
        case .asset: parsed = try assetParser.append(data)
        case .heartbeat: parsed = try controlParser.append(data)
        }
        return try parsed.compactMap { frame in
            guard frame.channel == channel
                    || (channel == .control && frame.channel == .heartbeat) else { return nil }
            switch frame.channel {
            case .control:
                let payload: Data
                if let secureChannel, secureChannel.isConfigured,
                   let bootstrap = try? Message.decoded(from: frame.payload),
                   bootstrap.isSecureChannelBootstrap {
                    payload = frame.payload
                } else if let secureChannel, secureChannel.isConfigured {
                    payload = try secureChannel.open(frame.payload, channel: .control)
                } else {
                    payload = frame.payload
                }
                guard let message = try? Message.decoded(from: payload) else {
                    throw BoothFrameError.invalidMessage
                }
                return .control(message)
            case .asset:
                guard let secureChannel, secureChannel.isConfigured else {
                    throw BoothSecureChannelError.notReady
                }
                let payload = try secureChannel.open(frame.payload, channel: .asset)
                if let binding = try BoothAssetTransfer.decodeBinding(payload) {
                    return .assetBinding(binding)
                }
                return .asset(try BoothAssetTransfer.decode(payload))
            case .heartbeat:
                // Heartbeats are authenticated Message.heartbeat values on
                // the ordered control channel. A separate raw channel must
                // never refresh liveness or bypass the secure channel.
                throw BoothFrameError.invalidMessage
            case .preview:
                let payload: Data
                if let secureChannel, secureChannel.isConfigured {
                    payload = try secureChannel.open(frame.payload, channel: .preview)
                } else {
                    payload = frame.payload
                }
                if (try? JSONDecoder().decode(BoothTransportHello.self, from: payload)) != nil {
                    return .previewHello(payload)
                }
                return .preview(payload)
            }
        }
    }
}
