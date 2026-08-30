import Foundation
import Testing

@testable import PRC_PhotoBooth_Mac

@Suite("Booth diagnostics report")
struct BoothDiagnosticsReportTests {
    @Test("report contains connection, preview, printer, and preflight summaries")
    func containsExpectedSections() {
        let report = BoothDiagnosticsReport.make(snapshot())

        for line in [
            "Version: 1.4.1",
            "Build: 5",
            "Requested: LAN",
            "Effective: Wi-Fi",
            "Fallback: LAN unavailable",
            "Control channel: Connected",
            "Preview channel: Connected",
            "FPS: 29.8",
            "Throughput: 2.4 MB/s",
            "Default status: System Default",
            "Print requests: 3",
            "Readiness: Ready with warnings",
            "Failures: Camera permission",
            "Warnings: Disk space"
        ] {
            #expect(report.contains(line))
        }
    }

    @Test("same snapshot produces stable human-readable lines")
    func isStable() {
        let input = snapshot()

        #expect(BoothDiagnosticsReport.make(input) == BoothDiagnosticsReport.make(input))
        #expect(BoothDiagnosticsReport.make(input).split(separator: "\n", omittingEmptySubsequences: false).first == "PRC PhotoBooth Diagnostics")
    }

    @Test("report redacts sensitive diagnostic values")
    func excludesSecrets() {
        var input = snapshot()
        input.lastNetworkError = "download-token=super-secret-token"
        input.lastPrintError = "password=diagnostic-test-value"
        input.lastPrinterTest = PrinterTestResult(
            date: Date(timeIntervalSince1970: 0),
            printerName: "Canon",
            isSuccess: false,
            message: "private key diagnostic-test-value"
        )
        input.preflightResults = [PreflightCheckResult(
            id: .localDownloadServer,
            title: "session-token",
            detail: "secret-value",
            requirement: .required,
            status: .failed,
            checkedAt: Date(timeIntervalSince1970: 0)
        )]

        let report = BoothDiagnosticsReport.make(input)

        #expect(!report.contains("super-secret-token"))
        #expect(!report.contains("diagnostic-test-value"))
        #expect(!report.contains("secret-value"))
        #expect(report.contains("[redacted]"))
    }

    private func snapshot() -> BoothDiagnosticsReport.Snapshot {
        var metrics = BoothPreviewDiagnostics()
        metrics.fps = 29.8
        metrics.bytesPerSecond = 2_400_000
        metrics.framesSubmitted = 1_200
        metrics.framesSent = 1_160
        metrics.framesCoalesced = 40
        return BoothDiagnosticsReport.Snapshot(
            appVersion: "1.4.1",
            appBuild: "5",
            macOS: "macOS test",
            architecture: "arm64",
            generatedAt: Date(timeIntervalSince1970: 0),
            requestedNetwork: .lan,
            effectiveNetwork: .wifi,
            connectionState: .connected(peerName: "iPad"),
            fallbackReason: "LAN unavailable",
            peerName: "iPad",
            ethernetPath: .available,
            wifiPath: .available,
            lanHandshake: .timeout,
            controlConnected: true,
            previewConnected: true,
            lastNetworkError: "No valid iPad hello",
            previewDiagnostics: metrics,
            printerDefaultStatus: "System Default",
            printerName: "Canon",
            lastPrinterTest: PrinterTestResult(
                date: Date(timeIntervalSince1970: 0),
                printerName: "Canon",
                isSuccess: true,
                message: "Test print submitted."
            ),
            printRequestCount: 3,
            printSuccessCount: 2,
            printFailureCount: 1,
            lastPrintError: nil,
            preflightReadiness: .readyWithWarnings,
            preflightResults: [
                PreflightCheckResult(
                    id: .cameraPermission,
                    title: "Camera permission",
                    detail: "Granted",
                    requirement: .required,
                    status: .failed,
                    checkedAt: Date(timeIntervalSince1970: 0)
                ),
                PreflightCheckResult(
                    id: .diskSpace,
                    title: "Disk space",
                    detail: "Warning",
                    requirement: .recommended,
                    status: .warning,
                    checkedAt: Date(timeIntervalSince1970: 0)
                )
            ]
        )
    }
}
