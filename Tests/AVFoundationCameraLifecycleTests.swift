import Foundation
import Testing
import CoreGraphics
@testable import PRC_PhotoBooth_Mac

private func makeDummyImage() -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    return context.makeImage()!
}

@Suite("AVFoundation Camera Lifecycle")
struct AVFoundationCameraLifecycleTests {
    @Test("overlapping capture is rejected")
    @MainActor
    func overlappingCaptureRejected() async throws {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)

        var cont1: CheckedContinuation<CGImage, any Error>?
        let task1 = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont1 = continuation
            }
        }
        while cont1 == nil { await Task.yield() }

        try coordinator.beginCapture(requestID: 101, continuation: cont1!, onTimeout: { _ in })
        #expect(coordinator.isCapturing)

        var cont2: CheckedContinuation<CGImage, any Error>?
        let task2 = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont2 = continuation
            }
        }
        while cont2 == nil { await Task.yield() }

        #expect(throws: CameraError.captureInProgress) {
            try coordinator.beginCapture(requestID: 102, continuation: cont2!, onTimeout: { _ in })
        }

        coordinator.finish(requestID: 101, result: .success(makeDummyImage()))
        _ = try await task1.value

        cont2?.resume(throwing: CameraError.cancelled)
        _ = try? await task2.value
    }

    @Test("timeout resolves request and allows subsequent capture")
    @MainActor
    func timeoutResolvesRequest() async throws {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 0.05)

        var cont1: CheckedContinuation<CGImage, any Error>?
        let task1 = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont1 = continuation
            }
        }
        while cont1 == nil { await Task.yield() }

        try coordinator.beginCapture(
            requestID: 201,
            continuation: cont1!,
            onTimeout: { reqID in
                coordinator.finish(requestID: reqID, result: .failure(CameraError.timeout))
            }
        )
        #expect(coordinator.isCapturing)

        do {
            _ = try await task1.value
            Issue.record("Expected timeout error")
        } catch {
            #expect(error as? CameraError == CameraError.timeout)
        }
        #expect(!coordinator.isCapturing)

        // Verify next capture is accepted
        var cont2: CheckedContinuation<CGImage, any Error>?
        let task2 = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont2 = continuation
            }
        }
        while cont2 == nil { await Task.yield() }

        try coordinator.beginCapture(requestID: 202, continuation: cont2!, onTimeout: { _ in })
        #expect(coordinator.isCapturing)
        let dummy = makeDummyImage()
        coordinator.finish(requestID: 202, result: .success(dummy))
        let img = try await task2.value
        #expect(img === dummy)
    }

    @Test("cancellation resolves request")
    @MainActor
    func cancellationResolvesRequest() async {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)

        var cont: CheckedContinuation<CGImage, any Error>?
        let captureTask = Task {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    cont = continuation
                }
            } onCancel: {
                Task { @MainActor in
                    coordinator.cancelCurrent(requestID: 301, error: CameraError.cancelled)
                }
            }
        }
        while cont == nil { await Task.yield() }

        try! coordinator.beginCapture(requestID: 301, continuation: cont!, onTimeout: { _ in })
        #expect(coordinator.isCapturing)

        captureTask.cancel()

        do {
            _ = try await captureTask.value
            Issue.record("Expected cancellation failure")
        } catch {
            #expect(error as? CameraError == CameraError.cancelled)
        }
        #expect(!coordinator.isCapturing)
    }

    @Test("stop resolves in-flight request")
    @MainActor
    func stopResolvesRequest() async {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)

        var cont: CheckedContinuation<CGImage, any Error>?
        let captureTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont = continuation
            }
        }
        while cont == nil { await Task.yield() }

        try! coordinator.beginCapture(requestID: 401, continuation: cont!, onTimeout: { _ in })
        #expect(coordinator.isCapturing)

        coordinator.abortAll(error: CameraError.notRunning)

        do {
            _ = try await captureTask.value
            Issue.record("Expected notRunning error")
        } catch {
            #expect(error as? CameraError == CameraError.notRunning)
        }
        #expect(!coordinator.isCapturing)
    }

    @Test("disconnect resolves in-flight request")
    @MainActor
    func disconnectResolvesRequest() async {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)

        var cont: CheckedContinuation<CGImage, any Error>?
        let captureTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont = continuation
            }
        }
        while cont == nil { await Task.yield() }

        try! coordinator.beginCapture(requestID: 501, continuation: cont!, onTimeout: { _ in })
        #expect(coordinator.isCapturing)

        coordinator.abortAll(error: CameraError.deviceDisconnected)

        do {
            _ = try await captureTask.value
            Issue.record("Expected deviceDisconnected error")
        } catch {
            #expect(error as? CameraError == CameraError.deviceDisconnected)
        }
        #expect(!coordinator.isCapturing)
    }

    @Test("stale callback from capture A cannot resolve newer capture B")
    @MainActor
    func staleCallbackCannotResolveNewerCapture() async throws {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)

        // Capture A
        var contA: CheckedContinuation<CGImage, any Error>?
        let taskA = Task {
            try await withCheckedThrowingContinuation { continuation in
                contA = continuation
            }
        }
        while contA == nil { await Task.yield() }

        try coordinator.beginCapture(requestID: 601, continuation: contA!, onTimeout: { _ in })
        coordinator.finish(requestID: 601, result: .failure(CameraError.timeout))

        do {
            _ = try await taskA.value
        } catch {
            #expect(error as? CameraError == CameraError.timeout)
        }

        // Capture B
        let dummyImageB = makeDummyImage()
        var contB: CheckedContinuation<CGImage, any Error>?
        let taskB = Task {
            try await withCheckedThrowingContinuation { continuation in
                contB = continuation
            }
        }
        while contB == nil { await Task.yield() }

        try coordinator.beginCapture(requestID: 602, continuation: contB!, onTimeout: { _ in })

        // Delayed callback for A arrives
        let staleResolved = coordinator.finish(requestID: 601, result: .success(makeDummyImage()))
        #expect(!staleResolved) // Must be ignored!

        #expect(coordinator.isCapturing)

        // Capture B callback arrives
        let currentResolved = coordinator.finish(requestID: 602, result: .success(dummyImageB))
        #expect(currentResolved)

        let imageB = try await taskB.value
        #expect(imageB === dummyImageB)
    }

    @Test("duplicate delegate callbacks cannot double-resume")
    @MainActor
    func duplicateCallbacksCannotDoubleResume() async throws {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)
        let dummyImage = makeDummyImage()

        var cont: CheckedContinuation<CGImage, any Error>?
        let captureTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont = continuation
            }
        }
        while cont == nil { await Task.yield() }

        try coordinator.beginCapture(requestID: 701, continuation: cont!, onTimeout: { _ in })

        let first = coordinator.finish(requestID: 701, result: .success(dummyImage))
        let second = coordinator.finish(requestID: 701, result: .success(dummyImage))

        #expect(first)
        #expect(!second)

        let img = try await captureTask.value
        #expect(img === dummyImage)
    }

    @Test("error callback and timeout racing each other resume exactly once")
    @MainActor
    func errorCallbackAndTimeoutRaceResumesExactlyOnce() async {
        let coordinator = StillCaptureLifecycleCoordinator(timeoutDuration: 5.0)

        var cont: CheckedContinuation<CGImage, any Error>?
        let captureTask = Task {
            try await withCheckedThrowingContinuation { continuation in
                cont = continuation
            }
        }
        while cont == nil { await Task.yield() }

        try! coordinator.beginCapture(
            requestID: 801,
            continuation: cont!,
            onTimeout: { reqID in
                coordinator.finish(requestID: reqID, result: .failure(CameraError.timeout))
            }
        )

        let errorFinished = coordinator.finish(requestID: 801, result: .failure(CameraError.captureDataMissing))
        let timeoutFinished = coordinator.finish(requestID: 801, result: .failure(CameraError.timeout))

        #expect(errorFinished)
        #expect(!timeoutFinished)

        do {
            _ = try await captureTask.value
            Issue.record("Expected error")
        } catch {
            #expect(error as? CameraError == CameraError.captureDataMissing)
        }
    }
}
