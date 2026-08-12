import Foundation

// Selects the high-bandwidth preview transport. Session controls use the
// selected BoothTransport; USB remains an optional preview-only path.
public enum PreviewTransport: String, Codable, Sendable {
    case wireless
    case usb
}

public enum CaptureFailureReason: String, Codable, Sendable, Equatable {
    case transferTimeout
    case cameraBusy
    case cameraDisconnected
    case downloadFailed
    case decodeFailed
    case ptpFailure
    case unknown
}

public struct CaptureFailureSummary: Codable, Sendable, Equatable {
    public var photoIndex: Int
    public var reason: CaptureFailureReason
    public var message: String
    public var shutterLikelyFired: Bool
    public var canRetryReceive: Bool
    public var canUsePreviousPhoto: Bool
    public var canContinueSession: Bool

    public init(
        photoIndex: Int,
        reason: CaptureFailureReason,
        message: String,
        shutterLikelyFired: Bool,
        canRetryReceive: Bool,
        canUsePreviousPhoto: Bool,
        canContinueSession: Bool
    ) {
        self.photoIndex = photoIndex
        self.reason = reason
        self.message = message
        self.shutterLikelyFired = shutterLikelyFired
        self.canRetryReceive = canRetryReceive
        self.canUsePreviousPhoto = canUsePreviousPhoto
        self.canContinueSession = canContinueSession
    }
}

public enum CaptureRecoveryAction: Codable, Sendable, Equatable {
    case retryReceive(photoIndex: Int)
    case retake(photoIndex: Int)
    case continueSession(photoIndex: Int)
    case usePrevious(photoIndex: Int)
}

public struct BoothTransportHello: Codable, Sendable, Equatable {
    public static let currentProtocolVersion = 1

    public var protocolVersion: Int
    public var appVersion: String
    public var role: DeviceRole
    public var deviceID: String
    public var capabilities: [String]

    public init(
        role: DeviceRole,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        deviceID: String = UUID().uuidString,
        capabilities: [String] = ["control", "preview", "state-sync"]
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.appVersion = appVersion
        self.role = role
        self.deviceID = deviceID
        self.capabilities = capabilities
    }
}

public struct SessionSyncSnapshot: Codable, Sendable, Equatable {
    public var config: EventConfig
    public var sessionID: String?
    public var phase: BoothPhase
    public var presentation: SessionPresentation?
    public var reviewThumbnailData: Data?
    public var stripThumbnailData: Data?
    public var isMirrored: Bool
    public var isBoothPaused: Bool

    public init(
        config: EventConfig,
        sessionID: String?,
        phase: BoothPhase,
        presentation: SessionPresentation?,
        reviewThumbnailData: Data? = nil,
        stripThumbnailData: Data? = nil,
        isMirrored: Bool,
        isBoothPaused: Bool = false
    ) {
        self.config = config
        self.sessionID = sessionID
        self.phase = phase
        self.presentation = presentation
        self.reviewThumbnailData = reviewThumbnailData
        self.stripThumbnailData = stripThumbnailData
        self.isMirrored = isMirrored
        self.isBoothPaused = isBoothPaused
    }
}

// All control messages exchanged over BoothTransport's reliable control channel.
public enum Message: Codable, Sendable, Equatable {
    case hello(role: DeviceRole)
    case helloDetails(hello: BoothTransportHello)
    case sessionSync(snapshot: SessionSyncSnapshot)
    case boothPaused(isPaused: Bool)
    case eventConfig(config: EventConfig)
    case eventExperienceCatalog(catalog: CustomerExperienceCatalog)
    case eventExperienceAsset(packet: ExperienceAssetPacket)
    case setMirrored(isMirrored: Bool)
    case setPreviewTransport(transport: PreviewTransport)
    case sessionStart
    case customerSessionRequest(selection: CustomerSessionSelection)
    case sessionRequestRejected(reason: String)
    case sessionPrepared(config: EventConfig, presentation: SessionPresentation)
    case beginCountdown(photoIndex: Int, seconds: Int)
    case shotCaptured(index: Int, thumbnailData: Data)
    case captureRecovery(photoIndex: Int, failure: CaptureFailureSummary)
    case captureRecoveryAction(action: CaptureRecoveryAction)
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
