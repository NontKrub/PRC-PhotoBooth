import Foundation

public enum BoothSoakTestMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case cameraOnly = "Camera-Only"
    case fullPipeline = "Full Pipeline"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .cameraOnly:
            return "Repeatedly triggers camera capture to exercise hardware shutter, transfer, buffer recycling, and thermal stability."
        case .fullPipeline:
            return "Simulates complete customer sessions: capture, review, compositing, GIF generation, job queue processing, and local delivery."
        }
    }
}

public struct BoothSoakTestConfig: Codable, Sendable, Equatable {
    public var mode: BoothSoakTestMode
    public var targetCycles: Int
    public var delayBetweenCyclesSeconds: Double
    public var photosPerSession: Int
    public var enablePhysicalPrint: Bool
    public var autoCleanupWorkingFiles: Bool

    public init(
        mode: BoothSoakTestMode = .fullPipeline,
        targetCycles: Int = 50,
        delayBetweenCyclesSeconds: Double = 1.0,
        photosPerSession: Int = 3,
        enablePhysicalPrint: Bool = false,
        autoCleanupWorkingFiles: Bool = true
    ) {
        self.mode = mode
        self.targetCycles = targetCycles
        self.delayBetweenCyclesSeconds = delayBetweenCyclesSeconds
        self.photosPerSession = photosPerSession
        self.enablePhysicalPrint = enablePhysicalPrint
        self.autoCleanupWorkingFiles = autoCleanupWorkingFiles
    }
}

public enum BoothSoakTestState: Sendable, Equatable {
    case idle
    case preflight(message: String)
    case running(cycle: Int, total: Int, phase: String)
    case stopping(reason: String)
    case completed(report: BoothSoakTestReport)
    case failed(error: String, partialReport: BoothSoakTestReport?)

    public var isRunning: Bool {
        switch self {
        case .preflight, .running, .stopping:
            return true
        case .idle, .completed, .failed:
            return false
        }
    }
}

public struct BoothSoakCycleMetric: Codable, Sendable, Equatable {
    public let cycleIndex: Int
    public let durationSeconds: Double
    public let captureLatencies: [Double]
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
    public let mode: BoothSoakTestMode
    public let startedAt: Date
    public let finishedAt: Date
    public let targetCycles: Int
    public let completedCycles: Int
    public let failedCycles: Int

    public let averageCycleDurationSeconds: Double

    public let minCaptureLatencySeconds: Double
    public let avgCaptureLatencySeconds: Double
    public let maxCaptureLatencySeconds: Double
    public let p95CaptureLatencySeconds: Double

    public let minRenderLatencySeconds: Double?
    public let avgRenderLatencySeconds: Double?
    public let maxRenderLatencySeconds: Double?
    public let p95RenderLatencySeconds: Double?

    public let baselineMemoryBytes: UInt64
    public let peakMemoryBytes: UInt64
    public let finalMemoryBytes: UInt64

    public let thermalTransitions: Int
    public let reconnectCount: Int
    public let invariantViolations: [String]
    public let summaryVerdict: String

    public init(
        id: UUID = UUID(),
        mode: BoothSoakTestMode,
        startedAt: Date,
        finishedAt: Date,
        targetCycles: Int,
        completedCycles: Int,
        failedCycles: Int,
        averageCycleDurationSeconds: Double,
        minCaptureLatencySeconds: Double,
        avgCaptureLatencySeconds: Double,
        maxCaptureLatencySeconds: Double,
        p95CaptureLatencySeconds: Double,
        minRenderLatencySeconds: Double?,
        avgRenderLatencySeconds: Double?,
        maxRenderLatencySeconds: Double?,
        p95RenderLatencySeconds: Double?,
        baselineMemoryBytes: UInt64,
        peakMemoryBytes: UInt64,
        finalMemoryBytes: UInt64,
        thermalTransitions: Int,
        reconnectCount: Int,
        invariantViolations: [String],
        summaryVerdict: String
    ) {
        self.id = id
        self.mode = mode
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.targetCycles = targetCycles
        self.completedCycles = completedCycles
        self.failedCycles = failedCycles
        self.averageCycleDurationSeconds = averageCycleDurationSeconds
        self.minCaptureLatencySeconds = minCaptureLatencySeconds
        self.avgCaptureLatencySeconds = avgCaptureLatencySeconds
        self.maxCaptureLatencySeconds = maxCaptureLatencySeconds
        self.p95CaptureLatencySeconds = p95CaptureLatencySeconds
        self.minRenderLatencySeconds = minRenderLatencySeconds
        self.avgRenderLatencySeconds = avgRenderLatencySeconds
        self.maxRenderLatencySeconds = maxRenderLatencySeconds
        self.p95RenderLatencySeconds = p95RenderLatencySeconds
        self.baselineMemoryBytes = baselineMemoryBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.finalMemoryBytes = finalMemoryBytes
        self.thermalTransitions = thermalTransitions
        self.reconnectCount = reconnectCount
        self.invariantViolations = invariantViolations
        self.summaryVerdict = summaryVerdict
    }

    public static func compute(
        mode: BoothSoakTestMode,
        targetCycles: Int,
        startedAt: Date,
        finishedAt: Date,
        baselineMemory: UInt64,
        metrics: [BoothSoakCycleMetric],
        reconnectCount: Int = 0,
        invariantViolations: [String] = []
    ) -> BoothSoakTestReport {
        let completed = metrics.filter { $0.errors.isEmpty }.count
        let failed = metrics.count - completed

        let allCaptures = metrics.flatMap { $0.captureLatencies }.sorted()
        let minCapture = allCaptures.first ?? 0
        let maxCapture = allCaptures.last ?? 0
        let avgCapture = allCaptures.isEmpty ? 0 : allCaptures.reduce(0, +) / Double(allCaptures.count)
        let p95Capture = percentile(95, values: allCaptures)

        let allRenders = metrics.compactMap { $0.renderLatency }.sorted()
        let minRender = allRenders.first
        let maxRender = allRenders.last
        let avgRender = allRenders.isEmpty ? nil : allRenders.reduce(0, +) / Double(allRenders.count)
        let p95Render = allRenders.isEmpty ? nil : percentile(95, values: allRenders)

        let avgDuration = metrics.isEmpty ? 0 : metrics.map(\.durationSeconds).reduce(0, +) / Double(metrics.count)
        let peakMem = metrics.map(\.memoryFootprintBytes).max() ?? baselineMemory
        let finalMem = metrics.last?.memoryFootprintBytes ?? baselineMemory

        let thermalTransitions = Set(metrics.map(\.thermalStateRaw)).count > 1 ? Set(metrics.map(\.thermalStateRaw)).count - 1 : 0

        var violations = invariantViolations
        for metric in metrics {
            violations.append(contentsOf: metric.errors)
        }

        let isPass = failed == 0 && completed >= targetCycles && violations.isEmpty
        let verdict = isPass
            ? "PASSED: All \(completed) cycles completed cleanly without memory leaks or invariant violations."
            : "FAILED: Completed \(completed)/\(targetCycles) cycles with \(failed) cycle failures and \(violations.count) violations."

        return BoothSoakTestReport(
            mode: mode,
            startedAt: startedAt,
            finishedAt: finishedAt,
            targetCycles: targetCycles,
            completedCycles: completed,
            failedCycles: failed,
            averageCycleDurationSeconds: avgDuration,
            minCaptureLatencySeconds: minCapture,
            avgCaptureLatencySeconds: avgCapture,
            maxCaptureLatencySeconds: maxCapture,
            p95CaptureLatencySeconds: p95Capture,
            minRenderLatencySeconds: minRender,
            avgRenderLatencySeconds: avgRender,
            maxRenderLatencySeconds: maxRender,
            p95RenderLatencySeconds: p95Render,
            baselineMemoryBytes: baselineMemory,
            peakMemoryBytes: peakMem,
            finalMemoryBytes: finalMem,
            thermalTransitions: thermalTransitions,
            reconnectCount: reconnectCount,
            invariantViolations: violations,
            summaryVerdict: verdict
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

        var md = """
        # PRC PhotoBooth Soak Test Report
        - **Report ID**: `\(id.uuidString)`
        - **Mode**: \(mode.rawValue)
        - **Started**: \(formatter.string(from: startedAt))
        - **Finished**: \(formatter.string(from: finishedAt))
        - **Verdict**: **\(summaryVerdict)**

        ## Summary Statistics
        | Metric | Value |
        | --- | --- |
        | Target Cycles | \(targetCycles) |
        | Completed Cycles | \(completedCycles) |
        | Failed Cycles | \(failedCycles) |
        | Avg Cycle Duration | \(String(format: "%.2f s", averageCycleDurationSeconds)) |
        | Baseline Memory | \(mb(baselineMemoryBytes)) |
        | Peak Memory | \(mb(peakMemoryBytes)) |
        | Final Memory | \(mb(finalMemoryBytes)) |
        | Thermal Transitions | \(thermalTransitions) |
        | Camera Reconnects | \(reconnectCount) |

        ## Latency Benchmarks
        | Operation | Min | Avg | Max | P95 |
        | --- | --- | --- | --- | --- |
        | Capture | \(String(format: "%.3f s", minCaptureLatencySeconds)) | \(String(format: "%.3f s", avgCaptureLatencySeconds)) | \(String(format: "%.3f s", maxCaptureLatencySeconds)) | \(String(format: "%.3f s", p95CaptureLatencySeconds)) |
        """

        if let minR = minRenderLatencySeconds, let avgR = avgRenderLatencySeconds, let maxR = maxRenderLatencySeconds, let p95R = p95RenderLatencySeconds {
            md += "\n| Strip Render | \(String(format: "%.3f s", minR)) | \(String(format: "%.3f s", avgR)) | \(String(format: "%.3f s", maxR)) | \(String(format: "%.3f s", p95R)) |"
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
