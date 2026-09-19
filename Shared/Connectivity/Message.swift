import CryptoKit
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

public struct ReviewStateToken: Codable, Sendable, Equatable, Hashable {
    public let sessionID: String
    public let photoIndex: Int
    public let revision: UInt64

    public init(sessionID: String, photoIndex: Int, revision: UInt64) {
        self.sessionID = sessionID
        self.photoIndex = photoIndex
        self.revision = revision
    }
}

public enum ReviewDecisionResult: String, Codable, Sendable, Equatable {
    case accepted
    case duplicate
    case stale
    case wrongPhoto
    case sessionChanged
    case persistenceFailed
}

public enum ReviewDecisionGate {
    public static func validate(
        current: ReviewStateToken?,
        phasePhotoIndex: Int?,
        requested: ReviewStateToken
    ) -> ReviewDecisionResult {
        guard let current else { return .stale }
        guard current.sessionID == requested.sessionID else { return .sessionChanged }
        guard current.photoIndex == requested.photoIndex,
              phasePhotoIndex == requested.photoIndex else { return .wrongPhoto }
        guard current.revision == requested.revision else { return .stale }
        return .accepted
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
        latestAcceptedSequence = sequence
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
    public static let currentProtocolVersion = 7

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
        capabilities: [String] = [
            "control",
            "preview",
            "state-sync",
            "preview-identity",
            "pairing-v2",
            "secure-channel-v1",
            "asset-channel-v2"
        ],
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

public enum BoothAssetKind: String, Codable, Sendable, Equatable {
    case templatePreview
    case promptImage
    case reviewImage
    case stripThumbnail
    case gifThumbnail
}

public struct BoothAssetReference: Codable, Sendable, Equatable, Hashable {
    public let assetID: String
    public let sessionID: String?
    public let revision: String
    public let kind: BoothAssetKind
    public let byteCount: Int
    public let sha256: Data

    public init(
        assetID: String,
        sessionID: String? = nil,
        revision: String,
        kind: BoothAssetKind,
        byteCount: Int,
        sha256: Data
    ) {
        self.assetID = assetID
        self.sessionID = sessionID
        self.revision = revision
        self.kind = kind
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct BoothAssetChunkMetadata: Codable, Sendable, Equatable, Hashable {
    public let assetID: String
    public let sessionID: String?
    public let revision: String
    public let kind: BoothAssetKind
    public let index: Int
    public let count: Int
    public let totalBytes: Int
    public let sha256: Data

    public init(
        assetID: String,
        sessionID: String? = nil,
        revision: String,
        kind: BoothAssetKind,
        index: Int,
        count: Int,
        totalBytes: Int,
        sha256: Data
    ) {
        self.assetID = assetID
        self.sessionID = sessionID
        self.revision = revision
        self.kind = kind
        self.index = index
        self.count = count
        self.totalBytes = totalBytes
        self.sha256 = sha256
    }

    public var reference: BoothAssetReference {
        BoothAssetReference(
            assetID: assetID,
            sessionID: sessionID,
            revision: revision,
            kind: kind,
            byteCount: totalBytes,
            sha256: sha256
        )
    }
}

public struct BoothAssetChunk: Codable, Sendable, Equatable {
    public let metadata: BoothAssetChunkMetadata
    public let data: Data

    public init(metadata: BoothAssetChunkMetadata, data: Data) {
        self.metadata = metadata
        self.data = data
    }
}

public enum BoothAssetTransferError: Error, Equatable, Sendable {
    case invalidMetadata
    case malformedFrame
    case metadataTooLarge(Int)
    case chunkTooLarge(Int)
    case assetTooLarge(Int)
    case duplicateChunk
    case inconsistentMetadata
    case incompleteAsset
    case hashMismatch
    case tooManyConcurrentAssets
    case bufferedAssetBytesExceeded
}

public enum BoothAssetTransfer {
    public static let maximumChunkBytes = 256 * 1024
    public static let maximumAssetBytes = 8 * 1024 * 1024
    public static let maximumChunkCount = 128
    public static let maximumConcurrentAssets = 16
    public static let maximumBufferedAssetBytes = 32 * 1024 * 1024
    private static let magic = Data([0x50, 0x52, 0x41, 0x31])
    private static let bindingMagic = Data([0x50, 0x52, 0x42, 0x31])

    public static func chunks(
        data: Data,
        reference: BoothAssetReference,
        chunkSize: Int = 192 * 1024
    ) throws -> [BoothAssetChunk] {
        guard valid(reference: reference), data.count == reference.byteCount else {
            throw BoothAssetTransferError.invalidMetadata
        }
        guard data.count <= maximumAssetBytes else {
            throw BoothAssetTransferError.assetTooLarge(data.count)
        }
        let size = min(max(1, chunkSize), maximumChunkBytes)
        let count = max(1, (data.count + size - 1) / size)
        guard count <= maximumChunkCount else { throw BoothAssetTransferError.assetTooLarge(data.count) }
        return (0..<count).map { index in
            let start = index * size
            let end = min(data.count, start + size)
            return BoothAssetChunk(
                metadata: BoothAssetChunkMetadata(
                    assetID: reference.assetID,
                    sessionID: reference.sessionID,
                    revision: reference.revision,
                    kind: reference.kind,
                    index: index,
                    count: count,
                    totalBytes: reference.byteCount,
                    sha256: reference.sha256
                ),
                data: Data(data[start..<end])
            )
        }
    }

    public static func encode(_ chunk: BoothAssetChunk) throws -> Data {
        guard valid(metadata: chunk.metadata),
              !chunk.data.isEmpty,
              chunk.data.count <= maximumChunkBytes else {
            throw chunk.data.count > maximumChunkBytes
                ? BoothAssetTransferError.chunkTooLarge(chunk.data.count)
                : BoothAssetTransferError.invalidMetadata
        }
        let metadata = try JSONEncoder().encode(chunk.metadata)
        guard metadata.count <= 8 * 1024 else {
            throw BoothAssetTransferError.metadataTooLarge(metadata.count)
        }
        var result = magic
        appendUInt32(UInt32(metadata.count), to: &result)
        result.append(metadata)
        result.append(chunk.data)
        return result
    }

    public static func encodeBinding(_ binding: BoothChannelBindingHello) throws -> Data {
        guard binding.isWellFormed else {
            throw BoothAssetTransferError.invalidMetadata
        }
        let payload = try JSONEncoder().encode(binding)
        guard payload.count <= 8 * 1024 else {
            throw BoothAssetTransferError.metadataTooLarge(payload.count)
        }
        var result = bindingMagic
        appendUInt32(UInt32(payload.count), to: &result)
        result.append(payload)
        return result
    }

    public static func decodeBinding(_ data: Data) throws -> BoothChannelBindingHello? {
        guard data.count >= bindingMagic.count else { return nil }
        guard data.prefix(bindingMagic.count) == bindingMagic else { return nil }
        let payloadLength = try readUInt32(data, offset: bindingMagic.count)
        guard payloadLength <= 8 * 1024 else {
            throw BoothAssetTransferError.metadataTooLarge(Int(payloadLength))
        }
        let payloadStart = bindingMagic.count + 4
        let payloadEnd = payloadStart + Int(payloadLength)
        guard payloadEnd == data.count else {
            throw BoothAssetTransferError.malformedFrame
        }
        let binding = try JSONDecoder().decode(
            BoothChannelBindingHello.self,
            from: data[payloadStart..<payloadEnd]
        )
        guard binding.isWellFormed else {
            throw BoothAssetTransferError.invalidMetadata
        }
        return binding
    }

    public static func decode(_ data: Data) throws -> BoothAssetChunk {
        guard data.count >= magic.count + 4,
              data.prefix(magic.count) == magic else {
            throw BoothAssetTransferError.malformedFrame
        }
        let metadataLength = try readUInt32(data, offset: magic.count)
        guard metadataLength <= 8 * 1024 else {
            throw BoothAssetTransferError.metadataTooLarge(Int(metadataLength))
        }
        let metadataStart = magic.count + 4
        let metadataEnd = metadataStart + Int(metadataLength)
        guard metadataEnd < data.count else { throw BoothAssetTransferError.malformedFrame }
        let metadata = try JSONDecoder().decode(
            BoothAssetChunkMetadata.self,
            from: data[metadataStart..<metadataEnd]
        )
        let chunkData = Data(data[metadataEnd...])
        guard chunkData.count <= maximumChunkBytes else {
            throw BoothAssetTransferError.chunkTooLarge(chunkData.count)
        }
        guard valid(metadata: metadata), !chunkData.isEmpty else {
            throw BoothAssetTransferError.invalidMetadata
        }
        return BoothAssetChunk(metadata: metadata, data: chunkData)
    }

    static func isValidForAssembly(_ chunk: BoothAssetChunk) -> Bool {
        valid(metadata: chunk.metadata)
            && !chunk.data.isEmpty
            && chunk.data.count <= maximumChunkBytes
            && chunk.data.count <= chunk.metadata.totalBytes
    }

    private static func valid(reference: BoothAssetReference) -> Bool {
        reference.byteCount >= 0 && reference.byteCount <= maximumAssetBytes
            && !reference.assetID.isEmpty && reference.assetID.count <= 128
            && reference.revision.count <= 128
            && reference.sha256.count == SHA256.Digest.byteCount
    }

    private static func valid(metadata: BoothAssetChunkMetadata) -> Bool {
        valid(reference: metadata.reference)
            && metadata.count > 0 && metadata.count <= maximumChunkCount
            && metadata.index >= 0 && metadata.index < metadata.count
            && metadata.totalBytes > 0
            && metadata.totalBytes <= maximumAssetBytes
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, offset: Int) throws -> UInt32 {
        guard offset >= 0, data.count >= offset + 4 else {
            throw BoothAssetTransferError.malformedFrame
        }
        return data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

public struct BoothAssetAssembler: Sendable {
    public static let assemblyLifetime: TimeInterval = 120
    private let clock = ContinuousClock()

    private struct Assembly: Sendable {
        let metadata: BoothAssetChunkMetadata
        var chunks: [Int: Data]
        var receivedBytes: Int
        var touchedAt: ContinuousClock.Instant
    }

    private var assemblies: [String: Assembly] = [:]
    private var bufferedBytes = 0

    public init() {}

    private mutating func evictStale(now: ContinuousClock.Instant) {
        let staleKeys = assemblies.compactMap { key, assembly in
            now - assembly.touchedAt > .seconds(Self.assemblyLifetime) ? key : nil
        }
        for key in staleKeys {
            if let assembly = assemblies.removeValue(forKey: key) {
                bufferedBytes -= assembly.receivedBytes
            }
        }
    }

    public mutating func append(_ chunk: BoothAssetChunk) throws -> (BoothAssetReference, Data)? {
        try append(chunk, now: clock.now)
    }

    public mutating func append(
        _ chunk: BoothAssetChunk,
        now: ContinuousClock.Instant
    ) throws -> (BoothAssetReference, Data)? {
        evictStale(now: now)
        guard BoothAssetTransfer.isValidForAssembly(chunk) else {
            throw BoothAssetTransferError.invalidMetadata
        }
        let key = [
            chunk.metadata.assetID,
            chunk.metadata.sessionID ?? "",
            chunk.metadata.revision,
            chunk.metadata.kind.rawValue
        ].joined(separator: "\u{1f}")
        if var assembly = assemblies[key] {
            guard assembly.metadata.reference == chunk.metadata.reference,
                  assembly.metadata.count == chunk.metadata.count else {
                throw BoothAssetTransferError.inconsistentMetadata
            }
            if let existing = assembly.chunks[chunk.metadata.index] {
                guard existing == chunk.data else { throw BoothAssetTransferError.duplicateChunk }
                return nil
            }
            guard bufferedBytes + chunk.data.count <= BoothAssetTransfer.maximumBufferedAssetBytes else {
                assemblies.removeValue(forKey: key)
                bufferedBytes -= assembly.receivedBytes
                throw BoothAssetTransferError.bufferedAssetBytesExceeded
            }
            assembly.chunks[chunk.metadata.index] = chunk.data
            assembly.touchedAt = now
            assembly.receivedBytes += chunk.data.count
            bufferedBytes += chunk.data.count
            guard assembly.receivedBytes <= chunk.metadata.totalBytes else {
                assemblies.removeValue(forKey: key)
                bufferedBytes -= assembly.receivedBytes
                throw BoothAssetTransferError.inconsistentMetadata
            }
            assemblies[key] = assembly
        } else {
            guard assemblies.count < BoothAssetTransfer.maximumConcurrentAssets else {
                throw BoothAssetTransferError.tooManyConcurrentAssets
            }
            guard bufferedBytes + chunk.data.count <= BoothAssetTransfer.maximumBufferedAssetBytes else {
                throw BoothAssetTransferError.bufferedAssetBytesExceeded
            }
            assemblies[key] = Assembly(
                metadata: chunk.metadata,
                chunks: [chunk.metadata.index: chunk.data],
                receivedBytes: chunk.data.count,
                touchedAt: now
            )
            bufferedBytes += chunk.data.count
        }

        guard let assembly = assemblies[key],
              assembly.chunks.count == assembly.metadata.count else { return nil }
        guard assembly.receivedBytes == assembly.metadata.totalBytes else {
            assemblies.removeValue(forKey: key)
            bufferedBytes -= assembly.receivedBytes
            throw BoothAssetTransferError.incompleteAsset
        }
        var result = Data(capacity: assembly.metadata.totalBytes)
        for index in 0..<assembly.metadata.count {
            guard let chunkData = assembly.chunks[index] else {
                assemblies.removeValue(forKey: key)
                bufferedBytes -= assembly.receivedBytes
                throw BoothAssetTransferError.incompleteAsset
            }
            result.append(chunkData)
        }
        guard Data(SHA256.hash(data: result)) == assembly.metadata.sha256 else {
            assemblies.removeValue(forKey: key)
            bufferedBytes -= assembly.receivedBytes
            throw BoothAssetTransferError.hashMismatch
        }
        assemblies.removeValue(forKey: key)
        bufferedBytes -= assembly.receivedBytes
        return (assembly.metadata.reference, result)
    }

    public mutating func reset() {
        assemblies.removeAll()
        bufferedBytes = 0
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
    public var reviewAsset: BoothAssetReference?
    public var stripAsset: BoothAssetReference?
    public var keptShotAssets: [Int: BoothAssetReference]
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
        reviewAsset: BoothAssetReference? = nil,
        stripAsset: BoothAssetReference? = nil,
        keptShotAssets: [Int: BoothAssetReference] = [:],
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
        self.reviewAsset = reviewAsset
        self.stripAsset = stripAsset
        self.keptShotAssets = keptShotAssets
        self.acceptedPhotoIndices = acceptedPhotoIndices
        self.deferredPhotoIndices = deferredPhotoIndices
        self.nextPhotoIndex = nextPhotoIndex
    }

    private enum CodingKeys: String, CodingKey {
        case config, sessionID, phase, presentation, reviewAsset, stripAsset
        case keptShotAssets, isMirrored, isBoothPaused, sequence, countdown
        case acceptedPhotoIndices, deferredPhotoIndices, nextPhotoIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        config = try container.decode(EventConfig.self, forKey: .config)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        phase = try container.decode(BoothPhase.self, forKey: .phase)
        presentation = try container.decodeIfPresent(SessionPresentation.self, forKey: .presentation)
        reviewThumbnailData = nil
        stripThumbnailData = nil
        keptShots = [:]
        reviewAsset = try container.decodeIfPresent(BoothAssetReference.self, forKey: .reviewAsset)
        stripAsset = try container.decodeIfPresent(BoothAssetReference.self, forKey: .stripAsset)
        keptShotAssets = try container.decodeIfPresent([Int: BoothAssetReference].self, forKey: .keptShotAssets) ?? [:]
        isMirrored = try container.decode(Bool.self, forKey: .isMirrored)
        isBoothPaused = try container.decodeIfPresent(Bool.self, forKey: .isBoothPaused) ?? false
        sequence = try container.decodeIfPresent(UInt64.self, forKey: .sequence) ?? 0
        countdown = try container.decodeIfPresent(CountdownDescriptor.self, forKey: .countdown)
        acceptedPhotoIndices = try container.decodeIfPresent([Int].self, forKey: .acceptedPhotoIndices) ?? []
        deferredPhotoIndices = try container.decodeIfPresent([Int].self, forKey: .deferredPhotoIndices) ?? []
        nextPhotoIndex = try container.decodeIfPresent(Int.self, forKey: .nextPhotoIndex) ?? 0
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
    case pairingVerificationConfirmed(sessionID: String, proof: Data)
    case authChallenge(challenge: BoothAuthChallenge)
    case authProof(proof: BoothAuthProof)
    case secureChannelHello(hello: BoothSecureChannelHello)
    case secureChannelReady(sessionID: String, proof: Data)
    case connectionRejected(reason: String)
    case sessionSync(snapshot: SessionSyncSnapshot)
    case assetRequest(references: [BoothAssetReference])
    case assetUnavailable(reference: BoothAssetReference, reason: String)
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
    case shotCapturedAsset(context: SessionMessageContext, index: Int, asset: BoothAssetReference)
    case captureRecovery(context: SessionMessageContext, photoIndex: Int, failure: CaptureFailureSummary)
    case captureRecoveryAction(context: SessionMessageContext, action: CaptureRecoveryAction)
    case reviewDecision(state: ReviewStateToken, requestID: UUID, action: ReviewAction)
    case reviewDecisionResult(requestID: UUID, result: ReviewDecisionResult)
    case sessionFinished(context: SessionMessageContext, qrPayload: String, stripThumbData: Data?, gifThumbData: Data?)
    case sessionFinishedAssets(context: SessionMessageContext, qrPayload: String, stripAsset: BoothAssetReference?, gifAsset: BoothAssetReference?)
    case customerFinished(context: SessionMessageContext)
    case operatorOverride(context: SessionMessageContext?, action: OperatorAction)
    case heartbeat
}

// Wire-level packet differentiates control vs preview stream.
// First byte: 0x01 = control (JSON-encoded Message), 0x02 = preview frame (raw JPEG)
enum PacketChannel: UInt8 {
    case control = 0x01
    case preview = 0x02
    case asset = 0x03
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

    func packedAsAsset() -> Data {
        var out = Data([PacketChannel.asset.rawValue])
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

    var isSecureChannelBootstrap: Bool {
        switch self {
        case .secureChannelHello, .secureChannelReady:
            return true
        default:
            return false
        }
    }
}
