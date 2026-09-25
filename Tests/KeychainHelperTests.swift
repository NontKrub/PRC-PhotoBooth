import Foundation
import Testing
import Security
import CryptoKit
@testable import PRC_PhotoBooth_Mac

private let testPINKey = "admin_pin_hash"
private let testPINService = "com.nont.prcphoto.operator-pin"
private let testPINAccount = "admin"
private let testPINKeychain = InMemoryGenericPasswordKeychain()

@Suite("Admin PIN storage", .serialized)
struct KeychainHelperTests {
    @Test("PIN setup cannot be dismissed after saving starts")
    func pinSavingBlocksCancellationAndDismissal() {
        #expect(PINGateView.CredentialActivity.saving.preventsDismissal)
        #expect(!PINGateView.CredentialActivity.verifying.preventsDismissal)
    }

    @Test("PIN verifier uses Keychain and rate-limits failures")
    func keychainPINAndBackoff() async {
        clearPINCopies()
        defer { clearPINCopies() }

        #expect(await setPIN("1234"))
        #expect(isPINSet())
        #expect(UserDefaults.standard.string(forKey: testPINKey) == nil)
        #expect(!(await verifyPIN("0000")))
        #expect(pinLockoutRemaining() > 0)

        clearPINCopies()
        #expect(await setPIN("1234"))
        #expect(await verifyPIN("1234"))
    }

    @Test("Successful current-cost Keychain verification removes stale legacy defaults")
    func currentCostKeychainVerificationCleansLegacyDefaults() async throws {
        clearPINCopies()
        defer { clearPINCopies() }

        let pin = "5317"
        let salt = Data(repeating: 0x5a, count: PINCredentialRecord.saltByteCount)
        let record = PINCredentialRecord(
            version: PINCredentialRecord.currentVersion,
            algorithm: PINCredentialRecord.defaultAlgorithm,
            salt: salt,
            iterations: PINCredentialRecord.defaultIterations,
            verifier: try #require(derivePBKDF2SHA256(
                pin: pin,
                salt: salt,
                iterations: PINCredentialRecord.defaultIterations
            ))
        )
        let encoded = try JSONEncoder().encode(record)
        savePINDataToDataProtectionKeychain(encoded)
        UserDefaults.standard.set(hashPINLegacy(pin), forKey: testPINKey)

        #expect(await verifyPIN(pin))
        #expect(UserDefaults.standard.string(forKey: testPINKey) == nil)
        #expect(readPINDataFromDataProtectionKeychain() == encoded)
    }

    @Test("new records use random salt so same PIN yields different records")
    func randomSaltProducesDifferentRecords() async throws {
        clearPINCopies()
        defer { clearPINCopies() }

        #expect(await setPIN("4321"))
        guard let firstData = readPINData(),
              let firstRecord = try? JSONDecoder().decode(PINCredentialRecord.self, from: firstData) else {
            Issue.record("Expected valid first record")
            return
        }

        #expect(await setPIN("4321"))
        guard let secondData = readPINData(),
              let secondRecord = try? JSONDecoder().decode(PINCredentialRecord.self, from: secondData) else {
            Issue.record("Expected valid second record")
            return
        }

        #expect(firstRecord.salt != secondRecord.salt)
        #expect(firstRecord.verifier != secondRecord.verifier)
        #expect(firstRecord.iterations == PINCredentialRecord.defaultIterations)
        #expect(firstRecord.algorithm == "PBKDF2-HMAC-SHA256")
        #expect(firstRecord.version == 1)
        #expect(await verifyPIN("4321"))
    }

    @Test("PIN credential bounds reject excessive work and oversized records")
    func credentialBounds() throws {
        let salt = Data(repeating: 0x5a, count: 16)
        let verifier = Data(repeating: 0x6b, count: 32)
        let excessiveWork = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: 2_000_001,
            verifier: verifier
        )
        let oversizedSalt = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: Data(repeating: 0x5a, count: 65),
            iterations: 100_000,
            verifier: verifier
        )

        #expect(!excessiveWork.isValid)
        #expect(!oversizedSalt.isValid)
        #expect(PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: 2_000_000,
            verifier: verifier
        ).isValid)

        let wrongVerifierLength = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: 100_000,
            verifier: Data(repeating: 0x6b, count: 31)
        )
        #expect(!wrongVerifierLength.isValid)

        clearPINCopies()
        defer { clearPINCopies() }
        let validRecord = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: 100_000,
            verifier: verifier
        )
        let encoded = try JSONEncoder().encode(validRecord)
        var oversizedJSON = String(decoding: encoded, as: UTF8.self)
        oversizedJSON.removeLast()
        oversizedJSON += ",\"padding\":\"\(String(repeating: "x", count: 5_000))\"}"
        saveRawToKeychain(Data(oversizedJSON.utf8))

        #expect(!isPINSet())
    }

    @Test("PIN setter accepts only four ASCII digits")
    func pinFormatIsEnforced() async {
        clearPINCopies()
        defer { clearPINCopies() }

        #expect(!(await setPIN("12a4")))
        #expect(!(await setPIN("12345")))
        #expect(!(await setPIN("１２３４")))
        #expect(await setPIN("0123"))
        #expect(!(await verifyPIN("12345")))
        #expect(!(await verifyPIN("０１２３")))
        UserDefaults.standard.removeObject(forKey: "admin_pin_failed_attempts")
        UserDefaults.standard.removeObject(forKey: "admin_pin_locked_until")
        #expect(await verifyPIN("0123"))
    }

    @Test("verified 100k PIN record upgrades to the preferred work factor")
    func oldWorkFactorUpgradesAfterVerification() async throws {
        clearPINCopies()
        defer { clearPINCopies() }

        let pin = "2468"
        let salt = Data(repeating: 0x45, count: 16)
        let verifier = derivePBKDF2SHA256(pin: pin, salt: salt, iterations: 100_000)!
        let oldRecord = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: 100_000,
            verifier: verifier
        )
        saveRawToKeychain(try JSONEncoder().encode(oldRecord))

        #expect(await verifyPIN(pin))
        guard let data = readPINData(),
              let upgraded = try? JSONDecoder().decode(PINCredentialRecord.self, from: data) else {
            Issue.record("Expected upgraded PBKDF2 record")
            return
        }
        #expect(upgraded.iterations == PINCredentialRecord.defaultIterations)
        #expect(upgraded.salt != oldRecord.salt)
    }

    @Test("legacy PIN Keychain item migrates to Data Protection Keychain")
    func legacyPINKeychainMigratesToDataProtection() throws {
        clearPINCopies()
        defer { clearPINCopies() }

        let pin = "7890"
        let salt = Data(repeating: 0x34, count: 16)
        let record = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: salt,
            iterations: 100_000,
            verifier: derivePBKDF2SHA256(pin: pin, salt: salt, iterations: 100_000)!
        )
        let legacyData = try JSONEncoder().encode(record)
        saveRawToKeychain(legacyData)

        #expect(readPINData() == legacyData)
        #expect(readPINDataFromDataProtectionKeychain() == legacyData)
        #expect(readLegacyPINData() == nil)
    }

    @Test("clearPIN removes Data Protection and legacy Keychain copies")
    func clearPINRemovesBothKeychainCopies() {
        clearPINCopies()
        defer { clearPINCopies() }
        let data = Data("pin credential".utf8)
        saveRawToKeychain(data)
        savePINDataToDataProtectionKeychain(data)

        clearPIN()

        #expect(readLegacyPINData() == nil)
        #expect(readPINDataFromDataProtectionKeychain() == nil)
    }

    @Test("malformed record fails closed without wiping credential")
    func malformedRecordFailsClosed() async throws {
        clearPINCopies()
        defer { clearPINCopies() }

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

        #expect(!(await verifyPIN("1234")))
        // Credential is NOT wiped out; isPINSet remains or fails closed
        #expect(readPINData() == malformedData)

        // Store completely corrupted bytes
        saveRawToKeychain(Data([0x01, 0x02, 0x03, 0x04]))
        #expect(!(await verifyPIN("1234")))
        #expect(readPINData() == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test("UserDefaults legacy SHA-256 migrates on correct PIN")
    func userDefaultsLegacyMigrates() async {
        clearPINCopies()
        defer { clearPINCopies() }

        let pin = "7890"
        let legacyHash = hashPINLegacy(pin)
        UserDefaults.standard.set(legacyHash, forKey: testPINKey)
        #expect(isPINSet())

        // Wrong PIN does NOT migrate
        #expect(!(await verifyPIN("0000")))
        #expect(UserDefaults.standard.string(forKey: testPINKey) == legacyHash)
        #expect(readPINData() == nil)

        // Reset lockout for testing correct PIN
        UserDefaults.standard.removeObject(forKey: "admin_pin_locked_until")

        // Correct PIN verifies and migrates
        #expect(await verifyPIN(pin))
        #expect(UserDefaults.standard.string(forKey: testPINKey) == nil)
        guard let migratedData = readPINData(),
              let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: migratedData) else {
            Issue.record("Expected migrated PBKDF2 record in Keychain")
            return
        }
        #expect(record.isValid)
        #expect(record.algorithm == "PBKDF2-HMAC-SHA256")
        #expect(await verifyPIN(pin))
    }

    @Test("Keychain legacy SHA-256 string migrates on correct PIN")
    func keychainLegacyMigrates() async {
        clearPINCopies()
        defer { clearPINCopies() }

        let pin = "5555"
        let legacyHash = hashPINLegacy(pin)
        let legacyData = Data(legacyHash.utf8)
        saveRawToKeychain(legacyData)
        #expect(isPINSet())

        // Wrong PIN does NOT migrate
        #expect(!(await verifyPIN("1111")))
        #expect(readPINData() == legacyData)

        // Reset lockout for testing correct PIN
        UserDefaults.standard.removeObject(forKey: "admin_pin_locked_until")

        // Correct PIN verifies and migrates to modern record
        #expect(await verifyPIN(pin))
        guard let migratedData = readPINData(),
              let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: migratedData) else {
            Issue.record("Expected migrated PBKDF2 record in Keychain")
            return
        }
        #expect(record.isValid)
        #expect(record.verifier.count == 32)
        #expect(migratedData != legacyData)
        #expect(await verifyPIN(pin))
    }

    @Test("raw SHA-256 Keychain PIN migrates only after a correct PIN")
    func rawKeychainLegacyMigrates() async {
        clearPINCopies()
        defer { clearPINCopies() }

        let pin = "1357"
        let legacyData = Data(SHA256.hash(data: Data(pin.utf8)))
        saveRawToKeychain(legacyData)

        #expect(!(await verifyPIN("0000")))
        #expect(readPINDataFromDataProtectionKeychain() == legacyData)
        #expect(readLegacyPINData() == nil)
        UserDefaults.standard.removeObject(forKey: "admin_pin_locked_until")
        #expect(await verifyPIN(pin))
        guard let migrated = readPINDataFromDataProtectionKeychain(),
              let record = try? JSONDecoder().decode(PINCredentialRecord.self, from: migrated) else {
            Issue.record("Expected PBKDF2 credential after successful legacy PIN verification")
            return
        }
        #expect(record.isValid)
        #expect(migrated != legacyData)
        #expect(readLegacyPINData() == nil)
    }

    @Test("clearPIN removes both Keychain and UserDefaults data")
    func clearPINRemovesAll() async {
        clearPINCopies()
        defer { clearPINCopies() }

        #expect(await setPIN("9999"))
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

    @Test("failed Data Protection migration preserves the legacy credential")
    func failedDataProtectionMigrationPreservesLegacyCredential() {
        let store = InMemoryGenericPasswordKeychain()
        let legacy = Data("legacy credential".utf8)
        store.put(legacy, service: "pin-test", account: "migration", useDataProtectionKeychain: false)
        store.failDataProtectionWrites = true

        let result = store.readDataMigratingToDataProtection(
            service: "pin-test",
            account: "migration",
            accessibility: .whenUnlockedThisDeviceOnly
        )

        #expect(result.data == legacy)
        #expect(result.legacyCleanupError == nil)
        #expect(store.item(service: "pin-test", account: "migration", useDataProtectionKeychain: false) == legacy)
        #expect(store.item(service: "pin-test", account: "migration", useDataProtectionKeychain: true) == nil)
    }

    @Test("migration readback mismatch preserves the legacy credential")
    func migrationReadbackMismatchPreservesLegacyCredential() {
        let store = InMemoryGenericPasswordKeychain()
        let legacy = Data("legacy credential".utf8)
        store.put(legacy, service: "pin-test", account: "readback", useDataProtectionKeychain: false)
        store.corruptDataProtectionReadback = true

        let result = store.readDataMigratingToDataProtection(
            service: "pin-test",
            account: "readback",
            accessibility: .whenUnlockedThisDeviceOnly
        )

        #expect(result.data == legacy)
        #expect(result.legacyCleanupError == nil)
        #expect(store.item(service: "pin-test", account: "readback", useDataProtectionKeychain: false) == legacy)
        #expect(store.item(service: "pin-test", account: "readback", useDataProtectionKeychain: true) == nil)
    }

    @Test("PIN reset leaves failure backoff intact when Keychain deletion fails")
    func pinResetDoesNotReportSuccessAfterDeleteFailure() async {
        clearPINCopies()
        defer {
            testPINKeychain.failDataProtectionDeletes = false
            clearPINCopies()
        }
        setPINKeychainStoreForTesting(testPINKeychain)
        #expect(await setPIN("1357"))
        #expect(!(await verifyPIN("2468")))
        #expect(pinLockoutRemaining() > 0)

        testPINKeychain.failDataProtectionDeletes = true
        #expect(!clearPIN())

        #expect(pinLockoutRemaining() > 0)
        #expect(isPINSet())
    }

    @Test("Data Protection read failure still returns the legacy credential")
    func dataProtectionReadFailurePreservesLegacyCredential() {
        let store = InMemoryGenericPasswordKeychain()
        let legacy = Data("legacy credential".utf8)
        store.put(legacy, service: "pin-test", account: "read-failure", useDataProtectionKeychain: false)
        store.failDataProtectionReads = true

        let result = store.readDataMigratingToDataProtection(
            service: "pin-test",
            account: "read-failure",
            accessibility: .whenUnlockedThisDeviceOnly
        )

        #expect(result.data == legacy)
        #expect(result.legacyCleanupError == nil)
        #expect(store.item(service: "pin-test", account: "read-failure", useDataProtectionKeychain: false) == legacy)
    }

    @Test("legacy Keychain cleanup failure is reported and retried")
    func legacyKeychainCleanupFailureIsReportedAndRetried() async throws {
        clearPINCopies()
        defer {
            testPINKeychain.failLegacyDeletes = false
            clearPINCopies()
        }

        let oldPIN = "2468"
        let oldSalt = Data(repeating: 0x41, count: 16)
        let oldRecord = PINCredentialRecord(
            version: 1,
            algorithm: "PBKDF2-HMAC-SHA256",
            salt: oldSalt,
            iterations: 100_000,
            verifier: derivePBKDF2SHA256(pin: oldPIN, salt: oldSalt, iterations: 100_000)!
        )
        saveRawToKeychain(try JSONEncoder().encode(oldRecord))
        testPINKeychain.failLegacyDeletes = true

        #expect(await setPIN("9753"))
        let pending = testPINKeychain.readDataMigratingToDataProtection(
            service: testPINService,
            account: testPINAccount,
            accessibility: .whenUnlockedThisDeviceOnly
        )
        #expect(pending.data == readPINDataFromDataProtectionKeychain())
        #expect(pending.legacyCleanupError == errSecIO)
        #expect(readLegacyPINData() != nil)

        testPINKeychain.failLegacyDeletes = false
        #expect(readPINData() == readPINDataFromDataProtectionKeychain())
        #expect(readLegacyPINData() == nil)
        #expect(await verifyPIN("9753"))
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

final class InMemoryGenericPasswordKeychain: GenericPasswordKeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var failDataProtectionReads = false
    var failDataProtectionWrites = false
    var failDataProtectionDeletes = false
    var failLegacyDeletes = false
    var corruptDataProtectionReadback = false

    func readData(
        service: String,
        account: String,
        useDataProtectionKeychain: Bool
    ) -> (status: OSStatus, data: Data?) {
        lock.lock()
        defer { lock.unlock() }
        if useDataProtectionKeychain && failDataProtectionReads {
            return (errSecInteractionNotAllowed, nil)
        }
        let key = itemKey(service: service, account: account, useDataProtectionKeychain: useDataProtectionKeychain)
        guard let data = items[key] else { return (errSecItemNotFound, nil) }
        if useDataProtectionKeychain && corruptDataProtectionReadback {
            return (errSecSuccess, Data([0]))
        }
        return (errSecSuccess, data)
    }

    func writeData(
        _ data: Data,
        service: String,
        account: String,
        useDataProtectionKeychain: Bool,
        accessibility: GenericPasswordKeychainAccessibility
    ) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        guard !useDataProtectionKeychain || !failDataProtectionWrites else { return errSecIO }
        let key = itemKey(service: service, account: account, useDataProtectionKeychain: useDataProtectionKeychain)
        items[key] = data
        return errSecSuccess
    }

    func deleteData(service: String, account: String, useDataProtectionKeychain: Bool) -> OSStatus {
        lock.lock()
        defer { lock.unlock() }
        if useDataProtectionKeychain && failDataProtectionDeletes { return errSecIO }
        if !useDataProtectionKeychain && failLegacyDeletes { return errSecIO }
        let key = itemKey(service: service, account: account, useDataProtectionKeychain: useDataProtectionKeychain)
        guard items.removeValue(forKey: key) != nil else { return errSecItemNotFound }
        return errSecSuccess
    }

    func put(_ data: Data, service: String, account: String, useDataProtectionKeychain: Bool) {
        lock.lock()
        defer { lock.unlock() }
        items[itemKey(service: service, account: account, useDataProtectionKeychain: useDataProtectionKeychain)] = data
    }

    func item(service: String, account: String, useDataProtectionKeychain: Bool) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return items[itemKey(service: service, account: account, useDataProtectionKeychain: useDataProtectionKeychain)]
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        items.removeAll()
    }

    private func itemKey(service: String, account: String, useDataProtectionKeychain: Bool) -> String {
        "\(service)\u{0}\(account)\u{0}\(useDataProtectionKeychain)"
    }
}

private func saveRawToKeychain(_ data: Data) {
    _ = testPINKeychain.deleteData(
        service: testPINService,
        account: testPINAccount,
        useDataProtectionKeychain: true
    )
    testPINKeychain.put(data, service: testPINService, account: testPINAccount, useDataProtectionKeychain: false)
}

private func clearPINCopies() {
    setPINKeychainStoreForTesting(testPINKeychain)
    clearPIN()
    testPINKeychain.removeAll()
    UserDefaults.standard.removeObject(forKey: testPINKey)
}

private func readPINDataFromDataProtectionKeychain() -> Data? {
    testPINKeychain.item(service: testPINService, account: testPINAccount, useDataProtectionKeychain: true)
}

private func readLegacyPINData() -> Data? {
    testPINKeychain.item(service: testPINService, account: testPINAccount, useDataProtectionKeychain: false)
}

private func savePINDataToDataProtectionKeychain(_ data: Data) {
    testPINKeychain.put(data, service: testPINService, account: testPINAccount, useDataProtectionKeychain: true)
}
