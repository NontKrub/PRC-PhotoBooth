import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Soak Test Harness")
struct SoakTests {
    @Test("report statistics computation calculates latency and RSS samples")
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
            mode: .syntheticBenchmark,
            targetCycles: 3,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            baselineMemory: 45 * 1024 * 1024,
            metrics: metrics,
            subsystemCoverage: ["Production workflow": "NOT TESTED"]
        )

        #expect(report.outcome == .passed)
        #expect(report.completedCycles == 3)
        #expect(report.failedCycles == 0)
        #expect(report.minCaptureLatencySeconds == 0.100)
        #expect(report.maxCaptureLatencySeconds == 0.250)
        #expect(report.captureSampleCount == 9)
        #expect(report.peakMemoryBytes == 55 * 1024 * 1024)
        #expect(report.baselineMemoryBytes == 45 * 1024 * 1024)
        #expect(report.summaryVerdict.hasPrefix("PASSED"))

        let md = report.markdownSummary()
        #expect(md.contains("PRC PhotoBooth Soak Test Report"))
        #expect(md.contains("Target Cycles | 3"))
        #expect(md.contains("Completed Cycles | 3"))
        #expect(md.contains("Production workflow | NOT TESTED"))
        #expect(md.contains("Run ID**: `NOT AVAILABLE`"))
        #expect(!md.localizedCaseInsensitiveContains("no memory leaks"))
        #expect(report.jsonRepresentation() != nil)
    }

    @Test("complete cycles with cleanup warnings report completed with warnings")
    func cleanupWarningIsNotReportedAsCleanPass() {
        let metric = BoothSoakCycleMetric(
            cycleIndex: 1,
            durationSeconds: 1,
            captureLatencies: [],
            memoryFootprintBytes: 10
        )
        let report = BoothSoakTestReport.compute(
            mode: .productionPipeline,
            targetCycles: 1,
            startedAt: Date().addingTimeInterval(-1),
            finishedAt: Date(),
            baselineMemory: 10,
            metrics: [metric],
            subsystemCoverage: ["Cloud cleanup": "WARNING (remote deletion failed)"],
            runID: "run-123"
        )

        #expect(report.outcome == .completedWithWarnings)
        #expect(report.runID == "run-123")
        #expect(report.outcome.displayName == "Completed with warnings")
        #expect(report.summaryVerdict.hasPrefix("COMPLETED WITH WARNINGS"))
    }

    @Test("subsystem failure cannot coexist with a passed report")
    func subsystemFailureCannotPass() {
        let metric = BoothSoakCycleMetric(
            cycleIndex: 1,
            durationSeconds: 1,
            captureLatencies: [],
            memoryFootprintBytes: 10
        )
        let report = BoothSoakTestReport.compute(
            mode: .productionPipeline,
            targetCycles: 1,
            startedAt: Date().addingTimeInterval(-1),
            finishedAt: Date(),
            baselineMemory: 10,
            metrics: [metric],
            subsystemCoverage: ["Gallery isolation": "FAIL (soak entry was public-visible)"]
        )

        #expect(report.outcome == .failed)
        #expect(report.summaryVerdict.hasPrefix("FAILED"))
    }

    @Test("live shutter count excludes deferred retake and prior-photo recovery records")
    func physicalCaptureCountExcludesLogicalRecoveryRecords() {
        let now = Date()
        let results: [CaptureAttemptResult] = [.success, .transferRecovered, .failed, .retaken, .deferred, .usedPrevious]
        let records = results.enumerated().map { index, result in
            CaptureAttemptRecord(
                id: "attempt-\(index)",
                photoIndex: 0,
                startedAt: now,
                completedAt: now,
                result: result,
                reason: nil,
                receiveDuration: nil
            )
        }
        #expect(BoothSoakCaptureMetrics.physicalCaptureAttemptCount(records) == 3)
    }

    @Test("report includes event evidence percentiles and first-to-last window degradation")
    func reportContainsReleaseEvidence() {
        let metrics = (1...4).map { index in
            BoothSoakCycleMetric(
                cycleIndex: index,
                durationSeconds: Double(index),
                captureLatencies: [Double(index)],
                captureAttemptCount: 1,
                captureFailureCount: 0,
                cameraRecoveryCount: index == 2 ? 1 : 0,
                renderLatency: Double(index) / 2,
                memoryFootprintBytes: UInt64(index * 10)
            )
        }
        let report = BoothSoakTestReport.compute(
            mode: .productionPipeline,
            targetCycles: 4,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            baselineMemory: 8,
            metrics: metrics,
            runID: "run-456",
            environmentSnapshot: ["Camera model": "Sony ZV-E10"],
            configurationSnapshot: ["Target sessions": "4"]
        )

        #expect(report.captureAttemptCount == 4)
        #expect(report.captureSampleCount == 4)
        #expect(report.captureFailureCount == 0)
        #expect(report.cameraRecoveryCount == 1)
        #expect(report.p50CaptureLatencySeconds == 2)
        #expect(report.p99CaptureLatencySeconds == 4)
        #expect(report.firstWindowAverageCycleDurationSeconds == 1)
        #expect(report.lastWindowAverageCycleDurationSeconds == 4)
        #expect(report.cycleDurationDegradationPercent == 300)
        #expect(report.environmentSnapshot?["Camera model"] == "Sony ZV-E10")
        #expect(report.configurationSnapshot?["Target sessions"] == "4")
        #expect(report.markdownSummary().contains("Cycle Duration Degradation | +300.0%"))
    }

    @Test("synthetic benchmark is explicitly scoped and completes its isolated queue")
    func runnerExecutesSyntheticBenchmark() async throws {
        let runner = BoothSoakTestRunner()
        let config = BoothSoakTestConfig(
            mode: .syntheticBenchmark,
            targetCycles: 3,
            delayBetweenCyclesSeconds: 0.01,
            photosPerSession: 2
        )
        let report = try await runner.run(
            config: config,
            captureService: nil,
            coordinator: nil,
            progressHandler: { _ in }
        )

        #expect(report.outcome == .passed)
        #expect(report.completedCycles == 3)
        #expect(report.failedCycles == 0)
        #expect(report.minRenderLatencySeconds != nil)
        #expect(report.subsystemCoverage["Synthetic compositor and queue benchmark"]?.hasPrefix("PASS") == true)
        #expect(report.subsystemCoverage["Camera hardware"] == "NOT TESTED")
        #expect(report.subsystemCoverage["Session workflow, persistence, guest delivery, cloud, physical print, iPad"] == "NOT TESTED")
        #expect(report.captureSampleCount == 0)
        #expect(report.markdownSummary().contains("| Capture | NOT TESTED |"))
    }

    @Test("camera hardware mode rejects a missing live camera")
    func cameraModeRejectsSyntheticFallback() async {
        let runner = BoothSoakTestRunner()
        do {
            _ = try await runner.run(
                config: BoothSoakTestConfig(mode: .cameraHardware, targetCycles: 1),
                captureService: nil,
                coordinator: nil,
                progressHandler: { _ in }
            )
            Issue.record("Camera Hardware mode unexpectedly succeeded without a physical camera.")
        } catch BoothSoakTestError.cameraRequired {
            // Expected: hardware mode has no synthetic capture fallback.
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test("production pipeline mode rejects a missing live coordinator")
    func productionModeRequiresCoordinator() async {
        let runner = BoothSoakTestRunner()
        do {
            _ = try await runner.run(
                config: BoothSoakTestConfig(mode: .productionPipeline, targetCycles: 1),
                captureService: nil,
                coordinator: nil,
                progressHandler: { _ in }
            )
            Issue.record("Production Pipeline mode unexpectedly succeeded without BoothCoordinator.")
        } catch BoothSoakTestError.coordinatorRequired {
            // Expected: production mode cannot fall back to scratch queue work.
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }

    @Test("graceful stop after a complete synthetic cycle is never reported as pass")
    func gracefulStopHasDistinctOutcome() async throws {
        let runner = BoothSoakTestRunner()
        let report = try await runner.run(
            config: BoothSoakTestConfig(mode: .syntheticBenchmark, targetCycles: 3, delayBetweenCyclesSeconds: 0),
            captureService: nil,
            coordinator: nil,
            progressHandler: { state in
                if case .running(let cycle, _, _, _) = state, cycle == 1 {
                    await runner.stopGracefully()
                }
            }
        )

        #expect(report.outcome == .stoppedEarly)
        #expect(report.completedCycles == 1)
        #expect(report.summaryVerdict.hasPrefix("STOPPED EARLY"))
    }

    @Test("cancelled synthetic work does not count a partial cycle as completed")
    func cancellationDoesNotCountPartialCycle() async throws {
        let runner = BoothSoakTestRunner()
        let report = try await runner.run(
            config: BoothSoakTestConfig(mode: .syntheticBenchmark, targetCycles: 3, delayBetweenCyclesSeconds: 0),
            captureService: nil,
            coordinator: nil,
            progressHandler: { state in
                if case .running(let cycle, _, let phase, _) = state,
                   cycle == 1, phase.hasPrefix("Generating") {
                    await runner.cancel()
                }
            }
        )

        #expect(report.outcome == .cancelled)
        #expect(report.completedCycles == 0)
        #expect(report.summaryVerdict.hasPrefix("CANCELLED"))
    }

    @Test("partial reports cannot pass when stopped before the target")
    func partialReportCannotPass() {
        let metric = BoothSoakCycleMetric(
            cycleIndex: 1,
            durationSeconds: 1,
            captureLatencies: [],
            memoryFootprintBytes: 10
        )
        let report = BoothSoakTestReport.compute(
            mode: .productionPipeline,
            targetCycles: 500,
            startedAt: Date().addingTimeInterval(-10),
            finishedAt: Date(),
            baselineMemory: 10,
            metrics: [metric],
            requestedOutcome: .stoppedEarly
        )
        #expect(report.outcome == .stoppedEarly)
        #expect(!report.summaryVerdict.hasPrefix("PASSED"))
    }

    @Test("old soak mode names decode to the explicit new modes")
    func legacyModeNamesRemainReadable() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(BoothSoakTestMode.self, from: Data(#""Camera-Only""#.utf8)) == .cameraHardware)
        #expect(try decoder.decode(BoothSoakTestMode.self, from: Data(#""Full Pipeline""#.utf8)) == .productionPipeline)
    }

    @Test("controller reports physical print warning and requires production coordinator")
    @MainActor
    func controllerWarnsAndBlocksUnboundProductionPrint() {
        let controller = BoothSoakTestController()
        controller.config.mode = .productionPipeline
        controller.config.enablePhysicalPrint = true
        controller.config.physicalPrintEveryCycles = 25
        controller.validatePreflight(coordinator: nil)

        #expect(controller.preflightWarnings.contains(where: { $0.contains("up to 2 real print jobs") }))
        #expect(controller.preflightErrors.contains(where: { $0.contains("live BoothCoordinator") }))
        #expect(!controller.isPreflightValid)
    }
}
