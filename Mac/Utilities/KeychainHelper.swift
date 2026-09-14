import Foundation
import CryptoKit
import Security

// MARK: - PIN helpers

private let kPINKey = "admin_pin_hash"
private let kPINService = "com.nont.prcphoto.operator-pin"
private let kPINAccount = "admin"
private let kPINFailedAttemptsKey = "admin_pin_failed_attempts"
private let kPINLockedUntilKey = "admin_pin_locked_until"
private let kPINMaximumBackoff: TimeInterval = 60

func isPINSet() -> Bool {
    readPINHash() != nil || UserDefaults.standard.string(forKey: kPINKey) != nil
}

func setPIN(_ pin: String) -> Bool {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: kPINService,
        kSecAttrAccount as String: kPINAccount
    ]
    let value = Data(hashPIN(pin).utf8)
    let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary
    )
    let status: OSStatus
    if updateStatus == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = value
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
    guard let stored = readPINHash()
            ?? UserDefaults.standard.string(forKey: kPINKey).map({ Data($0.utf8) }) else {
        return false
    }
    guard stored == Data(hashPIN(pin).utf8) else {
        recordPINFailure()
        return false
    }
    if UserDefaults.standard.string(forKey: kPINKey) != nil {
        _ = setPIN(pin)
    } else {
        resetPINBackoff()
    }
    return true
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

private func readPINHash() -> Data? {
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

private func hashPIN(_ pin: String) -> String {
    let digest = SHA256.hash(data: Data(pin.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
