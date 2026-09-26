import Foundation

public enum BoothSoakTestMode: String, Sendable, CaseIterable, Identifiable, Codable {
    case cameraHardware = "Camera Hardware"
    case productionPipeline = "Production Pipeline"
    case syntheticBenchmark = "Synthetic Benchmark"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .cameraHardware:
            return "Captures from the selected physical camera and fails the cycle on any capture error. Does not create customer sessions."
        case .productionPipeline:
            return "Drives the real session, capture, finalization, worker queue, and local guest delivery workflow. Requires a ready booth."
        case .syntheticBenchmark:
            return "Uses generated images and isolated storage to measure compositor and queue benchmark performance. Does not validate production sessions."
        }
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "Camera-Only": self = .cameraHardware
        case "Full Pipeline": self = .productionPipeline
        default:
            guard let mode = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Unknown soak test mode \(value).")
            }
            self = mode
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct BoothSoakTestConfig: Codable, Sendable, Equatable {
    public var mode: BoothSoakTestMode
    public var targetCycles: Int
    public var delayBetweenCyclesSeconds: Double
    public var photosPerSession: Int
    public var enablePhysicalPrint: Bool
    public var physicalPrintEveryCycles: Int
    public var testCloudUpload: Bool
    public var autoCleanupWorkingFiles: Bool

    public init(
        mode: BoothSoakTestMode = .syntheticBenchmark,
        targetCycles: Int = 50,
        delayBetweenCyclesSeconds: Double = 1.0,
        photosPerSession: Int = 3,
        enablePhysicalPrint: Bool = false,
        physicalPrintEveryCycles: Int = 25,
        testCloudUpload: Bool = false,
        autoCleanupWorkingFiles: Bool = true
    ) {
        self.mode = mode
        self.targetCycles = targetCycles
        self.delayBetweenCyclesSeconds = delayBetweenCyclesSeconds
        self.photosPerSession = photosPerSession
        self.enablePhysicalPrint = enablePhysicalPrint
        self.physicalPrintEveryCycles = max(1, physicalPrintEveryCycles)
        self.testCloudUpload = testCloudUpload
        self.autoCleanupWorkingFiles = autoCleanupWorkingFiles
    }

    private enum CodingKeys: String, CodingKey {
        case mode, targetCycles, delayBetweenCyclesSeconds, photosPerSession
        case enablePhysicalPrint, physicalPrintEveryCycles, testCloudUpload, autoCleanupWorkingFiles
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        mode = try values.decodeIfPresent(BoothSoakTestMode.self, forKey: .mode) ?? .syntheticBenchmark
        targetCycles = try values.decodeIfPresent(Int.self, forKey: .targetCycles) ?? 50
        delayBetweenCyclesSeconds = try values.decodeIfPresent(Double.self, forKey: .delayBetweenCyclesSeconds) ?? 1
        photosPerSession = try values.decodeIfPresent(Int.self, forKey: .photosPerSession) ?? 3
        enablePhysicalPrint = try values.decodeIfPresent(Bool.self, forKey: .enablePhysicalPrint) ?? false
        physicalPrintEveryCycles = max(1, try values.decodeIfPresent(Int.self, forKey: .physicalPrintEveryCycles) ?? 25)
        testCloudUpload = try values.decodeIfPresent(Bool.self, forKey: .testCloudUpload) ?? false
        autoCleanupWorkingFiles = try values.decodeIfPresent(Bool.self, forKey: .autoCleanupWorkingFiles) ?? true
    }
}

public enum BoothSoakTestState: Sendable, Equatable {
    case idle
    case preflight(message: String)
    case running(cycle: Int, total: Int, phase: String, runID: String?)
    case stopping(reason: String)
    case completed(report: BoothSoakTestReport)
    case failed(error: String, partialReport: BoothSoakTestReport?)
    case stopped(report: BoothSoakTestReport)
    case cancelled(report: BoothSoakTestReport)

    public var isRunning: Bool {
        switch self {
        case .preflight, .running, .stopping:
            return true
        case .idle, .completed, .failed, .stopped, .cancelled:
            return false
        }
    }
}

public enum BoothSoakTestOutcome: String, Codable, Sendable, Equatable {
    case passed
    case completedWithWarnings
    case failed
    case stoppedEarly
    case cancelled

    var displayName: String {
        switch self {
        case .passed: "Passed"
        case .completedWithWarnings: "Completed with warnings"
        case .failed: "Failed"
        case .stoppedEarly: "Stopped Early"
        case .cancelled: "Cancelled"
        }
    }
}

enum BoothSoakTestError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case cameraRequired
    case coordinatorRequired
    case productionRunUnavailable(String)
    case stageTimeout(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): reason
        case .cameraRequired: "Camera Hardware mode requires the selected physical camera to be ready."
        case .coordinatorRequired: "Production Pipeline mode requires the live BoothCoordinator."
        case .productionRunUnavailable(let reason): reason
        case .stageTimeout(let stage): "Production soak timed out while waiting for \(stage)."
        }
    }
}

struct BoothAutomatedSoakCycleResult: Sendable {
    let captureLatencies: [Double]
    let captureAttemptCount: Int
    let captureFailureCount: Int
    let cameraRecoveryCount: Int
    let queueFailureCount: Int
    let renderLatency: Double?
    let queueDrainSeconds: Double?
    let localDeliveryVerified: Bool
    let cloudUploadVerified: Bool
    let cloudQRRouteVerified: Bool
    let physicalPrintVerified: Bool
    let galleryUpdateVerified: Bool
    let galleryIsolationVerified: Bool
    let cleanupWarnings: [String]
}

enum BoothSoakCaptureMetrics {
    static func physicalCaptureAttemptCount(_ attempts: [CaptureAttemptRecord]) -> Int {
        attempts.filter {
            $0.result == .success || $0.result == .transferRecovered || $0.result == .failed
        }.count
    }
}

enum BoothSoakCleanupPolicy {
    static func hasUnresolvedPhysicalPrint(sessionID: String, jobs: [SessionJob]) -> Bool {
        jobs.contains {
            $0.sessionID == sessionID
                && $0.kind == .autoPrint
                && ($0.status == .running || $0.lastFailureDisposition == .sideEffectUnknown)
        }
    }

    static func shouldRetainDiagnostics(manifest: SessionManifest, jobs: [SessionJob]) -> Bool {
        let cleanupRetryPending = manifest.soakAutoCleanupEnabled == true
            && manifest.soakCleanupWarning != nil
        return manifest.origin == .soakTest
            && ((manifest.isRetainedSoakDiagnostic && !cleanupRetryPending)
                || manifest.lastError != nil
                || manifest.status == .failed
                || manifest.status == .capturing
                || manifest.status == .finalizing
                || hasUnresolvedPhysicalPrint(sessionID: manifest.id, jobs: jobs))
    }

}

public struct BoothSoakCycleMetric: Codable, Sendable, Equatable {
    public let cycleIndex: Int
    public let durationSeconds: Double
    public let captureLatencies: [Double]
    public let captureAttemptCount: Int?
    public let captureFailureCount: Int?
    public let cameraRecoveryCount: Int?
    public let renderLatency: Double?
    public let queueDrainSeconds: Double?
    public let memoryFootprintBytes: UInt64
    public let thermalStateRaw: Int
    public let errors: [String]
    public let timestamp: Date

    public init(
        cycleIndex: Int,
        durationSeconds: Double,
        captureLatencies: [Double],
        captureAttemptCount: Int? = nil,
        captureFailureCount: Int? = nil,
        cameraRecoveryCount: Int? = nil,
        renderLatency: Double? = nil,
        queueDrainSeconds: Double? = nil,
        memoryFootprintBytes: UInt64,
        thermalStateRaw: Int = 0,
        errors: [String] = [],
        timestamp: Date = Date()
    ) {
        self.cycleIndex = cycleIndex
        self.durationSeconds = durationSeconds
        self.captureLatencies = captureLatencies
        self.captureAttemptCount = captureAttemptCount
        self.captureFailureCount = captureFailureCount
        self.cameraRecoveryCount = cameraRecoveryCount
        self.renderLatency = renderLatency
        self.queueDrainSeconds = queueDrainSeconds
        self.memoryFootprintBytes = memoryFootprintBytes
        self.thermalStateRaw = thermalStateRaw
        self.errors = errors
        self.timestamp = timestamp
    }
}

public struct BoothSoakTestReport: Codable, Sendable, Equatable {
    public let id: UUID
    public let runID: String?
    public let mode: BoothSoakTestMode
    public let outcome: BoothSoakTestOutcome
    public let subsystemCoverage: [String: String]
    public let startedAt: Date
    public let finishedAt: Date
    public let targetCycles: Int
    public let completedCycles: Int
    public let failedCycles: Int
    public let stoppedCycles: Int?

    public let averageCycleDurationSeconds: Double

    public let captureSampleCount: Int
    public let captureAttemptCount: Int?
    public let captureFailureCount: Int?
    public let cameraRecoveryCount: Int?
    public let minCaptureLatencySeconds: Double
    public let avgCaptureLatencySeconds: Double
    public let maxCaptureLatencySeconds: Double
    public let p50CaptureLatencySeconds: Double?
    public let p95CaptureLatencySeconds: Double
    public let p99CaptureLatencySeconds: Double?

    public let minRenderLatencySeconds: Double?
    public let avgRenderLatencySeconds: Double?
    public let maxRenderLatencySeconds: Double?
    public let p50RenderLatencySeconds: Double?
    public let p95RenderLatencySeconds: Double?
    public let p99RenderLatencySeconds: Double?

    public let firstWindowAverageCycleDurationSeconds: Double?
    public let lastWindowAverageCycleDurationSeconds: Double?
    public let cycleDurationDegradationPercent: Double?

    public let baselineMemoryBytes: UInt64
    public let peakMemoryBytes: UInt64
    public let finalMemoryBytes: UInt64

    public let thermalTransitions: Int
    public let reconnectCount: Int?
    public let transportReconnectCount: Int?
    public let queueFailureCount: Int?
    public let invariantViolations: [String]
    public let summaryVerdict: String
    public let environmentSnapshot: [String: String]?
    public let configurationSnapshot: [String: String]?

    public init(
        id: UUID = UUID(),
        runID: String? = nil,
        mode: BoothSoakTestMode,
        outcome: BoothSoakTestOutcome = .failed,
        subsystemCoverage: [String: String] = [:],
        startedAt: Date,
        finishedAt: Date,
        targetCycles: Int,
        completedCycles: Int,
        failedCycles: Int,
        stoppedCycles: Int? = nil,
        averageCycleDurationSeconds: Double,
        captureSampleCount: Int = 0,
        captureAttemptCount: Int? = nil,
        captureFailureCount: Int? = nil,
        cameraRecoveryCount: Int? = nil,
        minCaptureLatencySeconds: Double,
        avgCaptureLatencySeconds: Double,
        maxCaptureLatencySeconds: Double,
        p50CaptureLatencySeconds: Double? = nil,
        p95CaptureLatencySeconds: Double,
        p99CaptureLatencySeconds: Double? = nil,
        minRenderLatencySeconds: Double?,
        avgRenderLatencySeconds: Double?,
        maxRenderLatencySeconds: Double?,
        p50RenderLatencySeconds: Double? = nil,
        p95RenderLatencySeconds: Double?,
        p99RenderLatencySeconds: Double? = nil,
        firstWindowAverageCycleDurationSeconds: Double? = nil,
        lastWindowAverageCycleDurationSeconds: Double? = nil,
        cycleDurationDegradationPercent: Double? = nil,
        baselineMemoryBytes: UInt64,
        peakMemoryBytes: UInt64,
        finalMemoryBytes: UInt64,
        thermalTransitions: Int,
        reconnectCount: Int?,
        transportReconnectCount: Int? = nil,
        queueFailureCount: Int? = nil,
        invariantViolations: [String],
        summaryVerdict: String,
        environmentSnapshot: [String: String]? = nil,
        configurationSnapshot: [String: String]? = nil
    ) {
        self.id = id
        self.runID = runID
        self.mode = mode
        self.outcome = outcome
        self.subsystemCoverage = subsystemCoverage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.targetCycles = targetCycles
        self.completedCycles = completedCycles
        self.failedCycles = failedCycles
        self.stoppedCycles = stoppedCycles
        self.averageCycleDurationSeconds = averageCycleDurationSeconds
        self.captureSampleCount = captureSampleCount
        self.captureAttemptCount = captureAttemptCount
        self.captureFailureCount = captureFailureCount
        self.cameraRecoveryCount = cameraRecoveryCount
        self.minCaptureLatencySeconds = minCaptureLatencySeconds
        self.avgCaptureLatencySeconds = avgCaptureLatencySeconds
        self.maxCaptureLatencySeconds = maxCaptureLatencySeconds
        self.p50CaptureLatencySeconds = p50CaptureLatencySeconds
        self.p95CaptureLatencySeconds = p95CaptureLatencySeconds
        self.p99CaptureLatencySeconds = p99CaptureLatencySeconds
        self.minRenderLatencySeconds = minRenderLatencySeconds
        self.avgRenderLatencySeconds = avgRenderLatencySeconds
        self.maxRenderLatencySeconds = maxRenderLatencySeconds
        self.p50RenderLatencySeconds = p50RenderLatencySeconds
        self.p95RenderLatencySeconds = p95RenderLatencySeconds
        self.p99RenderLatencySeconds = p99RenderLatencySeconds
        self.firstWindowAverageCycleDurationSeconds = firstWindowAverageCycleDurationSeconds
        self.lastWindowAverageCycleDurationSeconds = lastWindowAverageCycleDurationSeconds
        self.cycleDurationDegradationPercent = cycleDurationDegradationPercent
        self.baselineMemoryBytes = baselineMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.finalMemoryBytes = finalMemoryBytes
        self.thermalTransitions = thermalTransitions
        self.reconnectCount = reconnectCount
        self.transportReconnectCount = transportReconnectCount
        self.queueFailureCount = queueFailureCount
        self.invariantViolations = invariantViolations
        self.summaryVerdict = summaryVerdict
        self.environmentSnapshot = environmentSnapshot
        self.configurationSnapshot = configurationSnapshot
    }

    public static func compute(
        mode: BoothSoakTestMode,
        targetCycles: Int,
        startedAt: Date,
        finishedAt: Date,
        baselineMemory: UInt64,
        metrics: [BoothSoakCycleMetric],
        reconnectCount: Int? = nil,
        invariantViolations: [String] = [],
        requestedOutcome: BoothSoakTestOutcome? = nil,
        subsystemCoverage: [String: String] = [:],
        runID: String? = nil,
        transportReconnectCount: Int? = nil,
        queueFailureCount: Int? = nil,
        environmentSnapshot: [String: String]? = nil,
        configurationSnapshot: [String: String]? = nil
    ) -> BoothSoakTestReport {
        let completed = metrics.filter { $0.errors.isEmpty }.count
        let failed = metrics.count - completed

        let allCaptures = metrics.flatMap { $0.captureLatencies }.sorted()
        let minCapture = allCaptures.first ?? 0
        let maxCapture = allCaptures.last ?? 0
        let avgCapture = allCaptures.isEmpty ? 0 : allCaptures.reduce(0, +) / Double(allCaptures.count)
        let p95Capture = percentile(95, values: allCaptures)
        let p50Capture = percentile(50, values: allCaptures)
        let p99Capture = percentile(99, values: allCaptures)

        let allRenders = metrics.compactMap { $0.renderLatency }.sorted()
        let minRender = allRenders.first
        let maxRender = allRenders.last
        let avgRender = allRenders.isEmpty ? nil : allRenders.reduce(0, +) / Double(allRenders.count)
        let p95Render = allRenders.isEmpty ? nil : percentile(95, values: allRenders)
        let p50Render = allRenders.isEmpty ? nil : percentile(50, values: allRenders)
        let p99Render = allRenders.isEmpty ? nil : percentile(99, values: allRenders)

        let avgDuration = metrics.isEmpty ? 0 : metrics.map(\.durationSeconds).reduce(0, +) / Double(metrics.count)
        let peakMem = metrics.map(\.memoryFootprintBytes).max() ?? baselineMemory
        let finalMem = metrics.last?.memoryFootprintBytes ?? baselineMemory

        let thermalTransitions = zip(metrics, metrics.dropFirst())
            .filter { $0.0.thermalStateRaw != $0.1.thermalStateRaw }
            .count

        let windowSize = max(1, metrics.count / 4)
        let firstWindow = metrics.count < 2 ? [] : Array(metrics.prefix(windowSize))
        let lastWindow = metrics.count < 2 ? [] : Array(metrics.suffix(windowSize))
        let firstWindowAverage = firstWindow.isEmpty ? nil : firstWindow.map(\.durationSeconds).reduce(0, +) / Double(firstWindow.count)
        let lastWindowAverage = lastWindow.isEmpty ? nil : lastWindow.map(\.durationSeconds).reduce(0, +) / Double(lastWindow.count)
        let degradationPercent: Double? = if let firstWindowAverage, let lastWindowAverage, firstWindowAverage > 0 {
            (lastWindowAverage / firstWindowAverage - 1) * 100
        } else {
            nil
        }
        let attemptCounts = metrics.compactMap(\.captureAttemptCount)
        let failureCounts = metrics.compactMap(\.captureFailureCount)
        let recoveryCounts = metrics.compactMap(\.cameraRecoveryCount)

        var violations = invariantViolations
        for metric in metrics {
            violations.append(contentsOf: metric.errors)
        }

        let fullyCompleted = targetCycles > 0
            && metrics.count == targetCycles
            && completed == targetCycles
            && violations.isEmpty
        let outcome: BoothSoakTestOutcome
        let hasCoverageFailures = subsystemCoverage.values.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("FAIL")
        }
        let hasWarnings = subsystemCoverage.values.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("WARNING")
        }
        if failed > 0 || !violations.isEmpty || hasCoverageFailures || requestedOutcome == .failed {
            outcome = .failed
        } else if !fullyCompleted {
            outcome = requestedOutcome == .cancelled ? .cancelled : (requestedOutcome == .stoppedEarly ? .stoppedEarly : .failed)
        } else if hasWarnings {
            outcome = .completedWithWarnings
        } else {
            outcome = .passed
        }
        let verdict: String = switch outcome {
        case .passed:
            "PASSED: All \(completed) cycles completed cleanly."
        case .completedWithWarnings:
            "COMPLETED WITH WARNINGS: All \(completed) cycles completed; review the listed cleanup warnings."
        case .failed:
            "FAILED: Completed \(completed)/\(targetCycles) cycles with \(failed) cycle failures, \(violations.count) violations, and \(hasCoverageFailures ? "one or more subsystem failures" : "no subsystem coverage failures")."
        case .stoppedEarly:
            "STOPPED EARLY: Completed \(completed)/\(targetCycles) cycles at an operator safe point."
        case .cancelled:
            "CANCELLED: Completed \(completed)/\(targetCycles) cycles before cancellation."
        }

        return BoothSoakTestReport(
            runID: runID,
            mode: mode,
            outcome: outcome,
            subsystemCoverage: subsystemCoverage,
            startedAt: startedAt,
            finishedAt: finishedAt,
            targetCycles: targetCycles,
            completedCycles: completed,
            failedCycles: failed,
            stoppedCycles: (outcome == .stoppedEarly || outcome == .cancelled)
                ? max(0, targetCycles - metrics.count)
                : 0,
            averageCycleDurationSeconds: avgDuration,
            captureSampleCount: allCaptures.count,
            captureAttemptCount: attemptCounts.isEmpty ? nil : attemptCounts.reduce(0, +),
            captureFailureCount: failureCounts.isEmpty ? nil : failureCounts.reduce(0, +),
            cameraRecoveryCount: recoveryCounts.isEmpty ? nil : recoveryCounts.reduce(0, +),
            minCaptureLatencySeconds: minCapture,
            avgCaptureLatencySeconds: avgCapture,
            maxCaptureLatencySeconds: maxCapture,
            p50CaptureLatencySeconds: allCaptures.isEmpty ? nil : p50Capture,
            p95CaptureLatencySeconds: p95Capture,
            p99CaptureLatencySeconds: allCaptures.isEmpty ? nil : p99Capture,
            minRenderLatencySeconds: minRender,
            avgRenderLatencySeconds: avgRender,
            maxRenderLatencySeconds: maxRender,
            p50RenderLatencySeconds: p50Render,
            p95RenderLatencySeconds: p95Render,
            p99RenderLatencySeconds: p99Render,
            firstWindowAverageCycleDurationSeconds: firstWindowAverage,
            lastWindowAverageCycleDurationSeconds: lastWindowAverage,
            cycleDurationDegradationPercent: degradationPercent,
            baselineMemoryBytes: baselineMemory,
            peakMemoryBytes: peakMem,
            finalMemoryBytes: finalMem,
            thermalTransitions: thermalTransitions,
            reconnectCount: reconnectCount,
            transportReconnectCount: transportReconnectCount,
            queueFailureCount: queueFailureCount,
            invariantViolations: violations,
            summaryVerdict: verdict,
            environmentSnapshot: environmentSnapshot,
            configurationSnapshot: configurationSnapshot
        )
    }

    private static func percentile(_ p: Int, values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let index = Int(ceil(Double(p) / 100.0 * Double(values.count))) - 1
        return values[max(0, min(values.count - 1, index))]
    }

    public func markdownSummary() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium

        func mb(_ bytes: UInt64) -> String {
            String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
        }
        func mbGrowth(_ bytes: UInt64) -> String {
            String(format: "%+.1f MB", (Double(bytes) - Double(baselineMemoryBytes)) / (1024 * 1024))
        }

        var md = """
        # PRC PhotoBooth Soak Test Report
        - **Report ID**: `\(id.uuidString)`
        - **Run ID**: `\(runID ?? "NOT AVAILABLE")`
        - **Mode**: \(mode.rawValue) — \(mode.description)
        - **Started**: \(formatter.string(from: startedAt))
        - **Finished**: \(formatter.string(from: finishedAt))
        - **Outcome**: **\(outcome.displayName)**
        - **Verdict**: **\(summaryVerdict)**

        ## Summary Statistics
        | Metric | Value |
        | --- | --- |
        | Target Cycles | \(targetCycles) |
        | Completed Cycles | \(completedCycles) |
        | Failed Cycles | \(failedCycles) |
        | Stopped / Unrun Cycles | \(stoppedCycles.map { String($0) } ?? "NOT TESTED") |
        | Capture Attempts | \(captureAttemptCount.map { String($0) } ?? "NOT TESTED") |
        | Captures Succeeded | \(captureSampleCount) |
        | Capture Failures | \(captureFailureCount.map { String($0) } ?? "NOT TESTED") |
        | Camera Recovery Outcomes | \(cameraRecoveryCount.map { String($0) } ?? "NOT TESTED") |
        | Avg Cycle Duration | \(String(format: "%.2f s", averageCycleDurationSeconds)) |
        | First Window Avg Cycle Duration | \(firstWindowAverageCycleDurationSeconds.map { String(format: "%.2f s", $0) } ?? "NOT TESTED") |
        | Last Window Avg Cycle Duration | \(lastWindowAverageCycleDurationSeconds.map { String(format: "%.2f s", $0) } ?? "NOT TESTED") |
        | Cycle Duration Degradation | \(cycleDurationDegradationPercent.map { String(format: "%+.1f%%", $0) } ?? "NOT TESTED") |
        | Baseline Memory | \(mb(baselineMemoryBytes)) |
        | Peak Memory | \(mb(peakMemoryBytes)) |
        | Peak RSS Growth | \(mbGrowth(peakMemoryBytes)) |
        | Final Memory | \(mb(finalMemoryBytes)) |
        | Final RSS Growth | \(mbGrowth(finalMemoryBytes)) |
        | Thermal Transitions | \(thermalTransitions) |
        | Camera Reconnects | \(reconnectCount.map { String($0) } ?? "NOT TESTED") |
        | iPad Transport Reconnects | \(transportReconnectCount.map { String($0) } ?? "NOT TESTED") |
        | Queue Failures | \(queueFailureCount.map { String($0) } ?? "NOT TESTED") |

        ## Latency Benchmarks
        | Operation | Min | Avg | Max | P50 | P95 | P99 |
        | --- | --- | --- | --- | --- | --- | --- |
        """

        if captureSampleCount > 0 {
            md += "\n| Capture | \(String(format: "%.3f s", minCaptureLatencySeconds)) | \(String(format: "%.3f s", avgCaptureLatencySeconds)) | \(String(format: "%.3f s", maxCaptureLatencySeconds)) | \(p50CaptureLatencySeconds.map { String(format: "%.3f s", $0) } ?? "NOT TESTED") | \(String(format: "%.3f s", p95CaptureLatencySeconds)) | \(p99CaptureLatencySeconds.map { String(format: "%.3f s", $0) } ?? "NOT TESTED") |"
        } else {
            md += "\n| Capture | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |"
        }

        if let minR = minRenderLatencySeconds, let avgR = avgRenderLatencySeconds, let maxR = maxRenderLatencySeconds, let p95R = p95RenderLatencySeconds {
            md += "\n| Strip Render | \(String(format: "%.3f s", minR)) | \(String(format: "%.3f s", avgR)) | \(String(format: "%.3f s", maxR)) | \(p50RenderLatencySeconds.map { String(format: "%.3f s", $0) } ?? "NOT TESTED") | \(String(format: "%.3f s", p95R)) | \(p99RenderLatencySeconds.map { String(format: "%.3f s", $0) } ?? "NOT TESTED") |"
        }

        if let environmentSnapshot {
            md += "\n\n## Environment\n| Field | Value |\n| --- | --- |\n"
            for (key, value) in environmentSnapshot.sorted(by: { $0.key < $1.key }) {
                md += "| \(key) | \(value.replacingOccurrences(of: "|", with: "\\|")) |\n"
            }
        }
        if let configurationSnapshot {
            md += "\n## Configuration Snapshot\n| Setting | Value |\n| --- | --- |\n"
            for (key, value) in configurationSnapshot.sorted(by: { $0.key < $1.key }) {
                md += "| \(key) | \(value.replacingOccurrences(of: "|", with: "\\|")) |\n"
            }
        }

        if !subsystemCoverage.isEmpty {
            md += "\n\n## Subsystem Coverage\n| Subsystem | Result |\n| --- | --- |\n"
            for (subsystem, result) in subsystemCoverage.sorted(by: { $0.key < $1.key }) {
                md += "| \(subsystem) | \(result) |\n"
            }
        }

        if !invariantViolations.isEmpty {
            md += "\n\n## Invariant Violations\n"
            for violation in invariantViolations {
                md += "- ⚠️ \(violation)\n"
            }
        }

        return md
    }

    public func jsonRepresentation() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(self)
    }
}
