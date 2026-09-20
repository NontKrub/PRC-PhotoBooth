import Testing
import Foundation
import CryptoKit
@testable import PRC_PhotoBooth_Mac

let testAuthorityEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!

@Suite("Message Codable")
struct MessageTests {
    @Test("review decisions reject stale sessions and wrong photos")
    func reviewDecisionGate() {
        let current = ReviewStateToken(sessionID: "session-a", photoIndex: 2, revision: 9, authorityEpoch: testAuthorityEpoch)
        #expect(
            ReviewDecisionGate.validate(current: current, phasePhotoIndex: 2, requested: current)
                == .accepted
        )
        #expect(
            ReviewDecisionGate.validate(
                current: current,
                phasePhotoIndex: 1,
                requested: ReviewStateToken(sessionID: "session-a", photoIndex: 1, revision: 9, authorityEpoch: testAuthorityEpoch)
            ) == .wrongPhoto
        )
        #expect(
            ReviewDecisionGate.validate(
                current: current,
                phasePhotoIndex: 2,
                requested: ReviewStateToken(sessionID: "session-a", photoIndex: 2, revision: 8, authorityEpoch: testAuthorityEpoch)
            ) == .stale
        )
        #expect(
            ReviewDecisionGate.validate(
                current: current,
                phasePhotoIndex: 2,
                requested: ReviewStateToken(sessionID: "session-b", photoIndex: 2, revision: 9, authorityEpoch: testAuthorityEpoch)
            ) == .sessionChanged
        )
        #expect(
            ReviewDecisionGate.validate(current: nil, phasePhotoIndex: 2, requested: current)
                == .stale
        )
    }

    @Test("round-trips all message kinds")
    func roundTrip() throws {
        let context = SessionMessageContext(sessionID: "session-test", sequence: 7, authorityEpoch: testAuthorityEpoch)
        let reviewState = ReviewStateToken(sessionID: context.sessionID, photoIndex: 0, revision: context.sequence, authorityEpoch: testAuthorityEpoch)
        let reviewRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let countdown = CountdownDescriptor(
            photoIndex: 1,
            captureAt: Date(timeIntervalSince1970: 1_700_000_005)
        )
        let messages: [Message] = [
            .hello(role: .mac),
            .hello(role: .iPad),
            .helloDetails(hello: BoothTransportHello(role: .mac, deviceID: "mac-test")),
            .pairingIntent(intent: BoothPairingIntent(
                iPadIdentity: BoothDeviceIdentity(id: "ipad-test", displayName: "PRC-iPad-01", role: .iPad),
                targetMacDeviceID: "mac-test"
            )),
            .pairingSessionAvailable(session: BoothPairingSessionInfo(
                sessionID: "pairing-session",
                macDeviceID: "mac-test",
                macDeviceName: "PRC-Booth-01",
                expiresAt: Date(timeIntervalSince1970: 1_700_000_120),
                macEphemeralPublicKey: Data(repeating: 0x10, count: 32)
            )),
            .pairingRequest(request: BoothPairingRequest(
                sessionID: "pairing-session",
                targetMacDeviceID: "mac-test",
                iPadIdentity: BoothDeviceIdentity(id: "ipad-test", displayName: "PRC-iPad-01", role: .iPad),
                method: .pin,
                iPadEphemeralPublicKey: Data(repeating: 0x11, count: 32),
                admissionProof: Data(repeating: 0x12, count: 32)
            )),
            .pairingResult(result: BoothPairingResult(
                accepted: true,
                macIdentity: BoothDeviceIdentity(id: "mac-test", displayName: "PRC-Booth-01", role: .mac),
                pairingSessionID: "pairing-session",
                macEphemeralPublicKey: Data(repeating: 0x10, count: 32),
                keyAgreementProof: Data(repeating: 0x13, count: 32)
            )),
            .pairingVerificationConfirmed(
                sessionID: "pairing-session",
                proof: Data(repeating: 0x14, count: 32)
            ),
            .authChallenge(challenge: BoothAuthChallenge(
                id: "challenge",
                nonce: Data(repeating: 0x22, count: 32),
                challengerDeviceID: "mac-test",
                responderDeviceID: "ipad-test",
                issuedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )),
            .authProof(proof: BoothAuthProof(
                challengeID: "challenge",
                responderDeviceID: "ipad-test",
                proof: Data(repeating: 0x33, count: 32)
            )),
            .connectionRejected(reason: "This iPad is not paired with this Mac."),
            .sessionSync(snapshot: SessionSyncSnapshot(
                config: EventConfig(photoCount: 2),
                sessionID: "session-test",
                phase: .captureRecovery(
                    photoIndex: 1,
                    failure: CaptureFailureSummary(
                        photoIndex: 1,
                        reason: .cameraDisconnected,
                        message: "Camera disconnected.",
                        shutterLikelyFired: true,
                        canRetryReceive: false,
                        canUsePreviousPhoto: false,
                        canContinueSession: true
                    )
                ),
                presentation: nil,
                isMirrored: false,
                isBoothPaused: true,
                sequence: 6,
                countdown: countdown,
                authorityEpoch: testAuthorityEpoch
            )),
            .assetRequest(references: [BoothAssetReference(
                assetID: "asset-request",
                sessionID: context.sessionID,
                revision: "v1",
                kind: .reviewImage,
                byteCount: 32,
                sha256: Data(repeating: 0x45, count: 32)
            )]),
            .assetUnavailable(
                reference: BoothAssetReference(
                    assetID: "asset-missing",
                    sessionID: context.sessionID,
                    revision: "v1",
                    kind: .stripThumbnail,
                    byteCount: 32,
                    sha256: Data(repeating: 0x46, count: 32)
                ),
                reason: "Asset source unavailable"
            ),
            .boothPaused(isPaused: true),
            .setMirrored(isMirrored: true),
            .sessionStart(context: nil),
            .beginCountdown(context: context, descriptor: countdown),
            .shotCaptured(context: context, index: 0, thumbnailData: Data([0x01, 0x02])),
            .shotCapturedAsset(
                context: context,
                index: 0,
                asset: BoothAssetReference(
                    assetID: "review-session-test-0",
                    sessionID: context.sessionID,
                    revision: "review-v1",
                    kind: .reviewImage,
                    byteCount: 32,
                    sha256: Data(repeating: 0x44, count: 32)
                )
            ),
            .captureRecovery(
                context: context,
                photoIndex: 1,
                failure: CaptureFailureSummary(
                    photoIndex: 1,
                    reason: .transferTimeout,
                    message: "We couldn't receive this photo.",
                    shutterLikelyFired: true,
                    canRetryReceive: true,
                    canUsePreviousPhoto: false,
                    canContinueSession: true
                )
            ),
            .captureRecoveryAction(
                state: CaptureRecoveryStateToken(sessionID: context.sessionID, photoIndex: 1, revision: context.sequence, authorityEpoch: testAuthorityEpoch),
                requestID: reviewRequestID,
                action: .retryReceive(photoIndex: 1)
            ),
            .captureRecoveryActionResult(requestID: reviewRequestID, result: .accepted),
            .reviewDecision(state: reviewState, requestID: reviewRequestID, action: .keep),
            .reviewDecision(state: reviewState, requestID: reviewRequestID, action: .retake),
            .reviewDecisionResult(requestID: reviewRequestID, result: .accepted),
            .sessionFinished(context: context, qrPayload: "http://192.168.1.1:8585/s/abc", stripThumbData: nil, gifThumbData: nil),
            .sessionFinishedAssets(context: context, qrPayload: "http://192.168.1.1:8585/s/abc", stripAsset: nil, gifAsset: nil),
            .customerFinished(context: context),
            .operatorOverride(context: context, action: .cancelSession),
            .heartbeat,
        ]
        for msg in messages {
            let encoded = try msg.encoded()
            let decoded = try Message.decoded(from: encoded)
            #expect(decoded == msg)
            // Compare canonical JSON because Codable does not guarantee object-key order.
            let re = try JSONEncoder().encode(decoded)
            #expect(try canonicalJSON(encoded) == canonicalJSON(re))
        }
    }

    @Test("packet wrapping round-trips")
    func packetWrap() throws {
        let payload = Data("hello".utf8)
        let packed = payload.packedAsControl()
        let (channel, unwrapped) = try #require(packed.unpackedPacket())
        #expect(channel == .control)
        #expect(unwrapped == payload)
    }

    @Test("session gate rejects stale, duplicate, reordered, and wrong-session packets")
    func sessionGateRejectsStalePackets() {
        var gate = SessionMessageGate(currentSessionID: "B", latestAcceptedSequence: 10, authorityEpoch: testAuthorityEpoch)
        #expect(gate.accept(SessionMessageContext(sessionID: "A", sequence: 99, authorityEpoch: testAuthorityEpoch)) == false)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 10, authorityEpoch: testAuthorityEpoch)) == false)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 9, authorityEpoch: testAuthorityEpoch)) == false)
        let accepted = gate.accept(SessionMessageContext(sessionID: "B", sequence: 11, authorityEpoch: testAuthorityEpoch))
        #expect(accepted)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 11, authorityEpoch: testAuthorityEpoch)) == false)
    }

    @Test("session synchronization replaces the gate baseline")
    func sessionSyncSupersedesQueuedPackets() {
        var gate = SessionMessageGate(currentSessionID: "A", latestAcceptedSequence: 20, authorityEpoch: testAuthorityEpoch)
        gate.synchronize(sessionID: "B", sequence: 4, authorityEpoch: testAuthorityEpoch)
        #expect(gate.accept(SessionMessageContext(sessionID: "A", sequence: 21, authorityEpoch: testAuthorityEpoch)) == false)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 3, authorityEpoch: testAuthorityEpoch)) == false)
        let accepted = gate.accept(SessionMessageContext(sessionID: "B", sequence: 5, authorityEpoch: testAuthorityEpoch))
        #expect(accepted)
    }

    @Test("old authority epochs cannot rewind a newer baseline")
    func authorityEpochRejectsOldSync() {
        let oldEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let newEpoch = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        var gate = SessionMessageGate(
            currentSessionID: "old-session",
            latestAcceptedSequence: 90,
            authorityEpoch: oldEpoch
        )

        let acceptedNewEpoch = gate.acceptSessionChange(SessionMessageContext(
            sessionID: "new-session",
            sequence: 1,
            authorityEpoch: newEpoch
        ))
        #expect(acceptedNewEpoch)
        let acceptedOldEpochSync = gate.acceptSessionChange(SessionMessageContext(
            sessionID: "old-session",
            sequence: 91,
            authorityEpoch: oldEpoch
        ))
        #expect(!acceptedOldEpochSync)
        let acceptedOldEpochMessage = gate.accept(SessionMessageContext(
            sessionID: "old-session",
            sequence: 92,
            authorityEpoch: oldEpoch
        ))
        #expect(!acceptedOldEpochMessage)
    }

    @Test("session gate accepts a deterministic 500-message soak")
    func sessionGateSoak() {
        var gate = SessionMessageGate(currentSessionID: "soak", latestAcceptedSequence: 0, authorityEpoch: testAuthorityEpoch)
        for sequence in 1...500 {
            let accepted = gate.accept(SessionMessageContext(sessionID: "soak", sequence: UInt64(sequence), authorityEpoch: testAuthorityEpoch))
            #expect(accepted)
        }
        #expect(gate.latestAcceptedSequence == 500)
    }

    @Test("session sync keeps binary assets off the control payload")
    func sessionSyncOmitsBinaryAssets() throws {
        let encoded = try JSONEncoder().encode(SessionSyncSnapshot(
            config: EventConfig(photoCount: 1),
            sessionID: "session-test",
            phase: .review(photoIndex: 0),
            presentation: nil,
            reviewThumbnailData: Data(repeating: 1, count: 100_000),
            isMirrored: false,
            keptShots: [0: Data(repeating: 2, count: 100_000)],
            authorityEpoch: testAuthorityEpoch
        ))
        let json = String(decoding: encoded, as: UTF8.self)
        #expect(!json.contains("reviewThumbnailData"))
        #expect(!json.contains("keptShots"))
    }

    @Test("review and recovery tokens remain bound to their authority epoch")
    func actionTokensCarryAuthorityEpoch() throws {
        let review = ReviewStateToken(
            sessionID: "session",
            photoIndex: 1,
            revision: 4,
            authorityEpoch: testAuthorityEpoch
        )
        let recovery = CaptureRecoveryStateToken(
            sessionID: "session",
            photoIndex: 1,
            revision: 4,
            authorityEpoch: testAuthorityEpoch
        )
        #expect(try JSONDecoder().decode(ReviewStateToken.self, from: JSONEncoder().encode(review)) == review)
        #expect(try JSONDecoder().decode(CaptureRecoveryStateToken.self, from: JSONEncoder().encode(recovery)) == recovery)
        #expect(
            ReviewDecisionGate.validate(
                current: review,
                phasePhotoIndex: 1,
                requested: ReviewStateToken(
                    sessionID: review.sessionID,
                    photoIndex: review.photoIndex,
                    revision: review.revision,
                    authorityEpoch: UUID()
                )
            ) == .stale
        )
    }

    @Test("session sync without an authority epoch fails closed")
    func sessionSyncRequiresAuthorityEpoch() throws {
        let snapshot = SessionSyncSnapshot(
            config: EventConfig(photoCount: 1),
            sessionID: "session",
            phase: .idle,
            presentation: nil,
            isMirrored: false,
            authorityEpoch: testAuthorityEpoch
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "authorityEpoch")
        let missing = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SessionSyncSnapshot.self, from: missing)
        }
        object["authorityEpoch"] = NSNull()
        let null = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SessionSyncSnapshot.self, from: null)
        }
    }

    @Test("asset sockets do not accept heartbeat frames")
    func assetChannelRejectsHeartbeatFrames() throws {
        let frame = try BoothFrameEncoder.encode(channel: .heartbeat, payload: Data())
        let decoded = try BoothTransportFrameDecoder().decode(frame, channel: .asset)
        #expect(decoded.isEmpty)
    }

    @Test("asset channel binding is explicit and round-trippable")
    func assetChannelBinding() throws {
        let binding = BoothChannelBindingHello(
            secureSessionID: "secure-session",
            channel: .asset,
            senderDeviceID: "mac",
            receiverDeviceID: "ipad"
        )
        let encoded = try BoothAssetTransfer.encodeBinding(binding)
        #expect(try BoothAssetTransfer.decodeBinding(encoded) == binding)
        #expect(try BoothAssetTransfer.decodeBinding(Data("PRA1".utf8)) == nil)
        let unencryptedFrame = try BoothFrameEncoder.encode(channel: .asset, payload: encoded)
        #expect(throws: BoothSecureChannelError.notReady) {
            _ = try BoothTransportFrameDecoder().decode(unencryptedFrame, channel: .asset)
        }
    }

    @Test("connection status clears identity and peer list together")
    @MainActor
    func connectionStatusIsAuthoritative() {
        let status = BoothConnectionStatus()
        status.publish(
            requestedNetwork: .wifi,
            state: .connected(peerName: "Nont's iPad"),
            peerID: "ipad-id",
            peerDisplayName: "Nont's iPad",
            routeState: .connectedWiFi(peer: "Nont's iPad"),
            effectiveNetwork: .wifi
        )

        #expect(status.connectedPeerNames == ["Nont's iPad"])
        #expect(status.state == .connected(peerName: "Nont's iPad"))
        #expect(status.peerID == "ipad-id")

        status.publishDisconnected()

        #expect(status.connectedPeerNames.isEmpty)
        #expect(status.state == .disconnected)
        #expect(status.peerID == nil)
        #expect(status.peerDisplayName == nil)
        #expect(status.effectiveNetwork == .unavailable)
        #expect(!status.isFallbackActive)
    }

    @Test("hello device name decodes with a legacy identity fallback")
    func helloDeviceNameIsCompatible() throws {
        let hello = BoothTransportHello(
            role: .iPad,
            deviceID: "ipad-id",
            deviceName: "Nont's iPad"
        )
        let decoded = try JSONDecoder().decode(
            BoothTransportHello.self,
            from: JSONEncoder().encode(hello)
        )
        #expect(decoded.deviceName == "Nont's iPad")

        let legacy = Data(#"{"protocolVersion":2,"appVersion":"1.3","role":"iPad","deviceID":"legacy-id","capabilities":["control"]}"#.utf8)
        let legacyHello = try JSONDecoder().decode(BoothTransportHello.self, from: legacy)
        #expect(legacyHello.deviceName == "legacy-id")
        #expect(legacyHello.networkPreference == nil)
    }
    @Test("v1.4.3 connection protocol is version 10 and legacy protocol 9 remains decodable but incompatible")
    func protocolVersionMismatchIsVisible() throws {
        #expect(BoothTransportHello.currentProtocolVersion == 10)
        let legacy = Data(#"{"protocolVersion":9,"appVersion":"1.4.2","role":"iPad","deviceID":"legacy-id","capabilities":["control"]}"#.utf8)
        let hello = try JSONDecoder().decode(BoothTransportHello.self, from: legacy)
        #expect(hello.protocolVersion == 9)
        #expect(hello.protocolVersion != BoothTransportHello.currentProtocolVersion)
    }

    @Test("pairing result never serializes a raw shared secret")
    func pairingResultDoesNotSerializeRawSharedSecret() throws {
        let result = BoothPairingResult(
            accepted: true,
            macIdentity: BoothDeviceIdentity(id: "mac", displayName: "Mac", role: .mac),
            sharedSecret: Data(repeating: 0xAB, count: 32),
            pairingSessionID: "session",
            macEphemeralPublicKey: Data(repeating: 0x01, count: 32),
            keyAgreementProof: Data(repeating: 0x02, count: 32)
        )
        let encoded = try JSONEncoder().encode(result)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("sharedSecret"))
        #expect(try JSONDecoder().decode(BoothPairingResult.self, from: encoded).sharedSecret == nil)
    }

    @Test("ephemeral key agreement is symmetric and transcript-bound")
    func ephemeralKeyAgreement() throws {
        let mac = Curve25519.KeyAgreement.PrivateKey()
        let iPad = Curve25519.KeyAgreement.PrivateKey()
        let transcript = BoothPairingCrypto.pairingTranscript(
            sessionID: "session",
            macDeviceID: "mac",
            iPadDeviceID: "ipad",
            method: .pin,
            macEphemeralPublicKey: mac.publicKey.rawRepresentation,
            iPadEphemeralPublicKey: iPad.publicKey.rawRepresentation
        )
        let first = try BoothPairingCrypto.derivePairingSecret(
            privateKeyData: mac.rawRepresentation,
            peerPublicKeyData: iPad.publicKey.rawRepresentation,
            code: "482193",
            transcript: transcript
        )
        let second = try BoothPairingCrypto.derivePairingSecret(
            privateKeyData: iPad.rawRepresentation,
            peerPublicKeyData: mac.publicKey.rawRepresentation,
            code: "482193",
            transcript: transcript
        )
        #expect(first == second)
        #expect(first.count == 32)
        let wrongCode = try BoothPairingCrypto.derivePairingSecret(
            privateKeyData: iPad.rawRepresentation,
            peerPublicKeyData: mac.publicKey.rawRepresentation,
            code: "482194",
            transcript: transcript
        )
        #expect(first != wrongCode)
    }

    @Test("operational secure channel is directional, bound, and replay resistant")
    func secureChannel() throws {
        let secret = Data(repeating: 0xA5, count: 32)
        let macHello = BoothSecureChannelHello(
            sessionID: "secure-session",
            challenge: Data(repeating: 0x01, count: 32),
            senderRole: .mac,
            senderDeviceID: "mac",
            receiverDeviceID: "ipad"
        )
        let iPadHello = BoothSecureChannelHello(
            sessionID: "secure-session",
            challenge: Data(repeating: 0x02, count: 32),
            senderRole: .iPad,
            senderDeviceID: "ipad",
            receiverDeviceID: "mac"
        )
        let mac = BoothSecureChannel()
        let iPad = BoothSecureChannel()
        try mac.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
        try iPad.configure(secret: secret, localHello: iPadHello, peerHello: macHello)

        let controlEnvelope = try mac.protect(Data("control".utf8), channel: .control)
        #expect(try iPad.open(controlEnvelope, channel: .control) == Data("control".utf8))
        #expect(throws: BoothSecureChannelError.replayedCounter) {
            _ = try iPad.open(controlEnvelope, channel: .control)
        }

        let previewEnvelope = try mac.protect(Data("preview".utf8), channel: .preview)
        #expect(try iPad.open(previewEnvelope, channel: .preview) == Data("preview".utf8))
        #expect(throws: BoothSecureChannelError.wrongChannel) {
            _ = try iPad.open(previewEnvelope, channel: .control)
        }

        var tampered = try mac.protect(Data("tampered".utf8), channel: .control)
        tampered[tampered.count - 1] ^= 0x01
        #expect(throws: BoothSecureChannelError.authenticationFailed) {
            _ = try iPad.open(tampered, channel: .control)
        }
    }

    @Test("asset chunks round-trip out of order and reject tampering")
    func assetTransfer() throws {
        let data = Data(repeating: 0x41, count: 500_000)
        let reference = BoothAssetReference(
            assetID: "review-1",
            sessionID: "session-1",
            revision: "7",
            kind: .reviewImage,
            byteCount: data.count,
            sha256: Data(SHA256.hash(data: data))
        )
        let chunks = try BoothAssetTransfer.chunks(data: data, reference: reference)
        #expect(chunks.count == 3)
        var assembler = BoothAssetAssembler()
        var completed: (BoothAssetReference, Data)?
        for chunk in chunks.reversed() {
            completed = try assembler.append(try BoothAssetTransfer.decode(BoothAssetTransfer.encode(chunk))) ?? completed
        }
        #expect(completed?.0 == reference)
        #expect(completed?.1 == data)

        var tampered = chunks[0]
        tampered = BoothAssetChunk(
            metadata: tampered.metadata,
            data: Data(repeating: 0x42, count: tampered.data.count)
        )
        var rejectingAssembler = BoothAssetAssembler()
        for chunk in chunks.dropFirst() {
            _ = try rejectingAssembler.append(chunk)
        }
        #expect(throws: BoothAssetTransferError.hashMismatch) {
            _ = try rejectingAssembler.append(tampered)
        }
    }

    @Test("asset assembly enforces concurrent memory bounds")
    func assetAssemblyLimits() throws {
        var assembler = BoothAssetAssembler()
        for index in 0..<BoothAssetTransfer.maximumConcurrentAssets {
            let data = Data(repeating: UInt8(index), count: BoothAssetTransfer.maximumChunkBytes + 1)
            let reference = BoothAssetReference(
                assetID: "asset-\(index)",
                revision: "1",
                kind: .reviewImage,
                byteCount: data.count,
                sha256: Data(SHA256.hash(data: data))
            )
            _ = try assembler.append(try #require(BoothAssetTransfer.chunks(data: data, reference: reference).first))
        }
        let overflow = Data([0xFF])
        let reference = BoothAssetReference(
            assetID: "asset-overflow",
            revision: "1",
            kind: .reviewImage,
            byteCount: overflow.count,
            sha256: Data(SHA256.hash(data: overflow))
        )
        #expect(throws: BoothAssetTransferError.tooManyConcurrentAssets) {
            _ = try assembler.append(try #require(BoothAssetTransfer.chunks(data: overflow, reference: reference).first))
        }
    }

    @Test("control payload has a normal target and a hard ceiling")
    func controlPayloadBudget() throws {
        #expect(BoothFrameParser.targetControlPayloadLength == 128 * 1024)
        let allowed = try BoothFrameEncoder.encode(
            channel: .control,
            payload: Data(repeating: 0x00, count: BoothFrameParser.maximumControlPayloadLength)
        )
        #expect(!allowed.isEmpty)
        #expect(throws: BoothFrameError.oversizedPayload(BoothFrameParser.maximumControlPayloadLength + 1)) {
            _ = try BoothFrameEncoder.encode(
                channel: .control,
                payload: Data(repeating: 0x00, count: BoothFrameParser.maximumControlPayloadLength + 1)
            )
        }
    }

}

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
