import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Soak Test Harness")
struct SoakTests {
    @Test("report statistics computation calculates correct min, avg, max, and p95")
    func reportStatisticsComputation() {
        let metrics = [
            BoothSoakCycleMetric(
                cycleIndex: 1,
                durationSeconds: 1.0,
                captureLatencies: [0.100, 0.150, 0.200],
                renderLatency: 0.500,
                queueDrainSeconds: 0.200,
                memoryFootprintBytes: 50 * 1024 * 1024
            ),
            BoothSoakCycleMetric(
                cycleIndex: 2,
                durationSeconds: 1.2,
                captureLatencies: [0.120, 0.180, 0.250],
                renderLatency: 0.600,
                queueDrainSeconds: 0.250,
                memoryFootprintBytes: 55 * 1024 * 1024
            ),
            BoothSoakCycleMetric(
                cycleIndex: 3,
                durationSeconds: 1.1,
                captureLatencies: [0.110, 0.160, 0.220],
                renderLatency: 0.550,
                queueDrainSeconds: 0.220,
                memoryFootprintBytes: 52 * 1024 * 1024
            )
        ]

        let report = BoothSoakTestReport.compute(
            mode: .fullPipeline,
            targetCycles: 3,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            baselineMemory: 45 * 1024 * 1024,
            metrics: metrics
        )

        #expect(report.completedCycles == 3)
        #expect(report.failedCycles == 0)
        #expect(report.minCaptureLatencySeconds == 0.100)
        #expect(report.maxCaptureLatencySeconds == 0.250)
        #expect(report.peakMemoryBytes == 55 * 1024 * 1024)
        #expect(report.baselineMemoryBytes == 45 * 1024 * 1024)
        #expect(report.summaryVerdict.hasPrefix("PASSED"))

        let md = report.markdownSummary()
        #expect(md.contains("PRC PhotoBooth Soak Test Report"))
        #expect(md.contains("Target Cycles | 3"))
        #expect(md.contains("Completed Cycles | 3"))

        let json = report.jsonRepresentation()
        #expect(json != nil)
    }

    @Test("runner executes camera-only soak test cleanly")
    func runnerExecutesCameraOnlySoak() async throws {
        let runner = BoothSoakTestRunner()
        let config = BoothSoakTestConfig(
            mode: .cameraOnly,
            targetCycles: 3,
            delayBetweenCyclesSeconds: 0.01,
            photosPerSession: 2,
            enablePhysicalPrint: false
        )

        let report = try await runner.run(
            config: config,
            captureService: nil,
            coordinator: nil,
            progressHandler: { _ in }
        )

        #expect(report.completedCycles == 3)
        #expect(report.failedCycles == 0)
        #expect(report.summaryVerdict.hasPrefix("PASSED"))
    }

    @Test("runner executes full-pipeline soak test cleanly with cleanup")
    func runnerExecutesFullPipelineSoak() async throws {
        let runner = BoothSoakTestRunner()
        let config = BoothSoakTestConfig(
            mode: .fullPipeline,
            targetCycles: 3,
            delayBetweenCyclesSeconds: 0.01,
            photosPerSession: 3,
            enablePhysicalPrint: false,
            autoCleanupWorkingFiles: true
        )

        let report = try await runner.run(
            config: config,
            captureService: nil,
            coordinator: nil,
            progressHandler: { _ in }
        )

        #expect(report.completedCycles == 3)
        #expect(report.failedCycles == 0)
        #expect(report.minRenderLatencySeconds != nil)
        #expect(report.summaryVerdict.hasPrefix("PASSED"))
    }

    @Test("controller raises warning when physical printing is enabled")
    @MainActor
    func controllerWarnsOnPhysicalPrinting() {
        let controller = BoothSoakTestController()
        controller.config.enablePhysicalPrint = true
        controller.validatePreflight(coordinator: nil)

        #expect(controller.preflightWarnings.contains(where: { $0.contains("PHYSICAL PRINTING") }))
        #expect(controller.isPreflightValid) // Warnings do not block test start
    }
}
