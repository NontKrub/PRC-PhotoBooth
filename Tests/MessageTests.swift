import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

@Suite("Message Codable")
struct MessageTests {
    @Test("round-trips all message kinds")
    func roundTrip() throws {
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
                isBoothPaused: true
            )),
            .boothPaused(isPaused: true),
            .setMirrored(isMirrored: true),
            .setPreviewTransport(transport: .usb),
            .sessionStart,
            .beginCountdown(photoIndex: 1, seconds: 5),
            .shotCaptured(index: 0, thumbnailData: Data([0x01, 0x02])),
            .captureRecovery(
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
            .captureRecoveryAction(action: .retryReceive(photoIndex: 1)),
            .reviewDecision(action: .keep),
            .reviewDecision(action: .retake),
            .sessionFinished(qrPayload: "http://192.168.1.1:8585/s/abc", stripThumbData: nil, gifThumbData: nil),
            .operatorOverride(action: .cancelSession),
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
}

private func canonicalJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}
