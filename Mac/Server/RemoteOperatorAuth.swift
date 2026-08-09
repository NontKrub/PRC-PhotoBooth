import Foundation

@MainActor
final class RemoteOperatorAuth {
    private struct ExpiringToken {
        var value: String
        var expiresAt: Date
    }

    private var pairingToken: ExpiringToken?
    private var operatorTokens: [String: ExpiringToken] = [:]

    func pairingTokenValue() -> String {
        if let pairingToken, pairingToken.expiresAt > Date() { return pairingToken.value }
        let token = Self.randomToken()
        pairingToken = ExpiringToken(value: token, expiresAt: Date().addingTimeInterval(600))
        return token
    }

    func pair(_ token: String) -> String? {
        guard let pairingToken,
              pairingToken.expiresAt > Date(),
              token == pairingToken.value else { return nil }
        self.pairingToken = nil
        let session = Self.randomToken()
        operatorTokens[session] = ExpiringToken(value: session, expiresAt: Date().addingTimeInterval(28_800))
        return session
    }

    func isValidOperatorToken(_ token: String?) -> Bool {
        guard let token,
              let stored = operatorTokens[token],
              stored.expiresAt > Date() else {
            purgeExpired()
            return false
        }
        return true
    }

    func revokeAll() {
        pairingToken = nil
        operatorTokens.removeAll()
    }

    private func purgeExpired() {
        let now = Date()
        operatorTokens = operatorTokens.filter { $0.value.expiresAt > now }
    }

    private static func randomToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
