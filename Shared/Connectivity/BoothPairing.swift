import CryptoKit
import Foundation
import Security

public struct BoothDeviceIdentity: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var displayName: String
    public let role: DeviceRole

    public init(id: String, displayName: String, role: DeviceRole) {
        self.id = id
        self.displayName = displayName
        self.role = role
    }
}

public struct TrustedBoothPeer: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var displayName: String
    public let role: DeviceRole
    public var lastSeenAt: Date?

    public init(id: String, displayName: String, role: DeviceRole, lastSeenAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.lastSeenAt = lastSeenAt
    }
}

/// Prevents duplicate pairing requests on the same session and Control
/// connection while allowing a fresh request after either one changes.
public struct BoothPairingRequestSubmissionGate: Equatable, Sendable {
    private(set) var sessionID: String?
    private(set) var connectionGeneration: Int?

    @discardableResult
    public mutating func claim(sessionID: String, connectionGeneration: Int) -> Bool {
        guard self.sessionID != sessionID || self.connectionGeneration != connectionGeneration else {
            return false
        }
        self.sessionID = sessionID
        self.connectionGeneration = connectionGeneration
        return true
    }

    public mutating func resetIfMatches(sessionID: String, connectionGeneration: Int) {
        guard self.sessionID == sessionID,
              self.connectionGeneration == connectionGeneration else { return }
        self.sessionID = nil
        self.connectionGeneration = nil
    }

    public mutating func reset() {
        sessionID = nil
        connectionGeneration = nil
    }
}

/// Resolves the peer shown in pairing diagnostics without ever falling back
/// to the local identity. The iPad's pairing request contains the iPad
/// identity, so request-side data is not the iPad's remote peer.
public struct BoothPairingDiagnosticPeer: Equatable, Sendable {
    public let id: String?
    public let displayName: String?

    public init(id: String?, displayName: String?) {
        self.id = id
        self.displayName = displayName
    }

    public static func resolve(
        role: DeviceRole,
        connectedPeer: BoothDeviceIdentity?,
        targetMacPeer: BoothDeviceIdentity?,
        pendingIPadPeer: BoothDeviceIdentity?,
        fallbackPeer: TrustedBoothPeer?
    ) -> Self {
        if role == .iPad {
            if let peer = connectedPeer ?? targetMacPeer {
                return Self(id: peer.id, displayName: peer.displayName)
            }
        } else if let peer = connectedPeer ?? pendingIPadPeer {
            return Self(id: peer.id, displayName: peer.displayName)
        }
        return Self(id: fallbackPeer?.id, displayName: fallbackPeer?.displayName)
    }
}

/// Diagnostic stage for the secure pairing handshake.
///
/// This is deliberately separate from `BoothPairingState`: the latter is the
/// user-facing lifecycle, while this records the exact transport step that
/// last ran. It makes physical-device failures actionable without creating a
/// second authoritative pairing state machine.
public enum BoothPairingStage: String, Codable, Sendable, Equatable {
    case idle
    case discovering
    case intentSent
    case sessionReceived
    case sessionSending
    case sessionSent
    case waitingForPIN
    case requestSending
    case requestSent
    case trustSaving
    case resultSending
    case resultReceived
    case verificationPending
    case authenticating
    case authenticated
    case failed
}

public struct BoothDiscoveredPeer: Identifiable, Equatable, Sendable {
    public let id: String
    public var displayName: String
    public let role: DeviceRole
    public var appVersion: String
    public var protocolVersion: Int
    public var networkPreference: BoothNetworkPreference?
    public var availableInterfaces: Set<BoothNetworkInterfacePolicy>
    public var pairingSessionID: String?
    public var pairingExpiresAt: Date?
    public var pairingMacEphemeralPublicKey: Data?
    public var isTrusted: Bool
    public var isPreferred: Bool

    public init(
        id: String,
        displayName: String,
        role: DeviceRole,
        appVersion: String,
        protocolVersion: Int,
        networkPreference: BoothNetworkPreference?,
        availableInterfaces: Set<BoothNetworkInterfacePolicy>,
        pairingSessionID: String? = nil,
        pairingExpiresAt: Date? = nil,
        pairingMacEphemeralPublicKey: Data? = nil,
        isTrusted: Bool = false,
        isPreferred: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.role = role
        self.appVersion = appVersion
        self.protocolVersion = protocolVersion
        self.networkPreference = networkPreference
        self.availableInterfaces = availableInterfaces
        self.pairingSessionID = pairingSessionID
        self.pairingExpiresAt = pairingExpiresAt
        self.pairingMacEphemeralPublicKey = pairingMacEphemeralPublicKey
        self.isTrusted = isTrusted
        self.isPreferred = isPreferred
    }

    /// A Bonjour-advertised session may be used for the direct, Mac-started
    /// PIN flow. The Mac still validates the session and PIN on receipt.
    public func hasActivePairingSession(at now: Date = Date()) -> Bool {
        guard let pairingSessionID,
              !pairingSessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let pairingExpiresAt else {
            return false
        }
        return pairingExpiresAt > now
    }
}

public enum BoothPairingState: Equatable, Sendable {
    case idle
    case waitingForMac(peerID: String)
    case pairing(expiresAt: Date)
    case incoming(request: IncomingBoothPairingRequest, expiresAt: Date)
    case authenticating(peerID: String)
    case authenticated(peerID: String)
    case failed(String)
}

public enum BoothPairingMethod: String, Codable, Sendable, Equatable {
    case pin
    case qrToken
}

public struct BoothPairingSessionInfo: Codable, Sendable, Equatable {
    public let sessionID: String
    public let macDeviceID: String
    public let macDeviceName: String
    public let expiresAt: Date
    public let macEphemeralPublicKey: Data

    public init(
        sessionID: String,
        macDeviceID: String,
        macDeviceName: String,
        expiresAt: Date,
        macEphemeralPublicKey: Data = Data()
    ) {
        self.sessionID = sessionID
        self.macDeviceID = macDeviceID
        self.macDeviceName = macDeviceName
        self.expiresAt = expiresAt
        self.macEphemeralPublicKey = macEphemeralPublicKey
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID, macDeviceID, macDeviceName, expiresAt, macEphemeralPublicKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        macDeviceID = try container.decode(String.self, forKey: .macDeviceID)
        macDeviceName = try container.decode(String.self, forKey: .macDeviceName)
        expiresAt = try container.decode(Date.self, forKey: .expiresAt)
        macEphemeralPublicKey = try container.decodeIfPresent(Data.self, forKey: .macEphemeralPublicKey) ?? Data()
    }
}

public struct BoothPairingIntent: Codable, Sendable, Equatable {
    public let iPadIdentity: BoothDeviceIdentity
    public let targetMacDeviceID: String

    public init(iPadIdentity: BoothDeviceIdentity, targetMacDeviceID: String) {
        self.iPadIdentity = iPadIdentity
        self.targetMacDeviceID = targetMacDeviceID
    }

    public func validate(peerHello: BoothTransportHello, localMacDeviceID: String) throws {
        guard targetMacDeviceID == localMacDeviceID else { throw BoothPairingError.wrongDevice }
        guard peerHello.protocolVersion == BoothTransportHello.currentProtocolVersion else {
            throw BoothPairingError.incompatibleProtocol
        }
        guard peerHello.role == .iPad, iPadIdentity.role == .iPad else {
            throw BoothPairingError.wrongRole
        }
        guard !iPadIdentity.id.isEmpty,
              !iPadIdentity.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              peerHello.deviceID == iPadIdentity.id else {
            throw BoothPairingError.invalidPairingIntent
        }
    }
}

public struct IncomingBoothPairingRequest: Sendable, Equatable {
    public let iPadIdentity: BoothDeviceIdentity
    public let receivedAt: Date

    public init(iPadIdentity: BoothDeviceIdentity, receivedAt: Date = Date()) {
        self.iPadIdentity = iPadIdentity
        self.receivedAt = receivedAt
    }
}

public enum BoothPairingIntentPolicy {
    public static let requestCooldown: TimeInterval = 4

    public enum Decision: Equatable, Sendable {
        case startSession
        case reuseSession
        case reject(reason: String)
    }

    public static func decide(
        iPadID: String,
        activeRequestID: String?,
        hasActivePairingSession: Bool,
        boothIsIdle: Bool,
        hasAuthenticatedPeer: Bool,
        lastRequestAt: Date?,
        now: Date
    ) -> Decision {
        if hasAuthenticatedPeer {
            return .reject(reason: "Another iPad is currently connected.")
        }
        if !boothIsIdle {
            return .reject(reason: "Pairing is unavailable while a photo session is active.")
        }
        if hasActivePairingSession {
            if activeRequestID == nil || activeRequestID == iPadID {
                return .reuseSession
            }
            return .reject(reason: "Another iPad is currently being paired.")
        }
        if let lastRequestAt,
           now.timeIntervalSince(lastRequestAt) < requestCooldown {
            return .reject(reason: "Please wait before trying again.")
        }
        return .startSession
    }
}

public enum BoothPairingTrustPolicy {
    public static func accepts(
        result: BoothPairingResult,
        pendingPairingRequest: BoothPairingRequest?,
        targetPeerID: String?,
        expectedSessionID: String? = nil
    ) -> Bool {
        guard result.accepted,
              let pendingPairingRequest,
              let macIdentity = result.macIdentity,
              macIdentity.role == .mac,
              result.sharedSecret == nil,
              pendingPairingRequest.iPadEphemeralPublicKey.count == 32,
              pendingPairingRequest.admissionProof.count == SHA256.Digest.byteCount,
              result.macEphemeralPublicKey?.count == 32,
              result.keyAgreementProof?.count == SHA256.Digest.byteCount,
              !macIdentity.displayName.isEmpty,
              macIdentity.id == targetPeerID,
              pendingPairingRequest.targetMacDeviceID == macIdentity.id else { return false }
        if let expectedSessionID {
            guard result.pairingSessionID == expectedSessionID else { return false }
        }
        return true
    }
}

public struct BoothPairingRequest: Codable, Sendable, Equatable {
    public let sessionID: String
    public let targetMacDeviceID: String
    public let iPadIdentity: BoothDeviceIdentity
    public let method: BoothPairingMethod
    public let iPadEphemeralPublicKey: Data
    public let admissionProof: Data

    public init(
        sessionID: String,
        targetMacDeviceID: String,
        iPadIdentity: BoothDeviceIdentity,
        method: BoothPairingMethod,
        iPadEphemeralPublicKey: Data = Data(),
        admissionProof: Data = Data()
    ) {
        self.sessionID = sessionID
        self.targetMacDeviceID = targetMacDeviceID
        self.iPadIdentity = iPadIdentity
        self.method = method
        self.iPadEphemeralPublicKey = iPadEphemeralPublicKey
        self.admissionProof = admissionProof
    }
}

public struct BoothPairingResult: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let macIdentity: BoothDeviceIdentity?
    public let sharedSecret: Data?
    public let reason: String?
    public let retryable: Bool
    public let pairingSessionID: String?
    public let macEphemeralPublicKey: Data?
    public let keyAgreementProof: Data?

    public init(
        accepted: Bool,
        macIdentity: BoothDeviceIdentity? = nil,
        sharedSecret: Data? = nil,
        reason: String? = nil,
        retryable: Bool = false,
        pairingSessionID: String? = nil,
        macEphemeralPublicKey: Data? = nil,
        keyAgreementProof: Data? = nil
    ) {
        self.accepted = accepted
        self.macIdentity = macIdentity
        self.sharedSecret = sharedSecret
        self.reason = reason
        self.retryable = retryable
        self.pairingSessionID = pairingSessionID
        self.macEphemeralPublicKey = macEphemeralPublicKey
        self.keyAgreementProof = keyAgreementProof
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
        case macIdentity
        case reason
        case retryable
        case pairingSessionID
        case macEphemeralPublicKey
        case keyAgreementProof
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accepted, forKey: .accepted)
        try container.encodeIfPresent(macIdentity, forKey: .macIdentity)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encode(retryable, forKey: .retryable)
        try container.encodeIfPresent(pairingSessionID, forKey: .pairingSessionID)
        try container.encodeIfPresent(macEphemeralPublicKey, forKey: .macEphemeralPublicKey)
        try container.encodeIfPresent(keyAgreementProof, forKey: .keyAgreementProof)
        // sharedSecret is intentionally never encoded. It remains an optional
        // source-compatibility field for callers that have not migrated yet.
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decode(Bool.self, forKey: .accepted)
        macIdentity = try container.decodeIfPresent(BoothDeviceIdentity.self, forKey: .macIdentity)
        // Ignore the legacy field entirely so a v3 wire secret cannot enter
        // the trusted-pairing path through decoding.
        sharedSecret = nil
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        pairingSessionID = try container.decodeIfPresent(String.self, forKey: .pairingSessionID)
        macEphemeralPublicKey = try container.decodeIfPresent(Data.self, forKey: .macEphemeralPublicKey)
        keyAgreementProof = try container.decodeIfPresent(Data.self, forKey: .keyAgreementProof)
    }
}

public struct BoothPairingQRCodePayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2
    private static let prefix = "prc-photobooth-pairing-v2:"

    public let schemaVersion: Int
    public let macDeviceID: String
    public let macDeviceName: String
    public let pairingSessionID: String
    public let oneTimeToken: String
    public let expiresAt: Date
    public let macEphemeralPublicKey: Data

    public init(
        schemaVersion: Int = currentSchemaVersion,
        macDeviceID: String,
        macDeviceName: String,
        pairingSessionID: String,
        oneTimeToken: String,
        expiresAt: Date,
        macEphemeralPublicKey: Data = Data()
    ) {
        self.schemaVersion = schemaVersion
        self.macDeviceID = macDeviceID
        self.macDeviceName = macDeviceName
        self.pairingSessionID = pairingSessionID
        self.oneTimeToken = oneTimeToken
        self.expiresAt = expiresAt
        self.macEphemeralPublicKey = macEphemeralPublicKey
    }

    public func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(self)
        return Self.prefix + data.base64URLEncodedString()
    }

    public static func decode(_ string: String) throws -> BoothPairingQRCodePayload {
        guard string.hasPrefix(prefix),
              let data = Data(base64URLString: String(string.dropFirst(prefix.count))) else {
            throw BoothPairingError.invalidQRPayload
        }
        let payload: Self
        do {
            payload = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw BoothPairingError.invalidQRPayload
        }
        guard payload.schemaVersion == currentSchemaVersion else {
            throw BoothPairingError.unsupportedQRSchema
        }
        return payload
    }

    public func validate(now: Date = Date(), expectedMacID: String? = nil) throws {
        guard schemaVersion == Self.currentSchemaVersion else { throw BoothPairingError.unsupportedQRSchema }
        guard !macDeviceID.isEmpty,
              !macDeviceName.isEmpty,
              !pairingSessionID.isEmpty,
              !oneTimeToken.isEmpty,
              macEphemeralPublicKey.count == 32 else { throw BoothPairingError.invalidQRPayload }
        guard now < expiresAt else { throw BoothPairingError.expired }
        if let expectedMacID, expectedMacID != macDeviceID {
            throw BoothPairingError.wrongDevice
        }
    }
}

public enum BoothPairingAttemptResult: Equatable, Sendable {
    case accepted
    case rejected(remainingAttempts: Int)
    case expired
    case locked
}

public struct BoothPairingSession: Sendable, Equatable {
    public static let lifetime: TimeInterval = 120
    public static let maximumPINAttempts = 5

    public static func isValidPIN(_ candidate: String) -> Bool {
        candidate.utf8.count == 6 && candidate.utf8.allSatisfy { $0 >= 48 && $0 <= 57 }
    }

    public let info: BoothPairingSessionInfo
    public let pin: String
    public let qrToken: String
    private let ephemeralPrivateKeyData: Data
    public private(set) var failedPINAttempts: Int
    public private(set) var isConsumed: Bool

    public init(
        info: BoothPairingSessionInfo,
        pin: String,
        qrToken: String,
        failedPINAttempts: Int = 0,
        isConsumed: Bool = false,
        ephemeralPrivateKeyData: Data = Data()
    ) {
        self.info = info
        self.pin = pin
        self.qrToken = qrToken
        self.failedPINAttempts = failedPINAttempts
        self.isConsumed = isConsumed
        self.ephemeralPrivateKeyData = ephemeralPrivateKeyData
    }

    public static func make(macIdentity: BoothDeviceIdentity, now: Date = Date()) throws -> BoothPairingSession {
        var generator = SystemRandomNumberGenerator()
        let pinValue = Int.random(in: 0...999_999, using: &generator)
        let pin = String(format: "%06d", pinValue)
        let token = try secureRandomData(count: 32).base64URLEncodedString()
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let sessionID = UUID().uuidString
        let expiresAt = now.addingTimeInterval(lifetime)
        return BoothPairingSession(
            info: BoothPairingSessionInfo(
                sessionID: sessionID,
                macDeviceID: macIdentity.id,
                macDeviceName: macIdentity.displayName,
                expiresAt: expiresAt,
                macEphemeralPublicKey: ephemeralKey.publicKey.rawRepresentation
            ),
            pin: pin,
            qrToken: token,
            ephemeralPrivateKeyData: ephemeralKey.rawRepresentation
        )
    }

    static func isCurrentSession(_ scheduledSessionID: String, currentSessionID: String?) -> Bool {
        currentSessionID == scheduledSessionID
    }

    public var qrPayload: BoothPairingQRCodePayload {
        BoothPairingQRCodePayload(
            macDeviceID: info.macDeviceID,
            macDeviceName: info.macDeviceName,
            pairingSessionID: info.sessionID,
            oneTimeToken: qrToken,
            expiresAt: info.expiresAt,
            macEphemeralPublicKey: info.macEphemeralPublicKey
        )
    }

    func deriveSecret(
        iPadEphemeralPublicKey: Data,
        method: BoothPairingMethod,
        transcript: Data
    ) throws -> Data {
        let code = method == .pin ? pin : qrToken
        return try BoothPairingCrypto.derivePairingSecret(
            privateKeyData: ephemeralPrivateKeyData,
            peerPublicKeyData: iPadEphemeralPublicKey,
            code: code,
            transcript: transcript
        )
    }

    mutating func validateAdmissionProof(
        _ proof: Data,
        method: BoothPairingMethod,
        transcript: Data,
        now: Date = Date()
    ) -> BoothPairingAttemptResult {
        guard !isConsumed else { return .locked }
        guard now < info.expiresAt else {
            isConsumed = true
            return .expired
        }
        guard failedPINAttempts < Self.maximumPINAttempts else {
            isConsumed = true
            return .locked
        }
        let code = method == .pin ? pin : qrToken
        let expected = BoothPairingCrypto.makeAdmissionProof(code: code, transcript: transcript)
        guard BoothPairingCrypto.constantTimeEqual(expected, proof) else {
            failedPINAttempts += 1
            if failedPINAttempts >= Self.maximumPINAttempts {
                isConsumed = true
                return .locked
            }
            return .rejected(remainingAttempts: Self.maximumPINAttempts - failedPINAttempts)
        }
        isConsumed = true
        return .accepted
    }

    public func isActive(at now: Date = Date()) -> Bool {
        !isConsumed && failedPINAttempts < Self.maximumPINAttempts && now < info.expiresAt
    }

    public mutating func validatePIN(_ candidate: String, now: Date = Date()) -> BoothPairingAttemptResult {
        guard !isConsumed else { return .locked }
        guard now < info.expiresAt else {
            isConsumed = true
            return .expired
        }
        guard failedPINAttempts < Self.maximumPINAttempts else {
            isConsumed = true
            return .locked
        }
        guard Self.isValidPIN(candidate), candidate == pin else {
            failedPINAttempts += 1
            if failedPINAttempts >= Self.maximumPINAttempts {
                isConsumed = true
                return .locked
            }
            return .rejected(remainingAttempts: Self.maximumPINAttempts - failedPINAttempts)
        }
        isConsumed = true
        return .accepted
    }

    public mutating func validateQRToken(_ candidate: String, now: Date = Date()) -> BoothPairingAttemptResult {
        guard !isConsumed else { return .locked }
        guard now < info.expiresAt else {
            isConsumed = true
            return .expired
        }
        guard candidate == qrToken else { return .rejected(remainingAttempts: Self.maximumPINAttempts - failedPINAttempts) }
        isConsumed = true
        return .accepted
    }

    public mutating func invalidate() {
        isConsumed = true
    }
}

/// Context captured by a pairing-critical send completion.
///
/// NWConnection callbacks can arrive after a connection or pairing attempt
/// has been replaced. The transport must validate all three values before a
/// completion is allowed to mutate pairing state.
struct BoothPairingControlSendContext: Equatable, Sendable {
    let connectionGeneration: Int
    let pairingGeneration: Int
    let sessionID: String?
}

/// Generation gate for local expiry tasks. A task belongs to one pairing
/// attempt even when its Task cancellation races a newly scheduled timer.
struct BoothPairingExpiryGate {
    static func accepts(
        sessionID: String,
        generation: Int,
        currentGeneration: Int,
        currentSessionID: String?,
        pendingSessionID: String?,
        pendingResultSessionID: String?
    ) -> Bool {
        guard generation == currentGeneration else { return false }
        return sessionID == currentSessionID
            || sessionID == pendingSessionID
            || sessionID == pendingResultSessionID
    }
}

enum BoothPairingControlSendGate {
    static func accepts(
        _ context: BoothPairingControlSendContext,
        currentConnectionGeneration: Int,
        currentPairingGeneration: Int,
        currentSessionID: String?,
        pendingSessionID: String?,
        pendingResultSessionID: String?
    ) -> Bool {
        guard context.connectionGeneration == currentConnectionGeneration,
              context.pairingGeneration == currentPairingGeneration else { return false }
        guard let sessionID = context.sessionID else { return true }
        return sessionID == currentSessionID
            || sessionID == pendingSessionID
            || sessionID == pendingResultSessionID
    }
}

public struct BoothAuthChallenge: Codable, Sendable, Equatable {
    public static let lifetime: TimeInterval = 30

    public let id: String
    public let nonce: Data
    public let challengerDeviceID: String
    public let responderDeviceID: String
    public let issuedAt: Date

    public init(
        id: String = UUID().uuidString,
        nonce: Data,
        challengerDeviceID: String,
        responderDeviceID: String,
        issuedAt: Date = Date()
    ) {
        self.id = id
        self.nonce = nonce
        self.challengerDeviceID = challengerDeviceID
        self.responderDeviceID = responderDeviceID
        self.issuedAt = issuedAt
    }

    public static func make(challengerDeviceID: String, responderDeviceID: String, now: Date = Date()) throws -> Self {
        Self(
            nonce: try secureRandomData(count: 32),
            challengerDeviceID: challengerDeviceID,
            responderDeviceID: responderDeviceID,
            issuedAt: now
        )
    }

    public var isWellFormed: Bool {
        !id.isEmpty &&
        nonce.count == 32 &&
        !challengerDeviceID.isEmpty &&
        !responderDeviceID.isEmpty
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        isWellFormed &&
        now >= issuedAt &&
        now.timeIntervalSince(issuedAt) <= Self.lifetime
    }
}

public struct BoothAuthProof: Codable, Sendable, Equatable {
    public let challengeID: String
    public let responderDeviceID: String
    public let proof: Data

    public init(challengeID: String, responderDeviceID: String, proof: Data) {
        self.challengeID = challengeID
        self.responderDeviceID = responderDeviceID
        self.proof = proof
    }
}

public struct BoothSecureChannelHello: Codable, Sendable, Equatable {
    public static let protocolVersion = 1

    public let protocolVersion: Int
    public let sessionID: String
    public let challenge: Data
    public let senderRole: DeviceRole
    public let senderDeviceID: String
    public let receiverDeviceID: String

    public init(
        sessionID: String,
        challenge: Data,
        senderRole: DeviceRole,
        senderDeviceID: String,
        receiverDeviceID: String
    ) {
        self.protocolVersion = Self.protocolVersion
        self.sessionID = sessionID
        self.challenge = challenge
        self.senderRole = senderRole
        self.senderDeviceID = senderDeviceID
        self.receiverDeviceID = receiverDeviceID
    }

    public var isWellFormed: Bool {
        protocolVersion == Self.protocolVersion
            && !sessionID.isEmpty
            && challenge.count == 32
            && !senderDeviceID.isEmpty
            && !receiverDeviceID.isEmpty
            && (senderRole == .mac || senderRole == .iPad)
    }
}

enum BoothSecureChannelError: Error, Equatable, Sendable {
    case invalidSecret
    case invalidHello
    case notReady
    case malformedEnvelope
    case wrongChannel
    case replayedCounter
    case authenticationFailed
    case counterExhausted
}

private struct BoothSecureChannelKeySet {
    let sendKey: SymmetricKey
    let receiveKey: SymmetricKey
    let sendNoncePrefix: Data
    let receiveNoncePrefix: Data
}

/// CryptoKit-only operational channel. Pairing/authentication remains the
/// plaintext bootstrap; every control, preview, and asset payload after the
/// fresh challenge exchange is sealed with a directional ChaChaPoly key.
final class BoothSecureChannel: @unchecked Sendable {
    private static let envelopeMagic = Data([0x53, 0x43])
    private static let envelopeVersion: UInt8 = 1

    private let lock = NSLock()
    private var keySets: [UInt8: BoothSecureChannelKeySet] = [:]
    private var sentCounters: [UInt8: UInt64] = [:]
    private var receivedCounters: [UInt8: UInt64] = [:]
    private var configuredSessionID: String?
    private var localRole: DeviceRole?
    private var peerRole: DeviceRole?
    private var localDeviceID = ""
    private var peerDeviceID = ""

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return configuredSessionID != nil && !keySets.isEmpty
    }

    var isConfigured: Bool { isReady }

    var sessionID: String? {
        lock.lock()
        defer { lock.unlock() }
        return configuredSessionID
    }

    func configure(
        secret: Data,
        localHello: BoothSecureChannelHello,
        peerHello: BoothSecureChannelHello
    ) throws {
        guard secret.count == 32,
              localHello.isWellFormed,
              peerHello.isWellFormed,
              localHello.sessionID == peerHello.sessionID,
              localHello.senderRole != peerHello.senderRole,
              localHello.senderDeviceID == peerHello.receiverDeviceID,
              localHello.receiverDeviceID == peerHello.senderDeviceID else {
            throw BoothSecureChannelError.invalidHello
        }

        let macHello = localHello.senderRole == .mac ? localHello : peerHello
        let iPadHello = localHello.senderRole == .iPad ? localHello : peerHello
        let transcript = Self.transcript(macHello: macHello, iPadHello: iPadHello)
        let salt = Data(SHA256.hash(data: Data("PRC-PhotoBooth/secure-channel-salt/v1\0".utf8)))
        let root = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: transcript,
            outputByteCount: 32
        )

        var derived: [UInt8: BoothSecureChannelKeySet] = [:]
        for channel in [BoothTransportChannel.control, .preview, .asset] {
            let sendDirection = localHello.senderRole == .mac ? "mac-to-ipad" : "ipad-to-mac"
            let receiveDirection = localHello.senderRole == .mac ? "ipad-to-mac" : "mac-to-ipad"
            derived[channel.rawValue] = BoothSecureChannelKeySet(
                sendKey: Self.derive(root: root, label: "key", channel: channel, direction: sendDirection),
                receiveKey: Self.derive(root: root, label: "key", channel: channel, direction: receiveDirection),
                sendNoncePrefix: Self.deriveBytes(root: root, label: "nonce", channel: channel, direction: sendDirection, count: 4),
                receiveNoncePrefix: Self.deriveBytes(root: root, label: "nonce", channel: channel, direction: receiveDirection, count: 4)
            )
        }

        lock.lock()
        keySets = derived
        sentCounters = [:]
        receivedCounters = [:]
        configuredSessionID = localHello.sessionID
        localRole = localHello.senderRole
        peerRole = peerHello.senderRole
        localDeviceID = localHello.senderDeviceID
        peerDeviceID = peerHello.senderDeviceID
        lock.unlock()
    }

    func reset() {
        lock.lock()
        keySets = [:]
        sentCounters = [:]
        receivedCounters = [:]
        configuredSessionID = nil
        localRole = nil
        peerRole = nil
        localDeviceID = ""
        peerDeviceID = ""
        lock.unlock()
    }

    func protect(_ plaintext: Data, channel: BoothTransportChannel) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let keySet = keySets[channel.rawValue],
              let sessionID = configuredSessionID,
              let localRole,
              let peerRole else { throw BoothSecureChannelError.notReady }
        let previous = sentCounters[channel.rawValue] ?? 0
        guard previous < UInt64.max else { throw BoothSecureChannelError.counterExhausted }
        let counter = previous + 1
        let nonce = try ChaChaPoly.Nonce(data: keySet.sendNoncePrefix + Self.bigEndian(counter))
        let aad = Self.aad(
            sessionID: sessionID,
            channel: channel,
            senderRole: localRole,
            receiverRole: peerRole,
            senderDeviceID: localDeviceID,
            receiverDeviceID: peerDeviceID,
            counter: counter
        )
        let sealed = try ChaChaPoly.seal(plaintext, using: keySet.sendKey, nonce: nonce, authenticating: aad)
        sentCounters[channel.rawValue] = counter

        var envelope = Self.envelopeMagic
        envelope.append(Self.envelopeVersion)
        envelope.append(channel.rawValue)
        envelope.append(Self.bigEndian(counter))
        envelope.append(sealed.ciphertext)
        envelope.append(sealed.tag)
        return envelope
    }

    func open(_ envelope: Data, channel: BoothTransportChannel) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let minimumLength = Self.envelopeMagic.count + 2 + 8 + 16
        guard envelope.count >= minimumLength,
              envelope.prefix(Self.envelopeMagic.count) == Self.envelopeMagic,
              envelope[2] == Self.envelopeVersion else {
            throw BoothSecureChannelError.malformedEnvelope
        }
        guard envelope[3] == channel.rawValue else {
            throw BoothSecureChannelError.wrongChannel
        }
        guard let keySet = keySets[channel.rawValue],
              let sessionID = configuredSessionID,
              let localRole,
              let peerRole else { throw BoothSecureChannelError.malformedEnvelope }

        let counter = Self.readUInt64(envelope, offset: 4)
        guard counter > (receivedCounters[channel.rawValue] ?? 0) else {
            throw BoothSecureChannelError.replayedCounter
        }
        let ciphertextStart = 12
        let tagStart = envelope.count - 16
        let nonce = try ChaChaPoly.Nonce(data: keySet.receiveNoncePrefix + Self.bigEndian(counter))
        let aad = Self.aad(
            sessionID: sessionID,
            channel: channel,
            senderRole: peerRole,
            receiverRole: localRole,
            senderDeviceID: peerDeviceID,
            receiverDeviceID: localDeviceID,
            counter: counter
        )
        let sealed = try ChaChaPoly.SealedBox(
            nonce: nonce,
            ciphertext: Data(envelope[ciphertextStart..<tagStart]),
            tag: Data(envelope[tagStart...])
        )
        do {
            let plaintext = try ChaChaPoly.open(sealed, using: keySet.receiveKey, authenticating: aad)
            receivedCounters[channel.rawValue] = counter
            return plaintext
        } catch {
            throw BoothSecureChannelError.authenticationFailed
        }
    }

    static func transcript(macHello: BoothSecureChannelHello, iPadHello: BoothSecureChannelHello) -> Data {
        var result = Data("PRC-PhotoBooth/secure-channel/v1\0".utf8)
        appendField(macHello.sessionID, to: &result)
        appendField(macHello.senderDeviceID, to: &result)
        appendField(iPadHello.senderDeviceID, to: &result)
        appendField(macHello.challenge, to: &result)
        appendField(iPadHello.challenge, to: &result)
        return result
    }

    static func readyProof(
        secret: Data,
        macHello: BoothSecureChannelHello,
        iPadHello: BoothSecureChannelHello,
        senderRole: DeviceRole
    ) -> Data {
        var transcript = transcript(macHello: macHello, iPadHello: iPadHello)
        transcript.append(Data(senderRole.rawValue.utf8))
        return Data(HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: SymmetricKey(data: secret)
        ))
    }

    private static func derive(
        root: SymmetricKey,
        label: String,
        channel: BoothTransportChannel,
        direction: String
    ) -> SymmetricKey {
        SymmetricKey(data: deriveBytes(root: root, label: label, channel: channel, direction: direction, count: 32))
    }

    private static func deriveBytes(
        root: SymmetricKey,
        label: String,
        channel: BoothTransportChannel,
        direction: String,
        count: Int
    ) -> Data {
        var info = Data("PRC-PhotoBooth/secure-channel/\(label)/v1\0".utf8)
        appendField(channel.rawValue, to: &info)
        appendField(direction, to: &info)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: root,
            salt: Data(),
            info: info,
            outputByteCount: count
        )
        return key.withUnsafeBytes { Data($0) }
    }

    private static func aad(
        sessionID: String,
        channel: BoothTransportChannel,
        senderRole: DeviceRole,
        receiverRole: DeviceRole,
        senderDeviceID: String,
        receiverDeviceID: String,
        counter: UInt64
    ) -> Data {
        var result = Data("PRC-PhotoBooth/secure-channel-aad/v1\0".utf8)
        appendField(sessionID, to: &result)
        appendField(channel.rawValue, to: &result)
        appendField(senderRole.rawValue, to: &result)
        appendField(receiverRole.rawValue, to: &result)
        appendField(senderDeviceID, to: &result)
        appendField(receiverDeviceID, to: &result)
        appendField(counter, to: &result)
        return result
    }

    private static func appendField(_ value: String, to data: inout Data) {
        appendField(Data(value.utf8), to: &data)
    }

    private static func appendField(_ value: UInt8, to data: inout Data) {
        data.append(value)
    }

    private static func appendField(_ value: UInt64, to data: inout Data) {
        data.append(bigEndian(value))
    }

    private static func appendField(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func bigEndian(_ value: UInt64) -> Data {
        var value = value.bigEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }

    private static func readUInt64(_ data: Data, offset: Int) -> UInt64 {
        data[offset..<offset + 8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

enum BoothAuthProofVerificationFailure: String, Equatable, Sendable {
    case invalidSecretLength
    case expiredChallenge
    case wrongChallengeTarget
    case wrongChallengeID
    case wrongResponder
    case invalidProofLength
    case hmacMismatch

    var message: String {
        switch self {
        case .invalidSecretLength: return "pairing secret is invalid"
        case .expiredChallenge: return "authentication challenge expired"
        case .wrongChallengeTarget: return "challenge targets a different device"
        case .wrongChallengeID: return "proof answers a different challenge"
        case .wrongResponder: return "proof came from a different device"
        case .invalidProofLength: return "proof format is invalid"
        case .hmacMismatch: return "proof was created with a different pairing secret or transcript"
        }
    }
}

public enum BoothPairingCrypto {
    public static func makeSharedSecret() throws -> Data {
        try secureRandomData(count: 32)
    }

    public static func makeSecureChannelChallenge() throws -> Data {
        try secureRandomData(count: 32)
    }

    public static func pairingTranscript(
        sessionID: String,
        macDeviceID: String,
        iPadDeviceID: String,
        method: BoothPairingMethod,
        macEphemeralPublicKey: Data,
        iPadEphemeralPublicKey: Data
    ) -> Data {
        var transcript = Data("PRC-PhotoBooth/pairing-v2\0".utf8)
        appendField(sessionID, to: &transcript)
        appendField(macDeviceID, to: &transcript)
        appendField(iPadDeviceID, to: &transcript)
        appendField(method.rawValue, to: &transcript)
        appendField(macEphemeralPublicKey, to: &transcript)
        appendField(iPadEphemeralPublicKey, to: &transcript)
        return transcript
    }

    public static func makeAdmissionProof(code: String, transcript: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: transcript,
            using: SymmetricKey(data: Data(code.utf8))
        ))
    }

    public static func derivePairingSecret(
        privateKeyData: Data,
        peerPublicKeyData: Data,
        code: String,
        transcript: Data
    ) throws -> Data {
        guard privateKeyData.count == 32, peerPublicKeyData.count == 32 else {
            throw BoothPairingError.invalidSecret
        }
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKeyData)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let salt = SHA256.hash(data: Data(code.utf8))
        let derived = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(salt),
            sharedInfo: transcript,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    public static func makeKeyAgreementProof(secret: Data, transcript: Data, role: DeviceRole) -> Data {
        var message = Data("PRC-PhotoBooth/pairing-confirm/v2\0".utf8)
        appendField(role.rawValue, to: &message)
        message.append(transcript)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    public static func makeVerificationConfirmationProof(
        secret: Data,
        transcript: Data,
        role: DeviceRole
    ) -> Data {
        var message = Data("PRC-PhotoBooth/pairing-sas-confirm/v1\0".utf8)
        appendField(role.rawValue, to: &message)
        message.append(transcript)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret)))
    }

    /// A human-verifiable short authentication string. It is derived locally
    /// from the authenticated transcript and is never sent over the wire.
    public static func makeVerificationCode(secret: Data, transcript: Data) -> String {
        var message = Data("PRC-PhotoBooth/pairing-sas/v1\0".utf8)
        message.append(transcript)
        let digest = HMAC<SHA256>.authenticationCode(
            for: message,
            using: SymmetricKey(data: secret)
        )
        let value = digest.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let decimal = String(value % 1_000_000)
        return String(repeating: "0", count: max(0, 6 - decimal.utf8.count)) + decimal
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var result: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { result |= left ^ right }
        return result == 0
    }

    public static func makeProof(
        for challenge: BoothAuthChallenge,
        responderDeviceID: String,
        secret: Data
    ) -> BoothAuthProof {
        let key = SymmetricKey(data: secret)
        let signature = HMAC<SHA256>.authenticationCode(
            for: canonicalChallengeData(challenge, responderDeviceID: responderDeviceID),
            using: key
        )
        return BoothAuthProof(
            challengeID: challenge.id,
            responderDeviceID: responderDeviceID,
            proof: Data(signature)
        )
    }

    public static func verify(
        _ proof: BoothAuthProof,
        for challenge: BoothAuthChallenge,
        expectedResponderDeviceID: String,
        secret: Data,
        now: Date = Date()
    ) -> Bool {
        verificationFailure(
            proof,
            for: challenge,
            expectedResponderDeviceID: expectedResponderDeviceID,
            secret: secret,
            now: now
        ) == nil
    }

    static func verificationFailure(
        _ proof: BoothAuthProof,
        for challenge: BoothAuthChallenge,
        expectedResponderDeviceID: String,
        secret: Data,
        now: Date = Date()
    ) -> BoothAuthProofVerificationFailure? {
        guard secret.count == 32 else { return .invalidSecretLength }
        guard challenge.isFresh(at: now) else { return .expiredChallenge }
        guard challenge.responderDeviceID == expectedResponderDeviceID else { return .wrongChallengeTarget }
        guard proof.challengeID == challenge.id else { return .wrongChallengeID }
        guard proof.responderDeviceID == expectedResponderDeviceID else { return .wrongResponder }
        guard proof.proof.count == SHA256.Digest.byteCount else { return .invalidProofLength }
        let key = SymmetricKey(data: secret)
        guard HMAC<SHA256>.isValidAuthenticationCode(
            proof.proof,
            authenticating: canonicalChallengeData(challenge, responderDeviceID: expectedResponderDeviceID),
            using: key
        ) else { return .hmacMismatch }
        return nil
    }

    /// A short, non-secret identifier for comparing the exact authentication
    /// transcript across physical devices. It does not expose the nonce or key.
    static func transcriptIdentifier(
        for challenge: BoothAuthChallenge,
        responderDeviceID: String
    ) -> String {
        SHA256.hash(
            data: canonicalChallengeData(challenge, responderDeviceID: responderDeviceID)
        ).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalChallengeData(
        _ challenge: BoothAuthChallenge,
        responderDeviceID: String
    ) -> Data {
        // The challenger retains the original challenge and validates every
        // non-secret field before HMAC verification: challenge ID, expected
        // responder identity, challenge identity, and local freshness. The
        // HMAC therefore needs to cover only its unique, 256-bit nonce.
        //
        // Keeping this transcript binary avoids cross-runtime Foundation and
        // String serialization differences on the iPadOS 16 physical target.
        // The fixed label prevents this MAC from being reused by another
        // protocol message that happens to contain the same bytes.
        _ = responderDeviceID
        var data = Data("PRC-PhotoBooth/auth-proof/v3\0".utf8)
        data.append(challenge.nonce)
        return data
    }

    private static func appendField(_ value: String, to data: inout Data) {
        appendField(Data(value.utf8), to: &data)
    }

    private static func appendField(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}

public enum BoothPeerAdmission: Equatable, Sendable {
    case allowed
    case unpaired
    case notSelected
}

public enum BoothPeerSelectionPolicy {
    public static func canAutomaticallyConnect(
        peerID: String,
        preferredPeerID: String?,
        trustedPeerIDs: Set<String>,
        autoReconnect: Bool
    ) -> Bool {
        autoReconnect && preferredPeerID == peerID && trustedPeerIDs.contains(peerID)
    }

    public static func admission(
        peerID: String,
        preferredPeerID: String?,
        trustedPeerIDs: Set<String>
    ) -> BoothPeerAdmission {
        guard trustedPeerIDs.contains(peerID) else { return .unpaired }
        guard preferredPeerID == peerID else { return .notSelected }
        return .allowed
    }
}

public enum BoothPairingError: LocalizedError, Equatable {
    case expired
    case invalidPIN
    case tooManyAttempts
    case invalidQRToken
    case invalidQRPayload
    case unsupportedQRSchema
    case wrongDevice
    case invalidPairingIntent
    case wrongRole
    case incompatibleProtocol
    case unpaired
    case notSelected
    case authenticationFailed
    case invalidSecret
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .expired: return "Pairing code expired."
        case .invalidPIN: return "Pairing PIN is invalid."
        case .tooManyAttempts: return "Too many incorrect pairing PIN attempts."
        case .invalidQRToken: return "Pairing QR code is invalid."
        case .invalidQRPayload: return "Pairing QR code could not be read."
        case .unsupportedQRSchema: return "This pairing QR code uses an unsupported format."
        case .wrongDevice: return "Pairing code belongs to a different Mac."
        case .invalidPairingIntent: return "Pairing request does not match this connection."
        case .wrongRole: return "The discovered device has the wrong booth role."
        case .incompatibleProtocol: return "This version of PRC PhotoBooth is incompatible. Update both the Mac and iPad booth apps."
        case .unpaired: return "This device is not paired."
        case .notSelected: return "This Mac is configured for another iPad. Select this iPad in Mac Settings first."
        case .authenticationFailed: return "Authentication failed."
        case .invalidSecret: return "The pairing secret is invalid."
        case .keychain(let status): return "Keychain error (\(status))."
        }
    }
}

final class BoothDeviceIdentityStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(defaults: UserDefaults = .standard, keyPrefix: String = "boothDeviceIdentity") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func load(role: DeviceRole, defaultName: String) -> BoothDeviceIdentity {
        let idKey = "\(keyPrefix).\(role.rawValue).id"
        let nameKey = "\(keyPrefix).\(role.rawValue).name"
        let id: String
        if let existing = defaults.string(forKey: idKey), !existing.isEmpty {
            id = existing
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: idKey)
        }
        let storedName = defaults.string(forKey: nameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = storedName?.isEmpty == false ? storedName! : defaultName
        if storedName?.isEmpty != false { defaults.set(name, forKey: nameKey) }
        return BoothDeviceIdentity(id: id, displayName: name, role: role)
    }

    func rename(_ identity: BoothDeviceIdentity, to name: String) -> BoothDeviceIdentity {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return identity }
        defaults.set(trimmed, forKey: "\(keyPrefix).\(identity.role.rawValue).name")
        return BoothDeviceIdentity(id: identity.id, displayName: trimmed, role: identity.role)
    }
}

enum GenericPasswordKeychainAccessibility: Sendable {
    case whenUnlockedThisDeviceOnly
    case afterFirstUnlockThisDeviceOnly

    var securityAttribute: CFString {
        switch self {
        case .whenUnlockedThisDeviceOnly: return kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        case .afterFirstUnlockThisDeviceOnly: return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

protocol GenericPasswordKeychainStore: Sendable {
    func readData(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool
    ) -> (status: OSStatus, data: Data?)

    func writeData(
        _ data: Data,
        service: String,
        account: String,
        useDataProtectionKeychain: Bool,
        accessibility: GenericPasswordKeychainAccessibility
    ) -> OSStatus

    func deleteData(service: String, account: String, useDataProtectionKeychain: Bool) -> OSStatus
}

struct GenericPasswordMigrationReadResult: Equatable, Sendable {
    var data: Data?
    var legacyCleanupError: OSStatus?
}

func reportLegacyKeychainCleanupFailure(_ status: OSStatus) {
    NSLog("Data Protection Keychain credential is active, but legacy cleanup failed (OSStatus %d).", status)
}

extension GenericPasswordKeychainStore {
    func readDataMigratingToDataProtection(
        service: String,
        account: String,
        accessibility: GenericPasswordKeychainAccessibility
    ) -> GenericPasswordMigrationReadResult {
        let preferred = readData(service: service, account: account, useDataProtectionKeychain: true)
        if preferred.status == errSecSuccess {
            let cleanupStatus = deleteData(service: service, account: account, useDataProtectionKeychain: false)
            return GenericPasswordMigrationReadResult(
                data: preferred.data,
                legacyCleanupError: Self.isSuccessfulDelete(cleanupStatus) ? nil : cleanupStatus
            )
        }

        let legacy = readData(service: service, account: account, useDataProtectionKeychain: false)
        guard legacy.status == errSecSuccess, let legacyData = legacy.data else {
            return GenericPasswordMigrationReadResult(data: nil, legacyCleanupError: nil)
        }

        let writeStatus = writeData(
            legacyData,
            service: service,
            account: account,
            useDataProtectionKeychain: true,
            accessibility: accessibility
        )
        guard writeStatus == errSecSuccess else {
            return GenericPasswordMigrationReadResult(data: legacyData, legacyCleanupError: nil)
        }

        let verified = readData(service: service, account: account, useDataProtectionKeychain: true)
        guard verified.status == errSecSuccess, verified.data == legacyData else {
            _ = deleteData(service: service, account: account, useDataProtectionKeychain: true)
            return GenericPasswordMigrationReadResult(data: legacyData, legacyCleanupError: nil)
        }

        let cleanupStatus = deleteData(service: service, account: account, useDataProtectionKeychain: false)
        return GenericPasswordMigrationReadResult(
            data: verified.data,
            legacyCleanupError: Self.isSuccessfulDelete(cleanupStatus) ? nil : cleanupStatus
        )
    }

    private static func isSuccessfulDelete(_ status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    func writeDataAndVerify(
        _ data: Data,
        service: String,
        account: String,
        useDataProtectionKeychain: Bool,
        accessibility: GenericPasswordKeychainAccessibility
    ) -> OSStatus {
        let writeStatus = writeData(
            data,
            service: service,
            account: account,
            useDataProtectionKeychain: useDataProtectionKeychain,
            accessibility: accessibility
        )
        guard writeStatus == errSecSuccess else { return writeStatus }

        let readback = readData(service: service, account: account, useDataProtectionKeychain: useDataProtectionKeychain)
        guard readback.status == errSecSuccess else { return readback.status }
        return readback.data == data ? errSecSuccess : errSecIO
    }

    func deleteBothCopies(service: String, account: String) -> OSStatus {
        let dataProtectionStatus = deleteData(service: service, account: account, useDataProtectionKeychain: true)
        let legacyStatus = deleteData(service: service, account: account, useDataProtectionKeychain: false)
        for status in [dataProtectionStatus, legacyStatus]
        where status != errSecSuccess && status != errSecItemNotFound {
            return status
        }
        return errSecSuccess
    }
}

struct SecurityGenericPasswordKeychainStore: GenericPasswordKeychainStore, Sendable {
    func readData(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool
    ) -> (status: OSStatus, data: Data?) {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, nil) }
        guard let data = result as? Data else { return (errSecDecode, nil) }
        return (errSecSuccess, data)
    }

    func writeData(
        _ data: Data,
        service: String,
        account: String,
        useDataProtectionKeychain: Bool,
        accessibility: GenericPasswordKeychainAccessibility
    ) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility.securityAttribute
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility.securityAttribute
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecDuplicateItem else { return addStatus }
        return SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func deleteData(service: String, account: String, useDataProtectionKeychain: Bool) -> OSStatus {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return SecItemDelete(query as CFDictionary)
    }
}

final class BoothTrustedPeerStore {
    private let defaults: UserDefaults
    private let metadataKey: String
    private let preferredKey: String
    private let autoReconnectKey: String
    private let keychainService: String
    private let keychain: any GenericPasswordKeychainStore

    init(
        defaults: UserDefaults = .standard,
        namespace: String = "boothTrustedPeers",
        keychainService: String = "com.nont.prcphoto.booth-pairing",
        keychain: any GenericPasswordKeychainStore = SecurityGenericPasswordKeychainStore()
    ) {
        self.defaults = defaults
        self.metadataKey = "\(namespace).metadata"
        self.preferredKey = "\(namespace).preferred"
        self.autoReconnectKey = "\(namespace).autoReconnect"
        self.keychainService = keychainService
        self.keychain = keychain
    }

    var trustedPeers: [TrustedBoothPeer] {
        get {
            guard let data = defaults.data(forKey: metadataKey),
                  let peers = try? JSONDecoder().decode([TrustedBoothPeer].self, from: data) else { return [] }
            return peers
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: metadataKey)
            }
        }
    }

    var trustedPeerIDs: Set<String> { Set(trustedPeers.map(\.id)) }

    var preferredPeerID: String? {
        get { defaults.string(forKey: preferredKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: preferredKey) }
            else { defaults.removeObject(forKey: preferredKey) }
        }
    }

    var autoReconnect: Bool {
        get { defaults.object(forKey: autoReconnectKey) as? Bool ?? false }
        set { defaults.set(newValue, forKey: autoReconnectKey) }
    }

    func trust(_ peer: TrustedBoothPeer, secret: Data) throws {
        guard secret.count == 32 else { throw BoothPairingError.invalidSecret }
        try saveSecret(secret, peerID: peer.id)
        var peers = trustedPeers
        if let index = peers.firstIndex(where: { $0.id == peer.id }) { peers[index] = peer }
        else { peers.append(peer) }
        trustedPeers = peers
    }

    func updateLastSeen(peerID: String, name: String, date: Date = Date()) {
        var peers = trustedPeers
        guard let index = peers.firstIndex(where: { $0.id == peerID }) else { return }
        peers[index].displayName = name
        peers[index].lastSeenAt = date
        trustedPeers = peers
    }

    func secret(for peerID: String) -> Data? {
        let result = keychain.readDataMigratingToDataProtection(
            service: keychainService,
            account: peerID,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        if let status = result.legacyCleanupError {
            reportLegacyKeychainCleanupFailure(status)
        }
        return result.data
    }

    @discardableResult
    func forget(peerID: String) -> OSStatus {
        let status = deleteSecret(peerID: peerID)
        guard status == errSecSuccess else { return status }
        trustedPeers.removeAll { $0.id == peerID }
        if preferredPeerID == peerID {
            preferredPeerID = nil
            autoReconnect = false
        }
        return errSecSuccess
    }

    @discardableResult
    func forgetAll() -> OSStatus {
        var remainingPeers: [TrustedBoothPeer] = []
        var failureStatus: OSStatus = errSecSuccess
        for peer in trustedPeers {
            let status = deleteSecret(peerID: peer.id)
            if status == errSecSuccess {
                continue
            }
            remainingPeers.append(peer)
            if failureStatus == errSecSuccess { failureStatus = status }
        }
        trustedPeers = remainingPeers
        preferredPeerID = nil
        autoReconnect = false
        return failureStatus
    }

    private func saveSecret(_ secret: Data, peerID: String) throws {
        let status = keychain.writeDataAndVerify(
            secret,
            service: keychainService,
            account: peerID,
            useDataProtectionKeychain: true,
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        guard status == errSecSuccess else { throw BoothPairingError.keychain(status) }
        _ = keychain.deleteData(service: keychainService, account: peerID, useDataProtectionKeychain: false)
    }

    private func deleteSecret(peerID: String) -> OSStatus {
        keychain.deleteBothCopies(service: keychainService, account: peerID)
    }
}

private func secureRandomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw BoothPairingError.keychain(status) }
    return data
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLString: String) {
        var value = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = value.count % 4
        if remainder != 0 { value += String(repeating: "=", count: 4 - remainder) }
        self.init(base64Encoded: value)
    }
}
