import Foundation

struct BoothDiagnosticsReport {
    struct Snapshot: Sendable {
        var appVersion: String
        var appBuild: String
        var macOS: String
        var architecture: String
        var generatedAt: Date
        var requestedNetwork: BoothNetworkPreference
        var effectiveNetwork: BoothEffectiveNetworkTransport
        var connectionState: BoothConnectionState
        var fallbackReason: String?
        var peerName: String?
        var ethernetPath: BoothPathObservation
        var wifiPath: BoothPathObservation
        var lanHandshake: BoothLANHandshakeState
        var controlConnected: Bool
        var previewConnected: Bool
        var lastNetworkError: String?
        var previewDiagnostics: BoothPreviewDiagnostics
        var printerDefaultStatus: String
        var printerName: String
        var lastPrinterTest: PrinterTestResult?
        var printRequestCount: Int
        var printSuccessCount: Int
        var printFailureCount: Int
        var lastPrintError: String?
        var preflightReadiness: BoothReadinessStatus
        var preflightResults: [PreflightCheckResult]
    }

    static func make(_ snapshot: Snapshot) -> String {
        let metrics = snapshot.previewDiagnostics
        let failures = snapshot.preflightResults
            .filter { $0.status == .failed }
            .compactMap { safe($0.title) }
        let warnings = snapshot.preflightResults
            .filter { $0.status == .warning }
            .compactMap { safe($0.title) }

        return [
            "PRC PhotoBooth Diagnostics",
            "",
            "App",
            "Version: \(safe(snapshot.appVersion) ?? "Unknown")",
            "Build: \(safe(snapshot.appBuild) ?? "Unknown")",
            "macOS: \(safe(snapshot.macOS) ?? "Unknown")",
            "Architecture: \(safe(snapshot.architecture) ?? "Unknown")",
            "Generated: \(dateText(snapshot.generatedAt))",
            "",
            "Connection",
            "Requested: \(networkText(snapshot.requestedNetwork))",
            "Effective: \(networkText(snapshot.effectiveNetwork))",
            "State: \(connectionText(snapshot.connectionState))",
            "Fallback: \(safe(snapshot.fallbackReason) ?? "Inactive")",
            "Peer: \(safe(snapshot.peerName) ?? "None")",
            "Ethernet path: \(pathText(snapshot.ethernetPath))",
            "Wi-Fi path: \(pathText(snapshot.wifiPath))",
            "LAN handshake: \(handshakeText(snapshot.lanHandshake))",
            "Control channel: \(snapshot.controlConnected ? "Connected" : "Disconnected")",
            "Preview channel: \(snapshot.previewConnected ? "Connected" : "Disconnected")",
            "Last network error: \(safe(snapshot.lastNetworkError) ?? "None")",
            "",
            "Preview",
            "FPS: \(decimal(metrics.fps))",
            "Throughput: \(decimal(metrics.bytesPerSecond / 1_000_000)) MB/s",
            "Frames submitted: \(metrics.framesSubmitted)",
            "Frames sent: \(metrics.framesSent)",
            "Frames coalesced: \(metrics.framesCoalesced)",
            "",
            "Printer",
            "Default status: \(safe(snapshot.printerDefaultStatus) ?? "Unknown")",
            "Printer: \(safe(snapshot.printerName) ?? "Unknown")",
            "Last test: \(printerTestText(snapshot.lastPrinterTest))",
            "Print requests: \(snapshot.printRequestCount)",
            "Successful: \(snapshot.printSuccessCount)",
            "Failed: \(snapshot.printFailureCount)",
            "Last error: \(safe(snapshot.lastPrintError) ?? "None")",
            "",
            "Preflight",
            "Readiness: \(readinessText(snapshot.preflightReadiness))",
            "Failures: \(failures.isEmpty ? "None" : failures.joined(separator: ", "))",
            "Warnings: \(warnings.isEmpty ? "None" : warnings.joined(separator: ", "))"
        ].joined(separator: "\n")
    }

    private static func networkText(_ network: BoothNetworkPreference) -> String {
        network == .lan ? "LAN" : "Wi-Fi"
    }

    private static func networkText(_ network: BoothEffectiveNetworkTransport) -> String {
        switch network {
        case .wifi: return "Wi-Fi"
        case .lan: return "LAN (Ethernet)"
        case .unavailable: return "Unavailable"
        }
    }

    private static func connectionText(_ state: BoothConnectionState) -> String {
        switch state {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .disconnected: return "Disconnected"
        }
    }

    private static func pathText(_ path: BoothPathObservation) -> String {
        switch path {
        case .unknown: return "Unknown"
        case .available: return "Available"
        case .unavailable: return "Unavailable"
        }
    }

    private static func handshakeText(_ state: BoothLANHandshakeState) -> String {
        switch state {
        case .unknown: return "Unknown"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .timeout: return "Timeout"
        case .failed: return "Failed"
        }
    }

    private static func readinessText(_ readiness: BoothReadinessStatus) -> String {
        switch readiness {
        case .ready: return "Ready"
        case .readyWithWarnings: return "Ready with warnings"
        case .notReady: return "Not ready"
        case .checking: return "Checking"
        }
    }

    private static func printerTestText(_ result: PrinterTestResult?) -> String {
        guard let result else { return "Not run" }
        let status = result.isSuccess ? "Passed" : "Failed"
        return "\(status) (\(safe(result.printerName) ?? "Unknown")): \(safe(result.message) ?? "No details")"
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func dateText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }

    private static func safe(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let normalized = value.lowercased()
        let sensitiveWords = [
            "token", "password", "secret", "private key", "credential",
            "authorization", "bearer", "pin", "keychain"
        ]
        guard !sensitiveWords.contains(where: normalized.contains) else { return "[redacted]" }
        return value.replacingOccurrences(of: "\n", with: " ")
    }
}
