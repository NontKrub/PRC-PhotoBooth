import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Booth pairing")
struct BoothPairingTests {
    @Test("pairing intent validates its target, role, protocol, and hello identity")
    func pairingIntentValidation() throws {
        let intent = BoothPairingIntent(
            iPadIdentity: BoothDeviceIdentity(id: "ipad-1", displayName: "PRC-iPad-01", role: .iPad),
            targetMacDeviceID: "mac-1"
        )
        let hello = BoothTransportHello(
            role: .iPad,
            deviceID: "ipad-1",
            deviceName: "PRC-iPad-01"
        )

        try intent.validate(peerHello: hello, localMacDeviceID: "mac-1")

        #expect(throws: BoothPairingError.wrongDevice) {
            try intent.validate(peerHello: hello, localMacDeviceID: "other-mac")
        }

        let mismatchedHello = BoothTransportHello(
            role: .iPad,
            deviceID: "other-ipad",
            deviceName: "Other iPad"
        )
        #expect(throws: BoothPairingError.invalidPairingIntent) {
            try intent.validate(peerHello: mismatchedHello, localMacDeviceID: "mac-1")
        }
    }

    @Test("pairing intent policy reuses, rejects, cools down, or starts safely")
    func pairingIntentPolicy() {
        let now = Date(timeIntervalSince1970: 60_000)

        #expect(BoothPairingIntentPolicy.decide(
            iPadID: "ipad-1",
            activeRequestID: "ipad-1",
            hasActivePairingSession: true,
            boothIsIdle: true,
            hasAuthenticatedPeer: false,
            lastRequestAt: nil,
            now: now
        ) == .reuseSession)
        #expect(BoothPairingIntentPolicy.decide(
            iPadID: "ipad-2",
            activeRequestID: "ipad-1",
            hasActivePairingSession: true,
            boothIsIdle: true,
            hasAuthenticatedPeer: false,
            lastRequestAt: nil,
            now: now
        ) == .reject(reason: "Another iPad is currently being paired."))
        #expect(BoothPairingIntentPolicy.decide(
            iPadID: "ipad-1",
            activeRequestID: nil,
            hasActivePairingSession: false,
            boothIsIdle: false,
            hasAuthenticatedPeer: false,
            lastRequestAt: nil,
            now: now
        ) == .reject(reason: "Pairing is unavailable while a photo session is active."))
        #expect(BoothPairingIntentPolicy.decide(
            iPadID: "ipad-1",
            activeRequestID: nil,
            hasActivePairingSession: false,
            boothIsIdle: true,
            hasAuthenticatedPeer: true,
            lastRequestAt: nil,
            now: now
        ) == .reject(reason: "Another iPad is currently connected."))
        #expect(BoothPairingIntentPolicy.decide(
            iPadID: "ipad-1",
            activeRequestID: nil,
            hasActivePairingSession: false,
            boothIsIdle: true,
            hasAuthenticatedPeer: false,
            lastRequestAt: now.addingTimeInterval(-1),
            now: now
        ) == .reject(reason: "Please wait before trying again."))
        #expect(BoothPairingIntentPolicy.decide(
            iPadID: "ipad-1",
            activeRequestID: nil,
            hasActivePairingSession: false,
            boothIsIdle: true,
            hasAuthenticatedPeer: false,
            lastRequestAt: now.addingTimeInterval(-5),
            now: now
        ) == .startSession)
    }

    @Test("pairing intent alone cannot create trust before a PIN or QR request")
    func pairingResultTrustGate() {
        let result = BoothPairingResult(
            accepted: true,
            macIdentity: macIdentity,
            sharedSecret: Data(repeating: 0x11, count: 32)
        )
        let request = BoothPairingRequest(
            sessionID: "session",
            targetMacDeviceID: macIdentity.id,
            iPadIdentity: BoothDeviceIdentity(id: "ipad-1", displayName: "PRC-iPad-01", role: .iPad),
            method: .pin("123456")
        )

        #expect(!BoothPairingTrustPolicy.accepts(
            result: result,
            pendingPairingRequest: nil,
            targetPeerID: macIdentity.id
        ))
        #expect(BoothPairingTrustPolicy.accepts(
            result: result,
            pendingPairingRequest: request,
            targetPeerID: macIdentity.id
        ))
    }

    @Test("installation identity remains stable and rename keeps the ID")
    func stableIdentity() {
        let suite = "BoothPairingTests.identity.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoothDeviceIdentityStore(defaults: defaults, keyPrefix: "test.identity")

        let first = store.load(role: .mac, defaultName: "PRC Booth Mac")
        let second = store.load(role: .mac, defaultName: "Different Default")
        let renamed = store.rename(first, to: "PRC-Booth-01")
        let reloaded = store.load(role: .mac, defaultName: "Ignored")

        #expect(first.id == second.id)
        #expect(renamed.id == first.id)
        #expect(reloaded.id == first.id)
        #expect(reloaded.displayName == "PRC-Booth-01")
    }

    @Test("valid PIN succeeds once and consumes the pairing session")
    func validPINIsOneTime() throws {
        let now = Date(timeIntervalSince1970: 10_000)
        var session = try BoothPairingSession.make(macIdentity: macIdentity, now: now)
        let pin = session.pin

        #expect(session.validatePIN(pin, now: now.addingTimeInterval(1)) == .accepted)
        #expect(session.validatePIN(pin, now: now.addingTimeInterval(2)) == .locked)
    }

    @Test("PIN validation accepts only six ASCII digits")
    func pinFormat() {
        #expect(BoothPairingSession.isValidPIN("482193"))
        #expect(!BoothPairingSession.isValidPIN("48219"))
        #expect(!BoothPairingSession.isValidPIN("4821930"))
        #expect(!BoothPairingSession.isValidPIN("１２３４５６"))
        #expect(!BoothPairingSession.isValidPIN("48219a"))
    }

    @Test("invalid PIN is rejected and five attempts invalidate the session")
    func invalidPINRateLimit() throws {
        let now = Date(timeIntervalSince1970: 20_000)
        var session = try BoothPairingSession.make(macIdentity: macIdentity, now: now)
        let wrong = session.pin == "000000" ? "000001" : "000000"

        #expect(session.validatePIN(wrong, now: now) == .rejected(remainingAttempts: 4))
        #expect(session.validatePIN(wrong, now: now) == .rejected(remainingAttempts: 3))
        #expect(session.validatePIN(wrong, now: now) == .rejected(remainingAttempts: 2))
        #expect(session.validatePIN(wrong, now: now) == .rejected(remainingAttempts: 1))
        #expect(session.validatePIN(wrong, now: now) == .locked)
        #expect(!session.isActive(at: now))
    }

    @Test("expired PIN is rejected")
    func expiredPIN() throws {
        let now = Date(timeIntervalSince1970: 30_000)
        var session = try BoothPairingSession.make(macIdentity: macIdentity, now: now)

        #expect(session.validatePIN(session.pin, now: now.addingTimeInterval(121)) == .expired)
    }

    @Test("invalidating a pairing session rejects its PIN")
    func invalidatedSessionCannotAcceptPIN() throws {
        let now = Date(timeIntervalSince1970: 35_000)
        var session = try BoothPairingSession.make(macIdentity: macIdentity, now: now)

        session.invalidate()

        #expect(!session.isActive(at: now))
        #expect(session.validatePIN(session.pin, now: now) == .locked)
    }

    @Test("an old pairing expiry cannot match a newer session")
    func pairingExpiryUsesSessionIDGeneration() {
        #expect(BoothPairingSession.isCurrentSession("session-a", currentSessionID: "session-a"))
        #expect(!BoothPairingSession.isCurrentSession("session-a", currentSessionID: "session-b"))
        #expect(!BoothPairingSession.isCurrentSession("session-a", currentSessionID: nil))
    }

    @Test("manual Mac pairing starts without an incoming intent and cancels cleanly")
    @MainActor
    func manualPairingLifecycle() {
        let status = BoothConnectionStatus(requestedNetwork: .wifi)
        let transport = NetworkBoothTransport(
            role: .mac,
            networkPreference: .wifi,
            connectionStatus: status
        )

        #expect(transport.startPairingSession())
        #expect(transport.currentPairingSessionInfo != nil)
        let isPairing: Bool
        if case .pairing = status.pairingState {
            isPairing = true
        } else {
            isPairing = false
        }
        #expect(isPairing)

        transport.cancelPairingSession()

        #expect(transport.currentPairingSessionInfo == nil)
        #expect(status.pairingState == .idle)
    }

    @Test("QR payload round trips and enforces schema, Mac ID, expiry, and one-time token")
    func qrPayloadValidation() throws {
        let now = Date(timeIntervalSince1970: 40_000)
        var session = try BoothPairingSession.make(macIdentity: macIdentity, now: now)
        let payload = session.qrPayload
        let encoded = try payload.encodedString()
        let decoded = try BoothPairingQRCodePayload.decode(encoded)

        #expect(decoded == payload)
        #expect(throws: BoothPairingError.wrongDevice) {
            try decoded.validate(now: now, expectedMacID: "other-mac")
        }
        #expect(throws: BoothPairingError.expired) {
            try decoded.validate(now: now.addingTimeInterval(121))
        }

        let unsupported = BoothPairingQRCodePayload(
            schemaVersion: 99,
            macDeviceID: payload.macDeviceID,
            macDeviceName: payload.macDeviceName,
            pairingSessionID: payload.pairingSessionID,
            oneTimeToken: payload.oneTimeToken,
            expiresAt: payload.expiresAt
        )
        #expect(throws: BoothPairingError.unsupportedQRSchema) {
            try unsupported.validate(now: now)
        }

        #expect(session.validateQRToken(payload.oneTimeToken, now: now) == .accepted)
        #expect(session.validateQRToken(payload.oneTimeToken, now: now) == .locked)
    }

    @Test("malformed QR payloads return a pairing error")
    func malformedQRPayload() throws {
        #expect(throws: BoothPairingError.invalidQRPayload) {
            try BoothPairingQRCodePayload.decode("prc-photobooth-pairing-v1:not-json")
        }

        let invalid = BoothPairingQRCodePayload(
            macDeviceID: "",
            macDeviceName: "PRC Booth Mac",
            pairingSessionID: "session",
            oneTimeToken: "token",
            expiresAt: Date(timeIntervalSince1970: 40_100)
        )
        #expect(throws: BoothPairingError.invalidQRPayload) {
            try invalid.validate(now: Date(timeIntervalSince1970: 40_000))
        }
    }

    @Test("trusted peer store persists metadata, preferred peer, and Keychain secret; forget removes all")
    func trustedPeerPersistenceAndForget() throws {
        let suite = "BoothPairingTests.trust.\(UUID().uuidString)"
        let namespace = "test.trust.\(UUID().uuidString)"
        let service = "com.nont.prcphoto.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BoothTrustedPeerStore(defaults: defaults, namespace: namespace, keychainService: service)
        let peer = TrustedBoothPeer(id: "ipad-1", displayName: "PRC-iPad-01", role: .iPad)
        let secret = Data(repeating: 0x42, count: 32)

        defer { store.forgetAll() }
        try store.trust(peer, secret: secret)
        store.preferredPeerID = peer.id
        store.autoReconnect = true

        #expect(store.trustedPeerIDs == [peer.id])
        #expect(store.preferredPeerID == peer.id)
        #expect(store.autoReconnect)
        #expect(store.secret(for: peer.id) == secret)

        store.forget(peerID: peer.id)
        #expect(store.trustedPeers.isEmpty)
        #expect(store.preferredPeerID == nil)
        #expect(store.secret(for: peer.id) == nil)
        #expect(!store.autoReconnect)
    }

    @Test("HMAC proof succeeds with the paired secret and rejects wrong secret, stale challenge, or device")
    func hmacAuthentication() throws {
        let now = Date(timeIntervalSince1970: 50_000)
        let secret = Data(repeating: 0x11, count: 32)
        let otherSecret = Data(repeating: 0x22, count: 32)
        let first = BoothAuthChallenge(
            id: "challenge-1",
            nonce: Data(repeating: 0x01, count: 32),
            challengerDeviceID: "mac",
            responderDeviceID: "ipad",
            issuedAt: now
        )
        let second = BoothAuthChallenge(
            id: "challenge-2",
            nonce: Data(repeating: 0x02, count: 32),
            challengerDeviceID: "mac",
            responderDeviceID: "ipad",
            issuedAt: now
        )
        let proof = BoothPairingCrypto.makeProof(for: first, responderDeviceID: "ipad", secret: secret)
        let secondProof = BoothPairingCrypto.makeProof(for: second, responderDeviceID: "ipad", secret: secret)

        #expect(BoothPairingCrypto.verify(proof, for: first, expectedResponderDeviceID: "ipad", secret: secret, now: now))
        #expect(!BoothPairingCrypto.verify(proof, for: first, expectedResponderDeviceID: "ipad", secret: otherSecret, now: now))
        #expect(!BoothPairingCrypto.verify(proof, for: first, expectedResponderDeviceID: "other", secret: secret, now: now))
        #expect(!BoothPairingCrypto.verify(proof, for: first, expectedResponderDeviceID: "ipad", secret: secret, now: now.addingTimeInterval(31)))
        #expect(!BoothPairingCrypto.verify(proof, for: first, expectedResponderDeviceID: "ipad", secret: secret, now: now.addingTimeInterval(-1)))
        #expect(!BoothPairingCrypto.verify(proof, for: first, expectedResponderDeviceID: "ipad", secret: Data([0x01]), now: now))
        #expect(proof.proof != secondProof.proof)
    }

    @Test("only the selected trusted peer is admitted and eligible for automatic reconnect")
    func selectedPeerPolicy() {
        let trusted: Set<String> = ["mac-1", "mac-2"]

        #expect(BoothPeerSelectionPolicy.admission(peerID: "mac-1", preferredPeerID: "mac-1", trustedPeerIDs: trusted) == .allowed)
        #expect(BoothPeerSelectionPolicy.admission(peerID: "mac-2", preferredPeerID: "mac-1", trustedPeerIDs: trusted) == .notSelected)
        #expect(BoothPeerSelectionPolicy.admission(peerID: "unknown", preferredPeerID: "mac-1", trustedPeerIDs: trusted) == .unpaired)
        #expect(BoothPeerSelectionPolicy.canAutomaticallyConnect(peerID: "mac-1", preferredPeerID: "mac-1", trustedPeerIDs: trusted, autoReconnect: true))
        #expect(!BoothPeerSelectionPolicy.canAutomaticallyConnect(peerID: "mac-2", preferredPeerID: "mac-1", trustedPeerIDs: trusted, autoReconnect: true))
        #expect(!BoothPeerSelectionPolicy.canAutomaticallyConnect(peerID: "mac-1", preferredPeerID: "mac-1", trustedPeerIDs: trusted, autoReconnect: false))
    }

    private var macIdentity: BoothDeviceIdentity {
        BoothDeviceIdentity(id: "mac-1", displayName: "PRC-Booth-01", role: .mac)
    }
}
