import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Sony DSLR protocol")
struct DSLRProtocolTests {
    @Test("pacing subtracts completed work from target interval")
    func previewPacingUsesRemainingInterval() {
        let remaining = DSLRCameraSource.previewSleepInterval(
            targetFramesPerSecond: 30,
            elapsed: 0.010
        )
        #expect(abs(remaining - (1.0 / 30.0 - 0.010)) < 0.000_001)
        #expect(DSLRCameraSource.previewSleepInterval(
            targetFramesPerSecond: 30,
            elapsed: 0.050
        ) == 0)
    }

    @Test("builds PTP command packets")
    func buildsPTPCommandPackets() {
        let command = DSLRCameraSource.makePTPCommand(
            opcode: 0x9201,
            transactionID: 0x12345678,
            parameters: [1, 0, 0]
        )

        #expect(command.count == 24)
        #expect(DSLRCameraSource.ptpUInt16(command, at: 4) == 0x0001)
        #expect(DSLRCameraSource.ptpUInt16(command, at: 6) == 0x9201)
        #expect(DSLRCameraSource.ptpUInt32(command, at: 8) == 0x12345678)
        #expect(DSLRCameraSource.ptpUInt32(command, at: 12) == 1)
        #expect(DSLRCameraSource.ptpUInt32(command, at: 16) == 0)
        #expect(DSLRCameraSource.ptpUInt32(command, at: 20) == 0)
    }

    @Test("parses PTP response codes without alignment assumptions")
    func parsesPTPResponseCodes() {
        #expect(DSLRCameraSource.ptpResponseCode(from: Data([0, 0, 0, 0, 0, 0, 0x01, 0x20])) == 0x2001)
        #expect(DSLRCameraSource.ptpResponseCode(from: Data([0, 0, 0, 0, 0, 0, 0x1D, 0x20])) == 0x201D)
        #expect(DSLRCameraSource.ptpResponseCode(from: Data()) == 0)
        #expect(DSLRCameraSource.ptpResponseCode(from: Data(repeating: 0, count: 7)) == 0)

        let unaligned = Data([0xFF, 0, 0, 0, 0, 0, 0, 0x1D, 0x20]).dropFirst()
        #expect(DSLRCameraSource.ptpResponseCode(from: Data(unaligned)) == 0x201D)
    }

    @Test("rejects malformed PTP object-handle arrays")
    func rejectsMalformedObjectHandles() {
        #expect(DSLRCameraSource.newestPTPObjectHandle(from: Data()) == nil)
        #expect(DSLRCameraSource.newestPTPObjectHandle(from: Data([0, 0, 0, 0])) == nil)
        #expect(DSLRCameraSource.newestPTPObjectHandle(from: Data([2, 0, 0, 0, 1, 0, 0, 0])) == nil)
        #expect(DSLRCameraSource.newestPTPObjectHandle(from: Data([255, 255, 255, 127])) == nil)
        #expect(DSLRCameraSource.newestPTPObjectHandle(from: Data([
            2, 0, 0, 0,
            1, 0, 0, 0,
            2, 0, 0, 0,
        ])) == 2)
    }

    @Test("Sony capture waits until the PC-save object is ready")
    func sonyCaptureWaitsForPCSaveObject() {
        #expect(!DSLRCameraSource.sonyObjectInMemoryIsReady(nil))
        #expect(!DSLRCameraSource.sonyObjectInMemoryIsReady(0x7FFF))
        #expect(DSLRCameraSource.sonyObjectInMemoryIsReady(0x8000))
    }

    @Test("Sony buffer images are drained before shutter and downloaded after shutter")
    func sonyCaptureSeparatesStaleAndCurrentBufferImages() {
        #expect(DSLRCameraSource.sonyCaptureBufferAction(
            objectInMemory: 0x8001,
            shutterIssued: false
        ) == .discardStale)
        #expect(DSLRCameraSource.sonyCaptureBufferAction(
            objectInMemory: 0x8001,
            shutterIssued: true
        ) == .downloadCurrent)
        #expect(DSLRCameraSource.sonyCaptureBufferAction(
            objectInMemory: 0,
            shutterIssued: true
        ) == .wait)
    }

    @Test("capture fallback ignores files cataloged before the shutter")
    func captureFallbackIgnoresCatalogedFiles() {
        let cataloged = Set(["DSC00001.JPG"])
        #expect(!DSLRCameraSource.isNewCaptureMediaFile(named: "DSC00001.JPG", cataloged: cataloged))
        #expect(DSLRCameraSource.isNewCaptureMediaFile(named: "DSC00002.JPG", cataloged: cataloged))
    }

    @Test("parses both Sony vendor-code arrays")
    func parsesVendorCodes() {
        // 0x00C8 prefix, then two UInt16 arrays encoded with UInt32 counts.
        let payload = Data([
            0xC8, 0x00,
            0x02, 0x00, 0x00, 0x00,
            0x07, 0x92, 0x02, 0xC2,
            0x03, 0x00, 0x00, 0x00,
            0x0D, 0xD2, 0x5A, 0xD2, 0x07, 0xD2,
        ])

        #expect(DSLRCameraSource.parseSonyVendorCodes(payload) == [
            0x9207, 0xC202, 0xD20D, 0xD25A, 0xD207,
        ])
    }

    @Test("rejects a malformed Sony vendor-code payload")
    func rejectsMalformedVendorCodes() {
        #expect(DSLRCameraSource.parseSonyVendorCodes(Data([0xC8])) == [])
        #expect(DSLRCameraSource.parseSonyVendorCodes(Data([0x00, 0x00, 0x00, 0x00])) == [])
    }

    @Test("reads Sony ObjectInMemory from a descriptor block")
    func readsObjectInMemory() {
        let descriptors = Data([
            0x0D, 0xD2, 0x02, 0x00, 0x00, 0x01, 0x00, 0x01,
            0x15, 0xD2, 0x04, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x01, 0x80, 0x00,
            0x17, 0xD2, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00,
        ])

        #expect(DSLRCameraSource.parseSonyUInt16CurrentValue(
            descriptors,
            property: 0xD215
        ) == 0x8001)
        #expect(DSLRCameraSource.parseSonyUInt16CurrentValue(
            descriptors,
            property: 0xD222
        ) == nil)
    }

    @Test("finds complete JPEG previews embedded in Sony RAW data")
    func findsEmbeddedJPEGPreviews() {
        let payload = Data([
            0x49, 0x49, 0x2A, 0x00,
            0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x20, 0xFF, 0xD9,
            0x00, 0x00,
            0xFF, 0xD8, 0xFF, 0xDB, 0x30, 0x40, 0x50, 0xFF, 0xD9,
        ])

        #expect(DSLRCameraSource.embeddedJPEGRanges(in: payload) == [
            4..<12,
            14..<23,
        ])
    }

    @Test("ignores truncated JPEG previews")
    func ignoresTruncatedJPEGPreviews() {
        #expect(DSLRCameraSource.embeddedJPEGRanges(
            in: Data([0x00, 0xFF, 0xD8, 0xFF, 0xE1])
        ).isEmpty)
    }

    @Test("extracts Sony live view JPEG at advertised offset")
    func extractsSonyLiveViewJPEGAtOffset() {
        let expected = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x20, 0xFF, 0xD9])
        var payload = Data([0x08, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC, 0xDD])
        payload.append(expected)
        payload.append(contentsOf: [0x00, 0x00])

        #expect(DSLRCameraSource.sonyLiveViewJPEGData(from: payload) == expected)
    }

    @Test("falls back to largest complete Sony live view JPEG")
    func extractsLargestSonyLiveViewJPEG() {
        let small = Data([0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xD9])
        let large = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x10, 0x20, 0x30, 0x40, 0xFF, 0xD9])
        var payload = Data([0xFF, 0xFF, 0xFF, 0x7F])
        payload.append(small)
        payload.append(contentsOf: [0x00, 0x00])
        payload.append(large)

        #expect(DSLRCameraSource.sonyLiveViewJPEGData(from: payload) == large)
    }
}
