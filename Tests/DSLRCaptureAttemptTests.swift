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
        cameraTimeOffset: TimeInterval? = 0,
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
            cameraTimeOffset: cameraTimeOffset,
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

    @Test("Capture cancellation gates the shutter and resolves only its own camera generation")
    func captureCancellationOwnsItsAttemptAndGeneration() {
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 4)
        let control = DSLRCaptureAttemptControl(scope: scope)

        #expect(control.cancel(scope))
        #expect(!control.canContinue(scope))
        #expect(!control.markShutterMayHaveBeenIssued(scope))
        #expect(!control.shutterMayHaveBeenIssued(for: scope))
        var dispatchCount = 0
        let dispatched = control.performIfCurrent(scope) { dispatchCount += 1 }
        #expect(!dispatched)
        #expect(dispatchCount == 0)
        #expect(!control.resolve(DSLRCaptureAttemptScope(
            attemptID: scope.attemptID,
            cameraGeneration: scope.cameraGeneration + 1
        )))

        #expect(control.resolve(scope))
        #expect(!control.resolve(scope))
        #expect(!control.cancel(scope))
    }

    @Test("Cancellation after shutter dispatch preserves uncertainty while blocking more commands")
    func cancellationAfterShutterKeepsUncertainty() {
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 8)
        let control = DSLRCaptureAttemptControl(scope: scope)

        #expect(control.markShutterMayHaveBeenIssued(scope))
        #expect(control.shutterMayHaveBeenIssued(for: scope))
        #expect(control.cancel(scope))
        #expect(control.shutterMayHaveBeenIssued(for: scope))
        #expect(!control.canContinue(scope))
        #expect(!control.markShutterMayHaveBeenIssued(scope))
        var dispatchCount = 0
        let dispatched = control.performIfCurrent(scope) { dispatchCount += 1 }
        #expect(!dispatched)
        #expect(dispatchCount == 0)
    }

    @Test("Cancellation cleans only Sony controls that were physically dispatched")
    func cancellationCleansOnlyDispatchedSonyControls() {
        let beforePressScope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 20)
        let beforePressControl = DSLRCaptureAttemptControl(scope: beforePressScope)
        var beforePressState = DSLRSonyPhysicalControlState(cameraGeneration: 20)
        #expect(beforePressControl.cancel(beforePressScope))
        #expect(beforePressState.beginCleanup(laneQuarantined: false, generation: 20) == nil)

        let afterAFPressScope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 21)
        let afterAFPressControl = DSLRCaptureAttemptControl(scope: afterAFPressScope)
        var afterAFPressState = DSLRSonyPhysicalControlState(cameraGeneration: 21)
        afterAFPressState.commandDispatched(property: 0xD2C1, value: 2, generation: 21)
        #expect(afterAFPressControl.cancel(afterAFPressScope))
        #expect(afterAFPressState.beginCleanup(laneQuarantined: false, generation: 21) == [0xD2C1])

        let afterShutterScope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 22)
        let afterShutterControl = DSLRCaptureAttemptControl(scope: afterShutterScope)
        var afterShutterState = DSLRSonyPhysicalControlState(cameraGeneration: 22)
        afterShutterState.commandDispatched(property: 0xD2C1, value: 2, generation: 22)
        afterShutterState.commandDispatched(property: 0xD2C2, value: 2, generation: 22)
        #expect(afterShutterControl.markShutterMayHaveBeenIssued(afterShutterScope))
        #expect(afterShutterControl.cancel(afterShutterScope))
        #expect(afterShutterState.beginCleanup(laneQuarantined: true, generation: 22) == nil)
        #expect(afterShutterState.beginCleanup(laneQuarantined: false, generation: 22) == [0xD2C2, 0xD2C1])
    }

    @Test("Sony control state tracks autofocus independently and cleans only dispatched controls")
    func sonyPhysicalControlCleanupPlan() {
        let generation: UInt64 = 31
        var state = DSLRSonyPhysicalControlState(cameraGeneration: generation)
        state.commandDispatched(property: 0xD2C1, value: 2, generation: generation)
        #expect(state.needsNeutralization)
        #expect(state.beginCleanup(laneQuarantined: false, generation: generation) == [0xD2C1])
        #expect(state.beginCleanup(laneQuarantined: false, generation: generation) == nil)

        state.commandDispatched(property: 0xD2C1, value: 1, generation: generation)
        state.commandCompleted(
            property: 0xD2C1,
            value: 1,
            responseCode: 0x2001,
            failed: false,
            generation: generation
        )
        state.finishCleanup(generation: generation)
        #expect(!state.needsNeutralization)
        #expect(state.beginCleanup(laneQuarantined: false, generation: generation) == nil)
    }

    @Test("Sony shutter cleanup releases shutter before autofocus and never dispatches another press")
    func sonyShutterAndAutofocusCleanupOrdering() {
        let generation: UInt64 = 32
        var state = DSLRSonyPhysicalControlState(cameraGeneration: generation)
        state.commandDispatched(property: 0xD2C1, value: 2, generation: generation)
        state.commandDispatched(property: 0xD2C2, value: 2, generation: generation)
        #expect(state.beginCleanup(laneQuarantined: false, generation: generation) == [0xD2C2, 0xD2C1])

        state.commandDispatched(property: 0xD2C2, value: 1, generation: generation)
        state.commandCompleted(
            property: 0xD2C2,
            value: 1,
            responseCode: 0x2001,
            failed: false,
            generation: generation
        )
        #expect(state.shutterMayBeEngaged == false)
        #expect(state.autofocusMayBeEngaged)
        state.commandDispatched(property: 0xD2C1, value: 1, generation: generation)
        state.commandCompleted(
            property: 0xD2C1,
            value: 1,
            responseCode: 0x2001,
            failed: false,
            generation: generation
        )
        state.finishCleanup(generation: generation)
        #expect(!state.needsNeutralization)
    }

    @Test("Sony control state stays uncertain after failed release and ignores stale-generation callbacks")
    func sonyReleaseFailureAndStaleGeneration() {
        var state = DSLRSonyPhysicalControlState(cameraGeneration: 44)
        state.commandDispatched(property: 0xD2C2, value: 2, generation: 44)
        state.commandDispatched(property: 0xD2C2, value: 1, generation: 44)
        #expect(state.shutterReleaseInFlight)
        state.commandCompleted(
            property: 0xD2C2,
            value: 1,
            responseCode: 0,
            failed: true,
            generation: 44
        )
        #expect(!state.shutterReleaseInFlight)
        #expect(state.shutterMayBeEngaged)
        #expect(state.beginCleanup(laneQuarantined: true, generation: 44) == nil)
        #expect(state.beginCleanup(laneQuarantined: false, generation: 45) == nil)

        state.commandCompleted(
            property: 0xD2C2,
            value: 1,
            responseCode: 0x2001,
            failed: false,
            generation: 43
        )
        #expect(state.shutterMayBeEngaged)
    }

    @Test("PTP recovery admits one camera session cycle at a time")
    func oneRecoveryCycleAtATime() {
        #expect(DSLRCameraSessionRecoveryPolicy.mayScheduleCycle(
            requestedGeneration: 8,
            currentGeneration: 8,
            captureIsActive: false,
            closingGeneration: nil,
            openingGeneration: nil
        ))
        #expect(!DSLRCameraSessionRecoveryPolicy.mayScheduleCycle(
            requestedGeneration: 8,
            currentGeneration: 8,
            captureIsActive: true,
            closingGeneration: nil,
            openingGeneration: nil
        ))
        #expect(!DSLRCameraSessionRecoveryPolicy.mayScheduleCycle(
            requestedGeneration: 8,
            currentGeneration: 8,
            captureIsActive: false,
            closingGeneration: 8,
            openingGeneration: nil
        ))
        #expect(!DSLRCameraSessionRecoveryPolicy.mayScheduleCycle(
            requestedGeneration: 8,
            currentGeneration: 8,
            captureIsActive: false,
            closingGeneration: nil,
            openingGeneration: 9
        ))
        #expect(!DSLRCameraSessionRecoveryPolicy.mayScheduleCycle(
            requestedGeneration: 7,
            currentGeneration: 8,
            captureIsActive: false,
            closingGeneration: nil,
            openingGeneration: nil
        ))
        #expect(DSLRCameraSessionRecoveryPolicy.closeIsConfirmed(errorOccurred: false))
        #expect(!DSLRCameraSessionRecoveryPolicy.closeIsConfirmed(errorOccurred: true))
    }

    @Test("manual stop keeps a pending session close bounded and fails closed")
    func stoppedSessionCloseDeadlineRequiresItsPendingGeneration() {
        #expect(DSLRCameraSessionRecoveryPolicy.closeDeadlineCanReportFailure(
            generation: 12,
            currentGeneration: 13,
            cameraStillConnected: false,
            closeIsPending: true
        ))
        #expect(!DSLRCameraSessionRecoveryPolicy.closeDeadlineCanReportFailure(
            generation: 12,
            currentGeneration: 13,
            cameraStillConnected: false,
            closeIsPending: false
        ))
        #expect(!DSLRCameraSessionRecoveryPolicy.closeDeadlineCanReportFailure(
            generation: 12,
            currentGeneration: 13,
            cameraStillConnected: true,
            closeIsPending: true
        ))
    }

    @Test("a definitive busy refusal clears uncertainty before cancellation can suppress fallback")
    func busyRefusalThenCancellationSuppressesFallback() {
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 12)
        let control = DSLRCaptureAttemptControl(scope: scope)
        #expect(control.markShutterMayHaveBeenIssued(scope))
        control.confirmShutterRejected(scope)
        #expect(!control.shutterMayHaveBeenIssued(for: scope))

        #expect(control.cancel(scope))
        var fallbackCount = 0
        let dispatched = control.performIfCurrent(scope) { fallbackCount += 1 }
        #expect(!dispatched)
        #expect(fallbackCount == 0)
        #expect(!control.shutterMayHaveBeenIssued(for: scope))
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

    @Test("Camera file freshness is normalized using a validated camera clock offset")
    func cameraClockOffsetNormalizesCreationDate() {
        let shutterAt = Date(timeIntervalSince1970: 1_800_000_001)
        let cameraAhead = fired(context(cameraTimeOffset: 10), at: shutterAt)
        #expect(DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_NEW.JPG",
            creationDate: shutterAt.addingTimeInterval(11),
            context: cameraAhead
        ))
        #expect(!DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_NEW.JPG",
            creationDate: shutterAt.addingTimeInterval(9),
            context: cameraAhead
        ))
        #expect(DSLRCaptureAttemptValidator.authorizes(
            .cameraFile(name: "IMG_NEW.JPG", creationDate: shutterAt.addingTimeInterval(11)),
            context: cameraAhead,
            cameraIdentifier: cameraID
        ))

        let cameraBehind = fired(context(cameraTimeOffset: -10), at: shutterAt)
        #expect(DSLRCaptureAttemptValidator.isNewMediaFile(
            name: "IMG_NEW.JPG",
            creationDate: shutterAt.addingTimeInterval(-9),
            context: cameraBehind
        ))
    }

    @Test("Camera file freshness fails closed without a finite validated clock offset")
    func missingOrInvalidCameraClockOffsetFailsClosed() {
        let shutterAt = Date(timeIntervalSince1970: 1_800_000_001)
        for offset in [nil, TimeInterval.nan, .infinity] {
            let context = fired(self.context(cameraTimeOffset: offset), at: shutterAt)
            #expect(!DSLRCaptureAttemptValidator.isNewMediaFile(
                name: "IMG_NEW.JPG",
                creationDate: shutterAt.addingTimeInterval(100),
                context: context
            ))
        }
    }

    @Test("PTP handle quarantine clears only after disconnect, reopen, catalog, and a fresh baseline")
    func ptpHandleQuarantineRequiresTrustedResetSequence() throws {
        var store = DSLRCaptureAttemptContextStore()
        let failed = fired(context())
        store.beginCapture(failed)
        store.finish(succeeded: false)
        #expect(store.isPTPHandleQuarantined(cameraIdentifier: cameraID))

        store.cameraSessionDidOpen(identifier: cameraID)
        store.cameraCatalogDidComplete(identifier: cameraID)
        store.clearPTPHandleQuarantineAfterFreshBaseline(
            cameraIdentifier: cameraID,
            baselineSucceeded: true
        )
        #expect(store.isPTPHandleQuarantined(cameraIdentifier: cameraID))

        store.cameraDidDisconnect(identifier: cameraID)
        store.cameraSessionDidOpen(identifier: cameraID)
        store.cameraCatalogDidComplete(identifier: cameraID)
        store.clearPTPHandleQuarantineAfterFreshBaseline(
            cameraIdentifier: cameraID,
            baselineSucceeded: false
        )
        #expect(store.isPTPHandleQuarantined(cameraIdentifier: cameraID))

        store.clearPTPHandleQuarantineAfterFreshBaseline(
            cameraIdentifier: cameraID,
            baselineSucceeded: true
        )
        #expect(!store.isPTPHandleQuarantined(cameraIdentifier: cameraID))
        store.beginCapture(try #require(store.recoverable ?? failed))
        #expect(store.active?.allowsPTPHandleCandidates == true)
    }

    @Test("PTP handle quarantine cannot clear while a recovery is active")
    func ptpHandleQuarantineCannotClearDuringRecovery() throws {
        var store = DSLRCaptureAttemptContextStore()
        let failed = fired(context())
        store.beginCapture(failed)
        store.finish(succeeded: false)
        store.cameraDidDisconnect(identifier: cameraID)
        store.cameraSessionDidOpen(identifier: cameraID)
        store.cameraCatalogDidComplete(identifier: cameraID)
        #expect(store.beginRecovery(cameraIdentifier: cameraID) != nil)

        store.clearPTPHandleQuarantineAfterFreshBaseline(
            cameraIdentifier: cameraID,
            baselineSucceeded: true
        )
        #expect(store.isPTPHandleQuarantined(cameraIdentifier: cameraID))
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
