import Foundation

// Selects the high-bandwidth preview transport. Session controls continue to
// use the MultipeerConnectivity control channel.
public enum PreviewTransport: String, Codable, Sendable {
    case wireless
    case usb
}

// All control messages exchanged over MultipeerConnectivity reliable channel.
public enum Message: Codable, Sendable {
    case hello(role: DeviceRole)
    case eventConfig(config: EventConfig)
    case setMirrored(isMirrored: Bool)
    case setPreviewTransport(transport: PreviewTransport)
    case sessionStart
    case beginCountdown(photoIndex: Int, seconds: Int)
    case shotCaptured(index: Int, thumbnailData: Data)
    case reviewDecision(action: ReviewAction)
    case sessionFinished(qrPayload: String, stripThumbData: Data?, gifThumbData: Data?)
    case operatorOverride(action: OperatorAction)
    case heartbeat
}

// Wire-level packet differentiates control vs preview stream.
// First byte: 0x01 = control (JSON-encoded Message), 0x02 = preview frame (raw JPEG)
enum PacketChannel: UInt8 {
    case control = 0x01
    case preview = 0x02
}

extension Data {
    func packedAsControl() -> Data {
        var out = Data([PacketChannel.control.rawValue])
        out.append(self)
        return out
    }

    func packedAsPreview() -> Data {
        var out = Data([PacketChannel.preview.rawValue])
        out.append(self)
        return out
    }

    // Returns (channel, payload) or nil if malformed
    func unpackedPacket() -> (PacketChannel, Data)? {
        guard count >= 2, let channel = PacketChannel(rawValue: self[0]) else { return nil }
        return (channel, dropFirst())
    }
}

// Encode / decode helpers
extension Message {
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decoded(from data: Data) throws -> Message {
        try JSONDecoder().decode(Message.self, from: data)
    }
}
