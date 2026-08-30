import Foundation

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

public struct SessionMessageContext: Codable, Sendable, Equatable, Hashable {
    public var sessionID: String
    public var sequence: UInt64

    public init(sessionID: String, sequence: UInt64) {
        self.sessionID = sessionID
        self.sequence = sequence
    }
}

public struct CountdownDescriptor: Codable, Sendable, Equatable {
    public var photoIndex: Int
    public var captureAt: Date

    public init(photoIndex: Int, captureAt: Date) {
        self.photoIndex = photoIndex
        self.captureAt = captureAt
    }
}

// The iPad uses one gate for every Mac-issued, session-sensitive message.
// A reconnect snapshot moves the baseline forward before queued packets can apply.
public struct SessionMessageGate: Sendable, Equatable {
    public private(set) var currentSessionID: String?
    public private(set) var latestAcceptedSequence: UInt64

    public init(currentSessionID: String? = nil, latestAcceptedSequence: UInt64 = 0) {
        self.currentSessionID = currentSessionID
        self.latestAcceptedSequence = latestAcceptedSequence
    }

    public mutating func synchronize(sessionID: String?, sequence: UInt64) {
        currentSessionID = sessionID
        latestAcceptedSequence = sessionID == nil ? 0 : sequence
    }

    public mutating func accept(_ context: SessionMessageContext) -> Bool {
        guard let currentSessionID,
              context.sessionID == currentSessionID,
              context.sequence > latestAcceptedSequence else {
            return false
        }
        latestAcceptedSequence = context.sequence
        return true
    }
}

public enum CaptureRecoveryAction: Codable, Sendable, Equatable {
    case retryReceive(photoIndex: Int)
    case retake(photoIndex: Int)
    case continueSession(photoIndex: Int)
    case usePrevious(photoIndex: Int)
}

public struct BoothTransportHello: Codable, Sendable, Equatable {
    public static let currentProtocolVersion = 3

    public var protocolVersion: Int
    public var appVersion: String
    public var role: DeviceRole
    public var deviceID: String
    public var deviceName: String
    public var capabilities: [String]
    public var networkPreference: BoothNetworkPreference?

    public init(
        role: DeviceRole,
        appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
        deviceID: String = UUID().uuidString,
        deviceName: String? = nil,
        capabilities: [String] = ["control", "preview", "state-sync", "preview-identity", "pairing-v1"],
        networkPreference: BoothNetworkPreference? = .wifi
    ) {
        self.protocolVersion = Self.currentProtocolVersion
        self.appVersion = appVersion
        self.role = role
        self.deviceID = deviceID
        self.deviceName = deviceName?.isEmpty == false ? deviceName! : deviceID
        self.capabilities = capabilities
        self.networkPreference = networkPreference
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion
        case appVersion
        case role
        case deviceID
        case deviceName
        case capabilities
        case networkPreference
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        role = try container.decode(DeviceRole.self, forKey: .role)
        deviceID = try container.decode(String.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? deviceID
        capabilities = try container.decode([String].self, forKey: .capabilities)
        networkPreference = try container.decodeIfPresent(BoothNetworkPreference.self, forKey: .networkPreference)
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
    public var sequence: UInt64
    public var countdown: CountdownDescriptor?
    public var keptShots: [Int: Data]
    public var acceptedPhotoIndices: [Int]
    public var deferredPhotoIndices: [Int]
    public var nextPhotoIndex: Int

    public init(
        config: EventConfig,
        sessionID: String?,
        phase: BoothPhase,
        presentation: SessionPresentation?,
        reviewThumbnailData: Data? = nil,
        stripThumbnailData: Data? = nil,
        isMirrored: Bool,
        isBoothPaused: Bool = false,
        sequence: UInt64 = 0,
        countdown: CountdownDescriptor? = nil,
        keptShots: [Int: Data] = [:],
        acceptedPhotoIndices: [Int] = [],
        deferredPhotoIndices: [Int] = [],
        nextPhotoIndex: Int = 0
    ) {
        self.config = config
        self.sessionID = sessionID
        self.phase = phase
        self.presentation = presentation
        self.reviewThumbnailData = reviewThumbnailData
        self.stripThumbnailData = stripThumbnailData
        self.isMirrored = isMirrored
        self.isBoothPaused = isBoothPaused
        self.sequence = sequence
        self.countdown = countdown
        self.keptShots = keptShots
        self.acceptedPhotoIndices = acceptedPhotoIndices
        self.deferredPhotoIndices = deferredPhotoIndices
        self.nextPhotoIndex = nextPhotoIndex
    }
}

// All control messages exchanged over BoothTransport's reliable control channel.
public enum Message: Codable, Sendable, Equatable {
    case hello(role: DeviceRole)
    case helloDetails(hello: BoothTransportHello)
    case pairingIntent(intent: BoothPairingIntent)
    case pairingSessionAvailable(session: BoothPairingSessionInfo)
    case pairingRequest(request: BoothPairingRequest)
    case pairingResult(result: BoothPairingResult)
    case authChallenge(challenge: BoothAuthChallenge)
    case authProof(proof: BoothAuthProof)
    case connectionRejected(reason: String)
    case sessionSync(snapshot: SessionSyncSnapshot)
    case boothPaused(isPaused: Bool)
    case eventConfig(config: EventConfig)
    case eventExperienceCatalog(catalog: CustomerExperienceCatalog)
    case eventExperienceAsset(packet: ExperienceAssetPacket)
    case setMirrored(isMirrored: Bool)
    case sessionStart(context: SessionMessageContext?)
    case customerSessionRequest(selection: CustomerSessionSelection)
    case sessionRequestRejected(reason: String)
    case sessionPrepared(config: EventConfig, presentation: SessionPresentation, context: SessionMessageContext)
    case beginCountdown(context: SessionMessageContext, descriptor: CountdownDescriptor)
    case shotCaptured(context: SessionMessageContext, index: Int, thumbnailData: Data)
    case captureRecovery(context: SessionMessageContext, photoIndex: Int, failure: CaptureFailureSummary)
    case captureRecoveryAction(context: SessionMessageContext, action: CaptureRecoveryAction)
    case reviewDecision(context: SessionMessageContext, action: ReviewAction)
    case sessionFinished(context: SessionMessageContext, qrPayload: String, stripThumbData: Data?, gifThumbData: Data?)
    case operatorOverride(context: SessionMessageContext?, action: OperatorAction)
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
