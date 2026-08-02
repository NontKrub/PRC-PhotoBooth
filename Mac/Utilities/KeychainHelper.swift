import Foundation
import CryptoKit

// MARK: - PIN helpers

private let kPINKey = "admin_pin_hash"

func isPINSet() -> Bool { UserDefaults.standard.string(forKey: kPINKey) != nil }

func setPIN(_ pin: String) {
    UserDefaults.standard.set(hashPIN(pin), forKey: kPINKey)
}

func verifyPIN(_ pin: String) -> Bool {
    guard let stored = UserDefaults.standard.string(forKey: kPINKey) else { return false }
    return stored == hashPIN(pin)
}

func clearPIN() { UserDefaults.standard.removeObject(forKey: kPINKey) }

private func hashPIN(_ pin: String) -> String {
    let digest = SHA256.hash(data: Data(pin.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}
