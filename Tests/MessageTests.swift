import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

@Suite("Message Codable")
struct MessageTests {
    @Test("round-trips all message kinds")
    func roundTrip() throws {
        let context = SessionMessageContext(sessionID: "session-test", sequence: 7)
        let countdown = CountdownDescriptor(
            photoIndex: 1,
            captureAt: Date(timeIntervalSince1970: 1_700_000_005)
        )
        let messages: [Message] = [
            .hello(role: .mac),
            .hello(role: .iPad),
            .helloDetails(hello: BoothTransportHello(role: .mac, deviceID: "mac-test")),
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
                countdown: countdown
            )),
            .boothPaused(isPaused: true),
            .setMirrored(isMirrored: true),
            .sessionStart(context: nil),
            .beginCountdown(context: context, descriptor: countdown),
            .shotCaptured(context: context, index: 0, thumbnailData: Data([0x01, 0x02])),
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
            .captureRecoveryAction(context: context, action: .retryReceive(photoIndex: 1)),
            .reviewDecision(context: context, action: .keep),
            .reviewDecision(context: context, action: .retake),
            .sessionFinished(context: context, qrPayload: "http://192.168.1.1:8585/s/abc", stripThumbData: nil, gifThumbData: nil),
            .operatorOverride(context: context, action: .cancelSession),
            .heartbeat,
        ]
        for msg in messages {
            let encoded = try msg.encoded()
            let decoded = try Message.decoded(from: encoded)
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
        var gate = SessionMessageGate(currentSessionID: "B", latestAcceptedSequence: 10)
        #expect(gate.accept(SessionMessageContext(sessionID: "A", sequence: 99)) == false)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 10)) == false)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 9)) == false)
        let accepted = gate.accept(SessionMessageContext(sessionID: "B", sequence: 11))
        #expect(accepted)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 11)) == false)
    }

    @Test("session synchronization replaces the gate baseline")
    func sessionSyncSupersedesQueuedPackets() {
        var gate = SessionMessageGate(currentSessionID: "A", latestAcceptedSequence: 20)
        gate.synchronize(sessionID: "B", sequence: 4)
        #expect(gate.accept(SessionMessageContext(sessionID: "A", sequence: 21)) == false)
        #expect(gate.accept(SessionMessageContext(sessionID: "B", sequence: 3)) == false)
        let accepted = gate.accept(SessionMessageContext(sessionID: "B", sequence: 5))
        #expect(accepted)
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
    }
}

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
