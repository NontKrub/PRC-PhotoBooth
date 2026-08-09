import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Remote operator authentication")
struct RemoteOperatorAuthTests {
    @Test("pairing is one-time and operator sessions are revocable")
    @MainActor
    func pairingLifecycle() {
        let auth = RemoteOperatorAuth()
        let pairing = auth.pairingTokenValue()
        let session = auth.pair(pairing)

        #expect(session != nil)
        #expect(auth.isValidOperatorToken(session))
        #expect(auth.pair(pairing) == nil)
        #expect(!auth.isValidOperatorToken("not-a-token"))

        auth.revokeAll()
        #expect(!auth.isValidOperatorToken(session))
    }
}
