import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Data] = []

    func append(_ value: Data) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var snapshot: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite("Network framing")
struct NetworkFramingTests {
    @Test("preview coalescing keeps only newest pending frame")
    func latestFrameWins() {
        var frames = LatestFrameCoalescer()
        frames.enqueue(Data("A".utf8))
        #expect(frames.startNext() == Data("A".utf8))

        frames.enqueue(Data("B".utf8))
        frames.enqueue(Data("C".utf8))
        frames.enqueue(Data("D".utf8))

        #expect(frames.completeWrite() == Data("D".utf8))
        #expect(frames.completeWrite() == nil)
        #expect(frames.coalescedFrameCount == 3)
    }

    @Test("parses a complete frame")
    func completeFrame() throws {
        let encoded = try BoothFrameEncoder.encode(channel: .control, payload: Data("one".utf8))
        var parser = BoothFrameParser()
        #expect(try parser.append(encoded) == [BoothNetworkFrame(channel: .control, payload: Data("one".utf8))])
    }

    @Test("decodes a manually constructed big-endian payload length")
    func manuallyConstructedPayloadLength() throws {
        let payload = Data(repeating: 0xA5, count: 256)
        let frame = Data([0x50, 0x52, 0x01, BoothTransportChannel.control.rawValue, 0x00, 0x00, 0x01, 0x00]) + payload
        var parser = BoothFrameParser()

        let frames = try parser.append(frame)

        #expect(frames.count == 1)
        #expect(frames[0].channel == .control)
        #expect(frames[0].payload.count == 256)
        #expect(parser.bufferedByteCount == 0)
    }

    @Test("handles a split header and payload")
    func fragmentedFrame() throws {
        let encoded = try BoothFrameEncoder.encode(channel: .preview, payload: Data(repeating: 7, count: 64))
        var parser = BoothFrameParser()
        #expect(try parser.append(Data(encoded.prefix(3))).isEmpty)
        #expect(try parser.append(Data(encoded.dropFirst(3).prefix(9))).isEmpty)
        let frames = try parser.append(Data(encoded.dropFirst(12)))
        #expect(frames.count == 1)
        #expect(frames[0].channel == .preview)
        #expect(frames[0].payload.count == 64)
    }

    @Test("parses multiple frames from one receive")
    func coalescedFrames() throws {
        let first = try BoothFrameEncoder.encode(channel: .control, payload: Data("a".utf8))
        let second = try BoothFrameEncoder.encode(channel: .heartbeat, payload: Data("b".utf8))
        var parser = BoothFrameParser()
        #expect(try parser.append(first + second).map(\.payload) == [Data("a".utf8), Data("b".utf8)])
    }

    @Test("a reconnect starts with a fresh parser")
    func parserResetAfterReconnect() throws {
        let encoded = try BoothFrameEncoder.encode(channel: .control, payload: Data("fresh".utf8))
        var parser = BoothFrameParser()
        #expect(try parser.append(Data(encoded.prefix(4))).isEmpty)

        parser = BoothFrameParser()
        #expect(try parser.append(encoded) == [
            BoothNetworkFrame(channel: .control, payload: Data("fresh".utf8))
        ])
    }

    @Test("rejects invalid header values")
    func invalidHeader() throws {
        var parser = BoothFrameParser()
        #expect(throws: BoothFrameError.invalidMagic) { try parser.append(Data([0, 0, 1, 1, 0, 0, 0, 0])) }

        var unknownChannel = Data([0x50, 0x52, 1, 99, 0, 0, 0, 0])
        var channelParser = BoothFrameParser()
        #expect(throws: BoothFrameError.unknownChannel(99)) { try channelParser.append(unknownChannel) }
        unknownChannel[2] = 9
        var versionParser = BoothFrameParser()
        #expect(throws: BoothFrameError.unsupportedVersion(9)) { try versionParser.append(unknownChannel) }
    }

    @Test("rejects oversized payloads")
    func oversizedPayload() throws {
        var parser = BoothFrameParser()
        let length = UInt32(BoothFrameParser.maximumPayloadLength + 1).bigEndian
        var header = Data([0x50, 0x52, 1, BoothTransportChannel.control.rawValue])
        withUnsafeBytes(of: length) { header.append(contentsOf: $0) }
        #expect(throws: BoothFrameError.oversizedPayload(BoothFrameParser.maximumPayloadLength + 1)) {
            try parser.append(header)
        }
    }

    @Test("monotonic heartbeat reports a timeout once until activity")
    func heartbeatTimeoutIsEdgeTriggered() {
        let state = BoothTransportHeartbeatState()

        #expect(!state.shouldReportTimeout(after: 60))
        #expect(state.shouldReportTimeout(after: 0))
        #expect(!state.shouldReportTimeout(after: 0))

        state.markActivity()
        #expect(state.shouldReportTimeout(after: 0))
    }

    @Test("raw heartbeat channel frames are rejected")
    func rawHeartbeatChannelIsRejected() {
        let decoder = BoothTransportFrameDecoder()
        let frame = try! BoothFrameEncoder.encode(
            channel: .heartbeat,
            payload: Data("heartbeat".utf8)
        )

        #expect(throws: BoothFrameError.invalidMessage) {
            try decoder.decode(frame, channel: .control)
        }
    }

    @Test("plaintext bootstrap frames are rejected once the handshake completes")
    func rejectsLateePlaintextBootstrap() throws {
        let channel = try makeConfiguredSecureChannel()
        let decoder = BoothTransportFrameDecoder()
        let hello = Message.secureChannelHello(hello: makeHello())
        let frame = try BoothFrameEncoder.encode(
            channel: .control, payload: try hello.encoded()
        )
        // Before establishment the bootstrap frame is accepted in the clear.
        #expect(try decoder.decode(frame, channel: .control, secureChannel: channel).count == 1)

        decoder.setHandshakeComplete(true, channel: .control)
        #expect(throws: (any Error).self) {
            try decoder.decode(frame, channel: .control, secureChannel: channel)
        }
    }

    @Test("preview delivery keeps one pending frame while MainActor is blocked")
    func previewDeliveryCoalescesBeforeMainActor() {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PreviewDelivery")
        let pump = BoothLatestPreviewDeliveryPump(queue: queue)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let delivered = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            entered.signal()
            release.wait()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)

        let received = LockedDataBuffer()
        pump.onDeliver = { data, _, _ in
            received.append(data)
            delivered.signal()
        }

        queue.sync {
            for index in 0..<10_000 {
                pump.enqueueOnQueue(Data("frame-\(index)".utf8), generation: 0)
            }
        }
        let snapshot = pump.snapshot()
        #expect(snapshot.framesReceived == 10_000)
        #expect(snapshot.framesCoalesced == 9_999)
        #expect(snapshot.pendingFrames == 1)

        release.signal()
        #expect(delivered.wait(timeout: .now() + 2) == .success)
        let values = received.snapshot
        #expect(values.count == 1)
        let last = values.last
        #expect(last == Data("frame-9999".utf8))
    }

    @Test("preview delivery drops pending frames from an old generation")
    func previewDeliveryRejectsStaleGeneration() {
        let queue = DispatchQueue(label: "PRC-PhotoBooth.Tests.PreviewGeneration")
        let pump = BoothLatestPreviewDeliveryPump(queue: queue)
        let delivered = DispatchSemaphore(value: 0)
        let received = LockedDataBuffer()
        pump.onDeliver = { data, _, _ in
            received.append(data)
            delivered.signal()
        }

        queue.sync {
            pump.enqueueOnQueue(Data("old".utf8), generation: 0)
            pump.resetOnQueue(generation: 1)
            pump.enqueueOnQueue(Data("new".utf8), generation: 1)
        }

        #expect(delivered.wait(timeout: .now() + 2) == .success)
        #expect(received.snapshot == [Data("new".utf8)])
    }
}

private func makeConfiguredSecureChannel() throws -> BoothSecureChannel {
    let secret = Data(repeating: 0xA5, count: 32)
    let macHello = makeHello()
    let iPadHello = BoothSecureChannelHello(
        sessionID: "secure-session",
        challenge: Data(repeating: 0x02, count: 32),
        senderRole: .iPad,
        senderDeviceID: "ipad",
        receiverDeviceID: "mac"
    )
    let channel = BoothSecureChannel()
    try channel.configure(secret: secret, localHello: macHello, peerHello: iPadHello)
    return channel
}

private func makeHello() -> BoothSecureChannelHello {
    BoothSecureChannelHello(
        sessionID: "secure-session",
        challenge: Data(repeating: 0x01, count: 32),
        senderRole: .mac,
        senderDeviceID: "mac",
        receiverDeviceID: "ipad"
    )
}
