import Foundation
import Testing
import Security
import CryptoKit
@testable import PRC_PhotoBooth_Mac

private let testPINKey = "admin_pin_hash"
private let testPINService = "com.nont.prcphoto.operator-pin"
private let testPINAccount = "admin"

@Suite("Admin PIN storage")
struct KeychainHelperTests {
    @Test("PIN verifier uses Keychain and rate-limits failures")
    func keychainPINAndBackoff() {
        clearPIN()
        defer { clearPIN() }

        #expect(setPIN("1234"))
        #expect(isPINSet())
        #expect(UserDefaults.standard.string(forKey: testPINKey) == nil)
        #expect(!verifyPIN("0000"))
        #expect(pinLockoutRemaining() > 0)

        clearPIN()
        #expect(setPIN("1234"))
        #expect(verifyPIN("1234"))
    }

    @Test("new records use random salt so same PIN yields different records")
    func randomSaltProducesDifferentRecords() throws {
        clearPIN()
        defer { clearPIN() }

        #expect(setPIN("4321"))
        guard let firstData = readPINData(),
              let firstRecord = try? JSONDecoder().decode(PINCredentialRecord.self, from: firstData) else {
            Issue.record("Expected valid first record")
            return
        }

        #expect(setPIN("4321"))
        guard let secondData = readPINData(),
              let secondRecord = try? JSONDecoder().decode(PINCredentialRecord.self, from: secondData) else {
            Issue.record("Expected valid second record")
            return
        }

        #expect(firstRecord.salt != secondRecord.salt)
        #expect(firstRecord.verifier != secondRecord.verifier)
        #expect(firstRecord.iterations == 100_000)
        #expect(firstRecord.algorithm == "PBKDF2-HMAC-SHA256")
        #expect(firstRecord.version == 1)
        #expect(verifyPIN("4321"))
    }

    @Test("malformed record fails closed without wiping credential")
    func malformedRecordFailsClosed() throws {
        clearPIN()
        defer { clearPIN() }

        // Store a malformed JSON record directly into Keychain
        let malformedRecord = PINCredentialRecord(
            version: 99, // unsupported version
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: Data(repeating: 0, count: 16),
            iterations: 100_000,
            verifier: Data(repeating: 0, count: 32)
        )
        let malformedData = try JSONEncoder().encode(malformedRecord)
        saveRawToKeychain(malformedData)

        #expect(!verifyPIN("1234"))
        // Credential is NOT wiped out; isPINSet remains or fails closed
        #expect(readPINData() == malformedData)

        // Store completely corrupted bytes
        saveRawToKeychain(Data([0x01, 0x02, 0x03, 0x04]))
        #expect(!verifyPIN("1234"))
        #expect(readPINData() == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("UserDefaults legacy SHA-256 migrates on correct PIN")
    func userDefaultsLegacyMigrates() {
        clearPIN()
        defer { clearPIN() }

        let pin = "7890"
        let legacyHash = hashPINLegacy(pin)
        UserDefaults.standard.set(legacyHash, forKey: testPINKey)
        #expect(isPINSet())

        // Wrong PIN does NOT migrate
        #expect(!verifyPIN("0000"))
        #expect(UserDefaults.standard.string(forKey: testPINKey) == legacyHash)
        #expect(readPINData() == nil)

        // Reset lockout for testing correct PIN
        UserDefaults.standard.removeObject(forKey: "admin_pin_locked_until")

        // Correct PIN verifies and migrates
        #expect(verifyPIN(pin))
        #expect(UserDefaults.standard.string(forKey: testPINKey) == nil)
        guard let migratedData = readPINData(),
              let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: migratedData) else {
            Issue.record("Expected migrated PBKDF2 record in Keychain")
            return
        }
        #expect(record.isValid)
        #expect(record.algorithm == "PBKDF2-HMAC-SHA256")
        #expect(verifyPIN(pin))
    }

    @Test("Keychain legacy SHA-256 string migrates on correct PIN")
    func keychainLegacyMigrates() {
        clearPIN()
        defer { clearPIN() }

        let pin = "5555"
        let legacyHash = hashPINLegacy(pin)
        let legacyData = Data(legacyHash.utf8)
        saveRawToKeychain(legacyData)
        #expect(isPINSet())

        // Wrong PIN does NOT migrate
        #expect(!verifyPIN("1111"))
        #expect(readPINData() == legacyData)

        // Reset lockout for testing correct PIN
        UserDefaults.standard.removeObject(forKey: "admin_pin_locked_until")

        // Correct PIN verifies and migrates to modern record
        #expect(verifyPIN(pin))
        guard let migratedData = readPINData(),
              let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: migratedData) else {
            Issue.record("Expected migrated PBKDF2 record in Keychain")
            return
        }
        #expect(record.isValid)
        #expect(record.verifier.count == 32)
        #expect(migratedData != legacyData)
        #expect(verifyPIN(pin))
    }

    @Test("clearPIN removes both Keychain and UserDefaults data")
    func clearPINRemovesAll() {
        clearPIN()
        defer { clearPIN() }

        #expect(setPIN("9999"))
        UserDefaults.standard.set("legacy-residue", forKey: testPINKey)
        UserDefaults.standard.set(3, forKey: "admin_pin_failed_attempts")
        UserDefaults.standard.set(Date().timeIntervalSince1970 + 60, forKey: "admin_pin_locked_until")

        clearPIN()

        #expect(!isPINSet())
        #expect(readPINData() == nil)
        #expect(UserDefaults.standard.string(forKey: testPINKey) == nil)
        #expect(UserDefaults.standard.object(forKey: "admin_pin_failed_attempts") == nil)
        #expect(UserDefaults.standard.object(forKey: "admin_pin_locked_until") == nil)
        #expect(pinLockoutRemaining() == 0)
    }

    @Test("constantTimeEquals helper validates equal and unequal data correctly")
    func constantTimeEquality() {
        let d1 = Data([1, 2, 3, 4, 5])
        let d2 = Data([1, 2, 3, 4, 5])
        let d3 = Data([1, 2, 3, 4, 6])
        let d4 = Data([1, 2, 3, 4])

        #expect(constantTimeEquals(d1, d2))
        #expect(!constantTimeEquals(d1, d3))
        #expect(!constantTimeEquals(d1, d4))
        #expect(constantTimeEquals(Data(), Data()))
    }
}

private func saveRawToKeychain(_ data: Data) {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: testPINService,
        kSecAttrAccount as String: testPINAccount
    ]
    let updateStatus = SecItemUpdate(
        query as CFDictionary,
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ] as CFDictionary
    )
    if updateStatus == errSecItemNotFound {
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        _ = SecItemAdd(addQuery as CFDictionary, nil)
    }
}
