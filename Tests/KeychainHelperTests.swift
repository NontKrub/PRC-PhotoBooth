import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Admin PIN storage")
struct KeychainHelperTests {
    @Test("PIN verifier uses Keychain and rate-limits failures")
    func keychainPINAndBackoff() {
        clearPIN()
        defer { clearPIN() }

        #expect(setPIN("1234"))
        #expect(isPINSet())
        #expect(UserDefaults.standard.string(forKey: "admin_pin_hash") == nil)
        #expect(!verifyPIN("0000"))
        #expect(pinLockoutRemaining() > 0)

        clearPIN()
        #expect(setPIN("1234"))
        #expect(verifyPIN("1234"))
    }
}
