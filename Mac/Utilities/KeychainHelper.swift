import Foundation
import CryptoKit
import Security
import CommonCrypto

// MARK: - PIN Credential Model

struct PINCredentialRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultAlgorithm = "PBKDF2-HMAC-SHA256"
    static let defaultIterations: UInt32 = 100_000
    static let saltByteCount = 16
    static let verifierByteCount = 32

    var version: Int
    var algorithm: String
    var salt: Data
    var iterations: UInt32
    var verifier: Data

    var isValid: Bool {
        version == Self.currentVersion
            && algorithm == Self.defaultAlgorithm
            && salt.count >= Self.saltByteCount
            && iterations >= 10_000
            && verifier.count == Self.verifierByteCount
    }
}

// MARK: - Cryptographic Helpers

func derivePBKDF2SHA256(
    pin: String,
    salt: Data,
    iterations: UInt32,
    outputLength: Int = 32
) -> Data? {
    guard !pin.isEmpty, !salt.isEmpty, iterations > 0, outputLength > 0 else { return nil }
    var derived = [UInt8](repeating: 0, count: outputLength)
    let pinData = Array(pin.utf8)
    let saltData = Array(salt)
    let status = CCKeyDerivationPBKDF(
        CCPBKDFAlgorithm(kCCPBKDF2),
        pinData, pinData.count,
        saltData, saltData.count,
        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
        iterations,
        &derived, derived.count
    )
    guard status == kCCSuccess else { return nil }
    return Data(derived)
}

func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return a.withUnsafeBytes { bufA in
        b.withUnsafeBytes { bufB in
            guard let baseA = bufA.baseAddress, let baseB = bufB.baseAddress else { return false }
            return timingsafe_bcmp(baseA, baseB, a.count) == 0
        }
    }
}

// MARK: - PIN Storage Helpers

private let kPINKey = "admin_pin_hash"
private let kPINService = "com.nont.prcphoto.operator-pin"
private let kPINAccount = "admin"
private let kPINFailedAttemptsKey = "admin_pin_failed_attempts"
private let kPINLockedUntilKey = "admin_pin_locked_until"
private let kPINMaximumBackoff: TimeInterval = 60

func isPINSet() -> Bool {
    if let data = readPINData() {
        if let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: data) {
            return record.isValid
        }
        if data.count == 64 || data.count == 32 {
            return true
        }
    }
    if let legacyUD = UserDefaults.standard.string(forKey: kPINKey), !legacyUD.isEmpty {
        return true
    }
    return false
}

func setPIN(_ pin: String) -> Bool {
    guard !pin.isEmpty else { return false }
    var salt = [UInt8](repeating: 0, count: PINCredentialRecord.saltByteCount)
    let randomStatus = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
    guard randomStatus == errSecSuccess else { return false }
    let saltData = Data(salt)
    guard let verifier = derivePBKDF2SHA256(
        pin: pin,
        salt: saltData,
        iterations: PINCredentialRecord.defaultIterations,
        outputLength: PINCredentialRecord.verifierByteCount
    ) else {
        return false
    }

    let record = PINCredentialRecord(
        version: PINCredentialRecord.currentVersion,
        algorithm: PINCredentialRecord.defaultAlgorithm,
        salt: saltData,
        iterations: PINCredentialRecord.defaultIterations,
        verifier: verifier
    )
    guard let encoded = try? JSONEncoder().encode(record) else { return false }

    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kPINService,
        kSecAttrAccount as String: kPINAccount
    ]
    let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [
            kSecValueData as String: encoded,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary
    )
    let status: OSStatus
    if updateStatus == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = encoded
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        status = SecItemAdd(addQuery as CFDictionary, nil)
    } else {
        status = updateStatus
    }
    guard status == errSecSuccess else { return false }
    UserDefaults.standard.removeObject(forKey: kPINKey)
    resetPINBackoff()
    return true
}

func verifyPIN(_ pin: String) -> Bool {
    guard pinLockoutRemaining() == 0 else { return false }
    let storedKeychain = readPINData()
    let storedUserDefaults = UserDefaults.standard.string(forKey: kPINKey).map { Data($0.utf8) }

    guard let stored = storedKeychain ?? storedUserDefaults else {
        return false
    }

    // Modern versioned record
    if let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: stored) {
        guard record.isValid else {
            // Malformed record fails closed without clearing or resetting PIN
            recordPINFailure()
            return false
        }
        guard let computedVerifier = derivePBKDF2SHA256(
            pin: pin,
            salt: record.salt,
            iterations: record.iterations,
            outputLength: record.verifier.count
        ) else {
            recordPINFailure()
            return false
        }
        guard constantTimeEquals(computedVerifier, record.verifier) else {
            recordPINFailure()
            return false
        }
        resetPINBackoff()
        return true
    }

    // Legacy SHA-256 verification (hex string or raw bytes)
    let legacyHex = hashPINLegacy(pin)
    let matchesHex = constantTimeEquals(stored, Data(legacyHex.utf8))
    let matchesRaw = constantTimeEquals(stored, Data(SHA256.hash(data: Data(pin.utf8))))

    if matchesHex || matchesRaw {
        // Valid legacy PIN: migrate to versioned PBKDF2 record in Keychain
        if setPIN(pin) {
            UserDefaults.standard.removeObject(forKey: kPINKey)
        }
        resetPINBackoff()
        return true
    }

    // Verification failed
    recordPINFailure()
    return false
}

func clearPIN() {
    SecItemDelete([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kPINService,
        kSecAttrAccount as String: kPINAccount
    ] as CFDictionary)
    UserDefaults.standard.removeObject(forKey: kPINKey)
    resetPINBackoff()
}

func pinLockoutRemaining(now: Date = Date()) -> TimeInterval {
    max(0, UserDefaults.standard.double(forKey: kPINLockedUntilKey) - now.timeIntervalSince1970)
}

func readPINData() -> Data? {
    var result: AnyObject?
    let status = SecItemCopyMatching([
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kPINService,
        kSecAttrAccount as String: kPINAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ] as CFDictionary, &result)
    guard status == errSecSuccess else { return nil }
    return result as? Data
}

private func recordPINFailure(now: Date = Date()) {
    let attempts = UserDefaults.standard.integer(forKey: kPINFailedAttemptsKey) + 1
    UserDefaults.standard.set(attempts, forKey: kPINFailedAttemptsKey)
    let delay = min(
        kPINMaximumBackoff,
        pow(2, Double(max(0, attempts - 1)))
    )
    UserDefaults.standard.set(now.timeIntervalSince1970 + delay, forKey: kPINLockedUntilKey)
}

private func resetPINBackoff() {
    UserDefaults.standard.removeObject(forKey: kPINFailedAttemptsKey)
    UserDefaults.standard.removeObject(forKey: kPINLockedUntilKey)
}

func hashPINLegacy(_ pin: String) -> String {
    let digest = SHA256.hash(data: Data(pin.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
