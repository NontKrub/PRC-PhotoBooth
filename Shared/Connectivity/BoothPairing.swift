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

public enum BoothPairingMethod: Codable, Sendable, Equatable {
    case pin(String)
    case qrToken(String)
}

public struct BoothPairingSessionInfo: Codable, Sendable, Equatable {
    public let sessionID: String
    public let macDeviceID: String
    public let macDeviceName: String
    public let expiresAt: Date

    public init(sessionID: String, macDeviceID: String, macDeviceName: String, expiresAt: Date) {
        self.sessionID = sessionID
        self.macDeviceID = macDeviceID
        self.macDeviceName = macDeviceName
        self.expiresAt = expiresAt
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
              let secret = result.sharedSecret,
              secret.count == 32,
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

    public init(
        sessionID: String,
        targetMacDeviceID: String,
        iPadIdentity: BoothDeviceIdentity,
        method: BoothPairingMethod
    ) {
        self.sessionID = sessionID
        self.targetMacDeviceID = targetMacDeviceID
        self.iPadIdentity = iPadIdentity
        self.method = method
    }
}

public struct BoothPairingResult: Codable, Sendable, Equatable {
    public let accepted: Bool
    public let macIdentity: BoothDeviceIdentity?
    public let sharedSecret: Data?
    public let reason: String?
    public let retryable: Bool
    public let pairingSessionID: String?

    public init(
        accepted: Bool,
        macIdentity: BoothDeviceIdentity? = nil,
        sharedSecret: Data? = nil,
        reason: String? = nil,
        retryable: Bool = false,
        pairingSessionID: String? = nil
    ) {
        self.accepted = accepted
        self.macIdentity = macIdentity
        self.sharedSecret = sharedSecret
        self.reason = reason
        self.retryable = retryable
        self.pairingSessionID = pairingSessionID
    }

    private enum CodingKeys: String, CodingKey {
        case accepted
        case macIdentity
        case sharedSecret
        case reason
        case retryable
        case pairingSessionID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accepted = try container.decode(Bool.self, forKey: .accepted)
        macIdentity = try container.decodeIfPresent(BoothDeviceIdentity.self, forKey: .macIdentity)
        sharedSecret = try container.decodeIfPresent(Data.self, forKey: .sharedSecret)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        // Both fields were added to protocol v3 after the initial secure-pairing
        // build. Missing values remain safe defaults for an in-flight upgrade.
        retryable = try container.decodeIfPresent(Bool.self, forKey: .retryable) ?? false
        pairingSessionID = try container.decodeIfPresent(String.self, forKey: .pairingSessionID)
    }
}

public struct BoothPairingQRCodePayload: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    private static let prefix = "prc-photobooth-pairing-v1:"

    public let schemaVersion: Int
    public let macDeviceID: String
    public let macDeviceName: String
    public let pairingSessionID: String
    public let oneTimeToken: String
    public let expiresAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        macDeviceID: String,
        macDeviceName: String,
        pairingSessionID: String,
        oneTimeToken: String,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.macDeviceID = macDeviceID
        self.macDeviceName = macDeviceName
        self.pairingSessionID = pairingSessionID
        self.oneTimeToken = oneTimeToken
        self.expiresAt = expiresAt
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
              !oneTimeToken.isEmpty else { throw BoothPairingError.invalidQRPayload }
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
    public private(set) var failedPINAttempts: Int
    public private(set) var isConsumed: Bool

    public init(
        info: BoothPairingSessionInfo,
        pin: String,
        qrToken: String,
        failedPINAttempts: Int = 0,
        isConsumed: Bool = false
    ) {
        self.info = info
        self.pin = pin
        self.qrToken = qrToken
        self.failedPINAttempts = failedPINAttempts
        self.isConsumed = isConsumed
    }

    public static func make(macIdentity: BoothDeviceIdentity, now: Date = Date()) throws -> BoothPairingSession {
        var generator = SystemRandomNumberGenerator()
        let pinValue = Int.random(in: 0...999_999, using: &generator)
        let pin = String(format: "%06d", pinValue)
        let token = try secureRandomData(count: 32).base64URLEncodedString()
        let sessionID = UUID().uuidString
        let expiresAt = now.addingTimeInterval(lifetime)
        return BoothPairingSession(
            info: BoothPairingSessionInfo(
                sessionID: sessionID,
                macDeviceID: macIdentity.id,
                macDeviceName: macIdentity.displayName,
                expiresAt: expiresAt
            ),
            pin: pin,
            qrToken: token
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
            expiresAt: info.expiresAt
        )
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
        case .incompatibleProtocol: return "This device uses an older PRC PhotoBooth connection protocol. Update both devices to v1.4.2."
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

final class BoothTrustedPeerStore {
    private let defaults: UserDefaults
    private let metadataKey: String
    private let preferredKey: String
    private let autoReconnectKey: String
    private let keychainService: String

    init(
        defaults: UserDefaults = .standard,
        namespace: String = "boothTrustedPeers",
        keychainService: String = "com.nont.prcphoto.booth-pairing"
    ) {
        self.defaults = defaults
        self.metadataKey = "\(namespace).metadata"
        self.preferredKey = "\(namespace).preferred"
        self.autoReconnectKey = "\(namespace).autoReconnect"
        self.keychainService = keychainService
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
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: peerID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    func forget(peerID: String) {
        trustedPeers.removeAll { $0.id == peerID }
        if preferredPeerID == peerID {
            preferredPeerID = nil
            autoReconnect = false
        }
        deleteSecret(peerID: peerID)
    }

    func forgetAll() {
        for peer in trustedPeers { deleteSecret(peerID: peer.id) }
        trustedPeers = []
        preferredPeerID = nil
        autoReconnect = false
    }

    private func saveSecret(_ secret: Data, peerID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: peerID
        ]
        let update = [kSecValueData as String: secret]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw BoothPairingError.keychain(status) }
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = secret
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw BoothPairingError.keychain(addStatus) }
    }

    private func deleteSecret(peerID: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: peerID
        ]
        SecItemDelete(query as CFDictionary)
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

private extension Data {
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
