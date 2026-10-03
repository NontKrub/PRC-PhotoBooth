import Testing
import Foundation

@testable import PRC_PhotoBooth_Mac

@Suite("Soak Test Harness")
struct SoakTests {
    @Test("production soak can choose every enabled valid event template")
    func productionTemplateCandidates() throws {
        let first = EventTemplateDefinition(
            id: "first", name: LocalizedText(english: "First"), photoCount: 1,
            canvasWidth: 400, canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)]
        )
        var second = first
        second.id = "second"
        second.photoCount = 2
        second.slots.append(SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 1))
        var disabled = first
        disabled.id = "disabled"
        disabled.isEnabled = false
        var invalid = first
        invalid.id = "invalid"
        invalid.slots = []
        let document = EventExperienceDocument(
            id: "event", eventID: "event", revision: "revision",
            defaultTemplateID: first.id, guestTemplateSelectionEnabled: false,
            defaultCustomerLanguage: .thai,
            templates: [first, second, disabled, invalid], gallery: EventGalleryConfiguration()
        )
        let candidates = BoothSoakTemplateSelection.candidates(in: document)
        #expect(Set(candidates.map(\.templateID)) == ["first", "second"])
        for selection in candidates {
            #expect(selection.eventID == "event")
            #expect(selection.experienceRevision == "revision")
            #expect(selection.filterID == document.defaultFilterID)
            #expect(selection.language == .thai)
            let validated = try CustomerSelectionValidator().validate(selection, against: document)
            #expect(validated.template.photoCount == (selection.templateID == "first" ? 1 : 2))
        }
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<20 {
            let selection = try #require(candidates.randomElement(using: &generator))
            #expect(["first", "second"].contains(selection.templateID))
        }
    }

    @Test("production soak has no fallback when no template is eligible")
    func productionTemplatesRequireEligibleSelection() {
        var document = EventExperienceDocument(
            id: "event", eventID: "event", defaultTemplateID: "missing",
            templates: [], gallery: EventGalleryConfiguration()
        )
        #expect(BoothSoakTemplateSelection.candidates(in: document).isEmpty)
        let template = EventTemplateDefinition(
            id: "only", name: LocalizedText(english: "Only"), photoCount: 1,
            canvasWidth: 400, canvasHeight: 600,
            slots: [SharedPhotoSlot(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1), photoIndex: 0)]
        )
        document.templates = [template]
        #expect(BoothSoakTemplateSelection.candidates(in: document).map(\.templateID) == ["only"])
        document.allowedFilterIDs = []
        #expect(BoothSoakTemplateSelection.candidates(in: document).isEmpty)
    }

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

    @Test("AppKit job completion does not claim physical paper output was verified")
    func printJobCompletionRequiresOperatorPhysicalVerification() {
        let metric = BoothSoakCycleMetric(
            cycleIndex: 1,
            durationSeconds: 1,
            captureLatencies: [],
            memoryFootprintBytes: 10
        )
        let physicalCoverage = BoothSoakPrintVerification.physicalOutputCoverage(jobCompleted: true)
        let report = BoothSoakTestReport.compute(
            mode: .productionPipeline,
            targetCycles: 1,
            startedAt: Date().addingTimeInterval(-1),
            finishedAt: Date(),
            baselineMemory: 10,
            metrics: [metric],
            subsystemCoverage: [
                "Physical print submission": "PASS (AppKit print job completed)",
                "Physical printing": physicalCoverage
            ]
        )

        #expect(physicalCoverage.hasPrefix("WARNING"))
        #expect(report.outcome == .completedWithWarnings)
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

    @Test("random production retake plans stay within one to four captures")
    func randomProductionRetakePlanStaysInRange() {
        var generator = SystemRandomNumberGenerator()
        for photoCount in 1...8 {
            for _ in 0..<100 {
                let plan = BoothSoakRetakePlan.random(photoCount: photoCount, using: &generator)
                #expect(plan.countsByPhoto.count == photoCount)
                #expect((1...4).contains(plan.totalCount))
                #expect(plan.countsByPhoto.allSatisfy { $0 >= 0 })
            }
        }
    }

    @Test("production retake plan requires the saved counts and every replacement capture")
    func productionRetakeRequiresReplacementCaptures() {
        let now = Date()
        let plan = BoothSoakRetakePlan(countsByPhoto: [2, 0, 1])
        let attempts = [0, 0, 0, 1, 2, 2].enumerated().map { index, photoIndex in
            CaptureAttemptRecord(
                id: "capture-\(index)", photoIndex: photoIndex,
                startedAt: now, completedAt: now,
                result: .success, reason: nil, receiveDuration: nil
            )
        }
        #expect(!plan.verified(recordedCounts: [1, 0, 1], attempts: attempts))
        #expect(!plan.verified(recordedCounts: [2, 0, 1], attempts: Array(attempts.dropLast())))
        #expect(plan.verified(recordedCounts: [2, 0, 1], attempts: attempts))
    }

    @Test("report includes event evidence percentiles and first-to-last window degradation")
    func reportContainsReleaseEvidence() {
        var metrics: [BoothSoakCycleMetric] = []
        for index in 1...4 {
            let duration = Double(index)
            let cameraRecoveryCount = index == 2 ? 1 : 0
            let memoryFootprint = UInt64(index * 10)
            metrics.append(BoothSoakCycleMetric(
                cycleIndex: index,
                durationSeconds: duration,
                captureLatencies: [duration],
                captureAttemptCount: 1,
                captureFailureCount: 0,
                cameraRecoveryCount: cameraRecoveryCount,
                renderLatency: duration / 2,
                memoryFootprintBytes: memoryFootprint
            ))
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

    @Test("100 synthetic compositor and queue cycles report resident-memory trend")
    func runnerExecutesHundredSyntheticCycles() async throws {
        let runner = BoothSoakTestRunner()
        let memory = SoakMemorySamples()
        let report = try await runner.run(
            config: BoothSoakTestConfig(
                mode: .syntheticBenchmark,
                targetCycles: 100,
                delayBetweenCyclesSeconds: 0,
                photosPerSession: 3
            ),
            captureService: nil,
            coordinator: nil,
            progressHandler: { state in
                guard case .running(let cycle, _, let phase, _) = state,
                      phase.hasPrefix("Starting synthetic benchmark cycle") else { return }
                memory.append(cycle: cycle, bytes: BoothSoakTestRunner.currentResidentMemoryBytes())
            }
        )

        let samples = memory.values
        #expect(report.outcome == .passed)
        #expect(report.completedCycles == 100)
        #expect(report.failedCycles == 0)
        #expect(samples.count == 100)
        guard samples.count == 100 else { return }

        let firstWindow = samples.prefix(10).map(\.bytes)
        let lastWindow = samples.suffix(10).map(\.bytes)
        let firstAverage = firstWindow.reduce(UInt64.zero, +) / UInt64(firstWindow.count)
        let lastAverage = lastWindow.reduce(UInt64.zero, +) / UInt64(lastWindow.count)
        let elapsed = report.finishedAt.timeIntervalSince(report.startedAt)
        print("Synthetic soak: cycles=\(report.completedCycles), seconds=\(elapsed), baselineRSS=\(report.baselineMemoryBytes), peakRSS=\(report.peakMemoryBytes), finalRSS=\(report.finalMemoryBytes), startWindowRSS=\(firstAverage), endWindowRSS=\(lastAverage)")
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

private final class SoakMemorySamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(cycle: Int, bytes: UInt64)] = []

    var values: [(cycle: Int, bytes: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    func append(cycle: Int, bytes: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        samples.append((cycle, bytes))
    }
}
