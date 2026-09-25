import Foundation
import CryptoKit
import Security
import CommonCrypto

// MARK: - PIN Credential Model

struct PINCredentialRecord: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let defaultAlgorithm = "PBKDF2-HMAC-SHA256"
    static let minimumAcceptedIterations: UInt32 = 100_000
    static let defaultIterations: UInt32 = 600_000
    static let maximumAcceptedIterations: UInt32 = 2_000_000
    static let saltByteCount = 16
    static let maximumSaltByteCount = 64
    static let verifierByteCount = 32
    static let maximumEncodedRecordByteCount = 4_096

    var version: Int
    var algorithm: String
    var salt: Data
    var iterations: UInt32
    var verifier: Data

    var isValid: Bool {
        version == Self.currentVersion
            && algorithm == Self.defaultAlgorithm
            && (Self.saltByteCount...Self.maximumSaltByteCount).contains(salt.count)
            && (Self.minimumAcceptedIterations...Self.maximumAcceptedIterations).contains(iterations)
            && verifier.count == Self.verifierByteCount
    }
}

// MARK: - Cryptographic Helpers

func isValidPINFormat(_ pin: String) -> Bool {
    let digits = pin.utf8
    return digits.count == 4 && digits.allSatisfy { (48...57).contains($0) }
}

func derivePBKDF2SHA256(
    pin: String,
    salt: Data,
    iterations: UInt32,
    outputLength: Int = PINCredentialRecord.verifierByteCount
) -> Data? {
    guard isValidPINFormat(pin),
          (PINCredentialRecord.saltByteCount...PINCredentialRecord.maximumSaltByteCount).contains(salt.count),
          (PINCredentialRecord.minimumAcceptedIterations...PINCredentialRecord.maximumAcceptedIterations).contains(iterations),
          outputLength == PINCredentialRecord.verifierByteCount else { return nil }

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

private final class PINCredentialKeychainStoreBox: @unchecked Sendable {
    private let lock = NSLock()
    private var store: any GenericPasswordKeychainStore

    init(store: any GenericPasswordKeychainStore) {
        self.store = store
    }

    func snapshot() -> any GenericPasswordKeychainStore {
        lock.lock()
        defer { lock.unlock() }
        return store
    }

#if DEBUG
    func replaceForTesting(with store: any GenericPasswordKeychainStore) {
        lock.lock()
        defer { lock.unlock() }
        self.store = store
    }
#endif
}

private let pinKeychainStore = PINCredentialKeychainStoreBox(store: SecurityGenericPasswordKeychainStore())

#if DEBUG
func setPINKeychainStoreForTesting(_ store: any GenericPasswordKeychainStore) {
    pinKeychainStore.replaceForTesting(with: store)
}
#endif

func isPINSet() -> Bool {
    if let data = readPINData(), data.count <= PINCredentialRecord.maximumEncodedRecordByteCount {
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

func setPIN(_ pin: String) async -> Bool {
    await PINCredentialService.shared.setPIN(pin)
}

func verifyPIN(_ pin: String) async -> Bool {
    await PINCredentialService.shared.verifyPIN(pin)
}

@discardableResult
func clearPIN() -> Bool {
    let status = pinKeychainStore.snapshot().deleteBothCopies(service: kPINService, account: kPINAccount)
    guard status == errSecSuccess else { return false }
    UserDefaults.standard.removeObject(forKey: kPINKey)
    resetPINBackoff()
    return true
}

func pinLockoutRemaining(now: Date = Date()) -> TimeInterval {
    max(0, UserDefaults.standard.double(forKey: kPINLockedUntilKey) - now.timeIntervalSince1970)
}

func readPINData() -> Data? {
    let result = pinKeychainStore.snapshot().readDataMigratingToDataProtection(
        service: kPINService,
        account: kPINAccount,
        accessibility: .whenUnlockedThisDeviceOnly
    )
    if let status = result.legacyCleanupError {
        reportLegacyKeychainCleanupFailure(status)
    }
    return result.data
}

private actor PINCredentialService {
    static let shared = PINCredentialService()

    func setPIN(_ pin: String) -> Bool {
        guard isValidPINFormat(pin), storeCredential(pin) else { return false }
        UserDefaults.standard.removeObject(forKey: kPINKey)
        resetPINBackoff()
        return true
    }

    func verifyPIN(_ pin: String) -> Bool {
        guard !Task.isCancelled else { return false }
        guard pinLockoutRemaining() == 0 else { return false }
        guard isValidPINFormat(pin) else {
            recordPINFailure()
            return false
        }

        let storedKeychain = readPINData()
        let storedUserDefaults = UserDefaults.standard.string(forKey: kPINKey).map { Data($0.utf8) }
        guard let stored = storedKeychain ?? storedUserDefaults,
              stored.count <= PINCredentialRecord.maximumEncodedRecordByteCount else {
            return false
        }

        if let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: stored) {
            guard record.isValid,
                  let computedVerifier = derivePBKDF2SHA256(
                    pin: pin,
                    salt: record.salt,
                    iterations: record.iterations,
                    outputLength: record.verifier.count
                  ) else {
                recordPINFailure()
                return false
            }
            guard !Task.isCancelled else { return false }
            guard constantTimeEquals(computedVerifier, record.verifier) else {
                recordPINFailure()
                return false
            }

            resetPINBackoff()
            let upgradedCredential = record.iterations < PINCredentialRecord.defaultIterations
                && storeCredential(pin)
            if storedKeychain != nil || upgradedCredential {
                UserDefaults.standard.removeObject(forKey: kPINKey)
            }
            return true
        }

        // Legacy SHA-256 verification (hex string or raw bytes).
        let legacyHex = hashPINLegacy(pin)
        let matchesHex = constantTimeEquals(stored, Data(legacyHex.utf8))
        let matchesRaw = constantTimeEquals(stored, Data(SHA256.hash(data: Data(pin.utf8))))

        if matchesHex || matchesRaw {
            guard !Task.isCancelled else { return false }
            if storeCredential(pin) {
                UserDefaults.standard.removeObject(forKey: kPINKey)
            }
            resetPINBackoff()
            return true
        }

        recordPINFailure()
        return false
    }

    private func storeCredential(_ pin: String) -> Bool {
        guard !Task.isCancelled, isValidPINFormat(pin) else { return false }
        var salt = [UInt8](repeating: 0, count: PINCredentialRecord.saltByteCount)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        guard randomStatus == errSecSuccess else { return false }
        let saltData = Data(salt)
        guard let verifier = derivePBKDF2SHA256(
            pin: pin,
            salt: saltData,
            iterations: PINCredentialRecord.defaultIterations
        ), !Task.isCancelled else { return false }

        let record = PINCredentialRecord(
            version: PINCredentialRecord.currentVersion,
            algorithm: PINCredentialRecord.defaultAlgorithm,
            salt: saltData,
            iterations: PINCredentialRecord.defaultIterations,
            verifier: verifier
        )
        guard let encoded = try? JSONEncoder().encode(record),
              encoded.count <= PINCredentialRecord.maximumEncodedRecordByteCount else { return false }

        let keychainStore = pinKeychainStore.snapshot()
        let status = keychainStore.writeDataAndVerify(
            encoded,
            service: kPINService,
            account: kPINAccount,
            useDataProtectionKeychain: true,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        guard status == errSecSuccess else { return false }
        let legacyDeleteStatus = keychainStore.deleteData(
            service: kPINService,
            account: kPINAccount,
            useDataProtectionKeychain: false
        )
        if legacyDeleteStatus != errSecSuccess && legacyDeleteStatus != errSecItemNotFound {
            reportLegacyKeychainCleanupFailure(legacyDeleteStatus)
        }
        return true
    }
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
