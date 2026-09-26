import Testing
import Foundation
@testable import PRC_PhotoBooth_Mac

struct DSLRCaptureAttemptTests {
    private let cameraID = "uuid:sony-zv-e10"

    private func context(
        id: UUID = UUID(),
        requestedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        files: Set<String> = [],
        handles: PTPHandleBaselineResult = .success([]),
        camera: String? = "uuid:sony-zv-e10",
        shutterAt: Date? = nil,
        memoryBaseline: UInt16? = nil,
        memoryTransition: Bool = false
    ) -> DSLRCaptureAttemptContext {
        DSLRCaptureAttemptContext(
            id: id,
            requestedAt: requestedAt,
            baselineFileNames: files,
            baselineObjectHandles: handles,
            expectedCameraIdentifier: camera,
            shutterIssuedAt: shutterAt,
            shutterCommandGeneration: shutterAt == nil ? nil : 1,
            baselineObjectInMemoryValue: memoryBaseline,
            objectInMemoryTransitionObserved: memoryTransition
        )
    }

    private func fired(_ context: DSLRCaptureAttemptContext, at time: Date? = nil) -> DSLRCaptureAttemptContext {
        context.recordingShutterIssued(
            at: time ?? context.requestedAt.addingTimeInterval(1),
            generation: 1
        )
    }

    @Test("Failed transfer retains the original baseline for Retry Receive")
    func failedTransferRetainsOriginalContext() {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        var store = DSLRCaptureAttemptContextStore()
        let original = fired(context(
            requestedAt: requestedAt,
            files: ["IMG_0001.JPG"],
            handles: .success([0x101])
        ))
        store.beginCapture(original)
        store.finish(succeeded: false)

        #expect(store.active == nil)
        #expect(store.recoverable?.id == original.id)
        let recovery = store.beginRecovery(cameraIdentifier: cameraID)
        #expect(recovery?.id == original.id)
        #expect(recovery?.baselineFileNames == ["IMG_0001.JPG"])
        #expect(recovery.map {
            DSLRCaptureAttemptValidator.authorizes(
                .cameraFile(name: "IMG_0001.JPG", creationDate: requestedAt.addingTimeInterval(5)),
                context: $0,
                cameraIdentifier: cameraID
            )
        } == false)

        store.finish(succeeded: false)
        #expect(store.beginRecovery(cameraIdentifier: cameraID)?.id == original.id)
    }

    @Test("Hundreds of catalogued images do not hide one provably fresh image")
    func oldSDCardAndFreshFile() {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let shutterAt = requestedAt.addingTimeInterval(3)
        let oldFiles = Set((1...500).map { "IMG_\($0).JPG" })
        let context = fired(self.context(requestedAt: requestedAt, files: oldFiles), at: shutterAt)

        #expect(DSLRCaptureAttemptValidator.authorizes(
            .cameraFile(name: "IMG_501.JPG", creationDate: shutterAt.addingTimeInterval(1)),
            context: context,
            cameraIdentifier: cameraID
        ))
        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .cameraFile(name: "IMG_1.JPG", creationDate: shutterAt.addingTimeInterval(1)),
            context: context,
            cameraIdentifier: cameraID
        ))
    }

    @Test("Delayed ObjectAdded from the prior attempt is rejected by the next baseline")
    func delayedObjectAddedFromPriorAttempt() throws {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let oldAttempt = fired(context(requestedAt: requestedAt, handles: .success([0x10])))
        #expect(DSLRCaptureAttemptValidator.authorizes(
            .ptpObjectHandle(0x20),
            context: oldAttempt,
            cameraIdentifier: cameraID
        ))

        var store = DSLRCaptureAttemptContextStore()
        store.beginCapture(oldAttempt)
        store.finish(succeeded: false)
        store.invalidate()
        let nextAttempt = fired(context(
            requestedAt: requestedAt.addingTimeInterval(10),
            handles: .success([0x10, 0x20])
        ), at: requestedAt.addingTimeInterval(11))
        store.beginCapture(nextAttempt)
        let active = try #require(store.active)
        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .ptpObjectHandle(0x20),
            context: active,
            cameraIdentifier: cameraID
        ))
        #expect(!active.allowsPTPHandleCandidates)
    }

    @Test("A late old handle remains rejected after a new shutter begins")
    func oldHandleArrivingAfterNewShutter() {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = fired(self.context(
            requestedAt: requestedAt,
            handles: .success([0x44])
        ), at: requestedAt.addingTimeInterval(20))

        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .ptpObjectHandle(0x44),
            context: context,
            cameraIdentifier: cameraID
        ))
    }

    @Test("Failed GetObjectHandles baseline disables handle freshness but leaves catalog proof available")
    func unavailableHandleBaselineFailsClosed() {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let context = fired(self.context(
            requestedAt: requestedAt,
            files: ["IMG_100.JPG"],
            handles: .unavailable("PTP request timed out")
        ))

        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .ptpObjectHandle(0x200),
            context: context,
            cameraIdentifier: cameraID
        ))
        #expect(DSLRCaptureAttemptValidator.authorizes(
            .cameraFile(name: "IMG_101.JPG", creationDate: context.shutterIssuedAt!.addingTimeInterval(1)),
            context: context,
            cameraIdentifier: cameraID
        ))
    }

    @Test("Recovery requires the same stable camera identity")
    func cameraIdentityChangeRejectsRecovery() {
        var store = DSLRCaptureAttemptContextStore()
        store.beginCapture(fired(context()))
        store.finish(succeeded: false)

        #expect(store.beginRecovery(cameraIdentifier: "uuid:another-camera")?.id == nil)
        #expect(store.beginRecovery(cameraIdentifier: nil)?.id == nil)
        #expect(store.beginRecovery(cameraIdentifier: cameraID)?.id != nil)
    }

    @Test("Stale Sony PC buffer is rejected; a clean-to-ready transition is accepted")
    func fixedBufferRequiresTransition() {
        let requestedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let readyBaseline = context(requestedAt: requestedAt, memoryBaseline: 0x8005)
        let stale = fired(readyBaseline).recordingObjectInMemoryValue(0x8005)
        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .sonyPCBuffer(objectInMemoryValue: 0x8005),
            context: stale,
            cameraIdentifier: cameraID
        ))

        let fresh = context(requestedAt: requestedAt, memoryBaseline: 0)
            .recordingShutterIssued(at: requestedAt.addingTimeInterval(1), generation: 1)
            .recordingObjectInMemoryValue(0x8005)
        #expect(DSLRCaptureAttemptValidator.authorizes(
            .sonyPCBuffer(objectInMemoryValue: 0x8005),
            context: fresh,
            cameraIdentifier: cameraID
        ))
        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .sonyPCBuffer(objectInMemoryValue: 0x8006),
            context: fresh,
            cameraIdentifier: "uuid:another-camera"
        ))
    }

    @Test("Failed recovery timeout preserves the original recoverable context")
    func recoveryTimeoutKeepsContext() {
        var store = DSLRCaptureAttemptContextStore()
        let original = fired(context())
        store.beginCapture(original)
        store.finish(succeeded: false)
        #expect(store.beginRecovery(cameraIdentifier: cameraID)?.id != nil)
        store.finish(succeeded: false)
        #expect(store.beginRecovery(cameraIdentifier: cameraID)?.id == original.id)
    }

    @Test("Retake invalidation prevents old context and handle reuse by the next guest")
    func retakeAndNextGuestInvalidate() throws {
        var store = DSLRCaptureAttemptContextStore()
        store.beginCapture(fired(context(handles: .success([0x80]))))
        store.finish(succeeded: false)
        store.invalidate()
        #expect(store.recoverable?.id == nil)

        let nextGuest = fired(context(
            requestedAt: Date(timeIntervalSince1970: 1_800_000_010),
            files: ["IMG_A.JPG"],
            handles: .success([0x80])
        ))
        store.beginCapture(nextGuest)
        let active = try #require(store.active)
        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .cameraFile(name: "IMG_A.JPG", creationDate: active.shutterIssuedAt!.addingTimeInterval(1)),
            context: active,
            cameraIdentifier: cameraID
        ))
        #expect(!DSLRCaptureAttemptValidator.authorizes(
            .ptpObjectHandle(0x80),
            context: active,
            cameraIdentifier: cameraID
        ))
    }

    @Test("A new shutter clears the prior recoverable attempt")
    func newCaptureClearsPriorRecovery() {
        var store = DSLRCaptureAttemptContextStore()
        let first = fired(context())
        store.beginCapture(first)
        store.finish(succeeded: false)
        let second = fired(context(requestedAt: first.requestedAt.addingTimeInterval(10)))
        store.beginCapture(second)

        #expect(store.recoverable?.id == nil)
        #expect(store.active?.id == second.id)
    }
}
