import Foundation
import Observation

public enum BoothConnectionState: Codable, Equatable, Sendable {
    case disconnected
    case connecting
    case connected(peerName: String)
}

@MainActor
@Observable
public final class BoothConnectionStatus {
    public private(set) var state: BoothConnectionState = .disconnected
    public private(set) var peerID: String?
    public private(set) var peerDisplayName: String?
    public private(set) var connectedPeerNames: [String] = []
    public private(set) var requestedNetwork: BoothNetworkPreference
    public private(set) var effectiveNetwork: BoothEffectiveNetworkTransport = .unavailable
    public private(set) var routeState: BoothNetworkRouteState = .disconnected
    public private(set) var fallbackReason: String?
    public private(set) var isLANPathAvailable = false
    public private(set) var isWiFiPathAvailable = false

    public var isFallbackActive: Bool {
        if case .fallbackWiFi = routeState { return true }
        return false
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
        isWiFiPathAvailable: Bool = false
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
    }

    public func publishPathAvailability(lan: Bool, wifi: Bool) {
        isLANPathAvailable = lan
        isWiFiPathAvailable = wifi
    }

    public func publishDisconnected() {
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
    func sendControl(_ message: Message)
    func sendPreviewFrame(_ jpegData: Data)
    func disconnect()
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
