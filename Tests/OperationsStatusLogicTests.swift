import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Operations status logic")
struct OperationsStatusLogicTests {
    @Test("required queue failure is a failure")
    func requiredQueueFailure() {
        let job = SessionJob(
            id: "required", sessionID: "session", kind: .renderStrip, status: .failed,
            createdAt: .now, updatedAt: .now, lastAttemptAt: nil, nextAttemptAt: nil,
            attemptCount: 1, lastError: "failed"
        )
        let status = OperationsStatusLogic.queue([job], persistenceError: nil)
        #expect(status.severity == .failure)
        #expect(status.summary == "1 failed")
    }

    @Test("optional retry is a warning")
    func optionalRetryWarning() {
        let job = SessionJob(
            id: "optional", sessionID: "session", kind: .cloudUpload, status: .waitingRetry,
            createdAt: .now, updatedAt: .now, lastAttemptAt: nil, nextAttemptAt: .now,
            attemptCount: 1, lastError: "retry"
        )
        let status = OperationsStatusLogic.queue([job], persistenceError: nil)
        #expect(status.severity == .warning)
        #expect(status.summary == "1 retrying")
    }

    @Test("completed queue is normal and cloud failure is visible")
    func completedAndCloudFailure() {
        let completed = SessionJob(
            id: "complete", sessionID: "session", kind: .renderStrip, status: .succeeded,
            createdAt: .now, updatedAt: .now, lastAttemptAt: nil, nextAttemptAt: nil,
            attemptCount: 1, lastError: nil
        )
        #expect(OperationsStatusLogic.queue([completed], persistenceError: nil).severity == .normal)

        var failed = completed
        failed.id = "cloud"
        failed.kind = .cloudUpload
        failed.status = .failed
        #expect(OperationsStatusLogic.webDelivery([failed], configured: true).severity == .failure)
        #expect(OperationsStatusLogic.webDelivery([failed], configured: true).summary == "1 failed")
    }

    @Test("printer, server, and health failures stay visible")
    func componentFailures() {
        #expect(OperationsStatusLogic.printer(.unavailable(name: "No printer"), lastTestResult: nil).severity == .failure)
        #expect(OperationsStatusLogic.server(LocalWebServerStatus(state: .failed(message: "bind"), registeredTokenCount: 0)).severity == .failure)
        #expect(OperationsStatusLogic.health(.unavailable).severity == .failure)
        #expect(OperationsStatusLogic.health(.degraded).severity == .warning)
    }

    @Test("cancelled printer test is neutral, not a failure")
    func cancelledPrinterTest() {
        let result = PrinterTestResult(
            date: .now,
            printerName: "System Default",
            isSuccess: false,
            message: "Print dialog cancelled by operator.",
            outcome: .cancelled
        )
        let status = OperationsStatusLogic.printer(.systemDefault, lastTestResult: result)
        #expect(status.severity == .normal)
        #expect(status.summary == "Test cancelled")
    }

    @Test("active printer reports printing before stale test results")
    func activePrinterIsPrinting() {
        let status = OperationsStatusLogic.printer(
            .unavailable(name: "temporarily unavailable"),
            lastTestResult: nil,
            isPrinting: true
        )
        #expect(status.severity == .normal)
        #expect(status.summary == "Printing")
        #expect(OperationsStatusLogic.printer(.systemDefault, lastTestResult: nil).summary == "Idle")
    }

    @Test("unknown printer outcome requires verification")
    func unknownPrinterOutcome() {
        let result = PrinterTestResult(
            date: .now,
            printerName: "System Default",
            isSuccess: false,
            message: "Timed out",
            outcome: .unknown
        )
        let status = OperationsStatusLogic.printer(.systemDefault, lastTestResult: result, isPrinting: true)
        #expect(status.severity == .failure)
        #expect(status.summary == "Verify printer")
    }

    @Test("connection health separates control failures from channel degradation")
    func connectionHealth() {
        #expect(OperationsStatusLogic.connection(.connecting, authenticated: false, previewConnected: false).severity == .warning)
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: false, previewConnected: false).summary == "Trust pending")
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: true, previewConnected: false).severity == .warning)
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: true, previewConnected: true).severity == .normal)
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: true, previewConnected: true, secureConnected: false).severity == .failure)
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: true, previewConnected: true, assetReady: false).severity == .warning)
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: true, previewConnected: true, fallbackActive: true).summary == "Wi-Fi fallback active")
        #expect(OperationsStatusLogic.connection(.connected(peerName: "iPad"), authenticated: true, previewConnected: true, reconnectInProgress: true).summary == "Reconnecting…")
    }
}
