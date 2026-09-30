import Foundation
import Testing
@testable import PRC_PhotoBooth_Mac

@Suite("Sony DSLR protocol")
struct DSLRProtocolTests {
    @Test("a PTP reply delivered at the deadline wins exactly once")
    @MainActor
    func replyAtDeadlineWins() async throws {
        let lane = DSLRCameraPTPCommandLane()
        let scope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 3)
        let (sent, sentContinuation) = AsyncStream<DSLRCameraPTPCommandLane.Ticket>.makeStream()
        var replies: [UUID: @Sendable (DSLRCameraPTPReply) -> Void] = [:]
        let command = Task { @MainActor in
            await lane.execute(
                scope: scope,
                priority: 2,
                timeout: .seconds(60),
                isCurrent: { _ in true },
                send: { ticket, completion in
                    replies[ticket.id] = completion
                    sentContinuation.yield(ticket)
                }
            )
        }
        var iterator = sent.makeAsyncIterator()
        let ticket = try #require(await iterator.next())
        let reply = DSLRCameraPTPReply(data: Data([1, 2, 3]), responseCode: 0x2001, errorDescription: nil)
        replies[ticket.id]?(reply)

        let result = await command.value
        lane.deadlineReached(ticket)
        guard case .success(let received) = result else {
            Issue.record("The reply should resolve the command before its deadline.")
            return
        }
        #expect(received.data == reply.data)
        #expect(received.responseCode == reply.responseCode)
        #expect(lane.owner == nil)
        #expect(!lane.isQuarantined)
    }

    @Test("cancellation before the baseline query sends no PTP command")
    @MainActor
    func cancellationBeforeBaselineSuppressesPTPRequest() async {
        let lane = DSLRCameraPTPCommandLane()
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 4)
        let control = DSLRCaptureAttemptControl(scope: scope)
        #expect(control.cancel(scope))
        var sendCount = 0

        let result = await lane.execute(
            scope: DSLRCameraPTPScope(attemptID: scope.attemptID, cameraGeneration: scope.cameraGeneration),
            priority: 2,
            timeout: .seconds(60),
            isCurrent: { _ in control.canContinue(scope) },
            send: { _, _ in sendCount += 1 }
        )

        #expect(sendCount == 0)
        if case .success = result {
            Issue.record("A cancelled attempt must not start its PTP baseline query.")
        }
    }

    @Test("a never-replying baseline times out, quarantines late work, then permits the next capture")
    @MainActor
    func baselineTimeoutQuarantinesLateCallbackAndAllowsNextCapture() async throws {
        let lane = DSLRCameraPTPCommandLane()
        let firstScope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 5)
        let nextScope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 5)
        let (sent, sentContinuation) = AsyncStream<DSLRCameraPTPCommandLane.Ticket>.makeStream()
        var replies: [UUID: @Sendable (DSLRCameraPTPReply) -> Void] = [:]
        func start(_ scope: DSLRCameraPTPScope) -> Task<Result<DSLRCameraPTPReply, DSLRCameraPTPFailure>, Never> {
            Task { @MainActor in
                await lane.execute(
                    scope: scope,
                    priority: 2,
                    timeout: .seconds(60),
                    isCurrent: { _ in true },
                    send: { ticket, completion in
                        replies[ticket.id] = completion
                        sentContinuation.yield(ticket)
                    }
                )
            }
        }

        var iterator = sent.makeAsyncIterator()
        let firstCommand = start(firstScope)
        let timedOutTicket = try #require(await iterator.next())
        lane.deadlineReached(timedOutTicket)
        let firstResult = await firstCommand.value
        guard case .failure(.timedOut) = firstResult else {
            Issue.record("A baseline with no callback must time out.")
            return
        }
        #expect(lane.owner == timedOutTicket)
        #expect(lane.isQuarantined)

        let nextCommand = start(nextScope)
        replies[timedOutTicket.id]?(DSLRCameraPTPReply(
            data: Data([0xAA]),
            responseCode: 0x2001,
            errorDescription: nil
        ))
        replies[timedOutTicket.id]?(DSLRCameraPTPReply(
            data: Data([0xBB]),
            responseCode: 0x2001,
            errorDescription: nil
        ))

        let nextTicket = try #require(await iterator.next())
        #expect(nextTicket.scope == nextScope)
        #expect(!lane.isQuarantined)
        replies[nextTicket.id]?(DSLRCameraPTPReply(
            data: Data([0xCC]),
            responseCode: 0x2001,
            errorDescription: nil
        ))
        let nextResult = await nextCommand.value
        guard case .success(let nextReply) = nextResult else {
            Issue.record("A subsequent capture command should succeed after the old callback drains.")
            return
        }
        #expect(nextReply.data == Data([0xCC]))
        #expect(lane.owner == nil)
    }

    @Test("cancelling an in-flight baseline returns promptly while retaining its late-response quarantine")
    @MainActor
    func cancelledBaselineRetainsQuarantine() async throws {
        let lane = DSLRCameraPTPCommandLane()
        let scope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 6)
        let (sent, sentContinuation) = AsyncStream<DSLRCameraPTPCommandLane.Ticket>.makeStream()
        var reply: (@Sendable (DSLRCameraPTPReply) -> Void)?
        let baseline = Task { @MainActor in
            await lane.execute(
                scope: scope,
                priority: 2,
                timeout: .seconds(60),
                isCurrent: { _ in true },
                send: { ticket, completion in
                    reply = completion
                    sentContinuation.yield(ticket)
                }
            )
        }
        var iterator = sent.makeAsyncIterator()
        let ticket = try #require(await iterator.next())

        lane.cancel(scope: scope)
        let result = await baseline.value
        guard case .failure(.cancelled) = result else {
            Issue.record("Cancelling a baseline should resolve its caller promptly.")
            return
        }
        #expect(lane.owner == ticket)
        #expect(lane.isQuarantined)

        reply?(DSLRCameraPTPReply(data: Data([0x01]), responseCode: 0x2001, errorDescription: nil))
        reply = nil
        // The callback's main-actor barrier proves the old PTP owner was released.
        let nextScope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: scope.cameraGeneration)
        let next = Task { @MainActor in
            await lane.execute(
                scope: nextScope,
                priority: 2,
                timeout: .seconds(60),
                isCurrent: { _ in true },
                send: { nextTicket, completion in
                    reply = completion
                    sentContinuation.yield(nextTicket)
                }
            )
        }
        let nextTicket = try #require(await iterator.next())
        #expect(nextTicket.scope == nextScope)
        reply?(DSLRCameraPTPReply(data: Data([0x02]), responseCode: 0x2001, errorDescription: nil))
        guard case .success(let response) = await next.value else {
            Issue.record("A new baseline can run after the late old response releases the lane.")
            return
        }
        #expect(response.data == Data([0x02]))
    }

    @Test("cancellation before shutter dispatch prevents the PTP command from being sent")
    @MainActor
    func cancellationBeforeShutterSuppressesDispatch() async {
        let lane = DSLRCameraPTPCommandLane()
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 7)
        let control = DSLRCaptureAttemptControl(scope: scope)
        #expect(control.cancel(scope))
        var sendCount = 0
        var beforeSendCount = 0

        let result = await lane.execute(
            scope: DSLRCameraPTPScope(attemptID: scope.attemptID, cameraGeneration: scope.cameraGeneration),
            priority: 2,
            timeout: .seconds(60),
            isCurrent: { _ in control.canContinue(scope) },
            beforeSend: {
                beforeSendCount += 1
                return true
            },
            send: { _, _ in sendCount += 1 }
        )

        #expect(sendCount == 0)
        #expect(beforeSendCount == 0)
        if case .success = result {
            Issue.record("A cancelled attempt must not dispatch a shutter command.")
        }
    }

    @Test("shutter command is not sent when the attempt cannot record its dispatch")
    @MainActor
    func shutterDispatchRequiresAttemptAuthorization() async {
        let lane = DSLRCameraPTPCommandLane()
        var sendCount = 0
        let result = await lane.execute(
            scope: DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 8),
            priority: 2,
            timeout: .seconds(60),
            isCurrent: { _ in true },
            beforeSend: { false },
            send: { _, _ in sendCount += 1 }
        )

        #expect(sendCount == 0)
        if case .success = result {
            Issue.record("An attempt that cannot record shutter ownership must not send the command.")
        }
    }

    @Test("cancellation after shutter authorization but before send clears dispatch uncertainty")
    @MainActor
    func cancellationBetweenShutterAuthorizationAndSendClearsUncertainty() async {
        let lane = DSLRCameraPTPCommandLane()
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 9)
        let control = DSLRCaptureAttemptControl(scope: scope)
        var sendCount = 0

        let result = await lane.execute(
            scope: DSLRCameraPTPScope(attemptID: scope.attemptID, cameraGeneration: scope.cameraGeneration),
            priority: 2,
            timeout: .seconds(60),
            isCurrent: { _ in control.canContinue(scope) },
            beforeSend: {
                guard control.markShutterMayHaveBeenIssued(scope) else { return false }
                // Model cancellation winning after authorization but before the
                // command lane reaches its physical send closure.
                _ = control.cancel(scope)
                return true
            },
            onNotSent: { control.confirmShutterWasNotDispatched(scope) },
            send: { _, _ in sendCount += 1 }
        )

        #expect(sendCount == 0)
        #expect(!control.shutterMayHaveBeenIssued(for: scope))
        if case .success = result {
            Issue.record("A cancelled shutter authorization must be withdrawn before the send closure.")
        }
    }

    @Test("cancelling an in-flight shutter returns promptly and retains its late callback quarantine")
    @MainActor
    func cancelledShutterRemainsQuarantinedUntilCallback() async throws {
        let lane = DSLRCameraPTPCommandLane()
        let scope = DSLRCaptureAttemptScope(attemptID: UUID(), cameraGeneration: 9)
        let ptpScope = DSLRCameraPTPScope(attemptID: scope.attemptID, cameraGeneration: scope.cameraGeneration)
        let control = DSLRCaptureAttemptControl(scope: scope)
        #expect(control.markShutterMayHaveBeenIssued(scope))
        let (sent, sentContinuation) = AsyncStream<DSLRCameraPTPCommandLane.Ticket>.makeStream()
        var replies: [UUID: @Sendable (DSLRCameraPTPReply) -> Void] = [:]
        let command = Task { @MainActor in
            await lane.execute(
                scope: ptpScope,
                priority: 2,
                timeout: .seconds(60),
                isCurrent: { _ in control.canContinue(scope) },
                send: { ticket, completion in
                    replies[ticket.id] = completion
                    sentContinuation.yield(ticket)
                }
            )
        }
        var iterator = sent.makeAsyncIterator()
        let ticket = try #require(await iterator.next())
        #expect(control.cancel(scope))
        lane.cancel(scope: ptpScope)
        let result = await command.value
        guard case .failure(.cancelled) = result else {
            Issue.record("Cancellation must resolve the command caller promptly.")
            return
        }
        #expect(control.shutterMayHaveBeenIssued(for: scope))
        #expect(lane.owner == ticket)
        #expect(lane.isQuarantined)

        replies[ticket.id]?(DSLRCameraPTPReply(data: Data(), responseCode: 0x2001, errorDescription: nil))
        let nextScope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: scope.cameraGeneration)
        let nextCommand = Task { @MainActor in
            await lane.execute(
                scope: nextScope,
                priority: 2,
                timeout: .seconds(60),
                isCurrent: { _ in true },
                send: { nextTicket, completion in
                    replies[nextTicket.id] = completion
                    sentContinuation.yield(nextTicket)
                }
            )
        }
        let nextTicket = try #require(await iterator.next())
        #expect(nextTicket.scope == nextScope)
        replies[nextTicket.id]?(DSLRCameraPTPReply(data: Data([1]), responseCode: 0x2001, errorDescription: nil))
        guard case .success(let nextReply) = await nextCommand.value else {
            Issue.record("The next capture command should run after the old callback drains.")
            return
        }
        #expect(nextReply.data == Data([1]))
    }

    @Test("a late timed-out callback cannot resolve a command after camera-generation recovery")
    @MainActor
    func oldGenerationCallbackCannotResolveReconnect() async throws {
        let lane = DSLRCameraPTPCommandLane()
        let oldScope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 10)
        let newScope = DSLRCameraPTPScope(attemptID: UUID(), cameraGeneration: 11)
        let (sent, sentContinuation) = AsyncStream<DSLRCameraPTPCommandLane.Ticket>.makeStream()
        var replies: [UUID: @Sendable (DSLRCameraPTPReply) -> Void] = [:]
        func start(_ scope: DSLRCameraPTPScope) -> Task<Result<DSLRCameraPTPReply, DSLRCameraPTPFailure>, Never> {
            Task { @MainActor in
                await lane.execute(
                    scope: scope,
                    priority: 2,
                    timeout: .seconds(60),
                    isCurrent: { _ in true },
                    send: { ticket, completion in
                        replies[ticket.id] = completion
                        sentContinuation.yield(ticket)
                    }
                )
            }
        }

        var iterator = sent.makeAsyncIterator()
        let oldCommand = start(oldScope)
        let oldTicket = try #require(await iterator.next())
        lane.deadlineReached(oldTicket)
        let oldResult = await oldCommand.value
        guard case .failure(.timedOut) = oldResult else {
            Issue.record("The unanswered old generation must time out before session recovery.")
            return
        }
        #expect(lane.isQuarantined)
        lane.retire(cameraGeneration: oldScope.cameraGeneration)

        let newCommand = start(newScope)
        let newTicket = try #require(await iterator.next())
        replies[oldTicket.id]?(DSLRCameraPTPReply(
            data: Data([0x10]),
            responseCode: 0x2001,
            errorDescription: nil
        ))
        #expect(lane.owner == newTicket)
        #expect(!lane.isQuarantined)
        replies[newTicket.id]?(DSLRCameraPTPReply(
            data: Data([0x11]),
            responseCode: 0x2001,
            errorDescription: nil
        ))
        let newResult = await newCommand.value
        guard case .success(let reply) = newResult else {
            Issue.record("The reconnected generation should accept its own response.")
            return
        }
        #expect(reply.data == Data([0x11]))
    }

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
