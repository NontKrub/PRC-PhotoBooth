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
}

public enum BoothPairingState: Equatable, Sendable {
    case idle
    case pairing(expiresAt: Date)
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

    public init(
        accepted: Bool,
        macIdentity: BoothDeviceIdentity? = nil,
        sharedSecret: Data? = nil,
        reason: String? = nil
    ) {
        self.accepted = accepted
        self.macIdentity = macIdentity
        self.sharedSecret = sharedSecret
        self.reason = reason
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
        let data = try JSONEncoder().encode(self)
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

    public func isFresh(at now: Date = Date()) -> Bool {
        !id.isEmpty &&
        nonce.count == 32 &&
        !challengerDeviceID.isEmpty &&
        !responderDeviceID.isEmpty &&
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
        guard secret.count == 32,
              challenge.isFresh(at: now),
              challenge.responderDeviceID == expectedResponderDeviceID,
              proof.challengeID == challenge.id,
              proof.responderDeviceID == expectedResponderDeviceID,
              proof.proof.count == SHA256.Digest.byteCount else { return false }
        let key = SymmetricKey(data: secret)
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof.proof,
            authenticating: canonicalChallengeData(challenge, responderDeviceID: expectedResponderDeviceID),
            using: key
        )
    }

    private static func canonicalChallengeData(
        _ challenge: BoothAuthChallenge,
        responderDeviceID: String
    ) -> Data {
        let milliseconds = Int64((challenge.issuedAt.timeIntervalSince1970 * 1000).rounded())
        return Data([
            challenge.id,
            challenge.nonce.base64EncodedString(),
            challenge.challengerDeviceID,
            challenge.responderDeviceID,
            responderDeviceID,
            String(milliseconds)
        ].joined(separator: "\n").utf8)
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
