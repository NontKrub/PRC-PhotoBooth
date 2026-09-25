import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

struct DSLRCaptureAttemptTests {
    @Test("Guest A has image A, Guest B starts capture, no new image -> image A rejected")
    func testGuestBRecoveryRejectsImageA() {
        let baseline = Set(["IMG_0001.JPG"])
        let requestedAt = Date()
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: requestedAt,
            baselineFileNames: baseline,
            baselineObjectHandles: [],
            expectedCameraIdentifier: "Sony"
        )
        
        let isValid = DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_0001.JPG",
            creationDate: requestedAt.addingTimeInterval(10), // Even if timestamp is newer, filename is in baseline
            context: context
        )
        
        #expect(isValid == false)
    }
    
    @Test("Old SD card with hundreds of images, new capture succeeds -> only new image accepted")
    func testOldSDCardNewCapture() {
        let baseline = Set((1...500).map { "IMG_\($0).JPG" })
        let requestedAt = Date()
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: requestedAt,
            baselineFileNames: baseline,
            baselineObjectHandles: [],
            expectedCameraIdentifier: "Sony"
        )
        
        let isValid = DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_501.JPG",
            creationDate: requestedAt.addingTimeInterval(2),
            context: context
        )
        
        #expect(isValid == true)
    }
    
    @Test("New filename but old timestamp -> rejected")
    func testNewFilenameOldTimestampRejected() {
        let requestedAt = Date()
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: requestedAt,
            baselineFileNames: ["IMG_0001.JPG"],
            baselineObjectHandles: [],
            expectedCameraIdentifier: "Sony"
        )
        
        let isValid = DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_0002.JPG",
            creationDate: requestedAt.addingTimeInterval(-100), // More than 60s old
            context: context
        )
        
        #expect(isValid == false)
    }
    
    @Test("New PTP handle -> accepted")
    func testNewPTPHandleAccepted() {
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: Date(),
            baselineFileNames: [],
            baselineObjectHandles: [0x1234, 0x1235],
            expectedCameraIdentifier: "Sony"
        )
        
        #expect(DSLRCaptureAttemptValidator.isNewObjectHandle(0x1236, context: context) == true)
    }
    
    @Test("Same previous PTP handle -> rejected")
    func testSamePreviousPTPHandleRejected() {
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: Date(),
            baselineFileNames: [],
            baselineObjectHandles: [0x1234, 0x1235],
            expectedCameraIdentifier: "Sony"
        )
        
        #expect(DSLRCaptureAttemptValidator.isNewObjectHandle(0x1235, context: context) == false)
    }
    
    @Test("Camera reconnect between shutter and recovery -> stale image rejected")
    func testCameraReconnectStaleImageRejected() {
        let requestedAt = Date()
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: requestedAt,
            baselineFileNames: [],
            baselineObjectHandles: [],
            expectedCameraIdentifier: "Sony"
        )
        
        // After reconnect, camera might report an old file with no creation date
        let isValid = DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_9999.JPG",
            creationDate: nil,
            context: context
        )
        
        #expect(isValid == false)
    }
    
    @Test("Capture times out -> stale media rejected")
    func testCaptureTimeoutStaleMediaRejected() {
        // Similar to above, if capture times out and we try to read PC buffer
        // without objectInMemory being valid, we should reject
        let isValid = DSLRCaptureAttemptValidator.canTrustPCBufferContent(
            objectInMemoryValue: 0x0000,
            shutterWasIssued: true
        )
        
        #expect(isValid == false)
        
        let isAlsoValid = DSLRCaptureAttemptValidator.canTrustPCBufferContent(
            objectInMemoryValue: 0x8001,
            shutterWasIssued: false
        )
        
        #expect(isAlsoValid == false)
    }
    
    @Test("Fixed buffer handle 0xFFFFC001 freshness proof")
    func testFixedBufferHandleFreshness() {
        let context = DSLRCaptureAttemptContext(
            id: UUID(),
            requestedAt: Date(),
            baselineFileNames: [],
            baselineObjectHandles: [],
            expectedCameraIdentifier: "Sony"
        )
        
        // 0xFFFFC001 is always rejected by handle validation, must be checked by canTrustPCBufferContent
        #expect(DSLRCaptureAttemptValidator.isNewObjectHandle(0xFFFFC001, context: context) == false)
        
        #expect(DSLRCaptureAttemptValidator.canTrustPCBufferContent(objectInMemoryValue: 0x8005, shutterWasIssued: true) == true)
    }
}
