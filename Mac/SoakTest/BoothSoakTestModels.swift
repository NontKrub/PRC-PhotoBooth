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
    case running(cycle: Int, total: Int, phase: String)
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
    case failed
    case stoppedEarly
    case cancelled
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
    let renderLatency: Double?
    let queueDrainSeconds: Double?
    let localDeliveryVerified: Bool
    let cloudUploadVerified: Bool
    let physicalPrintVerified: Bool
    let galleryUpdateVerified: Bool
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
    public let outcome: BoothSoakTestOutcome
    public let subsystemCoverage: [String: String]
    public let startedAt: Date
    public let finishedAt: Date
    public let targetCycles: Int
    public let completedCycles: Int
    public let failedCycles: Int

    public let averageCycleDurationSeconds: Double

    public let captureSampleCount: Int
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
    public let reconnectCount: Int?
    public let invariantViolations: [String]
    public let summaryVerdict: String

    public init(
        id: UUID = UUID(),
        mode: BoothSoakTestMode,
        outcome: BoothSoakTestOutcome = .failed,
        subsystemCoverage: [String: String] = [:],
        startedAt: Date,
        finishedAt: Date,
        targetCycles: Int,
        completedCycles: Int,
        failedCycles: Int,
        averageCycleDurationSeconds: Double,
        captureSampleCount: Int = 0,
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
        reconnectCount: Int?,
        invariantViolations: [String],
        summaryVerdict: String
    ) {
        self.id = id
        self.mode = mode
        self.outcome = outcome
        self.subsystemCoverage = subsystemCoverage
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.targetCycles = targetCycles
        self.completedCycles = completedCycles
        self.failedCycles = failedCycles
        self.averageCycleDurationSeconds = averageCycleDurationSeconds
        self.captureSampleCount = captureSampleCount
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
        reconnectCount: Int? = nil,
        invariantViolations: [String] = [],
        requestedOutcome: BoothSoakTestOutcome? = nil,
        subsystemCoverage: [String: String] = [:]
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

        let thermalTransitions = zip(metrics, metrics.dropFirst())
            .filter { $0.0.thermalStateRaw != $0.1.thermalStateRaw }
            .count

        var violations = invariantViolations
        for metric in metrics {
            violations.append(contentsOf: metric.errors)
        }

        let fullyCompleted = targetCycles > 0
            && metrics.count == targetCycles
            && completed == targetCycles
            && violations.isEmpty
        let outcome: BoothSoakTestOutcome
        if failed > 0 || !violations.isEmpty || requestedOutcome == .failed {
            outcome = .failed
        } else if !fullyCompleted {
            outcome = requestedOutcome == .cancelled ? .cancelled : (requestedOutcome == .stoppedEarly ? .stoppedEarly : .failed)
        } else {
            outcome = .passed
        }
        let verdict: String = switch outcome {
        case .passed:
            "PASSED: All \(completed) cycles completed cleanly."
        case .failed:
            "FAILED: Completed \(completed)/\(targetCycles) cycles with \(failed) cycle failures and \(violations.count) violations."
        case .stoppedEarly:
            "STOPPED EARLY: Completed \(completed)/\(targetCycles) cycles at an operator safe point."
        case .cancelled:
            "CANCELLED: Completed \(completed)/\(targetCycles) cycles before cancellation."
        }

        return BoothSoakTestReport(
            mode: mode,
            outcome: outcome,
            subsystemCoverage: subsystemCoverage,
            startedAt: startedAt,
            finishedAt: finishedAt,
            targetCycles: targetCycles,
            completedCycles: completed,
            failedCycles: failed,
            averageCycleDurationSeconds: avgDuration,
            captureSampleCount: allCaptures.count,
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
        func mbGrowth(_ bytes: UInt64) -> String {
            String(format: "%+.1f MB", (Double(bytes) - Double(baselineMemoryBytes)) / (1024 * 1024))
        }

        var md = """
        # PRC PhotoBooth Soak Test Report
        - **Report ID**: `\(id.uuidString)`
        - **Mode**: \(mode.rawValue) — \(mode.description)
        - **Started**: \(formatter.string(from: startedAt))
        - **Finished**: \(formatter.string(from: finishedAt))
        - **Outcome**: **\(outcome.rawValue)**
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
        | Peak RSS Growth | \(mbGrowth(peakMemoryBytes)) |
        | Final Memory | \(mb(finalMemoryBytes)) |
        | Final RSS Growth | \(mbGrowth(finalMemoryBytes)) |
        | Thermal Transitions | \(thermalTransitions) |
        | Camera Reconnects | \(reconnectCount.map { String($0) } ?? "NOT TESTED") |

        ## Latency Benchmarks
        | Operation | Min | Avg | Max | P95 |
        | --- | --- | --- | --- | --- |
        """

        if captureSampleCount > 0 {
            md += "\n| Capture | \(String(format: "%.3f s", minCaptureLatencySeconds)) | \(String(format: "%.3f s", avgCaptureLatencySeconds)) | \(String(format: "%.3f s", maxCaptureLatencySeconds)) | \(String(format: "%.3f s", p95CaptureLatencySeconds)) |"
        } else {
            md += "\n| Capture | NOT TESTED | NOT TESTED | NOT TESTED | NOT TESTED |"
        }

        if let minR = minRenderLatencySeconds, let avgR = avgRenderLatencySeconds, let maxR = maxRenderLatencySeconds, let p95R = p95RenderLatencySeconds {
            md += "\n| Strip Render | \(String(format: "%.3f s", minR)) | \(String(format: "%.3f s", avgR)) | \(String(format: "%.3f s", maxR)) | \(String(format: "%.3f s", p95R)) |"
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
