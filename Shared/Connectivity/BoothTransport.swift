import Foundation
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

    public var isFallbackActive: Bool {
        if case .fallbackWiFi = routeState { return true }
        return fallbackReason != nil && requestedNetwork == .lan
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

    public func publishPreviewDiagnostics(_ diagnostics: BoothPreviewDiagnostics) {
        previewDiagnostics = diagnostics
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

    func start()
    func restart()
    func sendControl(_ message: Message)
    func sendPreviewFrame(_ jpegData: Data)
    func disconnect()
}

public extension BoothTransport {
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

struct BoothTransportCallbackGate: Sendable {
    private(set) var generation = 0

    mutating func invalidate() {
        generation &+= 1
    }

    func accepts(_ generation: Int) -> Bool {
        generation == self.generation
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
}

public struct BoothFrameParser: Sendable {
    public static let protocolVersion: UInt8 = 1
    public static let maximumPayloadLength = 2 * 1024 * 1024

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
        var frame = Data([0x50, 0x52, BoothFrameParser.protocolVersion, channel.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}
