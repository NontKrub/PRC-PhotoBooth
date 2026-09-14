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
    case routeViabilityChanged
    case pathHintUnavailableIgnored
    case secondaryCandidateRejected
    case waitingRecoveryScheduled
    case waitingRecoveryCancelled
    case ipadAppForegrounded
    case ipadAppBackgrounded
}

public struct BoothTransportDiagnosticEvent: Codable, Sendable, Equatable {
    public let kind: BoothTransportDiagnosticKind
    public let timestamp: Date
    public let channel: String?
    public let route: String?
    public let attempt: Int?
    public let byteCount: Int?
    public let duration: TimeInterval?
    public let reason: String?

    public init(
        kind: BoothTransportDiagnosticKind,
        timestamp: Date = Date(),
        channel: String? = nil,
        route: String? = nil,
        attempt: Int? = nil,
        byteCount: Int? = nil,
        duration: TimeInterval? = nil,
        reason: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.channel = channel
        self.route = route
        self.attempt = attempt
        self.byteCount = byteCount
        self.duration = duration
        self.reason = reason
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
                guard channel == .control else { throw BoothFrameError.invalidMessage }
                return .heartbeat
            case .preview:
                if let secureChannel, secureChannel.isConfigured {
                    return .preview(try secureChannel.open(frame.payload, channel: .preview))
                }
                return .preview(frame.payload)
            }
        }
    }
}
