import Foundation

/// Encrypted binding for a secondary socket. The control handshake remains
/// authoritative; this proves that the asset socket is using the same secure
/// session and authenticated device identities.
public struct BoothChannelBindingHello: Codable, Equatable, Sendable {
    public static let protocolVersion = 1

    public let protocolVersion: Int
    public let secureSessionID: String
    public let channel: BoothTransportChannel
    public let senderDeviceID: String
    public let receiverDeviceID: String

    public init(
        secureSessionID: String,
        channel: BoothTransportChannel,
        senderDeviceID: String,
        receiverDeviceID: String
    ) {
        self.protocolVersion = Self.protocolVersion
        self.secureSessionID = secureSessionID
        self.channel = channel
        self.senderDeviceID = senderDeviceID
        self.receiverDeviceID = receiverDeviceID
    }

    public var isWellFormed: Bool {
        protocolVersion == Self.protocolVersion
            && !secureSessionID.isEmpty
            && channel == .asset
            && !senderDeviceID.isEmpty
            && !receiverDeviceID.isEmpty
    }
}
