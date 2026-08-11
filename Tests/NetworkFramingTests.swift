import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

@Suite("Network framing")
struct NetworkFramingTests {
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
}
